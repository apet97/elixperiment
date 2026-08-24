defmodule PumbleAutomationWeb.Plugs.SecurityHeaders do
  @moduledoc """
  The HTTP security headers every response carries.

  Browser routes also set Content-Security-Policy through
  `put_secure_browser_headers` in the router so Sobelow can see a literal
  policy. This plug is the source of the other headers and the policy that
  non-browser routes (health, Pumble callbacks, inbound webhooks) receive,
  because those pipelines never call `put_secure_browser_headers`.

  ## Frame ancestors

  Pumble does not embed this add-on in a marketplace iframe in v1. The
  configuration and OAuth surfaces are top-level navigations. `frame-ancestors
  'self'` and `X-Frame-Options: SAMEORIGIN` are therefore the whole frame
  policy. A wildcard origin is never correct here.

  ## CORS

  There is no cross-origin browser API. This plug never sets
  `Access-Control-Allow-Origin`. A caller that sends `Origin` gets the same
  response it would without that header.

  ## HSTS

  `Strict-Transport-Security` is set on every response. Browsers ignore it on
  cleartext `localhost`. Production also enables Phoenix `force_ssl` so an HTTP
  request is redirected before a session cookie is written.
  """

  @behaviour Plug

  import Plug.Conn

  # Keep this string identical to the `:browser` pipeline map in the router.
  # Sobelow Config.CSP reads the router literal; this module is what every
  # other pipeline uses.
  @csp "default-src 'self'; base-uri 'self'; font-src 'self'; img-src 'self' data:; object-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self' ws: wss:; form-action 'self'; frame-ancestors 'self'; frame-src 'none'"

  @hsts "max-age=31536000; includeSubDomains"

  @headers %{
    "content-security-policy" => @csp,
    "referrer-policy" => "strict-origin-when-cross-origin",
    "x-content-type-options" => "nosniff",
    "x-frame-options" => "SAMEORIGIN",
    "permissions-policy" =>
      "camera=(), microphone=(), geolocation=(), payment=(), usb=(), browsing-topics=()",
    "x-permitted-cross-domain-policies" => "none",
    "x-download-options" => "noopen",
    "cross-origin-opener-policy" => "same-origin",
    "cross-origin-resource-policy" => "same-origin",
    "strict-transport-security" => @hsts
  }

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{} = conn, _opts) do
    register_before_send(conn, &put_headers/1)
  end

  @doc "The Content-Security-Policy applied to every HTML response."
  @spec csp() :: String.t()
  def csp, do: @csp

  @doc "Every header this plug writes, including CSP and HSTS."
  @spec headers() :: %{String.t() => String.t()}
  def headers, do: @headers

  defp put_headers(conn) do
    Enum.reduce(@headers, conn, fn {name, value}, conn ->
      put_resp_header(conn, name, value)
    end)
  end
end
