defmodule PumbleAutomationWeb.Plugs.HostAllowlist do
  @moduledoc """
  Rejects requests whose `Host` is not the configured public host.

  Production sets `:allowed_hosts` from `PUBLIC_BASE_URL`. An unset or
  `:any` value leaves the check off, which is the development and test
  default so `Phoenix.ConnTest`'s `www.example.com` host keeps working.

  The allowlist reads `conn.host`, which Plug takes from the `Host`
  header. It never consults `X-Forwarded-Host`, so a client cannot name a
  different host by forging a forwarding header.

  Liveness and readiness stay reachable on any host: orchestrators probe
  loopback and cluster-internal names that are not the public URL.
  """

  @behaviour Plug

  import Plug.Conn

  @health_paths ["/health/live", "/health/ready"]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{} = conn, opts) do
    if health?(conn) or allowed?(conn, hosts_from(opts)) do
      conn
    else
      conn
      |> send_resp(400, "Bad Request")
      |> halt()
    end
  end

  @doc "The configured allowlist, or `:any` when the check is off."
  @spec allowed_hosts() :: :any | [String.t()]
  def allowed_hosts do
    Application.get_env(:pumble_automation, :allowed_hosts, :any)
  end

  defp hosts_from(opts), do: Keyword.get(opts, :allowed_hosts, allowed_hosts())

  defp health?(conn), do: conn.request_path in @health_paths

  defp allowed?(_conn, :any), do: true

  defp allowed?(conn, hosts) when is_list(hosts), do: conn.host in hosts

  defp allowed?(_conn, _other), do: false
end
