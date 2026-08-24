defmodule PumbleAutomationWeb.Plugs.TrustedProxies do
  @moduledoc """
  Rewrites `conn.remote_ip` from `X-Forwarded-For` only when the TCP peer is
  a configured trusted proxy.

  An empty proxy list — the default — leaves the peer address alone, so a
  client cannot spoof a forwarding header. Production sets `TRUSTED_PROXIES`
  to the CIDRs of the load balancer. This plug never logs the header and never
  rewrites the host from `X-Forwarded-Host`.
  """

  @behaviour Plug

  import Plug.Conn

  alias PumbleAutomation.Limits

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{} = conn, _opts) do
    proxies = Limits.trusted_proxies()
    %{conn | remote_ip: client_ip(conn, proxies)}
  end

  defp client_ip(conn, []), do: conn.remote_ip

  defp client_ip(conn, proxies) do
    if trusted?(conn.remote_ip, proxies) do
      conn
      |> forwarded_hops()
      |> pick_client(conn.remote_ip, proxies)
    else
      conn.remote_ip
    end
  end

  defp forwarded_hops(conn) do
    conn
    |> get_req_header("x-forwarded-for")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.flat_map(&parse_ip/1)
  end

  defp parse_ip(value) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, ip} -> [ip]
      {:error, :einval} -> []
    end
  end

  defp pick_client([], peer, _proxies), do: peer

  defp pick_client(hops, _peer, proxies) do
    hops
    |> Enum.reverse()
    |> Enum.drop_while(&trusted?(&1, proxies))
    |> case do
      [client | _rest] -> client
      [] -> hd(hops)
    end
  end

  defp trusted?(ip, proxies) when is_tuple(ip) do
    Enum.any?(proxies, fn {net, prefix} -> in_cidr?(ip, net, prefix) end)
  end

  defp trusted?(_ip, _proxies), do: false

  defp in_cidr?({a, b, c, d}, {e, f, g, h}, prefix)
       when prefix >= 0 and prefix <= 32 do
    <<ip::32>> = <<a, b, c, d>>
    <<net::32>> = <<e, f, g, h>>
    mask = ipv4_mask(prefix)
    Bitwise.band(ip, mask) == Bitwise.band(net, mask)
  end

  defp in_cidr?(
         {a, b, c, d, e, f, g, h},
         {i, j, k, l, m, n, o, p},
         prefix
       )
       when prefix >= 0 and prefix <= 128 do
    <<ip::128>> = <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>
    <<net::128>> = <<i::16, j::16, k::16, l::16, m::16, n::16, o::16, p::16>>
    mask = ipv6_mask(prefix)
    Bitwise.band(ip, mask) == Bitwise.band(net, mask)
  end

  defp in_cidr?(_ip, _net, _prefix), do: false

  defp ipv4_mask(0), do: 0
  defp ipv4_mask(prefix), do: Bitwise.bsl(0xFFFFFFFF, 32 - prefix)

  defp ipv6_mask(0), do: 0
  defp ipv6_mask(prefix), do: Bitwise.bsl(Bitwise.bsl(1, 128) - 1, 128 - prefix)
end
