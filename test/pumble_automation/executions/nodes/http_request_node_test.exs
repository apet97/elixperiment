defmodule PumbleAutomation.Executions.Nodes.HttpRequestNodeTest do
  @moduledoc """
  HTTP node redirects, bounded response capture, JSON extraction, and
  retry/uncertainty windows. Every redirect is independently pinned.
  """

  use ExUnit.Case, async: true

  alias PumbleAutomation.Connections.ResolvedConnection
  alias PumbleAutomation.Connections.SafeHttp
  alias PumbleAutomation.Executions.NodeRunner
  alias PumbleAutomation.Executions.Nodes.HttpRequest
  alias PumbleAutomation.Executions.Outcome
  alias PumbleAutomation.Executions.RetryPolicy
  alias PumbleAutomation.HttpTestServer
  alias PumbleAutomation.Workflows.Templates

  @public {1, 1, 1, 1}
  @planted "Bearer planted-secret"

  describe "redirect to a private IP" do
    test "refuses the hop and does not connect a second time" do
      box = start_box()

      pid =
        start_http(
          handler: fn conn ->
            conn
            |> Plug.Conn.put_resp_header("location", "http://10.0.0.1/secret")
            |> Plug.Conn.send_resp(302, "")
          end
        )

      info = HttpTestServer.info(pid)
      {input, opts} = live_get(info, box, "/bounce")

      assert {:ok, outcome} = HttpRequest.run(input, opts)
      assert outcome.kind == :permanent_error
      assert outcome.error_class == "validation"
      assert outcome.output["remote_status"] == 302
      assert RetryPolicy.diagnostics(outcome, %{})["dispatch_state"] == "confirmed"
      assert Agent.get(box, & &1) == [info.port]
    end
  end

  describe "DNS rebind on redirect" do
    test "re-resolves the Location host and blocks a private answer" do
      box = start_box()

      pid =
        start_http(
          handler: fn conn ->
            conn
            |> Plug.Conn.put_resp_header("location", "http://rebind.test/x")
            |> Plug.Conn.send_resp(302, "")
          end
        )

      info = HttpTestServer.info(pid)

      resolver = fn
        "http.test.local" -> {:ok, [@public]}
        "rebind.test" -> {:ok, [{10, 0, 0, 1}]}
        _host -> {:ok, [@public]}
      end

      {input, opts} = live_get(info, box, "/rebind")
      opts = Keyword.put(opts, :dns_resolver, resolver)

      assert {:ok, outcome} = HttpRequest.run(input, opts)
      assert outcome.kind == :permanent_error
      assert outcome.error_class == "validation"
      assert Agent.get(box, & &1) == [info.port]
    end
  end

  describe "cross-origin secret stripping" do
    test "Authorization does not follow a host change; Set-Cookie is not captured" do
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
                    host: List.first(Plug.Conn.get_req_header(conn, "host")),
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
                |> Plug.Conn.put_resp_header("set-cookie", "session=steal")
                |> Plug.Conn.send_resp(302, "")

              "/next" ->
                conn
                |> Plug.Conn.put_resp_header("set-cookie", "session=steal")
                |> Plug.Conn.put_resp_content_type("application/json")
                |> Plug.Conn.send_resp(200, ~s({"ok":true}))
            end
          end
        )

      info = HttpTestServer.info(pid)

      resolver = fn
        "http.test.local" -> {:ok, [@public]}
        "other.test" -> {:ok, [@public]}
        _host -> {:ok, [@public]}
      end

      {input, opts} =
        live_input(
          info,
          box,
          %{
            "method" => "get",
            "url" => url(info, "/start"),
            "headers" => %{"Authorization" => Templates.secret_placeholder("API_TOKEN")}
          },
          secrets: %{"API_TOKEN" => @planted}
        )

      opts = Keyword.put(opts, :dns_resolver, resolver)

      assert {:ok, outcome} = HttpRequest.run(input, opts)
      assert outcome.kind == :success
      refute Map.has_key?(outcome.output["headers"], "set-cookie")
      refute inspect(outcome) =~ @planted

      [first, second] = Agent.get(seen, & &1)
      assert first.authorization == [@planted]
      assert second.authorization == []
      assert second.path == "/next"
    end

    test "all secret-backed header names are stripped on a host change" do
      box = start_box()
      seen = start_box()
      connection_secret_id = Ecto.UUID.generate()

      pid =
        start_http(
          handler: fn conn ->
            Agent.update(seen, fn rows ->
              rows ++
                [
                  %{
                    path: conn.request_path,
                    connection_secret: Plug.Conn.get_req_header(conn, "x-connection-auth"),
                    template_secret: Plug.Conn.get_req_header(conn, "x-workflow-auth")
                  }
                ]
            end)

            if conn.request_path == "/start" do
              conn
              |> Plug.Conn.put_resp_header("location", "http://other.test:#{conn.port}/next")
              |> Plug.Conn.send_resp(302, "")
            else
              Plug.Conn.send_resp(conn, 200, "ok")
            end
          end
        )

      info = HttpTestServer.info(pid)

      connection =
        struct!(ResolvedConnection, %{
          id: Ecto.UUID.generate(),
          installation_id: Ecto.UUID.generate(),
          name: "Secret headers",
          base_origin: "http://http.test.local:#{info.port}",
          base_path_prefix: nil,
          policy_version: 1,
          headers: %{},
          secret_headers: [%{header: "x-connection-auth", secret_id: connection_secret_id}]
        })

      config = %{
        "method" => "get",
        "path" => "/start",
        "headers" => %{"x-workflow-auth" => Templates.secret_placeholder("API_TOKEN")}
      }

      {input, opts} =
        live_input(info, box, config,
          connection: connection,
          secrets: %{"API_TOKEN" => @planted},
          secrets_by_id: %{connection_secret_id => @planted}
        )

      resolver = fn _host -> {:ok, [@public]} end

      assert {:ok, outcome} = HttpRequest.run(input, Keyword.put(opts, :dns_resolver, resolver))
      assert outcome.kind == :success

      [first, second] = Agent.get(seen, & &1)
      assert first.connection_secret == [@planted]
      assert first.template_secret == [@planted]
      assert second.path == "/next"
      assert second.connection_secret == []
      assert second.template_secret == []
    end
  end

  describe "303 and 307 behaviour" do
    test "303 converts POST to GET and drops the body; 307 preserves both" do
      assert_redirect_method(303, "GET", "")
      assert_redirect_method(307, "POST", "payload")
    end

    test "a cross-origin 307 cannot carry a write or its internal idempotency key" do
      box = start_box()
      seen = start_box()

      pid =
        start_http(
          handler: fn conn ->
            Agent.update(seen, &(&1 ++ [conn.request_path]))

            conn
            |> Plug.Conn.put_resp_header("location", "http://other.test:#{conn.port}/landed")
            |> Plug.Conn.send_resp(307, "")
          end
        )

      info = HttpTestServer.info(pid)

      {input, opts} =
        live_input(info, box, %{
          "method" => "post",
          "url" => url(info, "/write"),
          "body" => "payload",
          "body_mode" => "text",
          "idempotency_header" => "Idempotency-Key"
        })

      resolver = fn _host -> {:ok, [@public]} end

      assert {:ok, outcome} = HttpRequest.run(input, Keyword.put(opts, :dns_resolver, resolver))
      assert outcome.kind == :permanent_error
      assert outcome.error_class == "validation"
      assert outcome.output["remote_status"] == 307
      assert RetryPolicy.diagnostics(outcome, %{})["dispatch_state"] == "confirmed"
      assert Agent.get(seen, & &1) == ["/write"]
    end

    test "an unkeyed POST is not replayable when a rewritten redirect receives 5xx" do
      for redirect_status <- [302, 303] do
        box = start_box()

        pid =
          start_http(
            handler: fn conn ->
              case conn.request_path do
                "/write" ->
                  conn
                  |> Plug.Conn.put_resp_header("location", "/landed")
                  |> Plug.Conn.send_resp(redirect_status, "")

                "/landed" ->
                  Plug.Conn.send_resp(conn, 503, "unavailable")
              end
            end
          )

        info = HttpTestServer.info(pid)

        {input, opts} =
          live_input(info, box, %{
            "method" => "post",
            "url" => url(info, "/write"),
            "body" => "payload",
            "body_mode" => "text"
          })

        assert {:ok, outcome} = HttpRequest.run(input, opts)
        assert outcome.kind == :uncertain
        assert outcome.error_class == "side_effect_uncertain"

        diagnostics = RetryPolicy.diagnostics(outcome, %{})
        assert diagnostics["dispatch_state"] == "confirmed"
        assert diagnostics["duplicate_risk"]

        assert {:ok, applied} =
                 RetryPolicy.apply(outcome, %{
                   attempt_number: 1,
                   compiled_node: input.compiled_node
                 })

        assert applied.kind == :uncertain
        refute applied.resume_at
      end
    end

    test "an unkeyed POST is not replayable when a rewritten redirect receives 429" do
      for redirect_status <- [302, 303] do
        box = start_box()

        pid =
          start_http(
            handler: fn conn ->
              case conn.request_path do
                "/write" ->
                  conn
                  |> Plug.Conn.put_resp_header("location", "/landed")
                  |> Plug.Conn.send_resp(redirect_status, "")

                "/landed" ->
                  conn
                  |> Plug.Conn.put_resp_header("retry-after", "5")
                  |> Plug.Conn.send_resp(429, "rate limited")
              end
            end
          )

        info = HttpTestServer.info(pid)

        {input, opts} =
          live_input(info, box, %{
            "method" => "post",
            "url" => url(info, "/write"),
            "body" => "payload",
            "body_mode" => "text"
          })

        assert {:ok, outcome} = HttpRequest.run(input, opts)
        assert outcome.kind == :uncertain
        assert outcome.error_class == "side_effect_uncertain"

        diagnostics = RetryPolicy.diagnostics(outcome, %{})
        assert diagnostics["dispatch_state"] == "confirmed"
        assert diagnostics["duplicate_risk"]

        assert {:ok, applied} =
                 RetryPolicy.apply(outcome, %{
                   attempt_number: 1,
                   compiled_node: input.compiled_node
                 })

        assert applied.kind == :uncertain
        refute applied.resume_at
      end
    end

    test "a downstream timeout after an unkeyed POST redirect pauses uncertain" do
      box = start_box()
      test_pid = self()
      request_ref = make_ref()

      pid =
        start_http(
          handler: fn conn ->
            if conn.request_path == "/write" do
              conn
              |> Plug.Conn.put_resp_header("location", "/hang")
              |> Plug.Conn.send_resp(303, "")
            else
              send(test_pid, {request_ref, :downstream_request_started})

              receive do
                :release -> Plug.Conn.send_resp(conn, 200, "late")
              end
            end
          end
        )

      info = HttpTestServer.info(pid)

      {input, opts} =
        live_input(info, box, %{
          "method" => "post",
          "url" => url(info, "/write"),
          "body" => "payload",
          "body_mode" => "text"
        })

      _task =
        start_supervised!(
          Supervisor.child_spec(
            {Task,
             fn ->
               result = HttpRequest.run(input, Keyword.put(opts, :timeout_ms, 1_000))
               send(test_pid, {request_ref, result})
             end},
            id: {:redirect_timeout, System.unique_integer([:positive])}
          )
        )

      assert_receive {^request_ref, :downstream_request_started}, 5_000
      assert_receive {^request_ref, {:ok, outcome}}, 5_000

      assert outcome.kind == :uncertain
      assert outcome.error_class == "ambiguous_transport"
      assert outcome.output["remote_status"] == 303

      diagnostics = RetryPolicy.diagnostics(outcome, %{})
      assert diagnostics["dispatch_state"] == "confirmed"
      assert diagnostics["duplicate_risk"]
    end

    test "a DNS failure after an unkeyed POST redirect does not replay the write" do
      for redirect_status <- [302, 303] do
        box = start_box()

        pid =
          start_http(
            handler: fn conn ->
              conn
              |> Plug.Conn.put_resp_header("location", "http://missing.test/landed")
              |> Plug.Conn.send_resp(redirect_status, "")
            end
          )

        info = HttpTestServer.info(pid)

        {input, opts} =
          live_input(info, box, %{
            "method" => "post",
            "url" => url(info, "/write"),
            "body" => "payload",
            "body_mode" => "text"
          })

        resolver = fn
          "http.test.local" -> {:ok, [@public]}
          "missing.test" -> {:error, :nxdomain}
        end

        assert {:ok, outcome} =
                 HttpRequest.run(input, Keyword.put(opts, :dns_resolver, resolver))

        assert outcome.kind == :uncertain
        assert outcome.error_class == "ambiguous_transport"
        assert outcome.output["remote_status"] == redirect_status

        diagnostics = RetryPolicy.diagnostics(outcome, %{})
        assert diagnostics["dispatch_state"] == "confirmed"
        assert diagnostics["duplicate_risk"]

        assert {:ok, applied} =
                 RetryPolicy.apply(outcome, %{
                   attempt_number: 1,
                   compiled_node: input.compiled_node
                 })

        assert applied.kind == :uncertain
        refute applied.resume_at
      end
    end
  end

  describe "status range" do
    test "a configured success list admits 201 and rejects 200" do
      assert status_outcome([201], 201).kind == :success
      assert status_outcome([201], 200).kind == :permanent_error
      assert status_outcome([201], 200).error_class == "remote_permanent"
    end

    test "the default range treats 2xx as success and 404 as permanent" do
      assert status_outcome(nil, 204).kind == :success
      assert status_outcome(nil, 404).kind == :permanent_error
      assert status_outcome(nil, 404).error_class == "not_found"
    end
  end

  describe "JSON extraction" do
    test "reads bounded paths and omits the rest of the body" do
      pid =
        start_http(
          handler: fn conn ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, ~s({"id":"t-9","token":"leak-me","items":[{"n":1}]}))
          end
        )

      info = HttpTestServer.info(pid)
      box = start_box()

      {input, opts} =
        live_input(info, box, %{
          "method" => "get",
          "url" => url(info, "/ticket"),
          "extract" => %{"ticket_id" => "id", "first" => "items.0.n"}
        })

      assert {:ok, outcome} = HttpRequest.run(input, opts)
      assert outcome.kind == :success
      assert outcome.output["extracted"] == %{"ticket_id" => "t-9", "first" => 1}
      refute Map.has_key?(outcome.output, "body")
      refute outcome.output["body_excerpt"] =~ "leak-me"

      assert outcome.output["body_sha256"] ==
               SafeHttp.body_digest(~s({"id":"t-9","token":"leak-me","items":[{"n":1}]}))
    end

    test "malformed JSON with extract configured is permanent" do
      pid =
        start_http(handler: fn conn -> Plug.Conn.send_resp(conn, 200, "not-json") end)

      info = HttpTestServer.info(pid)
      box = start_box()

      {input, opts} =
        live_input(info, box, %{
          "method" => "post",
          "url" => url(info, "/bad"),
          "body" => "{}",
          "body_mode" => "json",
          "extract" => %{"id" => "id"}
        })

      assert {:ok, outcome} = HttpRequest.run(input, opts)
      assert outcome.kind == :permanent_error
      assert outcome.error_class == "validation"
      assert outcome.output["remote_status"] == 200

      diagnostics = RetryPolicy.diagnostics(outcome, %{})
      assert diagnostics["dispatch_state"] == "confirmed"
      assert diagnostics["dispatched"]
      assert diagnostics["bytes_may_have_left"]
      assert diagnostics["duplicate_risk"]
    end
  end

  describe "body cap" do
    test "an oversized response is a resource-limit failure" do
      pid =
        start_http(
          handler: fn conn -> Plug.Conn.send_resp(conn, 200, String.duplicate("x", 80)) end
        )

      info = HttpTestServer.info(pid)
      box = start_box()
      {input, opts} = live_get(info, box, "/big")
      opts = Keyword.put(opts, :max_body_bytes, 32)

      assert {:ok, outcome} = HttpRequest.run(input, opts)
      assert outcome.kind == :permanent_error
      assert outcome.error_class == "resource_limit"
    end

    test "body and header excerpts stay valid UTF-8 at the byte boundary" do
      boundary = String.duplicate("a", 255) <> "€"

      pid =
        start_http(
          handler: fn conn ->
            conn
            |> Plug.Conn.put_resp_header("x-request-id", boundary)
            |> Plug.Conn.send_resp(200, boundary)
          end
        )

      info = HttpTestServer.info(pid)
      box = start_box()

      {input, opts} =
        live_input(info, box, %{
          "method" => "post",
          "url" => url(info, "/unicode"),
          "body" => "{}",
          "body_mode" => "json"
        })

      assert {:ok, outcome} = HttpRequest.run(input, opts)
      assert outcome.kind == :success
      assert outcome.output["body_excerpt"] == String.duplicate("a", 255)
      assert outcome.output["headers"]["x-request-id"] == String.duplicate("a", 255)
      assert String.valid?(outcome.output["body_excerpt"])
      assert String.valid?(outcome.output["headers"]["x-request-id"])
      assert {:ok, _bounded} = Outcome.bound(outcome, 4_096)

      diagnostics = RetryPolicy.diagnostics(outcome, %{})
      assert diagnostics["dispatch_state"] == "confirmed"
      assert diagnostics["dispatched"]
    end

    test "non-text response excerpts are replaced with a JSON-safe description" do
      excerpt = SafeHttp.excerpt(<<255, 254, 0, 1>>)
      headers = SafeHttp.captured_headers([{"x-request-id", <<255, 254>>}])

      assert excerpt == "non-text value, 4 bytes"
      assert headers["x-request-id"] == "non-text value, 2 bytes"
      assert String.valid?(excerpt)
      assert {:ok, _json} = Jason.encode(%{"excerpt" => excerpt, "headers" => headers})
    end

    test "an oversized response body after an unkeyed POST pauses uncertain" do
      outcome =
        unsafe_post_response(
          fn conn ->
            Plug.Conn.send_resp(conn, 200, String.duplicate("x", 80))
          end,
          max_body_bytes: 32
        )

      assert_unsafe_response_pause(outcome)
    end

    test "oversized response headers after an unkeyed POST pause uncertain" do
      outcome =
        unsafe_post_response(fn conn ->
          conn
          |> Plug.Conn.put_resp_header(
            "x-oversized",
            String.duplicate("h", SafeHttp.max_header_bytes() + 1_024)
          )
          |> Plug.Conn.send_resp(200, "ok")
        end)

      assert_unsafe_response_pause(outcome)
    end

    test "a compressed response after an unkeyed POST pauses uncertain" do
      outcome =
        unsafe_post_response(fn conn ->
          conn
          |> Plug.Conn.put_resp_header("content-encoding", "gzip")
          |> Plug.Conn.send_resp(200, "compressed")
        end)

      assert_unsafe_response_pause(outcome)
    end
  end

  describe "GET retry" do
    test "a GET timeout is retryable and the policy schedules another attempt" do
      pid =
        start_http(
          handler: fn conn ->
            receive do
              :release -> Plug.Conn.send_resp(conn, 200, "late")
            end
          end
        )

      info = HttpTestServer.info(pid)
      box = start_box()
      {input, opts} = live_get(info, box, "/hang")
      opts = Keyword.put(opts, :timeout_ms, 100)

      assert {:ok, outcome} = HttpRequest.run(input, opts)
      assert outcome.kind == :retryable_error
      assert outcome.error_class == "transient_transport"

      snapshot = %{attempt_number: 1, compiled_node: input.compiled_node}
      assert RetryPolicy.retry_safety(snapshot) == :read_only
      {:ok, applied} = RetryPolicy.apply(outcome, snapshot)
      assert applied.kind == :retryable_error
      assert applied.resume_at
    end
  end

  describe "POST timeout with and without idempotency" do
    test "a write timeout without an idempotency header pauses uncertain" do
      outcome = post_timeout(%{})
      assert outcome.kind == :uncertain
      assert outcome.error_class == "ambiguous_transport"

      snapshot = %{
        attempt_number: 1,
        compiled_node: %{type: :http_action, config: %{"method" => "post"}}
      }

      {:ok, applied} = RetryPolicy.apply(outcome, snapshot)
      assert applied.kind == :uncertain
    end

    test "a write timeout with a remote idempotency header is retryable" do
      outcome =
        post_timeout(%{
          "idempotency_header" => "Idempotency-Key"
        })

      assert outcome.kind == :retryable_error
      assert outcome.error_class == "transient_transport"

      snapshot = %{
        attempt_number: 1,
        compiled_node: %{
          type: :http_action,
          config: %{"method" => "post", "idempotency_header" => "Idempotency-Key"}
        }
      }

      assert RetryPolicy.retry_safety(snapshot) == :idempotent_effect
      {:ok, applied} = RetryPolicy.apply(outcome, snapshot)
      assert applied.kind == :retryable_error
      assert applied.resume_at
    end

    test "a transport close after an unkeyed POST body pauses uncertain" do
      seen = start_box()

      pid =
        start_http(
          handler: fn conn ->
            {:ok, body, _conn} = Plug.Conn.read_body(conn)
            Agent.update(seen, fn _value -> body end)
            Process.exit(self(), :kill)
          end
        )

      info = HttpTestServer.info(pid)
      box = start_box()

      {input, opts} =
        live_input(info, box, %{
          "method" => "post",
          "url" => url(info, "/close"),
          "body" => "applied-payload",
          "body_mode" => "text"
        })

      assert {:ok, outcome} = HttpRequest.run(input, opts)
      assert Agent.get(seen, & &1) == "applied-payload"
      assert outcome.kind == :uncertain
      assert outcome.error_class == "ambiguous_transport"
      assert outcome.output["request_written"]

      diagnostics = RetryPolicy.diagnostics(outcome, %{})
      assert diagnostics["dispatch_state"] == "possibly_sent"
      assert diagnostics["duplicate_risk"]
    end
  end

  describe "retry safety classification" do
    test "GET is read-only; unmarked writes are not; only a header marks a write idempotent" do
      assert RetryPolicy.retry_safety(%{type: :http_action, config: %{"method" => "get"}}) ==
               :read_only

      assert RetryPolicy.retry_safety(%{type: :http_action, config: %{"method" => "post"}}) ==
               :not_idempotent

      assert RetryPolicy.retry_safety(%{
               type: :http_action,
               config: %{"method" => "put", "idempotent" => true}
             }) == :not_idempotent

      assert RetryPolicy.retry_safety(%{
               type: :http_action,
               config: %{"method" => "put", "idempotency_header" => "Idempotency-Key"}
             }) == :idempotent_effect
    end
  end

  describe "NodeRunner dry-run" do
    test "returns a redacted would-send summary without opening a socket" do
      input =
        runner_input(%{
          "method" => "post",
          "url" => "https://example.test/hook",
          "headers" => %{"accept" => "text/plain"},
          "body" => "token=" <> Templates.secret_placeholder("API_TOKEN"),
          "body_mode" => "text"
        })
        |> Map.put(:run_mode, "dry_run")

      assert {:ok, outcome} = NodeRunner.run(input)
      assert outcome.kind == :success
      assert outcome.output["adapter"] == "HTTP"
      assert outcome.output["method"] == "post"
      assert outcome.output["url"] == "https://example.test/hook"
      assert outcome.output["dry_run"] == true
    end

    test "a compiled POST without body_mode keeps a secret placeholder" do
      input =
        runner_input(%{
          "method" => "post",
          "url" => "https://example.test/hook",
          "headers" => %{"accept" => "text/plain"},
          "body" => "token=" <> Templates.secret_placeholder("API_TOKEN")
        })
        |> Map.put(:run_mode, "dry_run")

      assert {:ok, outcome} = NodeRunner.run(input)
      assert outcome.kind == :success

      assert outcome.output["body_bytes"] ==
               byte_size("token=" <> Templates.secret_placeholder("API_TOKEN"))
    end
  end

  describe "too many redirects" do
    test "a fourth Location is a permanent failure" do
      pid =
        start_http(
          handler: fn conn ->
            conn
            |> Plug.Conn.put_resp_header("location", "/loop")
            |> Plug.Conn.send_resp(302, "")
          end
        )

      info = HttpTestServer.info(pid)
      box = start_box()
      {input, opts} = live_get(info, box, "/loop")

      assert {:ok, outcome} = HttpRequest.run(input, opts)
      assert outcome.kind == :permanent_error
      assert outcome.error_class == "validation"
      assert outcome.output["remote_status"] == 302
      assert RetryPolicy.diagnostics(outcome, %{})["dispatch_state"] == "confirmed"
    end
  end

  defp assert_redirect_method(status, expected_method, expected_body) do
    box = start_box()
    seen = start_box()

    pid =
      start_http(
        handler: fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          Agent.update(seen, fn rows ->
            rows ++ [%{method: conn.method, path: conn.request_path, body: body}]
          end)

          case conn.request_path do
            "/write" ->
              conn
              |> Plug.Conn.put_resp_header("location", "/landed")
              |> Plug.Conn.send_resp(status, "")

            "/landed" ->
              Plug.Conn.send_resp(conn, 200, "ok")
          end
        end
      )

    info = HttpTestServer.info(pid)

    {input, opts} =
      live_input(info, box, %{
        "method" => "post",
        "url" => url(info, "/write"),
        "body" => "payload",
        "body_mode" => "text"
      })

    assert {:ok, outcome} = HttpRequest.run(input, opts)
    assert outcome.kind == :success
    [_first, second] = Agent.get(seen, & &1)
    assert second.method == expected_method
    assert second.body == expected_body
    assert second.path == "/landed"
  end

  defp status_outcome(success_status, status) do
    pid =
      start_http(handler: fn conn -> Plug.Conn.send_resp(conn, status, "x") end)

    info = HttpTestServer.info(pid)
    box = start_box()

    config =
      %{"method" => "get", "url" => url(info, "/s")}
      |> maybe_put_success(success_status)

    {input, opts} = live_input(info, box, config)
    assert {:ok, outcome} = HttpRequest.run(input, opts)
    outcome
  end

  defp maybe_put_success(config, nil), do: config
  defp maybe_put_success(config, list), do: Map.put(config, "success_status", list)

  defp post_timeout(extra) do
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

    config =
      Map.merge(
        %{
          "method" => "post",
          "url" => url(info, "/hang"),
          "body" => "{}",
          "body_mode" => "json"
        },
        extra
      )

    {input, opts} = live_input(info, box, config)
    opts = Keyword.put(opts, :timeout_ms, 100)
    assert {:ok, outcome} = HttpRequest.run(input, opts)
    outcome
  end

  defp unsafe_post_response(response, run_opts \\ []) do
    seen = start_box()

    pid =
      start_http(
        handler: fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          Agent.update(seen, fn _value -> body end)
          response.(conn)
        end
      )

    info = HttpTestServer.info(pid)
    box = start_box()

    {input, opts} =
      live_input(info, box, %{
        "method" => "post",
        "url" => url(info, "/response-policy"),
        "body" => "applied-payload",
        "body_mode" => "text"
      })

    assert {:ok, outcome} = HttpRequest.run(input, Keyword.merge(opts, run_opts))
    assert Agent.get(seen, & &1) == "applied-payload"
    outcome
  end

  defp assert_unsafe_response_pause(outcome) do
    assert outcome.kind == :uncertain
    assert outcome.error_class == "side_effect_uncertain"
    assert outcome.output["phase"] == "response"
    assert outcome.output["request_written"]

    diagnostics = RetryPolicy.diagnostics(outcome, %{})
    assert diagnostics["dispatch_state"] == "possibly_sent"
    assert diagnostics["duplicate_risk"]
  end

  defp live_get(info, box, path) do
    live_input(info, box, %{"method" => "get", "url" => url(info, path)})
  end

  defp live_input(info, box, config, input_opts \\ []) do
    input = runner_input(config, input_opts)
    {input, run_opts(info, box, input_opts)}
  end

  defp run_opts(info, box, input_opts) do
    [
      allow_http: true,
      dns_resolver: fn _host -> {:ok, [@public]} end,
      connection: Keyword.get(input_opts, :connection),
      secrets: Keyword.get(input_opts, :secrets, %{}),
      secrets_by_id: Keyword.get(input_opts, :secrets_by_id, %{}),
      connect: fn scheme, _address, port, hostname, opts ->
        Agent.update(box, fn ports -> ports ++ [port] end)
        SafeHttp.Transport.connect(scheme, info.ip, port, hostname, opts)
      end
    ]
  end

  defp runner_input(config, opts \\ []) do
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
      run_mode: Keyword.get(opts, :run_mode, "live"),
      effect_key: Keyword.get(opts, :effect_key, "inst/exec/node"),
      attempt: %{id: Ecto.UUID.generate(), number: 1},
      adapters: %{}
    }
  end

  defp url(info, path), do: "http://http.test.local:#{info.port}#{path}"

  defp start_http(opts) do
    start_supervised!({HttpTestServer, opts},
      id: {:http_test_server, System.unique_integer([:positive])}
    )
  end

  defp start_box do
    start_supervised!({Agent, fn -> [] end}, id: {:box, System.unique_integer([:positive])})
  end
end
