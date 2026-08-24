defmodule PumbleAutomation.Executions.Nodes.HttpRequest do
  @moduledoc """
  Renders an approved HTTP node into a bounded request and runs it.

  Templates expand against the execution tree. Secret placeholders stay
  placeholders until every other check has passed — including URL policy —
  and are substituted only into the bytes that will be written. The
  diagnostic summary never carries those values, and `Inspect` omits the
  wire headers and body.

  Live evaluation follows at most three redirects. Each Location is merged
  against the current URL, then independently pinned. Credentials never
  follow an origin change. GET/HEAD timeouts retry; a write timeout after
  bytes may have been sent pauses unless a remote idempotency header is set.
  """

  alias PumbleAutomation.Connections.Connection
  alias PumbleAutomation.Connections.ResolvedConnection
  alias PumbleAutomation.Connections.Resolver
  alias PumbleAutomation.Connections.SafeHttp
  alias PumbleAutomation.Connections.SecretResolver
  alias PumbleAutomation.Connections.UrlPolicy
  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Context
  alias PumbleAutomation.Executions.Outcome
  alias PumbleAutomation.Workflows.HttpExtraction
  alias PumbleAutomation.Workflows.Templates

  @telemetry_event [:pumble_automation, :executions, :http_action]

  @derive {Inspect, except: [:headers, :body]}
  defstruct [
    :method,
    :url,
    :path,
    :headers,
    :body,
    :body_mode,
    :content_type,
    :target,
    :timeout_ms,
    :effect_key,
    :idempotency_header,
    :secret_header_names,
    :prior_unsafe_write,
    :prior_remote_status,
    :summary
  ]

  @type t :: %__MODULE__{
          method: String.t(),
          url: String.t(),
          path: String.t(),
          headers: [{String.t(), String.t()}],
          body: binary() | nil,
          body_mode: :json | :text | :form | nil,
          content_type: String.t() | nil,
          target: UrlPolicy.t() | nil,
          timeout_ms: pos_integer(),
          effect_key: String.t() | nil,
          idempotency_header: String.t() | nil,
          secret_header_names: [String.t()],
          prior_unsafe_write: boolean() | nil,
          prior_remote_status: integer() | nil,
          summary: map()
        }

  @methods %{
    "get" => "GET",
    "head" => "HEAD",
    "post" => "POST",
    "put" => "PUT",
    "patch" => "PATCH",
    "delete" => "DELETE"
  }

  @modes %{"json" => :json, "text" => :text, "form" => :form}

  @content_types %{
    json: "application/json",
    text: "text/plain; charset=utf-8",
    form: "application/x-www-form-urlencoded"
  }

  @content_type_modes %{
    "application/json" => :json,
    "text/plain" => :text,
    "application/x-www-form-urlencoded" => :form
  }

  @blocked_headers MapSet.new(["accept-encoding" | Connection.blocked_headers()])
  @placeholder ~r/\{\{secret\.([A-Z][A-Z0-9_]{0,63})\}\}/
  @max_url_bytes 16 * 1024
  @max_timeout_ms 120_000
  @bodyless ~w(GET HEAD DELETE)

  @doc """
  Builds a bounded HTTP request from runner `input`.

  Options:

    * `:connection` — a `ResolvedConnection` (skips the database)
    * `:dns_resolver`, `:allow_http`, `:now` — forwarded to URL policy
    * `:secrets` — `%{name => plaintext}` used instead of `SecretResolver`
    * `:secrets_by_id` — `%{secret_id => plaintext}` for connection headers
  """
  @spec build(map(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def build(input, opts \\ []) when is_map(input) and is_list(opts) do
    config = config(input)
    tree = Context.tree(input)
    dry_run? = dry_run?(input)

    with {:ok, method} <- method(config),
         {:ok, connection} <- load_connection(input, config, opts),
         {:ok, url_text} <- render_optional(config["url"], tree, "url"),
         {:ok, node_path} <- render_optional(config["path"], tree, "path"),
         {:ok, query} <- render_query(config, tree),
         {:ok, url, path} <- combine(connection, url_text, node_path, query),
         :ok <- check_scheme(config, url),
         {:ok, body_mode} <- body_mode(config, method),
         {:ok, rendered_body} <- render_body(config, tree, body_mode, method),
         {:ok, body_mode} <- infer_mode(body_mode, rendered_body),
         {:ok, headers} <- render_headers(config, connection, tree),
         secret_header_names = secret_header_names(headers, connection),
         :ok <- bound_headers(headers),
         :ok <- bound_rendered_body(rendered_body),
         {:ok, secrets} <- load_secrets(input, connection, headers, rendered_body, opts, dry_run?),
         {:ok, target} <- approve_url(url, dry_run?, opts),
         {:ok, body} <- fill_body(rendered_body, body_mode, secrets),
         :ok <- bound_bytes(body, :request_too_large, "The HTTP request body is too large."),
         {:ok, headers, content_type, idempotency} <-
           finalize_headers(headers, connection, secrets, body_mode, body, input, config) do
      {:ok,
       finish(%{
         method: method,
         url: url,
         path: path,
         headers: headers,
         body: body,
         body_mode: body_mode,
         content_type: content_type,
         target: target,
         input: input,
         config: config,
         idempotency: idempotency,
         secret_header_names: secret_header_names,
         dry_run?: dry_run?
       })}
    end
  end

  @doc "The map `PumbleAutomation.Connections.SafeHttp.request/3` expects."
  @spec transport_request(t()) :: %{
          method: String.t(),
          path: String.t(),
          headers: [{String.t(), String.t()}],
          body: binary() | nil
        }
  def transport_request(%__MODULE__{} = request) do
    %{method: request.method, path: request.path, headers: request.headers, body: request.body}
  end

  @doc """
  Builds, optionally follows redirects, captures a bounded response, and
  extracts configured JSON fields.

  Options are the builder options plus `:connect`, `:transport_opts`,
  `:max_body_bytes`, and `:timeout_ms`.
  """
  @spec run(map(), keyword()) :: {:ok, Outcome.t()} | {:error, Error.t()}
  def run(input, opts \\ []) when is_map(input) and is_list(opts) do
    started_at = System.monotonic_time()

    result =
      case build(input, opts) do
        {:ok, request} -> dispatch_built(request, input, opts)
        {:error, %Error{} = error} -> from_error(error, request_stub(input), input)
      end

    emit(input, started_at, result)
    result
  end

  defp dispatch_built(request, input, opts) do
    if dry_run?(input) do
      dry_run_outcome(request, input)
    else
      exchange(request, input, opts, 0)
    end
  end

  defp emit(input, started_at, result) do
    duration = System.monotonic_time() - started_at
    {status, error_class} = result_status(result)

    :telemetry.execute(@telemetry_event, %{duration: duration}, %{
      operation: "http.action",
      installation_id: Map.get(input, :installation_id),
      run_mode: Map.get(input, :run_mode),
      status: status,
      error_class: error_class,
      duration_ms: System.convert_time_unit(duration, :native, :millisecond)
    })
  end

  defp result_status({:ok, %Outcome{kind: kind, error_class: error_class}}) do
    {kind, error_class}
  end

  defp result_status({:error, %Error{class: class, code: code}}) do
    {code, class}
  end

  defp dry_run_outcome(request, input) do
    Outcome.new(%{
      kind: :success,
      edge: Outcome.linear(),
      output:
        %{
          "dry_run" => true,
          "adapter" => "HTTP",
          "method" => String.downcase(request.method),
          "url" => request.url,
          "header_names" => request.summary["header_names"] || [],
          "body_bytes" => request.summary["body_bytes"] || 0
        }
        |> put_present("connection_id", request.summary["connection_id"])
        |> put_present("effect_key", Map.get(input, :effect_key))
    })
  end

  defp exchange(request, input, opts, hops) do
    transport_opts = transport_opts(request, opts)

    case SafeHttp.request(request.target, transport_request(request), transport_opts) do
      {:ok, response} ->
        handle_response(request, input, opts, hops, response)

      {:error, %Error{} = error} ->
        from_error(error, request, input)
    end
  end

  defp handle_response(request, input, opts, hops, response) do
    if SafeHttp.redirect_status?(response.status) do
      request = remember_redirect_response(request, input, response.status)
      follow_redirect(request, input, opts, hops, response)
    else
      finish_response(request, input, hops, response)
    end
  end

  defp remember_redirect_response(request, input, status) do
    %{
      request
      | prior_unsafe_write:
          prior_unsafe_write?(request) or not idempotent_effect?(request, input),
        prior_remote_status: status
    }
  end

  defp follow_redirect(request, input, opts, hops, response) do
    if hops >= SafeHttp.max_redirects() do
      from_error(
        Error.new(:validation, :too_many_redirects,
          message: "The HTTP request followed too many redirects."
        ),
        request,
        input,
        remote_response_evidence(response)
      )
    else
      with {:ok, next_url} <- SafeHttp.location(request.url, response.headers),
           {:ok, target} <- approve_url(next_url, false, opts),
           {:ok, next} <- redirect_request(request, response.status, next_url, target) do
        exchange(next, input, opts, hops + 1)
      else
        {:error, %Error{} = error} ->
          from_error(error, request, input, remote_response_evidence(response))
      end
    end
  end

  defp remote_response_evidence(response) do
    %{"remote_status" => response.status}
  end

  defp redirect_request(request, status, next_url, target) do
    {method, body} = redirect_method(request.method, request.body, status)
    same_origin? = same_origin?(request.url, next_url)
    keep_idempotency? = same_origin? and status in [307, 308]

    headers =
      redirect_headers(
        request.headers,
        request.url,
        next_url,
        body,
        request.idempotency_header,
        keep_idempotency?,
        request.secret_header_names
      )

    with :ok <- allow_method_preserving_redirect(request.method, status, same_origin?),
         {:ok, path} <- request_path(next_url) do
      {:ok,
       %{
         request
         | method: method,
           url: next_url,
           path: path,
           headers: headers,
           body: body,
           content_type: if(body, do: request.content_type, else: nil),
           idempotency_header: if(keep_idempotency?, do: request.idempotency_header, else: nil),
           secret_header_names: if(same_origin?, do: request.secret_header_names, else: []),
           target: target
       }}
    end
  end

  defp allow_method_preserving_redirect(method, status, false)
       when status in [307, 308] and method not in ["GET", "HEAD"] do
    {:error,
     fail(
       :cross_origin_write_redirect,
       "A write request may not follow a method-preserving redirect to another origin."
     )}
  end

  defp allow_method_preserving_redirect(_method, _status, _same_origin?), do: :ok

  defp redirect_method(method, _body, status) when status in [301, 302] do
    if method in ["GET", "HEAD"], do: {method, nil}, else: {"GET", nil}
  end

  defp redirect_method(_method, _body, 303), do: {"GET", nil}
  defp redirect_method(method, body, status) when status in [307, 308], do: {method, body}
  defp redirect_method(method, body, _status), do: {method, body}

  defp redirect_headers(
         headers,
         from_url,
         to_url,
         body,
         idempotency_header,
         keep_idempotency?,
         secret_header_names
       ) do
    headers
    |> maybe_strip_credentials(from_url, to_url, secret_header_names)
    |> maybe_drop_body_headers(body)
    |> maybe_drop_idempotency(idempotency_header, keep_idempotency?)
  end

  defp maybe_drop_idempotency(headers, nil, _keep?), do: headers
  defp maybe_drop_idempotency(headers, _name, true), do: headers

  defp maybe_drop_idempotency(headers, name, false) do
    Enum.reject(headers, fn {header, _value} ->
      String.downcase(header) == String.downcase(name)
    end)
  end

  defp maybe_strip_credentials(headers, from_url, to_url, secret_header_names) do
    if same_origin?(from_url, to_url) do
      headers
    else
      Enum.reject(headers, fn {name, _value} ->
        credential_header?(name) or secret_header?(name, secret_header_names)
      end)
    end
  end

  defp secret_header?(name, secret_header_names) when is_binary(name) do
    String.downcase(name) in List.wrap(secret_header_names)
  end

  defp secret_header?(_name, _secret_header_names), do: false

  defp maybe_drop_body_headers(headers, nil) do
    Enum.reject(headers, fn {name, _value} -> String.downcase(name) == "content-type" end)
  end

  defp maybe_drop_body_headers(headers, _body), do: headers

  defp same_origin?(left, right) do
    a = URI.parse(left)
    b = URI.parse(right)

    String.downcase(to_string(a.scheme)) == String.downcase(to_string(b.scheme)) and
      String.downcase(to_string(a.host)) == String.downcase(to_string(b.host)) and
      effective_port(a) == effective_port(b)
  end

  defp effective_port(%URI{port: port}) when is_integer(port), do: port
  defp effective_port(%URI{scheme: "https"}), do: 443
  defp effective_port(%URI{scheme: "http"}), do: 80
  defp effective_port(_uri), do: nil

  defp credential_header?(name) when is_binary(name) do
    key = String.downcase(name)

    key in ["authorization", "cookie", "proxy-authorization"] or
      Regex.match?(Error.secret_key_pattern(), key)
  end

  defp credential_header?(_name), do: false

  defp request_path(url) when is_binary(url) do
    uri = URI.parse(url)
    path = uri.path || "/"
    path = if uri.query in [nil, ""], do: path, else: path <> "?" <> uri.query

    if String.starts_with?(path, "/") do
      {:ok, path}
    else
      {:error, fail(:malformed_redirect, "The redirect Location is not valid.")}
    end
  end

  defp finish_response(request, input, hops, response) do
    config = config(input)

    if success_status?(response.status, config) do
      capture_success(request, input, hops, response, config)
    else
      status_failure(request, input, hops, response, config)
    end
  end

  defp success_status?(status, config) do
    status in success_range(config)
  end

  defp success_range(config) do
    case Map.get(config, "success_status") || Map.get(config, "success_statuses") do
      nil -> 200..299
      value -> parse_success_range(value)
    end
  end

  defp parse_success_range(value) when is_integer(value) and value in 100..599, do: [value]

  defp parse_success_range(values) when is_list(values) do
    Enum.flat_map(values, fn
      status when is_integer(status) and status in 100..599 -> [status]
      other -> parse_success_range(other)
    end)
  end

  defp parse_success_range(value) when is_binary(value) do
    case String.split(value, "-", parts: 2) do
      [from, to] ->
        with {low, ""} <- Integer.parse(String.trim(from)),
             {high, ""} <- Integer.parse(String.trim(to)),
             true <- low in 100..599 and high in 100..599 and low <= high do
          Enum.to_list(low..high)
        else
          _other -> 200..299
        end

      [one] ->
        case Integer.parse(String.trim(one)) do
          {status, ""} when status in 100..599 -> [status]
          _other -> 200..299
        end
    end
  end

  defp parse_success_range(_value), do: 200..299

  defp capture_success(request, input, hops, response, config) do
    case maybe_extract(response.body, config) do
      {:ok, extracted} ->
        Outcome.new(%{
          kind: :success,
          edge: Outcome.linear(),
          output: success_output(request, input, hops, response, extracted)
        })

      {:error, %Error{} = error} ->
        evidence =
          response
          |> remote_response_evidence()
          |> put_extraction_duplicate_risk(request, input)

        from_error(error, request, input, evidence)
    end
  end

  defp put_extraction_duplicate_risk(evidence, request, input) do
    if effect_chain_idempotent?(request, input) do
      evidence
    else
      Map.put(evidence, "duplicate_risk", true)
    end
  end

  defp maybe_extract(body, config) do
    case extract_fields(config) do
      fields when fields == %{} -> {:ok, %{}}
      fields -> HttpExtraction.extract(body, fields)
    end
  end

  defp extract_fields(config) do
    case Map.get(config, "extract") || Map.get(config, "response_extract") do
      fields when is_map(fields) and not is_struct(fields) -> fields
      _other -> %{}
    end
  end

  defp success_output(_request, input, hops, response, extracted) do
    %{
      "status" => response.status,
      "ok" => true,
      "headers" => SafeHttp.captured_headers(response.headers),
      "body_bytes" => byte_size(response.body),
      "body_sha256" => SafeHttp.body_digest(response.body),
      "body_excerpt" => SafeHttp.excerpt(response.body),
      "redirects" => hops
    }
    |> put_present("effect_key", Map.get(input, :effect_key))
    |> put_extracted(extracted)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp put_extracted(output, extracted) when extracted == %{}, do: output
  defp put_extracted(output, extracted), do: Map.put(output, "extracted", extracted)

  defp status_failure(request, input, hops, response, _config) do
    {kind, class, message} = status_class(response.status, request, input)

    Outcome.new(%{
      kind: kind,
      error_class: class,
      message: message,
      output:
        %{
          "status" => response.status,
          "ok" => false,
          "headers" => SafeHttp.captured_headers(response.headers),
          "body_bytes" => byte_size(response.body),
          "body_sha256" => SafeHttp.body_digest(response.body),
          "body_excerpt" => SafeHttp.excerpt(response.body),
          "redirects" => hops
        }
        |> put_prior_duplicate_risk(request)
        |> put_present("effect_key", Map.get(input, :effect_key))
        |> put_retry_after(response.headers)
    })
  end

  defp status_class(401, _request, _input) do
    {:permanent_error, "authentication", "The HTTP credential was rejected."}
  end

  defp status_class(403, _request, _input) do
    {:permanent_error, "authorization", "The HTTP request is not allowed."}
  end

  defp status_class(404, _request, _input) do
    {:permanent_error, "not_found", "The HTTP target does not exist."}
  end

  defp status_class(409, _request, _input) do
    {:permanent_error, "conflict", "The HTTP target is in a conflicting state."}
  end

  defp status_class(429, request, input) do
    if effect_chain_idempotent?(request, input) do
      {:retryable_error, "rate_limited", "The remote host asked this request to wait."}
    else
      {:uncertain, "side_effect_uncertain", "The HTTP write may have been delivered."}
    end
  end

  defp status_class(status, request, input) when status in 500..599 do
    if effect_chain_idempotent?(request, input) do
      {:retryable_error, "remote_transient", "The remote host returned a temporary error."}
    else
      {:uncertain, "side_effect_uncertain", "The HTTP write may have been delivered."}
    end
  end

  defp status_class(_status, _request, _input) do
    {:permanent_error, "remote_permanent", "The remote host rejected this request."}
  end

  defp idempotent_effect?(%__MODULE__{} = request, _input) do
    request.method in ["GET", "HEAD"] or present?(request.idempotency_header)
  end

  defp effect_chain_idempotent?(request, input) do
    not prior_unsafe_write?(request) and idempotent_effect?(request, input)
  end

  defp prior_unsafe_write?(%__MODULE__{prior_unsafe_write: true}), do: true
  defp prior_unsafe_write?(%__MODULE__{}), do: false

  defp from_error(%Error{} = error, request, input, response_evidence \\ %{}) do
    {kind, class} = error_kind(error, request, input)

    Outcome.new(%{
      kind: kind,
      error_class: class,
      message: error.message,
      output:
        response_evidence
        |> put_prior_remote_status(request)
        |> put_prior_duplicate_risk(request)
        |> put_present("effect_key", Map.get(input, :effect_key))
        |> put_detail(error.details, :field, "field")
        |> put_detail(error.details, :path, "path")
        |> put_detail(error.details, :phase, "phase")
        |> put_boolean_detail(error.details, :request_written?, "request_written")
    })
  end

  defp error_kind(%Error{} = error, request, input) do
    cond do
      unsafe_response_policy_failure?(error, request, input) ->
        {:uncertain, "side_effect_uncertain"}

      oversized_response?(error) ->
        {:permanent_error, "resource_limit"}

      ambiguous_write_failure?(error, request, input) ->
        {:uncertain, "ambiguous_transport"}

      error.class in [:timeout, :dependency] ->
        {:retryable_error, "transient_transport"}

      error.class == :rate_limited ->
        {:retryable_error, "rate_limited"}

      error.class == :not_found ->
        {:permanent_error, "not_found"}

      true ->
        {:permanent_error, "validation"}
    end
  end

  defp oversized_response?(%Error{code: code}) do
    code in [:response_too_large, :headers_too_large, :output_too_large]
  end

  defp unsafe_response_policy_failure?(%Error{code: code} = error, request, input) do
    code in [:response_too_large, :headers_too_large, :compressed_body] and
      unsafe_written_effect?(error, request, input)
  end

  defp ambiguous_write_failure?(%Error{} = error, request, input) do
    error.class in [:timeout, :dependency] and unsafe_written_effect?(error, request, input)
  end

  defp unsafe_written_effect?(%Error{} = error, request, input) do
    written? = Map.get(error.details, :request_written?) == true
    write? = request.method not in ["GET", "HEAD"]
    unsafe_chain? = prior_unsafe_write?(request)

    unsafe_chain? or
      (written? and write? and not idempotent_effect?(request, input))
  end

  defp put_prior_remote_status(output, %__MODULE__{prior_remote_status: status})
       when is_integer(status) do
    Map.put_new(output, "remote_status", status)
  end

  defp put_prior_remote_status(output, %__MODULE__{}), do: output

  defp put_prior_duplicate_risk(output, request) do
    if prior_unsafe_write?(request) do
      Map.put(output, "duplicate_risk", true)
    else
      output
    end
  end

  defp request_stub(input) do
    method =
      case config(input)["method"] do
        value when is_atom(value) -> value |> Atom.to_string() |> String.upcase()
        value when is_binary(value) -> String.upcase(value)
        _other -> "GET"
      end

    %__MODULE__{
      method: method,
      url: "",
      path: "/",
      headers: [],
      body: nil,
      idempotency_header: present(config(input)["idempotency_header"])
    }
  end

  defp transport_opts(request, opts) do
    []
    |> maybe_put(:connect, Keyword.get(opts, :connect))
    |> maybe_put(:transport_opts, Keyword.get(opts, :transport_opts))
    |> maybe_put(:max_body_bytes, Keyword.get(opts, :max_body_bytes))
    |> maybe_put(:now, Keyword.get(opts, :now))
    |> Keyword.put(:timeout_ms, Keyword.get(opts, :timeout_ms, request.timeout_ms))
  end

  defp put_retry_after(output, headers) do
    case SafeHttp.captured_headers(headers) do
      %{"retry-after" => value} -> Map.put(output, "retry_after", value)
      _other -> output
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp put_detail(output, details, key, name) when is_map(details) do
    case Map.get(details, key) || Map.get(details, Atom.to_string(key)) do
      value when is_binary(value) and value != "" ->
        Map.put(output, name, value)

      value when is_atom(value) and not is_nil(value) ->
        Map.put(output, name, Atom.to_string(value))

      _missing ->
        output
    end
  end

  defp put_boolean_detail(output, details, key, name) when is_map(details) do
    case Map.fetch(details, key) do
      {:ok, value} when is_boolean(value) -> Map.put(output, name, value)
      _missing -> output
    end
  end

  defp finish(parts) when is_map(parts) do
    effect_key = Map.get(parts.input, :effect_key)

    %__MODULE__{
      method: parts.method,
      url: parts.url,
      path: parts.path,
      headers: parts.headers,
      body: parts.body,
      body_mode: parts.body_mode,
      content_type: parts.content_type,
      target: parts.target,
      timeout_ms: timeout_ms(parts.config),
      effect_key: present(effect_key),
      idempotency_header: parts.idempotency,
      secret_header_names: parts.secret_header_names,
      summary:
        drop_nils(%{
          "method" => parts.method,
          "url" => parts.url,
          "path" => parts.path,
          "header_names" => parts.headers |> Enum.map(&elem(&1, 0)) |> Enum.sort(),
          "body_bytes" => body_bytes(parts.body),
          "body_mode" => mode_name(parts.body_mode),
          "content_type" => parts.content_type,
          "effect_key" => present(effect_key),
          "idempotency_header" => parts.idempotency,
          "dry_run" => parts.dry_run?,
          "connection_id" => present(parts.config["connection_id"])
        })
    }
  end

  defp method(config) do
    key =
      case config["method"] do
        value when is_atom(value) -> Atom.to_string(value)
        value when is_binary(value) -> String.downcase(value)
        _other -> nil
      end

    case Map.fetch(@methods, key) do
      {:ok, name} ->
        {:ok, name}

      :error ->
        {:error,
         field_error("method", :invalid_http_method, "The HTTP step does not name a method.")}
    end
  end

  defp load_connection(input, config, opts) do
    cond do
      match?(%ResolvedConnection{}, Keyword.get(opts, :connection)) ->
        {:ok, Keyword.fetch!(opts, :connection)}

      dry_run?(input) ->
        {:ok, nil}

      present(config["connection_id"]) ->
        resolver = Map.get(input, :resolver) || Resolver
        resolver.resolve_for_action(input.installation_id, config["connection_id"])

      true ->
        {:ok, nil}
    end
  end

  defp combine(%ResolvedConnection{} = connection, url_text, node_path, query) do
    with :ok <- origin_matches(connection, url_text),
         {:ok, suffix} <- connected_suffix(connection, url_text, node_path),
         {:ok, query} <- merge_query(url_text, query),
         {:ok, path} <- Resolver.narrow_path(connection, suffix),
         {:ok, path} <- Resolver.with_query(path, query) do
      {:ok, connection.base_origin <> path, path}
    end
  end

  defp combine(nil, url_text, _node_path, query) when is_binary(url_text) do
    with {:ok, uri} <- parse_rendered(url_text),
         {:ok, query} <- merge_query(uri, query),
         {:ok, path} <- Resolver.with_query(uri.path, query),
         {:ok, url} <- rebuild(uri, path) do
      {:ok, url, path}
    end
  end

  defp combine(nil, nil, _node_path, _query) do
    {:error, field_error("url", :invalid_http_field, "This HTTP field must render as text.")}
  end

  defp origin_matches(_connection, nil), do: :ok

  defp origin_matches(%ResolvedConnection{} = connection, url_text) when is_binary(url_text) do
    with {:ok, uri} <- parse_rendered(url_text) do
      conn = URI.parse(connection.base_origin)
      uri_port = uri.port || default_port(uri.scheme)
      conn_port = conn.port || default_port(conn.scheme)

      if uri.scheme == conn.scheme and host_name(uri.host) == host_name(conn.host) and
           uri_port == conn_port do
        :ok
      else
        {:error,
         Error.new(:validation, :origin_not_allowed,
           message: "The request is not allowed to leave this connection's origin.",
           details: %{field: "url"}
         )}
      end
    end
  end

  defp connected_suffix(_connection, _url_text, node_path) when is_binary(node_path) do
    {:ok, node_path}
  end

  defp connected_suffix(connection, url_text, nil) when is_binary(url_text) do
    with {:ok, uri} <- parse_rendered(url_text) do
      Resolver.suffix_under_prefix(connection, uri.path)
    end
  end

  defp connected_suffix(_connection, nil, nil), do: {:ok, nil}

  defp merge_query(nil, query), do: {:ok, query}

  defp merge_query(url_or_uri, query) do
    with {:ok, from_url} <- query_from(url_or_uri) do
      {:ok, Map.merge(from_url, query)}
    end
  end

  defp query_from(%URI{query: query}), do: query_from_string(query)
  defp query_from(url) when is_binary(url), do: url |> URI.parse() |> query_from()

  defp query_from_string(nil), do: {:ok, %{}}
  defp query_from_string(""), do: {:ok, %{}}

  defp query_from_string(query) when is_binary(query) do
    {:ok, URI.decode_query(query, %{}, :rfc3986)}
  end

  defp parse_rendered(url) when is_binary(url) do
    trimmed = String.trim(url)

    cond do
      trimmed == "" ->
        {:error, field_error("url", :invalid_http_field, "This HTTP field must render as text.")}

      String.contains?(trimmed, ["\r", "\n", "\t"]) ->
        {:error, field_error("url", :url_invalid, "The URL is not valid.")}

      true ->
        uri = URI.parse(trimmed)
        validate_uri(uri)
    end
  end

  defp validate_uri(%URI{} = uri) do
    with :ok <- uri_userinfo(uri),
         :ok <- uri_fragment(uri),
         :ok <- uri_scheme(uri),
         :ok <- uri_host(uri),
         :ok <- uri_path(uri) do
      {:ok, %{uri | path: uri.path || "/", scheme: String.downcase(uri.scheme)}}
    end
  end

  defp uri_userinfo(%URI{userinfo: nil}), do: :ok

  defp uri_userinfo(%URI{}),
    do: {:error, fail(:url_userinfo, "The URL must not include credentials.")}

  defp uri_fragment(%URI{fragment: nil}), do: :ok
  defp uri_fragment(%URI{}), do: {:error, fail(:url_invalid, "The URL is not valid.")}

  defp uri_scheme(%URI{scheme: scheme}) when scheme in ["http", "https"], do: :ok
  defp uri_scheme(%URI{}), do: {:error, fail(:scheme_not_allowed, "The URL must use HTTPS.")}

  defp uri_host(%URI{host: host}) when is_binary(host) and host != "" do
    if String.contains?(host, " ") do
      {:error, fail(:host_invalid, "The host is not valid.")}
    else
      :ok
    end
  end

  defp uri_host(%URI{}), do: {:error, fail(:host_invalid, "The URL needs a host.")}

  defp uri_path(%URI{path: path}) when is_binary(path) do
    if String.contains?(path, " ") do
      {:error, fail(:url_invalid, "The URL is not valid.")}
    else
      :ok
    end
  end

  defp uri_path(%URI{}), do: :ok

  defp rebuild(uri, path) do
    host =
      if uri.port in [nil, default_port(uri.scheme)] do
        uri.host
      else
        "#{uri.host}:#{uri.port}"
      end

    url = uri.scheme <> "://" <> host <> path

    if byte_size(url) > @max_url_bytes do
      {:error, fail(:url_invalid, "The URL is not valid.")}
    else
      {:ok, url}
    end
  end

  defp check_scheme(config, url) do
    declared = scheme_prefix(config["url"])
    rendered = url |> URI.parse() |> Map.get(:scheme)

    if is_binary(declared) and declared != rendered do
      {:error, fail(:scheme_not_allowed, "The URL must use HTTPS.")}
    else
      :ok
    end
  end

  defp scheme_prefix(url) when is_binary(url) do
    cond do
      String.starts_with?(url, "https://") -> "https"
      String.starts_with?(url, "http://") -> "http"
      true -> nil
    end
  end

  defp scheme_prefix(%{"template" => [%{"literal" => literal} | _]}) when is_binary(literal) do
    scheme_prefix(literal)
  end

  defp scheme_prefix(_url), do: nil

  defp body_mode(config, method) when method in @bodyless do
    if present?(config["body"]) do
      {:error,
       field_error(
         "body",
         :http_body_not_allowed,
         "A request with this method may not carry a body."
       )}
    else
      {:ok, nil}
    end
  end

  defp body_mode(config, _method) do
    cond do
      is_binary(config["body_mode"]) ->
        fetch_mode(config["body_mode"])

      is_atom(config["body_mode"]) and not is_nil(config["body_mode"]) ->
        fetch_mode(Atom.to_string(config["body_mode"]))

      (mode = content_type_mode(config)) != nil ->
        {:ok, mode}

      present?(config["body"]) ->
        {:ok, :auto}

      true ->
        {:ok, nil}
    end
  end

  defp fetch_mode(name) do
    case Map.fetch(@modes, String.downcase(name)) do
      {:ok, mode} ->
        {:ok, mode}

      :error ->
        {:error,
         field_error("body_mode", :invalid_http_field, "This HTTP field must render as text.")}
    end
  end

  defp content_type_mode(config) do
    config
    |> Map.get("headers", %{})
    |> header_value("content-type")
    |> content_type_hint()
  end

  defp header_value(headers, name) when is_map(headers) do
    Enum.find_value(headers, fn {key, value} ->
      if is_binary(key) and String.downcase(key) == name, do: value
    end)
  end

  defp header_value(_headers, _name), do: nil

  defp content_type_hint(value) when is_binary(value) do
    value
    |> String.split(";", parts: 2)
    |> hd()
    |> String.trim()
    |> String.downcase()
    |> then(&Map.get(@content_type_modes, &1))
  end

  defp content_type_hint(_value), do: nil

  defp render_body(_config, _tree, nil, _method), do: {:ok, nil}

  defp render_body(config, tree, mode, _method) do
    case config["body"] do
      body when body in [nil, ""] ->
        {:ok, nil}

      compiled ->
        opts = if mode == :json, do: [insert: :json], else: []

        case Templates.render(compiled, tree, opts) do
          {:ok, %{value: value}} -> {:ok, value}
          {:error, %Error{} = error} -> {:error, with_field(error, "body")}
        end
    end
  end

  defp infer_mode(:auto, value) do
    cond do
      value in [nil, ""] ->
        {:ok, nil}

      json_value?(value) ->
        {:ok, :json}

      is_binary(value) ->
        {:ok, :text}

      true ->
        {:error, field_error("body", :invalid_http_field, "This HTTP field must render as text.")}
    end
  end

  defp infer_mode(mode, _value), do: {:ok, mode}

  defp json_value?(value) when is_map(value) or is_list(value), do: true

  defp json_value?(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) or is_list(decoded) -> true
      _other -> false
    end
  end

  defp json_value?(_value), do: false

  defp render_headers(config, connection, tree) do
    with {:ok, node_headers} <- node_headers(config, tree),
         :ok <- no_overlap(connection, node_headers) do
      literals = connection_literals(connection)

      headers =
        literals
        |> Map.merge(node_headers)
        |> Map.drop(["content-type", "content_type"])

      {:ok, headers}
    end
  end

  defp node_headers(config, tree) do
    case Map.get(config, "headers", %{}) do
      headers when is_map(headers) and not is_struct(headers) ->
        collect_headers(headers, tree)

      nil ->
        {:ok, %{}}

      _other ->
        {:error,
         field_error("headers", :http_header_invalid, "This is not a header a request may carry.")}
    end
  end

  defp collect_headers(headers, tree) do
    Enum.reduce_while(headers, {:ok, %{}}, fn pair, {:ok, acc} ->
      header_step(pair, tree, acc)
    end)
  end

  defp header_step({name, compiled}, tree, acc) do
    case render_header(name, compiled, tree, acc) do
      {:ok, {key, value}} -> {:cont, {:ok, Map.put(acc, key, value)}}
      {:error, %Error{}} = error -> {:halt, error}
    end
  end

  defp render_header(name, compiled, tree, acc) do
    with {:ok, key} <- header_name(name),
         :ok <- unused_header(acc, key),
         {:ok, value} <- render_header_value(compiled, tree) do
      cond do
        key in @blocked_headers or String.starts_with?(key, "proxy-") ->
          {:error,
           field_error(
             "headers",
             :http_header_blocked,
             "This header is set by the transport and may not be set here."
           )}

        byte_size(value) > Connection.max_header_value() ->
          {:error, field_error("headers", :value_too_long, "This value is too long.")}

        key in Connection.secret_only_headers() and not placeholder?(value) ->
          {:error,
           field_error(
             "headers",
             :http_header_needs_secret,
             "This header may only carry a secret reference."
           )}

        not Regex.match?(Connection.header_value_format(), strip_placeholders(value)) ->
          {:error,
           field_error(
             "headers",
             :http_header_invalid,
             "This is not a header a request may carry."
           )}

        true ->
          {:ok, {key, value}}
      end
    end
  end

  defp render_header_value(compiled, tree) do
    case Templates.render(compiled, tree) do
      {:ok, %{value: value}} when is_binary(value) ->
        {:ok, value}

      {:ok, %{value: %{"secret" => name}}} when is_binary(name) ->
        {:ok, Templates.secret_placeholder(name)}

      {:ok, %{value: _other}} ->
        {:error,
         field_error("headers", :invalid_http_field, "This HTTP field must render as text.")}

      {:error, %Error{} = error} ->
        {:error, with_field(error, "headers")}
    end
  end

  defp header_name(name) when is_binary(name) do
    key = String.downcase(name)

    if Regex.match?(Connection.header_name_format(), key) do
      {:ok, key}
    else
      {:error,
       field_error("headers", :http_header_invalid, "This is not a header a request may carry.")}
    end
  end

  defp header_name(_name) do
    {:error,
     field_error("headers", :http_header_invalid, "This is not a header a request may carry.")}
  end

  defp unused_header(acc, key) do
    if Map.has_key?(acc, key) do
      {:error,
       field_error("headers", :http_header_invalid, "This is not a header a request may carry.")}
    else
      :ok
    end
  end

  defp connection_literals(%ResolvedConnection{headers: headers}) when is_map(headers),
    do: headers

  defp connection_literals(_connection), do: %{}

  defp no_overlap(nil, _node_headers), do: :ok

  defp no_overlap(%ResolvedConnection{} = connection, node_headers) do
    taken =
      MapSet.new(
        Map.keys(connection.headers || %{}) ++
          Enum.map(connection.secret_headers || [], & &1.header)
      )

    if Enum.any?(Map.keys(node_headers), &MapSet.member?(taken, &1)) do
      {:error,
       field_error("headers", :http_header_invalid, "This is not a header a request may carry.")}
    else
      :ok
    end
  end

  defp bound_headers(headers) do
    if map_size(headers) > Connection.max_headers() do
      {:error, fail(:http_header_invalid, "This is not a header a request may carry.")}
    else
      :ok
    end
  end

  defp bound_rendered_body(nil), do: :ok

  defp bound_rendered_body(value) when is_binary(value) do
    bound_bytes(value, :request_too_large, "The HTTP request body is too large.")
  end

  defp bound_rendered_body(value) do
    case Jason.encode(value) do
      {:ok, json} ->
        bound_bytes(json, :request_too_large, "The HTTP request body is too large.")

      {:error, _reason} ->
        {:error, field_error("body", :invalid_http_field, "This HTTP field must render as text.")}
    end
  end

  defp bound_bytes(nil, _code, _message), do: :ok

  defp bound_bytes(value, code, message) when is_binary(value) do
    if byte_size(value) > SafeHttp.max_request_bytes() do
      {:error, Error.new(:validation, code, message: message, details: %{field: "body"})}
    else
      :ok
    end
  end

  defp approve_url(_url, true, _opts), do: {:ok, nil}

  defp approve_url(url, false, opts) do
    policy_opts =
      [allow_http: Keyword.get(opts, :allow_http, false)]
      |> maybe_put(:resolver, Keyword.get(opts, :dns_resolver))
      |> maybe_put(:now, Keyword.get(opts, :now))

    unwrap_policy(UrlPolicy.approve(url, policy_opts))
  end

  defp unwrap_policy({:ok, target}), do: {:ok, target}
  defp unwrap_policy({:error, %Error{}} = error), do: error

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp load_secrets(_input, _connection, _headers, _body, _opts, true) do
    {:ok, %{names: %{}, ids: %{}}}
  end

  defp load_secrets(input, connection, headers, rendered_body, opts, false) do
    names = placeholder_names(headers, rendered_body)
    ids = secret_ids(connection)

    with {:ok, by_name} <- resolve_names(input, names, opts),
         {:ok, by_id} <- resolve_ids(input, ids, opts) do
      {:ok, %{names: by_name, ids: by_id}}
    end
  end

  defp placeholder_names(headers, rendered_body) do
    (Map.values(headers) ++ [body_text(rendered_body)])
    |> Enum.flat_map(&scan_placeholders/1)
    |> Enum.uniq()
  end

  defp secret_header_names(headers, connection) do
    template_headers =
      for {name, value} <- headers,
          scan_placeholders(value) != [],
          do: String.downcase(name)

    connection_headers =
      case connection do
        %ResolvedConnection{secret_headers: handles} ->
          Enum.map(handles, &String.downcase(&1.header))

        _connection ->
          []
      end

    Enum.uniq(template_headers ++ connection_headers)
  end

  defp scan_placeholders(text) when is_binary(text) do
    @placeholder |> Regex.scan(text) |> Enum.map(fn [_whole, name] -> name end)
  end

  defp scan_placeholders(_text), do: []

  defp body_text(value) when is_binary(value), do: value
  defp body_text(%{"secret" => name}) when is_binary(name), do: Templates.secret_placeholder(name)
  defp body_text(_value), do: ""

  defp secret_ids(%ResolvedConnection{secret_headers: handles}) do
    handles |> Enum.map(& &1.secret_id) |> Enum.uniq()
  end

  defp secret_ids(_connection), do: []

  defp resolve_names(_input, [], _opts), do: {:ok, %{}}

  defp resolve_names(input, names, opts) do
    Enum.reduce_while(names, {:ok, %{}}, fn name, {:ok, acc} ->
      case named_secret(input, name, opts) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, name, value)}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp named_secret(input, name, opts) do
    case Keyword.get(opts, :secrets) do
      %{} = map ->
        case Map.fetch(map, name) do
          {:ok, value} when is_binary(value) -> {:ok, value}
          :error -> {:error, missing_secret("body")}
          _other -> {:error, missing_secret("body")}
        end

      _other ->
        SecretResolver.resolve_named_for_action(input.installation_id, name)
    end
  end

  defp resolve_ids(_input, [], _opts), do: {:ok, %{}}

  defp resolve_ids(input, ids, opts) do
    Enum.reduce_while(ids, {:ok, %{}}, fn id, {:ok, acc} ->
      case id_secret(input, id, opts) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, id, value)}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp id_secret(input, id, opts) do
    case Keyword.get(opts, :secrets_by_id) do
      %{} = map ->
        case Map.fetch(map, id) do
          {:ok, value} when is_binary(value) -> {:ok, value}
          :error -> {:error, missing_secret("headers")}
          _other -> {:error, missing_secret("headers")}
        end

      _other ->
        SecretResolver.resolve_for_action(input.installation_id, id)
    end
  end

  defp fill_body(nil, _mode, _secrets), do: {:ok, nil}

  defp fill_body(value, :json, secrets) do
    with {:ok, encoded} <- json_bytes(value, secrets.names),
         {:ok, _decoded} <- Jason.decode(encoded) do
      {:ok, encoded}
    else
      {:error, %Error{}} = error ->
        error

      {:error, _reason} ->
        {:error, field_error("body", :invalid_http_field, "This HTTP field must render as text.")}
    end
  end

  defp fill_body(value, :form, secrets) when is_binary(value) do
    {:ok, form_encode(URI.decode_query(value, %{}, :www_form), secrets.names)}
  end

  defp fill_body(value, :form, secrets) when is_map(value) do
    pairs = Map.new(value, fn {key, val} -> {to_string(key), to_string(val)} end)
    {:ok, form_encode(pairs, secrets.names)}
  end

  defp fill_body(value, :text, secrets) when is_binary(value) do
    {:ok, substitute_text(value, secrets.names)}
  end

  defp fill_body(_value, _mode, _secrets) do
    {:error, field_error("body", :invalid_http_field, "This HTTP field must render as text.")}
  end

  defp form_encode(pairs, secrets) do
    pairs
    |> Enum.map(fn {key, val} -> {key, substitute_text(val, secrets)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> URI.encode_query(:www_form)
  end

  defp json_bytes(%{"secret" => name}, secrets) when is_binary(name) do
    encoded =
      case Map.fetch(secrets, name) do
        {:ok, value} -> Jason.encode(value)
        :error -> Jason.encode(Templates.secret_placeholder(name))
      end

    wrap_json(encoded)
  end

  defp json_bytes(value, _secrets) when is_map(value) or is_list(value) do
    wrap_json(Jason.encode(value))
  end

  defp json_bytes(value, secrets) when is_binary(value) do
    substituted = substitute_json(value, secrets)

    case Jason.decode(substituted) do
      {:ok, decoded} ->
        wrap_json(Jason.encode(decoded))

      {:error, _reason} ->
        {:error, field_error("body", :invalid_http_field, "This HTTP field must render as text.")}
    end
  end

  defp wrap_json({:ok, json}), do: {:ok, json}

  defp wrap_json({:error, _reason}) do
    {:error, field_error("body", :invalid_http_field, "This HTTP field must render as text.")}
  end

  defp substitute_json(text, secrets) do
    Regex.replace(@placeholder, text, fn _whole, name ->
      case Map.fetch(secrets, name) do
        {:ok, value} -> Jason.encode!(value)
        :error -> Jason.encode!(Templates.secret_placeholder(name))
      end
    end)
  end

  defp substitute_text(text, secrets) when is_binary(text) do
    Regex.replace(@placeholder, text, fn _whole, name ->
      case Map.fetch(secrets, name) do
        {:ok, value} -> value
        :error -> Templates.secret_placeholder(name)
      end
    end)
  end

  defp substitute_text(value, _secrets), do: to_string(value)

  defp finalize_headers(headers, connection, secrets, body_mode, body, input, config) do
    with {:ok, filled} <- fill_header_values(headers, secrets.names),
         {:ok, filled} <- put_secret_headers(filled, connection, secrets.ids),
         {:ok, content_type, filled} <- put_content_type(filled, body_mode, body),
         {:ok, idempotency, filled} <- put_idempotency(filled, input, config),
         :ok <- bound_headers(filled) do
      list =
        filled
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {name, value} -> {name, value} end)

      {:ok, list, content_type, idempotency}
    end
  end

  defp fill_header_values(headers, secrets) do
    Enum.reduce_while(headers, {:ok, %{}}, fn {name, value}, {:ok, acc} ->
      filled = substitute_text(value, secrets)

      cond do
        String.contains?(filled, ["\r", "\n"]) ->
          {:halt,
           {:error,
            field_error(
              "headers",
              :http_header_invalid,
              "This is not a header a request may carry."
            )}}

        byte_size(filled) > Connection.max_header_value() ->
          {:halt, {:error, field_error("headers", :value_too_long, "This value is too long.")}}

        true ->
          {:cont, {:ok, Map.put(acc, name, filled)}}
      end
    end)
  end

  defp put_secret_headers(headers, %ResolvedConnection{secret_headers: handles}, ids) do
    Enum.reduce_while(handles, {:ok, headers}, fn handle, {:ok, acc} ->
      secret_header_step(handle, ids, acc)
    end)
  end

  defp put_secret_headers(headers, _connection, _ids), do: {:ok, headers}

  defp secret_header_step(handle, ids, acc) do
    case Map.fetch(ids, handle.secret_id) do
      {:ok, value} -> put_unique_header(acc, handle.header, value)
      :error -> {:cont, {:ok, acc}}
    end
  end

  defp put_unique_header(acc, name, value) do
    if Map.has_key?(acc, name) do
      {:halt,
       {:error,
        field_error("headers", :http_header_invalid, "This is not a header a request may carry.")}}
    else
      {:cont, {:ok, Map.put(acc, name, value)}}
    end
  end

  defp put_content_type(headers, mode, body) when mode in [:json, :text, :form] and body != nil do
    {:ok, Map.fetch!(@content_types, mode),
     Map.put(headers, "content-type", Map.fetch!(@content_types, mode))}
  end

  defp put_content_type(headers, _mode, _body), do: {:ok, nil, headers}

  defp put_idempotency(headers, input, config) do
    case present(config["idempotency_header"]) do
      nil -> {:ok, nil, headers}
      name -> write_idempotency(headers, input, name)
    end
  end

  defp write_idempotency(headers, input, name) do
    with {:ok, key} <- header_name(name),
         :ok <- idempotency_allowed(key, headers),
         {:ok, value} <- idempotency_value(input) do
      {:ok, key, Map.put(headers, key, value)}
    end
  end

  defp idempotency_value(input) do
    case present(Map.get(input, :effect_key)) do
      nil ->
        {:error,
         field_error(
           "idempotency_header",
           :invalid_http_field,
           "This HTTP field must render as text."
         )}

      value ->
        {:ok, value}
    end
  end

  defp idempotency_allowed(key, headers) do
    cond do
      key in @blocked_headers or key in Connection.secret_only_headers() or
        key == "content-type" or String.starts_with?(key, "proxy-") ->
        {:error,
         field_error(
           "idempotency_header",
           :http_header_blocked,
           "This header is set by the transport and may not be set here."
         )}

      Map.has_key?(headers, key) ->
        {:error,
         field_error(
           "idempotency_header",
           :http_header_invalid,
           "This is not a header a request may carry."
         )}

      true ->
        :ok
    end
  end

  defp render_query(config, tree) do
    case Map.get(config, "query") do
      nil ->
        {:ok, %{}}

      query when is_map(query) and not is_struct(query) ->
        collect_query(query, tree)

      _other ->
        {:error,
         field_error("query", :query_invalid, "The query must be a map of text keys and values.")}
    end
  end

  defp collect_query(query, tree) do
    Enum.reduce_while(query, {:ok, %{}}, fn pair, {:ok, acc} ->
      query_step(pair, tree, acc)
    end)
  end

  defp query_step({key, compiled}, tree, acc) do
    case render_query_pair(key, compiled, tree) do
      {:ok, {name, value}} -> {:cont, {:ok, Map.put(acc, name, value)}}
      {:error, %Error{}} = error -> {:halt, error}
    end
  end

  defp render_query_pair(key, compiled, tree) when is_binary(key) do
    case render_optional(compiled, tree, "query") do
      {:ok, nil} -> {:ok, {key, ""}}
      {:ok, value} -> {:ok, {key, value}}
      {:error, %Error{}} = error -> error
    end
  end

  defp render_query_pair(_key, _compiled, _tree) do
    {:error,
     field_error("query", :query_invalid, "The query must be a map of text keys and values.")}
  end

  defp render_optional(value, _tree, _field) when value in [nil, ""], do: {:ok, nil}

  defp render_optional(compiled, tree, field) do
    case Templates.render(compiled, tree) do
      {:ok, %{value: value}} when is_binary(value) and value != "" ->
        {:ok, value}

      {:ok, %{value: value}} when value in [nil, ""] ->
        {:ok, nil}

      {:ok, %{value: _other}} ->
        {:error, field_error(field, :invalid_http_field, "This HTTP field must render as text.")}

      {:error, %Error{} = error} ->
        {:error, with_field(error, field)}
    end
  end

  defp timeout_ms(config) do
    case config["timeout_ms"] do
      value when is_integer(value) and value > 0 -> min(value, @max_timeout_ms)
      _other -> SafeHttp.timeout_ms()
    end
  end

  defp dry_run?(%{run_mode: "dry_run"}), do: true
  defp dry_run?(_input), do: false

  defp config(%{compiled_node: %{config: config}}) when is_map(config), do: config
  defp config(%{compiled_node: %{"config" => config}}) when is_map(config), do: config
  defp config(_input), do: %{}

  defp placeholder?(value), do: Regex.match?(@placeholder, value)

  defp strip_placeholders(value), do: Regex.replace(@placeholder, value, "x")

  defp present?(value) when value in [nil, ""], do: false
  defp present?(_value), do: true

  defp present(value) when value in [nil, ""], do: nil
  defp present(value), do: value

  defp drop_nils(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  defp mode_name(nil), do: nil
  defp mode_name(mode), do: Atom.to_string(mode)

  defp body_bytes(body) when is_binary(body), do: byte_size(body)
  defp body_bytes(_body), do: 0

  defp host_name(host) when is_binary(host), do: String.downcase(host)
  defp host_name(host), do: host

  defp default_port("http"), do: 80
  defp default_port("https"), do: 443
  defp default_port(_scheme), do: nil

  defp missing_secret(field) do
    Error.new(:not_found, :resource_not_found,
      message: "That resource does not exist.",
      details: %{field: field}
    )
  end

  defp field_error(field, code, message) do
    Error.new(:validation, code, message: message, details: %{field: field})
  end

  defp fail(code, message) do
    Error.new(:validation, code, message: message, details: %{field: "url"})
  end

  defp with_field(%Error{} = error, field) do
    %{error | details: Map.put(error.details, :field, field)}
  end
end
