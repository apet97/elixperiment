defmodule PumbleAutomation.Connections.SafeHttpTransportTest do
  @moduledoc """
  DNS-pinned outbound transport: the socket goes to a validated IP, TLS
  identity stays on the original hostname, and streamed responses stay bounded.
  """

  use ExUnit.Case, async: true

  alias PumbleAutomation.Connections.SafeHttp
  alias PumbleAutomation.Connections.UrlPolicy
  alias PumbleAutomation.Error
  alias PumbleAutomation.HttpTestServer

  describe "destination pinning" do
    test "keeps the pinned address when DNS later returns a different answer" do
      approved = {1, 1, 1, 1}
      rebound = {8, 8, 8, 8}
      box = start_box()

      {:ok, target} =
        UrlPolicy.approve("https://example.com/hooks",
          resolver: fn "example.com" -> {:ok, [approved]} end
        )

      connect = fn scheme, address, port, hostname, opts ->
        put_box(box, %{
          scheme: scheme,
          address: address,
          port: port,
          hostname: hostname,
          opts_keys: Keyword.keys(opts)
        })

        {:error, :econnrefused}
      end

      assert {:error, %Error{} = error} =
               SafeHttp.request(target, %{method: :get, path: "/hooks"}, connect: connect)

      observed = get_box(box)
      assert observed.scheme == :https
      assert observed.address == approved
      assert observed.address != rebound
      assert observed.port == 443
      assert observed.hostname == "example.com"
      refute :proxy in observed.opts_keys
      assert error.code == :connect_failed
      assert error.details.phase == :connect
      refute error.details.request_written?
    end

    test "connects to the pin address, not the hostname" do
      pid = start_supervised!({HttpTestServer, handler: &echo/1})
      info = HttpTestServer.info(pid)
      public = {1, 1, 1, 1}
      box = start_box()

      target = %UrlPolicy{
        scheme: "http",
        hostname: "example.test",
        port: info.port,
        addresses: [public],
        expires_at: DateTime.add(DateTime.utc_now(), 10_000, :millisecond)
      }

      connect = fn scheme, address, port, hostname, opts ->
        merge_box(box, %{
          scheme: scheme,
          address: address,
          port: port,
          hostname: hostname
        })

        SafeHttp.Transport.connect(scheme, info.ip, port, hostname, opts)
      end

      assert {:ok, response} =
               SafeHttp.request(target, %{method: :get, path: "/pinned"}, connect: connect)

      observed = get_box(box)
      assert observed.address == public
      assert observed.hostname == "example.test"
      refute is_binary(observed.address)
      assert response.address == public
      assert response.status == 200
      assert response.body == "GET /pinned"
    end
  end

  describe "Host and SNI" do
    test "sends the original hostname as Host and identity Accept-Encoding" do
      box = start_box()

      pid =
        start_supervised!(
          {HttpTestServer,
           handler: fn conn ->
             put_box(box, %{
               host: Plug.Conn.get_req_header(conn, "host"),
               encoding: Plug.Conn.get_req_header(conn, "accept-encoding")
             })

             echo(conn)
           end}
        )

      info = HttpTestServer.info(pid)
      target = pin(info, hostname: "example.test")

      assert {:ok, response} = SafeHttp.request(target, %{method: :get, path: "/v1"})
      assert response.status == 200
      observed = get_box(box)
      assert observed.host == ["example.test:#{info.port}"]
      assert observed.encoding == ["identity"]
    end

    test "uses the original hostname for SNI and certificate verification" do
      box = start_box()
      hostname = HttpTestServer.hostname()

      pid =
        start_supervised!(
          {HttpTestServer,
           mode: :https,
           handler: fn conn ->
             merge_box(box, %{host: Plug.Conn.get_req_header(conn, "host")})
             Plug.Conn.send_resp(conn, 200, "tls-ok")
           end}
        )

      info = HttpTestServer.info(pid)
      target = pin(info, scheme: "https", hostname: hostname)
      wrap = record_connect(box, info)

      assert {:ok, response} =
               SafeHttp.request(target, %{method: :get, path: "/secure"},
                 connect: wrap,
                 transport_opts: [cacerts: info.cacerts]
               )

      assert response.status == 200
      assert response.body == "tls-ok"
      observed = get_box(box)
      assert observed.host == ["#{hostname}:#{info.port}"]
      assert observed.hostname == hostname
      assert is_tuple(observed.address)
    end

    test "fails closed when the certificate does not match the hostname" do
      pid = start_supervised!({HttpTestServer, mode: :https})
      info = HttpTestServer.info(pid)
      target = pin(info, scheme: "https", hostname: "other.test.local")

      assert {:error, %Error{} = error} =
               SafeHttp.request(target, %{method: :get, path: "/"},
                 transport_opts: [cacerts: info.cacerts]
               )

      assert error.code == :tls_verify_failed
      refute error.retryable?
      refute error.details.request_written?
      assert error.details.phase == :connect
    end
  end

  describe "timeouts" do
    test "timeout before write does not report that bytes were sent" do
      pid = start_supervised!({HttpTestServer, mode: :tcp})
      info = HttpTestServer.info(pid)
      target = pin(info, scheme: "https", hostname: HttpTestServer.hostname())

      assert {:error, %Error{} = error} =
               SafeHttp.request(target, %{method: :post, path: "/write", body: "payload"},
                 timeout_ms: 100,
                 connect_timeout_ms: 100
               )

      assert error.class == :timeout
      assert error.details.phase == :connect
      refute error.details.request_written?
    end

    test "timeout after write reports that request bytes may have been sent" do
      pid =
        start_supervised!(
          {HttpTestServer,
           handler: fn conn ->
             receive do
               :release -> Plug.Conn.send_resp(conn, 200, "late")
             end
           end}
        )

      info = HttpTestServer.info(pid)
      target = pin(info)

      assert {:error, %Error{} = error} =
               SafeHttp.request(target, %{method: :post, path: "/hang", body: "payload"},
                 timeout_ms: 100
               )

      assert error.class == :timeout
      assert error.code == :timeout
      assert error.details.phase == :response
      assert error.details.request_written?
    end
  end

  describe "response caps" do
    test "stops a chunked body at the byte cap during streaming" do
      pid =
        start_supervised!(
          {HttpTestServer,
           handler: fn conn ->
             conn = Plug.Conn.send_chunked(conn, 200)

             Enum.reduce_while(1..40, conn, fn _index, conn ->
               case Plug.Conn.chunk(conn, String.duplicate("x", 16)) do
                 {:ok, conn} -> {:cont, conn}
                 {:error, _reason} -> {:halt, conn}
               end
             end)
           end}
        )

      info = HttpTestServer.info(pid)
      target = pin(info)

      assert {:error, %Error{} = error} =
               SafeHttp.request(target, %{method: :get, path: "/chunked"}, max_body_bytes: 64)

      assert error.code == :response_too_large
      refute error.retryable?
      assert error.details.request_written?
      assert error.details.phase == :response
    end

    test "rejects an unexpected compressed body" do
      pid =
        start_supervised!(
          {HttpTestServer,
           handler: fn conn ->
             conn
             |> Plug.Conn.put_resp_header("content-encoding", "gzip")
             |> Plug.Conn.send_resp(
               200,
               <<31, 139, 8, 0, 0, 0, 0, 0, 0, 3, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0>>
             )
           end}
        )

      info = HttpTestServer.info(pid)
      target = pin(info)

      assert {:error, %Error{} = error} =
               SafeHttp.request(target, %{method: :get, path: "/gzip"})

      assert error.code == :compressed_body
      refute error.retryable?
      assert error.details.request_written?
    end
  end

  describe "IPv6" do
    test "connects to a pinned IPv6 address" do
      ipv6 = {0, 0, 0, 0, 0, 0, 0, 1}

      pid = start_supervised!({HttpTestServer, ip: ipv6, id: :ipv6, handler: &echo/1})
      info = HttpTestServer.info(pid)
      target = pin(info, hostname: "ipv6.test.local", ip: ipv6)

      assert {:ok, response} = SafeHttp.request(target, %{method: :get, path: "/v6"})
      assert response.address == ipv6
      assert response.status == 200
      assert response.body == "GET /v6"
    end
  end

  describe "refusals before a socket" do
    test "does not connect after the pin expires" do
      pid = start_supervised!({HttpTestServer, handler: &echo/1})
      info = HttpTestServer.info(pid)
      now = ~U[2026-08-18 12:00:00.000000Z]
      target = pin(info, now: now, ttl_ms: 10)
      box = start_box()

      connect = fn _scheme, _address, _port, _hostname, _opts ->
        put_box(box, :connected)
        {:error, :econnrefused}
      end

      assert {:error, %Error{} = error} =
               SafeHttp.request(target, %{method: :get, path: "/"},
                 now: DateTime.add(now, 11, :millisecond),
                 connect: connect
               )

      assert error.code == :pin_expired
      assert get_box(box) == nil
    end

    test "refuses a proxy option" do
      pid = start_supervised!({HttpTestServer, handler: &echo/1})
      info = HttpTestServer.info(pid)
      target = pin(info)

      assert {:error, %Error{} = error} =
               SafeHttp.request(target, %{method: :get, path: "/"},
                 proxy: {:http, "127.0.0.1", 8080, []}
               )

      assert error.code == :proxy_forbidden
    end

    test "refuses an oversized request body without connecting" do
      box = start_box()

      connect = fn _scheme, _address, _port, _hostname, _opts ->
        put_box(box, :connected)
        {:error, :econnrefused}
      end

      target = %UrlPolicy{
        scheme: "http",
        hostname: "example.test",
        port: 80,
        addresses: [{1, 1, 1, 1}],
        expires_at: DateTime.add(DateTime.utc_now(), 10_000, :millisecond)
      }

      body = String.duplicate("a", SafeHttp.max_request_bytes() + 1)

      assert {:error, %Error{} = error} =
               SafeHttp.request(target, %{method: :post, path: "/", body: body}, connect: connect)

      assert error.code == :request_too_large
      assert get_box(box) == nil
    end
  end

  defp pin(info, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    ttl = Keyword.get(opts, :ttl_ms, 10_000)

    %UrlPolicy{
      scheme: Keyword.get(opts, :scheme, "http"),
      hostname: Keyword.get(opts, :hostname, "example.test"),
      port: info.port,
      addresses: [Keyword.get(opts, :ip, info.ip)],
      expires_at: DateTime.add(now, ttl, :millisecond)
    }
  end

  defp echo(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(200, conn.method <> " " <> conn.request_path)
  end

  defp start_box do
    start_supervised!({Agent, fn -> nil end})
  end

  defp put_box(box, value), do: Agent.update(box, fn _ -> value end)

  defp merge_box(box, value),
    do: Agent.update(box, fn current -> Map.merge(current || %{}, value) end)

  defp get_box(box), do: Agent.get(box, & &1)

  defp record_connect(box, info) do
    fn scheme, address, port, hostname, opts ->
      merge_box(box, %{scheme: scheme, address: address, port: port, hostname: hostname})
      merged = Keyword.merge(opts, transport_opts: [cacerts: info.cacerts])
      SafeHttp.Transport.connect(scheme, address, port, hostname, merged)
    end
  end
end
