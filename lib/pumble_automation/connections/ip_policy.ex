defmodule PumbleAutomation.Connections.IpPolicy do
  @moduledoc """
  The address classes a workflow HTTP request may never target.

  Plan Section 26's SSRF algorithm resolves every name, then refuses the
  request if **any** returned address is blocked. This module is that
  classification, and nothing else: it does not parse URLs, it does not talk
  to DNS, and it does not open sockets. `PumbleAutomation.Connections.UrlPolicy`
  is the caller that feeds it every A and AAAA result.

  ## Every address, not one

  An allow-if-any-public rule is how DNS rebinding wins. A name that returns
  `8.8.8.8` and `127.0.0.1` is blocked, even though a public address was in
  the set. The transport later pins to one validated address from a set that
  has already been shown to contain only public ones.

  ## Mapped and non-canonical forms

  IPv4-mapped IPv6 (`::ffff:0:0/96`) is refused as its own class, including a
  mapping of a public IPv4 address. Connecting to `::ffff:8.8.8.8` is still a
  mapped form, and the plan lists mapped IPv4 as blocked.

  Decimal, hex, octal, and shortened IPv4 literals (`2130706433`,
  `0x7f000001`, `0177.0.0.1`, `127.1`) are not canonical addresses. They are
  the historical browser tricks. `parse_literal/1` names them so the URL
  policy can refuse the host before anyone treats it as a DNS name.
  """

  import Bitwise

  @type reason ::
          :loopback
          | :unspecified
          | :private
          | :cgnat
          | :link_local
          | :unique_local
          | :mapped
          | :multicast
          | :documentation
          | :benchmark
          | :reserved
          | :metadata

  @type classification :: :public | {:blocked, reason()}

  @type ip_address :: :inet.ip_address()

  # More specific prefixes first. 169.254.169.254 is link-local *and* the
  # cloud metadata endpoint; naming it metadata makes the test table prove
  # the case the threat model cares about, rather than an adjacent range.
  @ipv4_blocks [
    {{169, 254, 169, 254}, 32, :metadata},
    {{169, 254, 170, 2}, 32, :metadata},
    {{169, 254, 169, 253}, 32, :metadata},
    {{0, 0, 0, 0}, 8, :unspecified},
    {{10, 0, 0, 0}, 8, :private},
    {{100, 64, 0, 0}, 10, :cgnat},
    {{127, 0, 0, 0}, 8, :loopback},
    {{169, 254, 0, 0}, 16, :link_local},
    {{172, 16, 0, 0}, 12, :private},
    {{192, 0, 0, 0}, 24, :reserved},
    {{192, 0, 2, 0}, 24, :documentation},
    {{192, 88, 99, 0}, 24, :reserved},
    {{192, 168, 0, 0}, 16, :private},
    {{198, 18, 0, 0}, 15, :benchmark},
    {{198, 51, 100, 0}, 24, :documentation},
    {{203, 0, 113, 0}, 24, :documentation},
    {{224, 0, 0, 0}, 4, :multicast},
    {{240, 0, 0, 0}, 4, :reserved}
  ]

  @ipv6_blocks [
    {{0xFD00, 0xEC2, 0, 0, 0, 0, 0, 0x254}, 128, :metadata},
    {{0, 0, 0, 0, 0, 0, 0, 0}, 128, :unspecified},
    {{0, 0, 0, 0, 0, 0, 0, 1}, 128, :loopback},
    {{0, 0, 0, 0, 0, 0xFFFF, 0, 0}, 96, :mapped},
    {{0x64, 0xFF9B, 0, 0, 0, 0, 0, 0}, 96, :mapped},
    {{0x64, 0xFF9B, 1, 0, 0, 0, 0, 0}, 48, :mapped},
    {{0, 0, 0, 0, 0, 0, 0, 0}, 96, :mapped},
    {{0x0100, 0, 0, 0, 0, 0, 0, 0}, 64, :reserved},
    {{0x2001, 0x0002, 0, 0, 0, 0, 0, 0}, 48, :benchmark},
    {{0x2001, 0x0010, 0, 0, 0, 0, 0, 0}, 28, :reserved},
    {{0x2001, 0x0020, 0, 0, 0, 0, 0, 0}, 28, :reserved},
    {{0x2001, 0x0DB8, 0, 0, 0, 0, 0, 0}, 32, :documentation},
    {{0x2001, 0, 0, 0, 0, 0, 0, 0}, 32, :reserved},
    {{0x2002, 0, 0, 0, 0, 0, 0, 0}, 16, :reserved},
    {{0xFC00, 0, 0, 0, 0, 0, 0, 0}, 7, :unique_local},
    {{0xFE80, 0, 0, 0, 0, 0, 0, 0}, 10, :link_local},
    {{0xFF00, 0, 0, 0, 0, 0, 0, 0}, 8, :multicast}
  ]

  @doc "Returns whether an address is in public unicast space."
  @spec allowed?(term()) :: boolean()
  def allowed?(ip), do: classify(ip) == :public

  @doc """
  Classifies an IPv4 or IPv6 tuple.

  Unknown shapes are blocked: a value this module cannot name is not a
  public address.
  """
  @spec classify(term()) :: classification()
  def classify(ip) when tuple_size(ip) == 4 do
    classify_against(ip, @ipv4_blocks)
  end

  def classify(ip) when tuple_size(ip) == 8 do
    classify_against(ip, @ipv6_blocks)
  end

  def classify(_ip), do: {:blocked, :reserved}

  @doc """
  Reads a host string as an IP literal.

  `:canonical` is a strict IPv4 dotted-quad or a strict IPv6 literal.
  `:non_canonical` is every decimal, hex, octal, shortened, or otherwise
  browser-legacy form that still names an address. `:error` means the host
  is not an IP literal and must go through DNS.
  """
  @spec parse_literal(String.t()) :: {:canonical, ip_address()} | :non_canonical | :error
  def parse_literal(host) when is_binary(host) do
    chars = String.to_charlist(host)

    case {:inet.parse_strict_address(chars), :inet.parse_address(chars)} do
      {{:ok, ip}, _} -> {:canonical, ip}
      {{:error, _}, {:ok, _ip}} -> :non_canonical
      _other -> if ip_shaped?(host), do: :non_canonical, else: :error
    end
  end

  defp classify_against(ip, blocks) do
    case Enum.find(blocks, fn {base, bits, _reason} -> prefix_match?(ip, base, bits) end) do
      {_base, _bits, reason} -> {:blocked, reason}
      nil -> :public
    end
  end

  defp prefix_match?(ip, base, bits) when tuple_size(ip) == tuple_size(base) do
    size = if tuple_size(ip) == 4, do: 32, else: 128
    bsr(to_integer(ip), size - bits) == bsr(to_integer(base), size - bits)
  end

  defp to_integer({a, b, c, d}) do
    a * 0x1000000 + b * 0x10000 + c * 0x100 + d
  end

  defp to_integer({a, b, c, d, e, f, g, h}) do
    <<n::128>> = <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>
    n
  end

  # Digits, dots, and 0x only — the alphabet of IPv4 tricks. A real hostname
  # almost always carries a letter outside a–f once a TLD is present; the
  # remainder is fail-closed because a name that looks like an address is
  # how the bypasses in the test table are written.
  defp ip_shaped?(host) do
    String.match?(host, ~r/\A(?:0x[0-9a-fA-F]+|\d+)(?:\.(?:0x[0-9a-fA-F]+|\d+))*\z/)
  end
end
