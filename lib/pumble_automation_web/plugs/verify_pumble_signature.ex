defmodule PumbleAutomationWeb.Plugs.VerifyPumbleSignature do
  @moduledoc """
  Authenticates a Pumble callback before anything else looks at it.

  The plug reads `x-pumble-request-signature` and `x-pumble-request-timestamp`,
  both of which are mandatory (`X-2`, `H-10`), and verifies them against the raw
  bytes `PumbleAutomationWeb.Plugs.CacheRawBody` retained. On success it marks
  the connection with `:pumble_signature_verified`; on any failure it answers a
  generic `401` and halts.

  ## Every failure looks the same

  A missing header, a malformed signature, a wrong-length signature, a mismatch,
  and an absent raw body all produce the same status and the same body. The
  response never says which check failed, never echoes the expected signature,
  and never reveals whether a signing secret is configured. A caller that could
  tell those apart could probe for the answer.

  ## Divergence from the Node SDK

  The SDK answers `403 'Invalid signature!'` (`H-17`). This application answers a
  generic `401` with no detail, as plan Section 12.1 requires. The status is the
  only difference; the accepted requests are identical.

  ## No bypass

  The signing secret is read from configuration on every call. When it is absent
  the verification simply fails, so an unconfigured deployment rejects every
  callback instead of accepting every callback. In production the case is
  unreachable: `PumbleAutomation.Config.load_prod!/1` requires
  `PUMBLE_SIGNING_SECRET` and aborts the boot without it. There is no
  environment flag, header, or path that skips this plug.

  ## Raw bytes must already be there

  `conn.private[:raw_body]` is set by `Plug.Parsers` through the cached body
  reader, which only runs when a parser matched the request's content type. A
  callback sent with a content type this application does not parse therefore
  arrives with no raw body, and is refused here rather than verified against an
  empty string.
  """

  @behaviour Plug

  import Plug.Conn

  alias PumbleAutomation.Ingress.RateLimiter
  alias PumbleAutomation.Limits
  alias PumbleAutomation.Pumble.Signature

  @signature_header "x-pumble-request-signature"
  @timestamp_header "x-pumble-request-timestamp"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{} = conn, _opts) do
    key = {:callback_failure, RateLimiter.ip_digest(conn.remote_ip)}
    limit = Limits.get(:callback_failures_per_minute)

    if RateLimiter.limited?(key, limit: limit) do
      Limits.record_hit(:callback_failures, nil)
      emit_verify("rate_limited")
      refuse_rate(conn)
    else
      with {:ok, signature} <- header(conn, @signature_header),
           {:ok, timestamp} <- header(conn, @timestamp_header),
           {:ok, raw_body} <- raw_body(conn),
           true <- Signature.valid?(signing_secret(), timestamp, raw_body, signature) do
        emit_verify("ok")
        put_private(conn, :pumble_signature_verified, true)
      else
        _refused ->
          RateLimiter.hit(key)
          emit_verify("unauthorized")
          refuse(conn)
      end
    end
  end

  @doc "The header carrying the signature."
  @spec signature_header() :: String.t()
  def signature_header, do: @signature_header

  @doc "The header carrying the signed timestamp."
  @spec timestamp_header() :: String.t()
  def timestamp_header, do: @timestamp_header

  # Exactly one value. A repeated header is ambiguous about which value was
  # signed, and picking the first would let a caller append a second.
  defp header(conn, name) do
    case get_req_header(conn, name) do
      [value] -> {:ok, value}
      _none_or_many -> :error
    end
  end

  defp raw_body(%Plug.Conn{private: %{raw_body: raw_body}}) when is_binary(raw_body) do
    {:ok, raw_body}
  end

  defp raw_body(_conn), do: :error

  defp signing_secret do
    :pumble_automation
    |> Application.fetch_env!(:pumble)
    |> Keyword.get(:signing_secret)
  end

  defp refuse(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(401, "unauthorized")
    |> halt()
  end

  defp refuse_rate(conn) do
    conn
    |> put_resp_header("retry-after", "60")
    |> put_resp_content_type("text/plain")
    |> send_resp(429, "too many requests")
    |> halt()
  end

  defp emit_verify(status) do
    PumbleAutomation.Telemetry.execute(
      [:pumble_automation, :pumble, :callback, :verify],
      %{count: 1},
      %{operation: "callback.verify", status: status}
    )
  end
end
