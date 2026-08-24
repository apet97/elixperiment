defmodule PumbleAutomation.Connections.IpPolicyTest do
  @moduledoc """
  URL and IP policy refuse every documented SSRF bypass before a socket
  exists. DNS is injected; nothing here opens a connection.
  """

  use ExUnit.Case, async: true

  alias PumbleAutomation.Connections.IpPolicy
  alias PumbleAutomation.Connections.UrlPolicy
  alias PumbleAutomation.Error

  @public_v4 {1, 1, 1, 1}
  @public_v6 {0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8888}
  @now ~U[2026-08-18 12:00:00.000000Z]

  defp public_dns(addrs \\ [@public_v4]) do
    fn _host -> {:ok, List.wrap(addrs)} end
  end

  defp approve(url, opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:resolver, public_dns())
      |> Keyword.put_new(:now, @now)

    UrlPolicy.approve(url, opts)
  end

  describe "IpPolicy.classify/1 IPv4 classes" do
    @ipv4_cases [
      {{0, 0, 0, 0}, :unspecified},
      {{0, 255, 255, 255}, :unspecified},
      {{10, 0, 0, 1}, :private},
      {{10, 255, 255, 255}, :private},
      {{100, 64, 0, 1}, :cgnat},
      {{100, 127, 255, 255}, :cgnat},
      {{127, 0, 0, 1}, :loopback},
      {{127, 255, 255, 255}, :loopback},
      {{169, 254, 0, 1}, :link_local},
      {{169, 254, 169, 254}, :metadata},
      {{169, 254, 170, 2}, :metadata},
      {{169, 254, 169, 253}, :metadata},
      {{172, 16, 0, 1}, :private},
      {{172, 31, 255, 255}, :private},
      {{192, 0, 0, 1}, :reserved},
      {{192, 0, 2, 1}, :documentation},
      {{192, 88, 99, 1}, :reserved},
      {{192, 168, 0, 1}, :private},
      {{198, 18, 0, 1}, :benchmark},
      {{198, 19, 255, 255}, :benchmark},
      {{198, 51, 100, 1}, :documentation},
      {{203, 0, 113, 1}, :documentation},
      {{224, 0, 0, 1}, :multicast},
      {{239, 255, 255, 255}, :multicast},
      {{240, 0, 0, 1}, :reserved},
      {{255, 255, 255, 255}, :reserved}
    ]

    @ipv4_public [
      {1, 1, 1, 1},
      {8, 8, 8, 8},
      {9, 9, 9, 9},
      {11, 0, 0, 1},
      {100, 63, 255, 255},
      {100, 128, 0, 1},
      {126, 255, 255, 255},
      {128, 0, 0, 1},
      {172, 15, 255, 255},
      {172, 32, 0, 1},
      {192, 167, 255, 255},
      {192, 169, 0, 1}
    ]

    test "every blocked IPv4 class is named" do
      for {ip, reason} <- @ipv4_cases do
        assert IpPolicy.classify(ip) == {:blocked, reason},
               "#{inspect(ip)} expected #{reason}"

        refute IpPolicy.allowed?(ip)
      end
    end

    test "adjacent public IPv4 addresses stay public" do
      for ip <- @ipv4_public do
        assert IpPolicy.classify(ip) == :public, "#{inspect(ip)} was blocked"
        assert IpPolicy.allowed?(ip)
      end
    end
  end

  describe "IpPolicy.classify/1 IPv6 classes" do
    @ipv6_cases [
      {{0, 0, 0, 0, 0, 0, 0, 0}, :unspecified},
      {{0, 0, 0, 0, 0, 0, 0, 1}, :loopback},
      {{0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}, :mapped},
      {{0, 0, 0, 0, 0, 0xFFFF, 2056, 2056}, :mapped},
      {{0x64, 0xFF9B, 0, 0, 0, 0, 0x7F00, 1}, :mapped},
      {{0x0100, 0, 0, 0, 0, 0, 0, 1}, :reserved},
      {{0x2001, 0x0002, 0, 0, 0, 0, 0, 1}, :benchmark},
      {{0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1}, :documentation},
      {{0x2001, 0, 0, 0, 0, 0, 0, 1}, :reserved},
      {{0x2002, 0, 0, 0, 0, 0, 0, 1}, :reserved},
      {{0xFC00, 0, 0, 0, 0, 0, 0, 1}, :unique_local},
      {{0xFD00, 0, 0, 0, 0, 0, 0, 1}, :unique_local},
      {{0xFD00, 0xEC2, 0, 0, 0, 0, 0, 0x254}, :metadata},
      {{0xFE80, 0, 0, 0, 0, 0, 0, 1}, :link_local},
      {{0xFF02, 0, 0, 0, 0, 0, 0, 1}, :multicast}
    ]

    test "every blocked IPv6 class is named" do
      for {ip, reason} <- @ipv6_cases do
        assert IpPolicy.classify(ip) == {:blocked, reason},
               "#{inspect(ip)} expected #{reason}"
      end
    end

    test "a public IPv6 unicast address is allowed" do
      assert IpPolicy.classify(@public_v6) == :public
    end

    test "addresses just outside unique-local and link-local stay public" do
      adjacent_public = [
        {0xFBFF, 0, 0, 0, 0, 0, 0, 1},
        {0xFE00, 0, 0, 0, 0, 0, 0, 1},
        {0xFE7F, 0xFFFF, 0, 0, 0, 0, 0, 1}
      ]

      for ip <- adjacent_public do
        assert IpPolicy.classify(ip) == :public, "#{inspect(ip)} was blocked"
        assert IpPolicy.allowed?(ip)
      end
    end

    test "addresses adjacent to 2001:db8 documentation stay public" do
      assert IpPolicy.classify({0x2001, 0x0DB7, 0, 0, 0, 0, 0, 1}) == :public
      assert IpPolicy.classify({0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1}) == {:blocked, :documentation}
      assert IpPolicy.classify({0x2001, 0x0DB9, 0, 0, 0, 0, 0, 1}) == :public
    end

    test "an unknown shape is blocked" do
      assert IpPolicy.classify({1, 2, 3}) == {:blocked, :reserved}
      assert IpPolicy.classify("127.0.0.1") == {:blocked, :reserved}
    end
  end

  describe "IpPolicy.parse_literal/1" do
    test "strict dotted-quad and IPv6 are canonical" do
      assert {:canonical, {127, 0, 0, 1}} = IpPolicy.parse_literal("127.0.0.1")
      assert {:canonical, {8, 8, 8, 8}} = IpPolicy.parse_literal("8.8.8.8")
      assert {:canonical, {0, 0, 0, 0, 0, 0, 0, 1}} = IpPolicy.parse_literal("::1")
    end

    test "decimal, hex, octal, and shortened IPv4 are non-canonical" do
      tricks = [
        "2130706433",
        "0x7f000001",
        "0177.0.0.1",
        "127.1",
        "127.0.1",
        "0",
        "0x7f.1",
        "0x7f.0x0.0x0.0x1"
      ]

      for host <- tricks do
        assert IpPolicy.parse_literal(host) == :non_canonical, "#{host} was not a trick"
      end
    end

    test "a hostname is not an IP literal" do
      assert IpPolicy.parse_literal("example.com") == :error
      assert IpPolicy.parse_literal("localhost") == :error
    end
  end

  describe "UrlPolicy.approve/2 scheme and shape" do
    test "a public HTTPS host returns a pin with original hostname and short expiry" do
      assert {:ok, target} = approve("https://Example.COM./path?q=1")
      assert %UrlPolicy{} = target
      assert target.scheme == "https"
      assert target.hostname == "example.com"
      assert target.port == 443
      assert target.addresses == [@public_v4]
      assert target.expires_at == DateTime.add(@now, UrlPolicy.ttl_ms(), :millisecond)
      refute UrlPolicy.expired?(target, @now)
      assert UrlPolicy.expired?(target, target.expires_at)
    end

    test "a URL without a scheme defaults to HTTPS" do
      assert {:ok, target} = approve("example.com/v1")
      assert target.scheme == "https"
      assert target.hostname == "example.com"
    end

    test "HTTP is refused unless the caller explicitly allows it" do
      assert {:error, %Error{class: :validation, code: :http_not_allowed, retryable?: false}} =
               approve("http://example.com")

      assert {:ok, target} = approve("http://example.com", allow_http: true)
      assert target.scheme == "http"
      assert target.port == 80
    end

    test "non-HTTP schemes, userinfo, fragments, and invalid ports are permanent" do
      refusals = [
        {"ftp://example.com", :scheme_not_allowed},
        {"file:///etc/passwd", :host_invalid},
        {"javascript:alert(1)", :host_invalid},
        {"https://user:pass@example.com", :url_userinfo},
        {"https://user@example.com", :url_userinfo},
        {"https://example.com#frag", :url_fragment},
        {"https://example.com:0", :port_invalid},
        {"https://example.com:65536", :port_invalid},
        {"https://example.com:abc", :port_invalid},
        {"https://example.com:-1", :port_invalid}
      ]

      for {url, code} <- refusals do
        assert {:error, %Error{class: :validation, code: ^code, retryable?: false}} =
                 approve(url),
               "#{url} expected #{code}"
      end
    end

    test "a non-default public port is kept" do
      assert {:ok, target} = approve("https://example.com:8443")
      assert target.port == 8443
    end

    test "proxy configuration from the caller is refused" do
      assert {:error, %Error{class: :validation, code: :proxy_forbidden, retryable?: false}} =
               approve("https://example.com", proxy: "http://127.0.0.1:8080")
    end
  end

  describe "UrlPolicy.approve/2 localhost and metadata names" do
    test "localhost variants are blocked before DNS" do
      names = [
        "https://localhost",
        "https://localhost.",
        "https://LocalHost",
        "https://localhost.localdomain",
        "https://foo.localhost",
        "https://ip6-localhost",
        "https://ip6-loopback"
      ]

      for url <- names do
        assert {:error, %Error{code: :target_blocked, retryable?: false} = error} =
                 approve(url, resolver: fn _ -> flunk("DNS ran for #{url}") end),
               "#{url} reached DNS"

        assert error.details.reason == :name
      end
    end

    test "cloud metadata names are blocked before DNS" do
      names = [
        "https://metadata.google.internal",
        "https://metadata.google.internal.",
        "https://metadata",
        "https://instance-data",
        "https://kubernetes",
        "https://kubernetes.default",
        "https://foo.metadata.google.internal"
      ]

      for url <- names do
        assert {:error, %Error{code: :target_blocked} = error} =
                 approve(url, resolver: fn _ -> flunk("DNS ran for #{url}") end),
               "#{url} reached DNS"

        assert error.details.reason == :name
      end
    end
  end

  describe "UrlPolicy.approve/2 IP literals" do
    test "a public IPv4 literal is approved without DNS" do
      assert {:ok, target} =
               approve("https://1.1.1.1", resolver: fn _ -> flunk("DNS ran for a literal") end)

      assert target.hostname == "1.1.1.1"
      assert target.addresses == [{1, 1, 1, 1}]
    end

    test "a public IPv6 literal keeps the original hostname for SNI" do
      assert {:ok, target} =
               approve("https://[2001:4860:4860::8888]/",
                 resolver: fn _ -> flunk("DNS ran for a literal") end
               )

      assert target.hostname == "2001:4860:4860::8888"
      assert target.addresses == [@public_v6]
    end

    test "loopback, private, link-local, and metadata literals are blocked" do
      urls = [
        "https://127.0.0.1",
        "https://10.0.0.1",
        "https://192.168.1.1",
        "https://172.16.0.1",
        "https://169.254.169.254",
        "https://169.254.1.1",
        "https://100.64.0.1",
        "https://0.0.0.0",
        "https://[::1]",
        "https://[::ffff:127.0.0.1]",
        "https://[::ffff:8.8.8.8]",
        "https://[fd00::1]",
        "https://[fe80::1]",
        "https://[2001:db8::1]"
      ]

      for url <- urls do
        assert {:error, %Error{code: :target_blocked, retryable?: false}} = approve(url),
               "#{url} was accepted"
      end
    end

    test "decimal, hex, octal, and shortened IPv4 tricks are refused" do
      urls = [
        "https://2130706433",
        "https://0x7f000001",
        "https://0177.0.0.1",
        "https://127.1",
        "https://127.0.1",
        "https://0",
        "https://0x7f.1",
        "https://0x7f.0x0.0x0.0x1"
      ]

      for url <- urls do
        assert {:error, %Error{code: :ip_literal_noncanonical, retryable?: false}} =
                 approve(url),
               "#{url} was accepted"
      end
    end

    test "IPv4-mapped IPv6 is blocked even when the embedded address is public" do
      assert {:error, %Error{code: :target_blocked} = error} =
               approve("https://[::ffff:1.1.1.1]/")

      assert error.details.reason == :mapped
    end
  end

  describe "UrlPolicy.approve/2 DNS" do
    test "every resolved address must be public" do
      assert {:error, %Error{code: :target_blocked} = error} =
               approve("https://example.com", resolver: public_dns([@public_v4, {127, 0, 0, 1}]))

      refute error.retryable?
      assert error.details.reason == :loopback
    end

    test "an IPv6-only public answer is accepted" do
      assert {:ok, target} =
               approve("https://example.com", resolver: public_dns([@public_v6]))

      assert target.addresses == [@public_v6]
    end

    test "DNS failure is transient" do
      assert {:error, %Error{class: :dependency, code: :dns_failed, retryable?: true}} =
               approve("https://example.com", resolver: fn _ -> {:error, :nxdomain} end)

      assert {:error, %Error{class: :dependency, code: :dns_failed, retryable?: true}} =
               approve("https://example.com", resolver: fn _ -> {:error, :timeout} end)
    end

    test "an empty answer is transient" do
      assert {:error, %Error{class: :dependency, code: :dns_failed, retryable?: true}} =
               approve("https://example.com", resolver: fn _ -> {:ok, []} end)
    end

    test "the resolver sees the normalised ASCII hostname" do
      parent = self()

      resolver = fn host ->
        send(parent, {:resolved, host})
        {:ok, [@public_v4]}
      end

      assert {:ok, _} = approve("HTTPS://Example.COM.", resolver: resolver)
      assert_received {:resolved, "example.com"}
    end

    test "each call resolves again" do
      agent =
        start_supervised!({Agent, fn -> [@public_v4] end})

      resolver = fn _ -> {:ok, Agent.get(agent, & &1)} end

      assert {:ok, _} = approve("https://example.com", resolver: resolver)
      :ok = Agent.update(agent, fn _ -> [{127, 0, 0, 1}] end)

      assert {:error, %Error{code: :target_blocked}} =
               approve("https://example.com", resolver: resolver)
    end
  end

  describe "UrlPolicy.approve/2 IDNA" do
    test "a single-script unicode label is encoded to an A-label" do
      parent = self()

      resolver = fn host ->
        send(parent, {:resolved, host})
        {:ok, [@public_v4]}
      end

      assert {:ok, target} = approve("https://münchen.example", resolver: resolver)
      assert target.hostname == "xn--mnchen-3ya.example"
      assert_received {:resolved, "xn--mnchen-3ya.example"}
    end

    test "a mixed Latin and Cyrillic label is confusion and is refused" do
      assert {:error, %Error{code: :host_idna_confusion, retryable?: false}} =
               approve("https://еxample.com", resolver: fn _ -> flunk("DNS ran") end)
    end

    test "an already-encoded A-label is not double-encoded" do
      parent = self()

      resolver = fn host ->
        send(parent, {:resolved, host})
        {:ok, [@public_v4]}
      end

      assert {:ok, target} = approve("https://xn--mnchen-3ya.example", resolver: resolver)
      assert target.hostname == "xn--mnchen-3ya.example"
      assert_received {:resolved, "xn--mnchen-3ya.example"}
    end
  end

  describe "UrlPolicy.approve/2 host limits" do
    test "an overlong label, overlong host, empty label, and hyphen edges are refused" do
      long_label = String.duplicate("a", 64)
      long_host = Enum.map_join(1..20, ".", fn _ -> String.duplicate("a", 63) end)

      refusals = [
        "https://#{long_label}.com",
        "https://#{long_host}",
        "https://a..b.com",
        "https://.example.com",
        "https://-example.com",
        "https://example-.com",
        "https://exam_ple.com",
        "https://exam ple.com"
      ]

      for url <- refusals do
        assert {:error, %Error{class: :validation, retryable?: false}} = approve(url),
               "#{url} was accepted"
      end
    end
  end

  describe "UrlPolicy messages" do
    test "errors never name the host or the address" do
      {:error, blocked} = approve("https://127.0.0.1")
      {:error, named} = approve("https://localhost")

      {:error, mixed} =
        approve("https://example.com", resolver: public_dns([@public_v4, {10, 0, 0, 1}]))

      for error <- [blocked, named, mixed] do
        rendered = error.message <> inspect(error.details)
        refute rendered =~ "127.0.0.1"
        refute rendered =~ "localhost"
        refute rendered =~ "10.0.0.1"
        refute rendered =~ "example.com"
      end
    end
  end
end
