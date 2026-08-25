defmodule PumbleAutomation.Pumble.Client.Transport do
  @moduledoc """
  The single socket-facing function for the Pumble JSON API.

  It takes a request that `PumbleAutomation.Pumble.Client` has already built and
  validated, sends it, and returns either a decoded body or a
  `PumbleAutomation.Pumble.Client.Error`. It contains no knowledge of any
  operation: the method, the path, and the body arrive fully formed.

  ## Why there is no public generic request

  `execute/1` is reachable only through a named operation on
  `PumbleAutomation.Pumble.Client`, and it refuses a path it did not receive as
  an absolute, host-free `/…` string. A workflow node therefore cannot ask this
  application to call an arbitrary Pumble endpoint — or an arbitrary host — by
  supplying a path, because no node-facing function accepts one.

  ## The four bounds

    * TLS is verified against the system trust store, so the configured host is
      the host that answers.
    * connect and receive timeouts bound a Pumble that never replies.
    * `max_response_bytes/0` bounds a body that never ends: it is streamed and
      abandoned the moment it passes the cap.
    * redirects are refused. A redirect on an authenticated API call is a
      misconfiguration or an attack, never a hop to follow with a token.

  ## No retry lives here

  `retry: false`. The Pumble client contract puts retry above this boundary, where the
  action's own semantics are known; a transport that retried would duplicate
  messages, because Pumble publishes no idempotency key on writes (`PR-09`).

  ## Telemetry

  `[:pumble_automation, :pumble, :client, :start]` and `[…, :stop]` carry the
  workspace, the operation, the correlation id, the status, and the provider's
  request id. No token, no path parameter, and no body reaches the metadata.
  """

  alias PumbleAutomation.FailureInjection
  alias PumbleAutomation.Pumble.Client.Error

  @telemetry_event [:pumble_automation, :pumble, :client]

  # Larger than any response this application asks for — the biggest is a
  # channel listing — and small enough that a runaway body cannot hurt the node.
  @max_response_bytes 262_144

  @connect_timeout_ms 5_000
  @receive_timeout_ms 10_000

  # The far side publishes no correlation header of its own (`PR-08` closes no
  # header name), so the common proxy header is read when present and nothing is
  # invented when it is absent. The value is bounded before it is logged.
  @request_id_headers ~w(x-request-id x-correlation-id)
  @max_request_id_bytes 64

  @typedoc """
  A fully built request. Only `PumbleAutomation.Pumble.Client` constructs one.

  `:idempotent_effect?` states whether repeating this call can duplicate an
  effect. It changes the class of a `5xx` and of a lost connection, and nothing
  else.
  """
  @type request :: %{
          required(:operation) => atom(),
          required(:method) => :get | :post | :delete,
          required(:path) => String.t(),
          required(:token) => String.t(),
          required(:workspace_id) => String.t(),
          optional(:query) => keyword(),
          optional(:body) => map() | nil,
          optional(:correlation_id) => String.t() | nil,
          optional(:idempotent_effect?) => boolean(),
          optional(:scope) => String.t() | nil
        }

  @doc """
  Sends `request` and returns the decoded body or a typed error.

  A `2xx` with an empty body returns `{:ok, nil}`: several Pumble writes answer
  with no content, and an empty body is a success, not a malformed response.
  """
  @spec execute(request()) :: {:ok, term()} | {:error, Error.t()}
  def execute(%{path: "/" <> _rest} = request) do
    started_at = System.monotonic_time()
    metadata = telemetry_metadata(request)

    :telemetry.execute(
      @telemetry_event ++ [:start],
      %{system_time: System.system_time()},
      metadata
    )

    FailureInjection.crash(:before_network_write)

    result =
      case Req.request(options(request)) do
        {:ok, response} -> handle_response(response, request)
        {:error, exception} -> {:error, transport_error(exception, request)}
      end

    result = FailureInjection.crash_if_ambiguous(result)

    :telemetry.execute(
      @telemetry_event ++ [:stop],
      %{duration: System.monotonic_time() - started_at},
      Map.merge(metadata, outcome_metadata(result))
    )

    result
  end

  def execute(%{} = request) do
    {:error,
     Error.new(:internal_invariant,
       operation: Map.get(request, :operation),
       body_summary: "the request path is not an absolute API path"
     )}
  end

  @doc "The largest response body this client will read, in bytes."
  @spec max_response_bytes() :: pos_integer()
  def max_response_bytes, do: @max_response_bytes

  @doc "The telemetry event prefix this module emits under."
  @spec telemetry_event() :: [atom()]
  def telemetry_event, do: @telemetry_event

  defp options(request) do
    [
      method: request.method,
      url: base_url() <> request.path,
      headers: headers(request),
      params: Map.get(request, :query) || [],
      into: &collect/2,
      decode_body: false,
      retry: false,
      redirect: false,
      receive_timeout: @receive_timeout_ms
    ]
    |> put_body(Map.get(request, :body))
    |> Keyword.merge(transport_options())
    |> Keyword.merge(http_options())
  end

  # `H-1` to `H-5`: the credential goes in a lowercase `token` header with no
  # scheme prefix, the manifest app key goes in `x-app-token`, and no
  # `Authorization` header is ever sent. Both auth headers are required; the API
  # answers `401` when either is missing.
  defp headers(request) do
    [
      {"token", request.token},
      {"x-app-token", app_key()},
      {"accept", "application/json"}
    ]
  end

  # A body is encoded even on `DELETE`: `A-6` removes a reaction with a JSON
  # body on a `DELETE`, which is the vendor client's only form for it.
  defp put_body(options, nil), do: options
  defp put_body(options, body) when is_map(body), do: Keyword.put(options, :json, body)

  defp base_url do
    :pumble_automation
    |> Application.fetch_env!(:pumble)
    |> Keyword.fetch!(:api_base_url)
  end

  defp app_key do
    :pumble_automation
    |> Application.fetch_env!(:pumble)
    |> Keyword.fetch!(:app_key)
  end

  defp http_options do
    Application.get_env(:pumble_automation, :pumble_api_http_options, [])
  end

  # TLS options are built only for a real connection. Under a stub adapter they
  # are unused, and `:public_key.cacerts_get/0` raises on a host with no trust
  # store, which would turn an offline unit test into a failure about
  # certificates.
  defp transport_options do
    if Keyword.has_key?(http_options(), :plug) do
      []
    else
      [
        connect_options: [
          timeout: @connect_timeout_ms,
          transport_opts: [
            verify: :verify_peer,
            cacerts: :public_key.cacerts_get(),
            depth: 3,
            versions: [:"tlsv1.2", :"tlsv1.3"],
            customize_hostname_check: [
              match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
            ]
          ]
        ]
      ]
    end
  end

  # Accumulates the body and abandons the request as soon as it passes the cap.
  # Halting closes the connection, so an endless body is never fully read.
  defp collect({:data, data}, {req, response}) do
    accumulated = (response.private[:body_acc] || "") <> data

    if byte_size(accumulated) > @max_response_bytes do
      {:halt, {req, Req.Response.put_private(response, :body_overflow, true)}}
    else
      {:cont, {req, Req.Response.put_private(response, :body_acc, accumulated)}}
    end
  end

  defp handle_response(%Req.Response{private: %{body_overflow: true}}, request) do
    {:error,
     Error.new(:resource_limit,
       operation: request.operation,
       body_summary: "the response exceeded #{@max_response_bytes} bytes"
     )}
  end

  defp handle_response(%Req.Response{status: status} = response, request)
       when status in 200..299 do
    decode(body(response), request)
  end

  defp handle_response(%Req.Response{status: status} = response, request) do
    {:error,
     Error.from_status(status, decoded_or_raw(body(response)),
       operation: request.operation,
       provider_request_id: provider_request_id(response),
       retry_after_header: Req.Response.get_header(response, "retry-after"),
       idempotent_effect?: Map.get(request, :idempotent_effect?, false),
       scope: Map.get(request, :scope)
     )}
  end

  defp decode("", _request), do: {:ok, nil}

  defp decode(raw, request) do
    case Jason.decode(raw) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, _reason} ->
        {:error,
         Error.new(:remote_permanent,
           status: 200,
           operation: request.operation,
           body_summary: "the response body is not JSON"
         )}
    end
  end

  defp body(%Req.Response{private: private}), do: Map.get(private, :body_acc, "")

  # An error body is redacted as structured data when it parses, and as text
  # when it does not. Either form is bounded by the error module.
  defp decoded_or_raw(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> raw
    end
  end

  defp provider_request_id(response) do
    Enum.find_value(@request_id_headers, fn name ->
      case Req.Response.get_header(response, name) do
        [value | _rest] when is_binary(value) -> binary_slice(value, 0, @max_request_id_bytes)
        _other -> nil
      end
    end)
  end

  defp transport_error(%Req.TransportError{reason: reason}, request) do
    Error.from_transport(reason,
      operation: request.operation,
      idempotent_effect?: Map.get(request, :idempotent_effect?, false)
    )
  end

  defp transport_error(exception, request) do
    Error.from_transport(
      exception.__struct__,
      operation: request.operation,
      idempotent_effect?: Map.get(request, :idempotent_effect?, false)
    )
  end

  defp telemetry_metadata(request) do
    %{
      operation: request.operation,
      workspace_id: request.workspace_id,
      correlation_id: Map.get(request, :correlation_id)
    }
  end

  defp outcome_metadata({:ok, _body}), do: %{status: :ok, error_class: nil}

  defp outcome_metadata({:error, %Error{} = error}) do
    %{
      status: error.status,
      error_class: error.class,
      provider_request_id: error.provider_request_id
    }
  end
end
