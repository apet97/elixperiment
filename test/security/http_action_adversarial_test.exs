defmodule PumbleAutomation.Security.HttpActionAdversarialTest do
  @moduledoc """
  End-to-end certification of the generic HTTP boundary: SSRF, rebinding,
  redirects, size, timeout honesty, Host/SNI, and secret redaction.
  """

  use PumbleAutomation.DataCase, async: true
  use Oban.Testing, repo: PumbleAutomation.Repo

  import ExUnit.CaptureLog
  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Connections.ResolvedConnection
  alias PumbleAutomation.Connections.SafeHttp
  alias PumbleAutomation.Connections.UrlPolicy
  alias PumbleAutomation.DnsResolverFake
  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.Nodes.HttpRequest
  alias PumbleAutomation.Executions.RetryPolicy
  alias PumbleAutomation.Executions.StepAttempt
  alias PumbleAutomation.Executions.StepExecution
  alias PumbleAutomation.HttpTestServer
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Node
  alias PumbleAutomation.Workflows.Templates

  @public {1, 1, 1, 1}
  @public_v6 {0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8888}
  @planted "P10T05-planted-bearer-must-not-leak"
  @lib Path.expand("../../lib/pumble_automation", __DIR__)

  describe "blocked destinations open no socket" do
    test "loopback, private, link-local, and metadata IPv4 literals never connect" do
      urls = [
        "http://127.0.0.1/",
        "http://10.1.2.3/secret",
        "http://192.168.0.9/",
        "http://169.254.1.1/",
        "http://169.254.169.254/latest/meta-data/",
        "http://169.254.170.2/",
        "http://100.64.0.1/"
      ]

      for url <- urls do
        assert_blocked_without_socket(url)
      end
    end

    test "loopback, unique-local, link-local, and metadata IPv6 literals never connect" do
      urls = [
        "http://[::1]/",
        "http://[fd00::1]/",
        "http://[fe80::1]/",
        "http://[fd00:ec2::254]/"
      ]

      for url <- urls do
        assert_blocked_without_socket(url)
      end
    end

    test "localhost and metadata names are blocked before DNS" do
      names = [
        "http://localhost/",
        "http://foo.localhost/",
        "http://metadata.google.internal/",
        "http://metadata/",
        "http://instance-data/",
        "http://kubernetes.default.svc.cluster.local/"
      ]

      for url <- names do
        assert_blocked_without_socket(url, dns: &flunk_dns/1)
      end
    end

    test "decimal, hex, octal, and shortened IPv4 tricks never connect" do
      tricks = [
        "http://2130706433/",
        "http://0x7f000001/",
        "http://0177.0.0.1/",
        "http://127.1/"
      ]

      for url <- tricks do
        assert_blocked_without_socket(url, dns: &flunk_dns/1)
      end
    end

    test "a mixed public and blocked DNS answer is refused without a socket" do
      dns = start_dns(%{"mixed.test" => [@public, {10, 0, 0, 1}]})
      box = start_box()

      {input, opts} =
        live_input(%{"method" => "get", "url" => "http://mixed.test/x"},
          dns: dns,
          connect: record_and_flunk(box)
        )

      assert {:ok, outcome} = HttpRequest.run(input, opts)
      assert outcome.kind == :permanent_error
      assert outcome.error_class == "validation"
      assert Agent.get(box, & &1) == []
      assert DnsResolverFake.lookup_count(dns, "mixed.test") == 1
    end

    test "userinfo, fragments, and non-HTTP schemes never connect" do
      refusals = [
        "https://user:#{@planted}@example.test/x",
        "https://example.test/x#frag",
        "ftp://example.test/",
        "file:///etc/passwd",
        "gopher://example.test/"
      ]

      for url <- refusals do
        {input, opts} =
          live_input(%{"method" => "get", "url" => url},
            allow_http: false,
            dns: &flunk_dns/1,
            connect: flunk_connect()
          )

        assert {:ok, outcome} = HttpRequest.run(input, opts)
        assert outcome.kind == :permanent_error
        refute_leak(outcome)
      end
    end
  end

  describe "DNS pinning versus rebinding" do
    test "a later private answer does not move the already-approved pin" do
      dns = start_dns(%{"http.test.local" => {:sequence, [[@public], [{127, 0, 0, 1}]]}})
      box = start_box()
      pid = start_http(handler: &echo/1)
      info = HttpTestServer.info(pid)

      {:ok, target} =
        UrlPolicy.approve("http://http.test.local:#{info.port}/pin",
          allow_http: true,
          resolver: DnsResolverFake.fun(dns)
        )

      DnsResolverFake.put(dns, "http.test.local", [{10, 0, 0, 1}])

      assert {:ok, response} =
               SafeHttp.request(target, %{method: :get, path: "/pin"},
                 connect: pin_connect(box, info)
               )

      assert response.status == 200
      [hit] = Agent.get(box, & &1)
      assert hit.address == @public
      assert hit.hostname == "http.test.local"
      assert hit.address != {10, 0, 0, 1}
      assert hit.address != {127, 0, 0, 1}
    end

    test "HttpRequest uses the pin and does not re-resolve the same hop" do
      dns = start_dns(%{"http.test.local" => {:sequence, [[@public], [{169, 254, 169, 254}]]}})
      box = start_box()
      pid = start_http(handler: &echo/1)
      info = HttpTestServer.info(pid)
      {input, opts} = live_get(info, dns, box, "/once")

      assert {:ok, outcome} = HttpRequest.run(input, opts)
      assert outcome.kind == :success
      assert DnsResolverFake.lookup_count(dns, "http.test.local") == 1
      [hit] = Agent.get(box, & &1)
      assert hit.address == @public
    end

    test "a redirect Location is independently re-resolved and a private hop is blocked" do
      dns =
        start_dns(%{
          "http.test.local" => [@public],
          "rebind.test" => [{10, 0, 0, 1}]
        })

      box = start_box()

      pid =
        start_http(
          handler: fn conn ->
            conn
            |> Plug.Conn.put_resp_header("location", "http://rebind.test/internal")
            |> Plug.Conn.send_resp(302, "")
          end
        )

      info = HttpTestServer.info(pid)
      {input, opts} = live_get(info, dns, box, "/bounce")

      assert {:ok, outcome} = HttpRequest.run(input, opts)
      assert outcome.kind == :permanent_error
      assert outcome.error_class == "validation"
      assert outcome.output["remote_status"] == 302
      assert RetryPolicy.diagnostics(outcome, %{})["dispatch_state"] == "confirmed"
      assert DnsResolverFake.lookups(dns) == ["http.test.local", "rebind.test"]
      [hit] = Agent.get(box, & &1)
      assert hit.address == @public
      assert HttpTestServer.request_count(pid) == 1
    end
  end

  describe "Host header and TLS names" do
    test "the wire Host is the original hostname, not the pinned IP" do
      dns = start_dns(%{"http.test.local" => [@public]})
      box = start_box()
      seen = start_box()

      pid =
        start_http(
          handler: fn conn ->
            Agent.update(seen, fn _ -> Plug.Conn.get_req_header(conn, "host") end)
            echo(conn)
          end
        )

      info = HttpTestServer.info(pid)
      {input, opts} = live_get(info, dns, box, "/host")

      assert {:ok, outcome} = HttpRequest.run(input, opts)
      assert outcome.kind == :success
      assert Agent.get(seen, & &1) == ["http.test.local:#{info.port}"]
      [hit] = Agent.get(box, & &1)
      assert is_tuple(hit.address)
      refute is_binary(hit.address)
    end

    test "HTTPS keeps SNI on the certificate name and fails a mismatched name" do
      dns = start_dns(%{"http.test.local" => [@public], "other.test.local" => [@public]})
      box = start_box()
      hostname = HttpTestServer.hostname()

      pid =
        start_http(
          mode: :https,
          handler: fn conn -> Plug.Conn.send_resp(conn, 200, "tls-ok") end
        )

      info = HttpTestServer.info(pid)

      {good, good_opts} =
        live_input(%{"method" => "get", "url" => url(info, "/secure", "https")},
          dns: dns,
          connect: pin_connect(box, info),
          transport_opts: [cacerts: info.cacerts]
        )

      assert {:ok, ok} = HttpRequest.run(good, good_opts)
      assert ok.kind == :success
      [hit] = Agent.get(box, & &1)
      assert hit.hostname == hostname
      assert hit.scheme == :https

      {bad, bad_opts} =
        live_input(%{"method" => "get", "url" => "https://other.test.local:#{info.port}/"},
          dns: dns,
          connect: pin_connect(box, info),
          transport_opts: [cacerts: info.cacerts]
        )

      assert {:ok, failed} = HttpRequest.run(bad, bad_opts)
      assert failed.kind == :permanent_error
      assert failed.error_class == "validation"
    end
  end

  describe "redirect credentials, Location, and hop cap" do
    test "Authorization does not follow a host change and Set-Cookie is not stored" do
      dns =
        start_dns(%{
          "http.test.local" => [@public],
          "other.test" => [@public]
        })

      box = start_box()
      seen = start_box()

      pid =
        start_http(
          handler: fn conn ->
            {:ok, _body, conn} = Plug.Conn.read_body(conn)

            Agent.update(seen, fn rows ->
              rows ++
                [
                  %{
                    path: conn.request_path,
                    authorization: Plug.Conn.get_req_header(conn, "authorization")
                  }
                ]
            end)

            case conn.request_path do
              "/start" ->
                conn
                |> Plug.Conn.put_resp_header(
                  "location",
                  "http://other.test:#{conn.port}/next"
                )
                |> Plug.Conn.put_resp_header("set-cookie", "session=#{@planted}")
                |> Plug.Conn.send_resp(302, "")

              "/next" ->
                conn
                |> Plug.Conn.put_resp_header("set-cookie", "session=#{@planted}")
                |> Plug.Conn.put_resp_content_type("application/json")
                |> Plug.Conn.send_resp(200, ~s({"ok":true}))
            end
          end
        )

      info = HttpTestServer.info(pid)

      {input, opts} =
        live_input(
          %{
            "method" => "get",
            "url" => url(info, "/start"),
            "headers" => %{"Authorization" => Templates.secret_placeholder("API_TOKEN")}
          },
          dns: dns,
          connect: pin_connect(box, info),
          secrets: %{"API_TOKEN" => @planted}
        )

      log =
        capture_log(fn ->
          assert {:ok, outcome} = HttpRequest.run(input, opts)
          assert outcome.kind == :success
          refute Map.has_key?(outcome.output["headers"], "set-cookie")
          refute_leak(outcome)
          send(self(), {:outcome, outcome})
        end)

      refute log =~ @planted
      assert_received {:outcome, _outcome}
      [first, second] = Agent.get(seen, & &1)
      assert first.authorization == [@planted]
      assert second.authorization == []
      assert second.path == "/next"
    end

    test "a Location with credentials or CR-LF is a permanent refusal" do
      dns = start_dns(%{"http.test.local" => [@public]})
      box = start_box()

      pid =
        start_http(
          handler: fn conn ->
            conn
            |> Plug.Conn.put_resp_header("location", "http://user:pass@evil.test/x")
            |> Plug.Conn.send_resp(302, "")
          end
        )

      info = HttpTestServer.info(pid)
      {input, opts} = live_get(info, dns, box, "/loc")
      assert {:ok, outcome} = HttpRequest.run(input, opts)
      assert outcome.kind == :permanent_error
      assert outcome.output["remote_status"] == 302
      assert RetryPolicy.diagnostics(outcome, %{})["dispatch_state"] == "confirmed"
      refute_leak(outcome)

      assert {:error, %Error{code: :malformed_redirect, retryable?: false}} =
               SafeHttp.location("http://http.test.local/x", [
                 {"location", "http://evil.test/x\r\nX: y"}
               ])
    end
  end

  describe "CRLF headers and path confusion" do
    test "a CR-LF in a header value is refused before connect" do
      dns = start_dns(%{"example.test" => [@public]})
      box = start_box()

      {input, opts} =
        live_input(
          %{
            "method" => "get",
            "url" => "http://example.test/x",
            "headers" => %{"x-note" => "ok\r\nHost: evil.test"}
          },
          dns: dns,
          connect: record_and_flunk(box)
        )

      assert {:ok, outcome} = HttpRequest.run(input, opts)
      assert outcome.kind == :permanent_error
      assert Agent.get(box, & &1) == []
    end

    test "a secret that injects CR-LF is refused before connect" do
      dns = start_dns(%{"example.test" => [@public]})
      box = start_box()

      {input, opts} =
        live_input(
          %{
            "method" => "get",
            "url" => "http://example.test/x",
            "headers" => %{"x-note" => Templates.secret_placeholder("API_TOKEN")}
          },
          dns: dns,
          connect: record_and_flunk(box),
          secrets: %{"API_TOKEN" => "ok\r\nHost: evil.test"}
        )

      assert {:ok, outcome} = HttpRequest.run(input, opts)
      assert outcome.kind == :permanent_error
      assert Agent.get(box, & &1) == []
    end

    test "a scheme-relative path or a newline in the URL is refused" do
      dns = start_dns(%{"example.test" => [@public]})
      box = start_box()

      for url <- ["http://example.test//evil.test/x", "http://example.test/x\ny"] do
        {input, opts} =
          live_input(%{"method" => "get", "url" => url},
            dns: dns,
            connect: record_and_flunk(box)
          )

        assert {:ok, outcome} = HttpRequest.run(input, opts)
        assert outcome.kind == :permanent_error
        assert Agent.get(box, & &1) == []
      end
    end

    test "a node path cannot climb out of the connection prefix" do
      dns = start_dns(%{"api.example.test" => [@public]})
      box = start_box()

      {input, opts} =
        live_input(
          %{"method" => "get", "url" => "https://api.example.test/v1", "path" => "../admin"},
          allow_http: false,
          dns: dns,
          connect: record_and_flunk(box),
          connection: resolved_connection()
        )

      assert {:ok, outcome} = HttpRequest.run(input, opts)
      assert outcome.kind == :permanent_error
      assert Agent.get(box, & &1) == []
    end
  end

  describe "size, compression, and timeout honesty" do
    test "a chunked body is cut at the cap during streaming" do
      dns = start_dns(%{"http.test.local" => [@public]})
      box = start_box()

      pid =
        start_http(
          handler: fn conn ->
            conn = Plug.Conn.send_chunked(conn, 200)

            Enum.reduce_while(1..40, conn, fn _index, conn ->
              case Plug.Conn.chunk(conn, String.duplicate("x", 16)) do
                {:ok, conn} -> {:cont, conn}
                {:error, _reason} -> {:halt, conn}
              end
            end)
          end
        )

      info = HttpTestServer.info(pid)
      {input, opts} = live_get(info, dns, box, "/chunked")
      opts = Keyword.put(opts, :max_body_bytes, 64)

      assert {:ok, outcome} = HttpRequest.run(input, opts)
      assert outcome.kind == :permanent_error
      assert outcome.error_class == "resource_limit"
    end

    test "a compressed bomb is refused without decompressing it" do
      dns = start_dns(%{"http.test.local" => [@public]})
      box = start_box()
      bomb = HttpTestServer.gzip_bomb(1_048_576)

      pid =
        start_http(
          handler: fn conn ->
            conn
            |> Plug.Conn.put_resp_header("content-encoding", "gzip")
            |> Plug.Conn.send_resp(200, bomb)
          end
        )

      info = HttpTestServer.info(pid)
      {input, opts} = live_get(info, dns, box, "/gzip")

      assert {:ok, outcome} = HttpRequest.run(input, opts)
      assert outcome.kind == :permanent_error
      assert outcome.error_class == "validation"
      refute byte_size(bomb) > 1_048_576
    end

    test "GET timeout after write is retryable; POST without idempotency is uncertain" do
      dns = start_dns(%{"http.test.local" => [@public]})

      pid =
        start_http(
          handler: fn conn ->
            {:ok, _body, conn} = Plug.Conn.read_body(conn)

            receive do
              :release -> Plug.Conn.send_resp(conn, 200, "late")
            end
          end
        )

      info = HttpTestServer.info(pid)
      box = start_box()
      {get_input, get_opts} = live_get(info, dns, box, "/hang")
      get_opts = Keyword.put(get_opts, :timeout_ms, 100)

      assert {:ok, get_outcome} = HttpRequest.run(get_input, get_opts)
      assert get_outcome.kind == :retryable_error
      assert get_outcome.error_class == "transient_transport"
      assert get_outcome.output["phase"] == "response"

      {post_input, post_opts} =
        live_input(
          %{
            "method" => "post",
            "url" => url(info, "/hang"),
            "body" => "{}",
            "body_mode" => "json"
          },
          dns: dns,
          connect: pin_connect(box, info)
        )

      post_opts = Keyword.put(post_opts, :timeout_ms, 100)
      assert {:ok, post_outcome} = HttpRequest.run(post_input, post_opts)
      assert post_outcome.kind == :uncertain
      assert post_outcome.error_class == "ambiguous_transport"
      assert post_outcome.output["phase"] == "response"
    end

    test "a connect-phase timeout does not claim that request bytes were sent" do
      dns = start_dns(%{"http.test.local" => [@public]})
      box = start_box()
      pid = start_http(mode: :tcp)
      info = HttpTestServer.info(pid)

      {input, opts} =
        live_input(
          %{
            "method" => "post",
            "url" => url(info, "/write", "https"),
            "body" => "x",
            "body_mode" => "text"
          },
          dns: dns,
          connect: pin_connect(box, info)
        )

      opts = Keyword.put(opts, :timeout_ms, 100)
      assert {:ok, outcome} = HttpRequest.run(input, opts)
      assert outcome.kind == :retryable_error
      assert outcome.error_class == "transient_transport"
      assert outcome.output["phase"] == "connect"
    end
  end

  describe "IPv6 pinning" do
    test "connects to a public IPv6 pin while the socket lands on the test listener" do
      dns = start_dns(%{"http.test.local" => [@public_v6]})
      box = start_box()
      pid = start_http(ip: {0, 0, 0, 0, 0, 0, 0, 1}, id: :ipv6, handler: &echo/1)
      info = HttpTestServer.info(pid)
      {input, opts} = live_get(info, dns, box, "/v6")

      assert {:ok, outcome} = HttpRequest.run(input, opts)
      assert outcome.kind == :success
      [hit] = Agent.get(box, & &1)
      assert hit.address == @public_v6
    end
  end

  describe "leak assertions against logs and stored rows" do
    test "a JSON authorization echo is redacted in the excerpt" do
      dns = start_dns(%{"http.test.local" => [@public]})
      box = start_box()

      pid =
        start_http(
          handler: fn conn ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              200,
              Jason.encode!(%{"authorization" => @planted, "ok" => true})
            )
          end
        )

      info = HttpTestServer.info(pid)
      {input, opts} = live_get(info, dns, box, "/echo")

      assert {:ok, outcome} = HttpRequest.run(input, opts)
      assert outcome.kind == :success
      refute outcome.output["body_excerpt"] =~ @planted
      refute_leak(outcome)
    end

    test "captured logs and persisted attempt rows never contain the planted secret" do
      %{installation: installation, member: member} = InstallationsFixtures.install()
      scope = Scope.new(member)
      dns = start_dns(%{"http.test.local" => [@public]})
      box = start_box()

      pid =
        start_http(
          handler: fn conn ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, ~s({"ok":true,"id":"n-1"}))
          end
        )

      info = HttpTestServer.info(pid)

      {input, opts} =
        live_input(
          %{
            "method" => "post",
            "url" => url(info, "/hook"),
            "headers" => %{"Authorization" => Templates.secret_placeholder("API_TOKEN")},
            "body" => "token=" <> Templates.secret_placeholder("API_TOKEN"),
            "body_mode" => "text"
          },
          dns: dns,
          connect: pin_connect(box, info),
          secrets: %{"API_TOKEN" => @planted}
        )

      %{snapshot: snapshot, execution: execution} =
        claimed!(scope, installation.id, [
          Node.new(:http_action, %{method: :post, url: "https://example.test/hook"})
        ])

      log =
        capture_log(fn ->
          assert {:ok, outcome} = HttpRequest.run(input, opts)
          assert outcome.kind == :success
          refute_leak(outcome)
          assert {:ok, finalized} = Engine.finalize(snapshot, outcome)
          assert finalized.status == "completed"
          send(self(), {:stored, finalized.id, snapshot})
        end)

      refute log =~ @planted
      assert_received {:stored, execution_id, snap}
      stored = Repo.get!(Execution, execution_id)
      step = Repo.get!(StepExecution, snap.step_execution_id)
      attempt = Repo.get!(StepAttempt, snap.attempt_id)
      refute_leak([stored.context, step.output, attempt.diagnostics, execution.id])
    end
  end

  describe "concurrent cancellation" do
    test "cancel during a hanging GET does not leak the secret and halts the run" do
      %{installation: installation, member: member} = InstallationsFixtures.install()
      scope = Scope.new(member)
      dns = start_dns(%{"http.test.local" => [@public]})
      box = start_box()

      pid =
        start_http(
          handler: fn conn ->
            receive do
              :release -> Plug.Conn.send_resp(conn, 200, "late")
            end
          end
        )

      info = HttpTestServer.info(pid)

      {input, opts} =
        live_input(
          %{
            "method" => "get",
            "url" => url(info, "/hang"),
            "headers" => %{"Authorization" => Templates.secret_placeholder("API_TOKEN")}
          },
          dns: dns,
          connect: pin_connect(box, info),
          secrets: %{"API_TOKEN" => @planted}
        )

      opts = Keyword.put(opts, :timeout_ms, 150)

      %{snapshot: snapshot, execution: execution} =
        claimed!(scope, installation.id, [
          Node.new(:http_action, %{method: :get, url: "https://example.test/hook"})
        ])

      log =
        capture_log(fn ->
          task = Task.async(fn -> HttpRequest.run(input, opts) end)

          assert {:ok, requested} =
                   Engine.cancel(scope, execution.id, %{reason: "operator halt"})

          assert requested.status == "running"
          assert {:ok, outcome} = Task.await(task, 2_000)
          refute_leak(outcome)
          assert {:ok, halted} = Engine.finalize(snapshot, outcome)
          assert halted.status == "cancelled"
          send(self(), {:halted, halted.id, snapshot})
        end)

      refute log =~ @planted
      assert_received {:halted, execution_id, snap}
      stored = Repo.get!(Execution, execution_id)
      attempt = Repo.get!(StepAttempt, snap.attempt_id)
      refute_leak([stored.context, attempt.diagnostics])
    end
  end

  describe "Mint usage and certificate options" do
    test "the transport verifies the peer, pins HTTP/1, and never uses Req" do
      transport = File.read!(Path.join(@lib, "connections/safe_http/transport.ex"))
      safe = File.read!(Path.join(@lib, "connections/safe_http.ex"))
      node = File.read!(Path.join(@lib, "executions/nodes/http_request.ex"))

      assert transport =~ "verify: :verify_peer"
      refute transport =~ "verify_none"
      assert transport =~ "protocols: [:http1]"
      assert transport =~ "hostname: hostname"
      assert transport =~ "pkix_verify_hostname"
      refute safe =~ "alias Req"
      refute node =~ "alias Req"
      assert safe =~ "@max_redirects 3"
      assert safe =~ "{\"accept-encoding\", \"identity\"}"
    end
  end

  defp assert_blocked_without_socket(url, opts \\ []) do
    dns = Keyword.get(opts, :dns, &flunk_dns/1)
    box = start_box()

    {input, run_opts} =
      live_input(%{"method" => "get", "url" => url},
        dns: dns,
        connect: record_and_flunk(box)
      )

    assert {:ok, outcome} = HttpRequest.run(input, run_opts)
    assert outcome.kind == :permanent_error
    assert outcome.error_class == "validation"
    assert Agent.get(box, & &1) == []
    refute_leak(outcome)
  end

  defp live_get(info, dns, box, path) do
    live_input(%{"method" => "get", "url" => url(info, path)},
      dns: dns,
      connect: pin_connect(box, info)
    )
  end

  defp live_input(config, opts) do
    input = runner_input(config, opts)
    {input, run_opts(opts)}
  end

  defp run_opts(opts) do
    dns = Keyword.fetch!(opts, :dns)

    resolver =
      if is_function(dns, 1) do
        dns
      else
        DnsResolverFake.fun(dns)
      end

    [
      allow_http: Keyword.get(opts, :allow_http, true),
      dns_resolver: resolver,
      secrets: Keyword.get(opts, :secrets, %{}),
      connect: Keyword.fetch!(opts, :connect)
    ]
    |> maybe_put(:connection, Keyword.get(opts, :connection))
    |> maybe_put(:transport_opts, Keyword.get(opts, :transport_opts))
  end

  defp runner_input(config, opts) do
    %{
      compiled_node: %{
        type: :http_action,
        config: config,
        edges: %{"next" => "end"},
        requires: %{
          "connection_ids" => [],
          "operations" => [],
          "scopes" => [],
          "secret_names" => []
        }
      },
      context: %{"execution" => %{"id" => "run-1", "run_mode" => "live"}, "steps" => %{}},
      trigger_snapshot: %{},
      installation_id: Keyword.get(opts, :installation_id, Ecto.UUID.generate()),
      run_mode: "live",
      effect_key: Keyword.get(opts, :effect_key, "inst/exec/node"),
      attempt: %{id: Ecto.UUID.generate(), number: 1},
      adapters: %{}
    }
  end

  defp url(info, path, scheme \\ "http") do
    "#{scheme}://http.test.local:#{info.port}#{path}"
  end

  defp pin_connect(box, info) do
    fn scheme, address, port, hostname, opts ->
      Agent.update(box, fn hits ->
        hits ++ [%{scheme: scheme, address: address, port: port, hostname: hostname}]
      end)

      SafeHttp.Transport.connect(scheme, info.ip, port, hostname, opts)
    end
  end

  defp record_and_flunk(box) do
    fn _scheme, address, port, hostname, _opts ->
      Agent.update(box, fn hits ->
        hits ++ [%{address: address, port: port, hostname: hostname}]
      end)

      flunk("opened a socket to #{inspect(address)}:#{port} host=#{hostname}")
    end
  end

  defp flunk_connect do
    fn _scheme, address, port, hostname, _opts ->
      flunk("opened a socket to #{inspect(address)}:#{port} host=#{hostname}")
    end
  end

  defp flunk_dns(host), do: flunk("DNS ran for #{host}")

  defp echo(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(200, conn.method <> " " <> conn.request_path)
  end

  defp start_http(opts) do
    start_supervised!({HttpTestServer, opts},
      id: {:http_test_server, System.unique_integer([:positive])}
    )
  end

  defp start_dns(answers) do
    start_supervised!({DnsResolverFake, answers: answers},
      id: {:dns, System.unique_integer([:positive])}
    )
  end

  defp start_box do
    start_supervised!({Agent, fn -> [] end}, id: {:box, System.unique_integer([:positive])})
  end

  defp resolved_connection do
    %ResolvedConnection{
      id: Ecto.UUID.generate(),
      installation_id: Ecto.UUID.generate(),
      name: "Tickets",
      base_origin: "https://api.example.test",
      base_path_prefix: "/v1",
      policy_version: 1,
      headers: %{},
      secret_headers: []
    }
  end

  defp claimed!(scope, installation_id, nodes) do
    workflow =
      drafted_workflow(installation_id, %{draft_definition: Definition.encode(definition(nodes))})

    {:ok, result} = Workflows.activate_workflow(scope, workflow.id, 0)

    {:ok, execution} =
      Engine.create(scope, %{
        workflow_version_id: result.version.id,
        execution_key: "adv-#{System.unique_integer([:positive])}"
      })

    execution = Repo.get!(Execution, execution.id)

    {:ok, snapshot} =
      Engine.claim(%{
        "installation_id" => execution.installation_id,
        "execution_id" => execution.id,
        "expected_node_id" => execution.current_node_id,
        "generation" => execution.lock_version
      })

    %{execution: execution, snapshot: snapshot}
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp refute_leak(value) do
    blob =
      value
      |> inspect(limit: :infinity, pretty: true)
      |> Kernel.<>(leak_json(value))

    refute blob =~ @planted
  end

  defp leak_json(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _reason} -> ""
    end
  end
end
