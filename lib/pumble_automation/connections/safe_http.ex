defmodule PumbleAutomation.Connections.SafeHttp do
  @moduledoc """
  The only outbound HTTP path a user-supplied URL may take.

  A caller first obtains a short-lived pin from
  `PumbleAutomation.Connections.UrlPolicy`. This module connects to one
  address from that pin and keeps the original hostname for SNI, the
  certificate, and Host. It does not resolve DNS, follow redirects, honour a
  proxy, or retry. Redirects re-enter URL policy at the HTTP node; helpers
  here only classify status codes, parse Location, and sanitize captures.

  Req is never used here. Pumble API calls stay on Req against a fixed host;
  workflow HTTP stays on Mint against a validated IP.
  """

  alias PumbleAutomation.Connections.SafeHttp.Transport
  alias PumbleAutomation.Connections.UrlPolicy
  alias PumbleAutomation.Error
  alias PumbleAutomation.FailureInjection
  alias PumbleAutomation.Limits

  @methods %{
    get: "GET",
    head: "HEAD",
    post: "POST",
    put: "PUT",
    patch: "PATCH",
    delete: "DELETE"
  }

  @method_names Map.new(@methods, fn {_atom, name} -> {name, name} end)

  @blocked_headers MapSet.new([
                     "host",
                     "content-length",
                     "transfer-encoding",
                     "connection",
                     "keep-alive",
                     "te",
                     "trailer",
                     "trailers",
                     "upgrade",
                     "expect",
                     "proxy-authenticate",
                     "proxy-authorization",
                     "proxy-connection",
                     "accept-encoding"
                   ])

  @max_header_bytes 16 * 1024
  @max_excerpt_bytes 256
  @connect_timeout_ms 5_000
  @max_redirects 3
  @redirect_statuses [301, 302, 303, 307, 308]
  @captured_headers MapSet.new([
                      "content-type",
                      "retry-after",
                      "x-request-id",
                      "x-correlation-id",
                      "etag",
                      "date",
                      "cache-control"
                    ])

  @type method :: :get | :head | :post | :put | :patch | :delete
  @type request :: %{
          required(:method) => method() | String.t(),
          required(:path) => String.t(),
          optional(:headers) => [{String.t(), String.t()}],
          optional(:body) => iodata() | nil
        }

  @type response :: %{
          status: 100..599,
          headers: [{String.t(), String.t()}],
          body: binary(),
          address: :inet.ip_address()
        }

  @doc "Section 31 HTTP request body cap, in bytes."
  @spec max_request_bytes() :: pos_integer()
  def max_request_bytes, do: Limits.get(:http_request_body_bytes)

  @doc "Section 31 HTTP response body cap, in bytes."
  @spec max_body_bytes() :: pos_integer()
  def max_body_bytes, do: Limits.get(:http_response_body_bytes)

  @doc "Largest response header block this transport will read, in bytes."
  @spec max_header_bytes() :: pos_integer()
  def max_header_bytes, do: @max_header_bytes

  @doc "Default connect timeout, in milliseconds."
  @spec connect_timeout_ms() :: pos_integer()
  def connect_timeout_ms, do: @connect_timeout_ms

  @doc "Default overall request timeout, in milliseconds."
  @spec timeout_ms() :: pos_integer()
  def timeout_ms, do: Limits.get(:outbound_http_timeout_ms)

  @doc "Section 31 redirect cap: at most this many Location hops."
  @spec max_redirects() :: pos_integer()
  def max_redirects, do: min(Limits.get(:redirects), @max_redirects)

  @doc "Whether `status` is a redirect this transport may consider."
  @spec redirect_status?(integer()) :: boolean()
  def redirect_status?(status) when status in @redirect_statuses, do: true
  def redirect_status?(_status), do: false

  @doc """
  Turns a Location header into an absolute URL against `current_url`.

  Relative values are resolved with RFC 3986 merge. Credentials in the
  target, a missing header, and a second Location are all refusals. This
  does not approve the URL; the caller re-enters URL policy.
  """
  @spec location(String.t(), [{String.t(), String.t()}]) ::
          {:ok, String.t()} | {:error, Error.t()}
  def location(current_url, headers) when is_binary(current_url) and is_list(headers) do
    case locations(headers) do
      [value] ->
        absolute_location(current_url, value)

      [] ->
        {:error, fail(:validation, :malformed_redirect, "The redirect did not name a Location.")}

      _other ->
        {:error,
         fail(:validation, :malformed_redirect, "The redirect named more than one Location.")}
    end
  end

  def location(_current_url, _headers) do
    {:error, fail(:validation, :malformed_redirect, "The redirect did not name a Location.")}
  end

  @doc """
  Headers safe to persist from a response.

  `Set-Cookie` is dropped and never becomes a cookie jar. Names that look
  like credentials cannot become outbound Authorization on a later hop.
  """
  @spec captured_headers([{String.t(), String.t()}]) :: %{String.t() => String.t()}
  def captured_headers(headers) when is_list(headers) do
    headers
    |> Enum.reduce(%{}, fn
      {name, value}, acc when is_binary(name) and is_binary(value) ->
        key = String.downcase(name)

        if key in @captured_headers and not Regex.match?(Error.secret_key_pattern(), key) do
          Map.put_new(acc, key, clip(value, @max_excerpt_bytes))
        else
          acc
        end

      _header, acc ->
        acc
    end)
  end

  def captured_headers(_headers), do: %{}

  @doc "SHA-256 hex digest of `body`, for a persistable summary."
  @spec body_digest(binary()) :: String.t()
  def body_digest(body) when is_binary(body) do
    Base.encode16(:crypto.hash(:sha256, body), case: :lower)
  end

  def body_digest(_body), do: body_digest("")

  @doc "A short, redacted excerpt of a response body. Never the full body."
  @spec excerpt(binary()) :: String.t()
  def excerpt(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, value} -> json_excerpt(value)
      {:error, _reason} -> clip(strip_controls(body), @max_excerpt_bytes)
    end
  end

  def excerpt(_body), do: ""

  @doc """
  Sends `request` to one address on `target`.

  Options:

    * `:connect` — injectable connector with the Mint `connect/5` shape
    * `:address` — must be a member of `target.addresses`
    * `:timeout_ms` and `:connect_timeout_ms`
    * `:max_body_bytes`, `:max_header_bytes`, `:max_request_bytes`
    * `:transport_opts` — extra TLS trust material for tests (`:cacerts`)
    * `:now` — pin expiry clock
    * `:proxy` — always refused
  """
  @spec request(UrlPolicy.t(), request(), keyword()) :: {:ok, response()} | {:error, Error.t()}
  def request(%UrlPolicy{} = target, request, opts \\ [])
      when is_map(request) and is_list(opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    cond do
      Keyword.has_key?(opts, :proxy) ->
        {:error,
         fail(:validation, :proxy_forbidden, "Outbound proxy configuration is not allowed.")}

      UrlPolicy.expired?(target, now) ->
        {:error, fail(:validation, :pin_expired, "The destination is no longer valid.")}

      true ->
        dispatch(target, request, opts)
    end
  end

  defp dispatch(target, request, opts) do
    FailureInjection.crash(:before_network_write)

    result =
      with {:ok, prepared} <- prepare_request(target, request, opts),
           {:ok, address} <- select_address(target, opts),
           {:ok, conn} <- open(target, address, opts) do
        exchange(conn, prepared, address, opts)
      end

    FailureInjection.crash_if_ambiguous(result)
  end

  defp prepare_request(target, request, opts) do
    max_request = Keyword.get(opts, :max_request_bytes, max_request_bytes())

    with {:ok, method} <- method(Map.get(request, :method)),
         {:ok, path} <- path(Map.get(request, :path)),
         {:ok, body} <- body(Map.get(request, :body), max_request) do
      headers = request_headers(target, Map.get(request, :headers, []))
      {:ok, %{method: method, path: path, headers: headers, body: body}}
    end
  end

  defp method(method) when is_atom(method) do
    case Map.fetch(@methods, method) do
      {:ok, name} ->
        {:ok, name}

      :error ->
        {:error, fail(:validation, :method_not_allowed, "That HTTP method is not allowed.")}
    end
  end

  defp method(method) when is_binary(method) do
    case Map.fetch(@method_names, String.upcase(method)) do
      {:ok, name} ->
        {:ok, name}

      :error ->
        {:error, fail(:validation, :method_not_allowed, "That HTTP method is not allowed.")}
    end
  end

  defp method(_method) do
    {:error, fail(:validation, :method_not_allowed, "That HTTP method is not allowed.")}
  end

  defp path(path) when is_binary(path) do
    cond do
      not String.starts_with?(path, "/") ->
        {:error, fail(:validation, :path_invalid, "The request path is not valid.")}

      String.starts_with?(path, "//") or String.contains?(path, "://") ->
        {:error, fail(:validation, :path_invalid, "The request path is not valid.")}

      String.contains?(path, [" ", "\r", "\n", "\t"]) ->
        {:error, fail(:validation, :path_invalid, "The request path is not valid.")}

      true ->
        {:ok, path}
    end
  end

  defp path(_path) do
    {:error, fail(:validation, :path_invalid, "The request path is not valid.")}
  end

  defp body(nil, _max), do: {:ok, nil}

  defp body(body, max) when is_binary(body) or is_list(body) do
    bytes = IO.iodata_length(body)

    if bytes > max do
      {:error, fail(:validation, :request_too_large, "The HTTP request body is too large.")}
    else
      {:ok, body}
    end
  end

  defp body(_body, _max) do
    {:error, fail(:validation, :request_invalid, "The HTTP request body is not valid.")}
  end

  defp request_headers(target, headers) when is_list(headers) do
    [
      {"host", host_value(target)},
      {"accept-encoding", "identity"}
      | Enum.flat_map(headers, &keep_header/1)
    ]
  end

  defp request_headers(_target, _headers), do: []

  defp keep_header({name, value}) when is_binary(name) and is_binary(value) do
    if String.downcase(name) in @blocked_headers or String.contains?(value, ["\r", "\n"]) do
      []
    else
      [{name, value}]
    end
  end

  defp keep_header(_header), do: []

  defp host_value(%UrlPolicy{hostname: hostname, scheme: scheme, port: port}) do
    if port == default_port(scheme), do: hostname, else: "#{hostname}:#{port}"
  end

  defp default_port("http"), do: 80
  defp default_port("https"), do: 443
  defp default_port(_scheme), do: nil

  defp select_address(%UrlPolicy{addresses: []}, _opts) do
    {:error, fail(:validation, :target_invalid, "The destination is not valid.")}
  end

  defp select_address(%UrlPolicy{addresses: addresses}, opts) do
    case Keyword.get(opts, :address) do
      nil ->
        {:ok, hd(addresses)}

      address ->
        if address in addresses do
          {:ok, address}
        else
          {:error, fail(:validation, :target_invalid, "The destination is not valid.")}
        end
    end
  end

  defp open(target, address, opts) do
    connect = Keyword.get(opts, :connect, &Transport.connect/5)
    scheme = scheme_atom(target.scheme)

    case connect.(scheme, address, target.port, target.hostname, connect_opts(opts)) do
      {:ok, conn} ->
        {:ok, conn}

      {:error, reason} ->
        {:error, map_connect_error(reason)}

      other ->
        {:error, map_connect_error(other)}
    end
  end

  defp connect_opts(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, timeout_ms())
    connect_ms = Keyword.get(opts, :connect_timeout_ms, @connect_timeout_ms)

    [
      connect_timeout_ms: min(connect_ms, timeout_ms),
      max_header_bytes: Keyword.get(opts, :max_header_bytes, @max_header_bytes),
      transport_opts: Keyword.get(opts, :transport_opts, [])
    ]
  end

  defp exchange(conn, prepared, address, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, timeout_ms())
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    case Transport.exchange(conn, prepared.method, prepared.path, prepared.headers, prepared.body,
           deadline: deadline,
           max_body_bytes: Keyword.get(opts, :max_body_bytes, max_body_bytes()),
           max_header_bytes: Keyword.get(opts, :max_header_bytes, @max_header_bytes)
         ) do
      {:ok, response} ->
        {:ok, Map.put(response, :address, address)}

      {:error, error} ->
        {:error, map_exchange_error(error)}
    end
  end

  defp scheme_atom("https"), do: :https
  defp scheme_atom("http"), do: :http

  defp map_connect_error(%Mint.TransportError{reason: reason}), do: map_connect_reason(reason)
  defp map_connect_error(reason), do: map_connect_reason(reason)

  defp map_connect_reason(reason) do
    cond do
      tls_mismatch?(reason) ->
        fail(:validation, :tls_verify_failed, "The TLS certificate did not match the host.", %{
          phase: :connect,
          request_written?: false
        })

      timeout_reason?(reason) ->
        fail(:timeout, :timeout, "The HTTP request timed out.", %{
          phase: :connect,
          request_written?: false
        })

      true ->
        fail(:dependency, :connect_failed, "The remote host could not be reached.", %{
          phase: :connect,
          request_written?: false
        })
    end
  end

  defp map_exchange_error(%{reason: :body_too_large} = error) do
    fail(:validation, :response_too_large, "The HTTP response is too large.", meta(error))
  end

  defp map_exchange_error(%{reason: :headers_too_large} = error) do
    fail(:validation, :headers_too_large, "The HTTP response headers are too large.", meta(error))
  end

  defp map_exchange_error(%{reason: :compressed} = error) do
    fail(
      :validation,
      :compressed_body,
      "Compressed HTTP responses are not accepted.",
      meta(error)
    )
  end

  defp map_exchange_error(%{reason: :timeout} = error) do
    fail(:timeout, :timeout, "The HTTP request timed out.", meta(error))
  end

  defp map_exchange_error(
         %{reason: %Mint.HTTPError{reason: {:max_header_list_size_exceeded, _, _}}} = error
       ) do
    fail(:validation, :headers_too_large, "The HTTP response headers are too large.", meta(error))
  end

  defp map_exchange_error(%{reason: %Mint.TransportError{reason: reason}} = error) do
    map_written_reason(reason, error)
  end

  defp map_exchange_error(error) do
    map_written_reason(error.reason, error)
  end

  defp map_written_reason(reason, error) do
    if timeout_reason?(reason) do
      fail(:timeout, :timeout, "The HTTP request timed out.", meta(error))
    else
      fail(:dependency, :transport_closed, "The HTTP connection closed.", meta(error))
    end
  end

  defp meta(%{phase: phase, request_written?: written?}) do
    %{phase: phase, request_written?: written?}
  end

  defp tls_mismatch?(reason) do
    case reason do
      {:tls_alert, _} -> true
      {:bad_cert, _} -> true
      {:handshake_failure, _} -> true
      :handshake_failure -> true
      :hostname_check_failed -> true
      _other -> false
    end
  end

  defp timeout_reason?(:timeout), do: true
  defp timeout_reason?(:etimedout), do: true
  defp timeout_reason?(_reason), do: false

  defp fail(class, code, message, details \\ %{phase: :connect, request_written?: false}) do
    Error.new(class, code, message: message, details: details)
  end

  defp locations(headers) do
    Enum.flat_map(headers, fn
      {name, value} when is_binary(name) and is_binary(value) ->
        if String.downcase(name) == "location", do: [value], else: []

      _header ->
        []
    end)
  end

  defp absolute_location(current_url, value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        {:error, fail(:validation, :malformed_redirect, "The redirect did not name a Location.")}

      String.contains?(trimmed, ["\r", "\n", "\t", " "]) ->
        {:error, fail(:validation, :malformed_redirect, "The redirect Location is not valid.")}

      true ->
        merge_location(current_url, trimmed)
    end
  end

  defp merge_location(current_url, value) do
    merged = current_url |> URI.merge(value) |> Map.put(:fragment, nil)

    cond do
      merged.userinfo != nil ->
        {:error, fail(:validation, :url_userinfo, "The URL must not include credentials.")}

      not is_binary(merged.scheme) or not is_binary(merged.host) ->
        {:error, fail(:validation, :malformed_redirect, "The redirect Location is not valid.")}

      true ->
        url = URI.to_string(merged)

        if byte_size(url) > 16 * 1024 do
          {:error, fail(:validation, :malformed_redirect, "The redirect Location is not valid.")}
        else
          {:ok, url}
        end
    end
  rescue
    _reason ->
      {:error, fail(:validation, :malformed_redirect, "The redirect Location is not valid.")}
  end

  defp json_excerpt(value) do
    case Jason.encode(Error.sanitize(value)) do
      {:ok, json} -> clip(json, @max_excerpt_bytes)
      {:error, _reason} -> ""
    end
  end

  defp clip(value, max) when is_binary(value) do
    cond do
      not String.valid?(value) ->
        clip("non-text value, #{byte_size(value)} bytes", max)

      byte_size(value) <= max ->
        value

      true ->
        value
        |> binary_part(0, max)
        |> trim_partial_codepoint()
    end
  end

  defp trim_partial_codepoint(value) do
    if String.valid?(value) do
      value
    else
      value
      |> binary_part(0, byte_size(value) - 1)
      |> trim_partial_codepoint()
    end
  end

  defp strip_controls(value) when is_binary(value) do
    if String.valid?(value) do
      String.replace(value, ~r/[\x00-\x08\x0B\x0C\x0E-\x1F]/, "")
    else
      value
    end
  end
end
