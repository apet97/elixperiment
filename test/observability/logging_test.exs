defmodule PumbleAutomation.Observability.LoggingTest do
  @moduledoc """
  Structured logs carry correlation ids and never the content that produced
  the run. Each capture is a real path (OAuth, callback, Pumble action, HTTP
  action, approval, uncertainty, exception), then a secret-pattern scan.
  """

  use PumbleAutomationWeb.ConnCase, async: false
  use Oban.Testing, repo: PumbleAutomation.Repo

  import ExUnit.CaptureLog
  import PumbleAutomation.InstallationsFixtures
  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Connections.SafeHttp
  alias PumbleAutomation.Executions.Approval
  alias PumbleAutomation.Executions.ApprovalService
  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.NodeRunner
  alias PumbleAutomation.Executions.Nodes.HttpRequest
  alias PumbleAutomation.Executions.Outcome
  alias PumbleAutomation.HttpTestServer
  alias PumbleAutomation.Installations.OauthStates
  alias PumbleAutomation.Logging
  alias PumbleAutomation.Pumble.Payload
  alias PumbleAutomation.Pumble.Signature
  alias PumbleAutomation.PumbleFake
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Node
  alias PumbleAutomation.Workflows.Templates

  @public {1, 1, 1, 1}
  @callback_secret "test-signing-secret"
  @callback_timestamp "1767225600000"
  @secret_patterns [
    ~r/Bearer\s+[A-Za-z0-9._~+\/=-]{8,}/,
    ~r/test-client-secret/,
    ~r/test-signing-secret/,
    ~r/bot-access-token/,
    ~r/user-access-token/
  ]

  setup do
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)
    :ok
  end

  describe "schema and redaction" do
    test "the documented schema lists every allowlisted field" do
      schema = File.read!("docs/operations/logging.md")

      for field <- Logging.fields() do
        assert schema =~ "`#{field}`", "#{field} missing from docs/operations/logging.md"
      end
    end

    test "redact replaces nested secrets and private bodies" do
      assert Logging.redact(%{
               "ok" => 1,
               "token" => "leak-me",
               "error_code" => "RuntimeError",
               "nested" => %{"body" => "private text", "status" => "ok"}
             }) == %{
               "ok" => 1,
               "token" => "[REDACTED]",
               "error_code" => "RuntimeError",
               "nested" => %{"body" => "[REDACTED]", "status" => "ok"}
             }
    end

    test "redact failure becomes a replacement, not the raw term" do
      assert Logging.redact([1 | :not_a_list]) == "[REDACTED]"
    end

    test "filter_headers redacts secrets and never echoes values" do
      assert Logging.filter_headers([
               {"authorization", "Bearer planted-header"},
               {"x-pumble-request-signature", "abc123"},
               {"content-type", "application/json"},
               :bad
             ]) == [
               {"authorization", "[REDACTED]"},
               {"x-pumble-request-signature", "[REDACTED]"},
               {"content-type", "[present]"},
               {"unknown", "[REDACTED]"}
             ]
    end

    test "JSON format writes allowlisted fields and drops tokens" do
      installation_id = Ecto.UUID.generate()
      execution_id = Ecto.UUID.generate()

      json =
        Logging.format(
          %{
            level: :info,
            msg: {:string, "pumble.action"},
            meta: %{
              time: System.system_time(:microsecond),
              request_id: "req-1",
              installation_id: installation_id,
              execution_id: execution_id,
              operation: "post_message",
              duration_ms: 12,
              status: "ok",
              token: "must-not-leak",
              body: "callback body"
            }
          },
          %{}
        )
        |> IO.iodata_to_binary()

      payload = Jason.decode!(String.trim(json))
      assert payload["msg"] == "pumble.action"
      assert payload["installation_id"] == installation_id
      assert payload["execution_id"] == execution_id
      assert payload["operation"] == "post_message"
      assert payload["duration_ms"] == 12
      refute Map.has_key?(payload, "token")
      refute Map.has_key?(payload, "body")
      refute json =~ "must-not-leak"
      refute json =~ "callback body"
    end

    test "JSON format failure is a replacement object" do
      line = Logging.format(:not_a_map, %{}) |> IO.iodata_to_binary()
      payload = Jason.decode!(String.trim(line))
      assert payload["msg"] == "[REDACTED]"
      assert payload["error_code"] == "log_format_failed"
    end

    test "event never raises into the caller" do
      capture_log(fn ->
        assert :ok = Logging.event(:info, "event", %{token: "x"})
        assert :ok = Logging.event(:not_a_level, "event", %{})
        assert :ok = Logging.event(:info, :not_a_string, %{})
        assert :ok = Logging.event(:info, "event", :not_a_map)
      end)
    end

    test "a Bearer token in the message is redacted before JSON encode" do
      json =
        Logging.format(%{level: :info, msg: {:string, "Bearer planted-token"}, meta: %{}}, %{})
        |> IO.iodata_to_binary()

      refute json =~ "planted-token"
      assert Jason.decode!(String.trim(json))["msg"] == "[REDACTED]"
    end
  end

  describe "diagnostic mode" do
    test "requires a tenant actor, expires, and never logs the content" do
      installation_id = Ecto.UUID.generate()
      planted = planted("diag")
      digest = Logging.fingerprint(planted)

      assert {:error, :unauthorized} = Logging.enable_diagnostics(installation_id)

      assert :ok =
               Logging.enable_diagnostics(installation_id,
                 authorized_by: "member-1",
                 ttl_seconds: 60
               )

      log =
        capture_log(fn ->
          Logging.event(:info, "http.action", %{
            installation_id: installation_id,
            operation: "http.action",
            diagnostics: planted
          })
        end)

      assert log =~ "http.action"
      assert log =~ installation_id
      assert log =~ digest.sha256
      refute_forbidden(log, [planted])

      :ets.insert(
        :pumble_automation_log_diagnostics,
        {installation_id, DateTime.add(DateTime.utc_now(), -1, :second), 1.0, "member-1"}
      )

      refute Logging.diagnostics_enabled?(installation_id)

      log =
        capture_log(fn ->
          Logging.event(:info, "http.action", %{
            installation_id: installation_id,
            diagnostics: planted
          })
        end)

      refute log =~ digest.sha256
      refute_forbidden(log, [planted])
    end

    test "ttl cannot exceed one hour" do
      installation_id = Ecto.UUID.generate()

      assert :ok =
               Logging.enable_diagnostics(installation_id,
                 authorized_by: "member-1",
                 ttl_seconds: 10_000
               )

      [{^installation_id, expires_at, _rate, "member-1"}] =
        :ets.lookup(:pumble_automation_log_diagnostics, installation_id)

      assert DateTime.diff(expires_at, DateTime.utc_now(), :second) <= 3_600
      Logging.disable_diagnostics(installation_id)
    end
  end

  describe "OAuth" do
    test "callback logs ids and omits codes, state, and tokens", %{conn: conn} do
      PumbleFake.stub_success()
      state = mint_state()
      code = planted("oauth-code")

      {conn, log} =
        with_log(fn ->
          get(conn, ~p"/oauth/callback?code=#{code}&state=#{state}")
        end)

      assert redirected_to(conn) == "/"
      assert [installation] = Repo.all(PumbleAutomation.Installations.Installation)
      assert log =~ "oauth.callback"
      assert log =~ installation.id
      refute_forbidden(log, [code, state, "test-client-secret"])
    end
  end

  describe "callback" do
    test "a signed NEW_MESSAGE log has class and duration, not message text" do
      planted = planted("callback-text")
      inner = Jason.decode!(PumbleFake.fixture("callbacks/event_new_message.json")["body"])
      body = Jason.encode!(Map.put(inner, "tx", planted))

      payload =
        "callbacks/event_new_message.json"
        |> PumbleFake.fixture()
        |> Map.put("body", body)
        |> Jason.encode!()

      log =
        capture_log(fn ->
          conn = signed_callback(payload)
          assert response(conn, 200) == "ok"
        end)

      assert log =~ "pumble.callback"
      refute log =~ "deploy the release please"
      refute log =~ "thread root text"
      refute_forbidden(log, [planted, @callback_secret])
    end
  end

  describe "Pumble action" do
    test "a live send logs installation and attempt ids without text or tokens" do
      %{installation: installation} = install(tokens: %{bot_user_id: "bot1"})
      planted = planted("pumble-text")
      attempt_id = Ecto.UUID.generate()

      PumbleFake.stub_api_routes(self(), [
        {"POST", "/v1/channels/channel-1/messages", 200,
         %{"id" => "message1", "channelId" => "channel-1", "text" => planted}}
      ])

      input = %{
        compiled_node: %{
          type: :pumble_action,
          config: %{"action" => "send_message", "channel_id" => "channel-1", "text" => planted},
          edges: %{"next" => "end"},
          requires: %{
            "operations" => ["post_message"],
            "scopes" => ["messages:write"],
            "connection_ids" => [],
            "secret_names" => []
          }
        },
        context: %{},
        trigger_snapshot: %{"data" => %{}},
        installation_id: installation.id,
        run_mode: "live",
        effect_key: "inst/exec/node",
        attempt: %{id: attempt_id, number: 1},
        resolver: PumbleAutomation.Connections.Resolver,
        adapters: %{}
      }

      log =
        capture_log(fn ->
          assert {:ok, outcome} = NodeRunner.run(input)
          assert outcome.kind == :success
        end)

      assert log =~ "pumble.action"
      assert log =~ installation.id
      assert log =~ attempt_id
      refute_forbidden(log, [planted])
    end
  end

  describe "HTTP action" do
    test "a live GET logs status without Authorization, URL, or bodies" do
      planted = planted("http")
      box = start_box()

      pid =
        start_http(
          handler: fn conn ->
            {:ok, _body, conn} = Plug.Conn.read_body(conn)

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, ~s({"secret":"#{planted}"}))
          end
        )

      info = HttpTestServer.info(pid)
      installation_id = Ecto.UUID.generate()

      input = %{
        compiled_node: %{
          type: :http_action,
          config: %{
            "method" => "get",
            "url" => "http://http.test.local:#{info.port}/secret",
            "headers" => %{"Authorization" => Templates.secret_placeholder("API_TOKEN")}
          },
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
        installation_id: installation_id,
        run_mode: "live",
        effect_key: "inst/exec/node",
        attempt: %{id: Ecto.UUID.generate(), number: 1},
        adapters: %{}
      }

      opts = [
        allow_http: true,
        dns_resolver: fn _host -> {:ok, [@public]} end,
        secrets: %{"API_TOKEN" => "Bearer #{planted}"},
        connect: fn scheme, _address, port, hostname, opts ->
          Agent.update(box, fn ports -> ports ++ [port] end)
          SafeHttp.Transport.connect(scheme, info.ip, port, hostname, opts)
        end
      ]

      log =
        capture_log(fn ->
          assert {:ok, outcome} = HttpRequest.run(input, opts)
          assert outcome.kind == :success
        end)

      assert log =~ "http.action"
      assert log =~ installation_id
      refute log =~ "http.test.local"
      refute_forbidden(log, [planted, "Bearer #{planted}"])
    end
  end

  describe "approval" do
    test "a decision logs execution ids and omits the button payload" do
      context = approval_context()
      {_waiting, approval, _stop} = waited_with_stop!(context)
      interaction = click(approval, context.member, "approved", context)
      payload = interaction.payload

      log =
        capture_log(fn ->
          assert {:ok, {:decided, "Approved."}} = ApprovalService.decide(interaction)
        end)

      assert log =~ "approval.decision"
      assert log =~ context.installation_id
      assert log =~ approval.step_execution_id
      refute_forbidden(log, [payload, approval.nonce])
    end
  end

  describe "uncertainty" do
    test "resolution logs ids and omits planted evidence" do
      context = uncertainty_context()
      planted = planted("evidence")
      next = stop_node()
      %{execution: execution} = paused!(context, [message_node(), next])

      log =
        capture_log(fn ->
          assert {:ok, continued} =
                   Engine.resolve_uncertain(context.scope, execution.id, :succeeded, %{
                     evidence: %{"note" => planted}
                   })

          assert continued.status == "running"
          assert continued.current_node_id == next.id
        end)

      assert log =~ "execution.uncertain"
      assert log =~ execution.id
      assert log =~ context.installation_id
      refute_forbidden(log, [planted])
    end
  end

  describe "exception" do
    test "router exception logs class and request id without the reason text" do
      planted = planted("exception")
      request_id = "req-p14-t01-#{System.unique_integer([:positive])}"

      log =
        capture_log(fn ->
          :telemetry.execute(
            [:phoenix, :router_dispatch, :exception],
            %{duration: System.convert_time_unit(9, :millisecond, :native)},
            %{
              kind: :error,
              reason: %RuntimeError{message: planted},
              conn: %{assigns: %{request_id: request_id}},
              body: planted,
              token: planted
            }
          )
        end)

      assert log =~ "exception"
      assert log =~ request_id
      assert log =~ "RuntimeError"
      refute_forbidden(log, [planted])
    end
  end

  describe "secret-pattern scan" do
    test "one capture over the seven paths matches no secret pattern" do
      bag = capture_all_paths()
      refute_secret_patterns(bag)
    end
  end

  defp capture_all_paths do
    oauth = planted("scan-oauth")
    callback = planted("scan-callback")
    pumble = planted("scan-pumble")
    http = planted("scan-http")
    evidence = planted("scan-evidence")
    exception = planted("scan-exception")

    {_conn, oauth_log} =
      with_log(fn ->
        PumbleFake.stub_success()
        get(build_conn(), ~p"/oauth/callback?code=#{oauth}&state=#{mint_state()}")
      end)

    inner = Jason.decode!(PumbleFake.fixture("callbacks/event_new_message.json")["body"])

    callback_body =
      "callbacks/event_new_message.json"
      |> PumbleFake.fixture()
      |> Map.put("body", Jason.encode!(Map.put(inner, "tx", callback)))
      |> Jason.encode!()

    callback_log = capture_log(fn -> signed_callback(callback_body) end)

    %{installation: installation} = install(tokens: %{bot_user_id: "bot1"})

    PumbleFake.stub_api_routes(self(), [
      {"POST", "/v1/channels/channel-1/messages", 200,
       %{"id" => "message1", "channelId" => "channel-1", "text" => pumble}}
    ])

    pumble_log =
      capture_log(fn ->
        NodeRunner.run(pumble_input(installation.id, pumble, Ecto.UUID.generate()))
      end)

    {_pid, info, box} = http_server(http)

    http_log =
      capture_log(fn ->
        HttpRequest.run(http_input(info, Ecto.UUID.generate()), http_opts(info, box, http))
      end)

    context = approval_context()
    {_waiting, approval, _stop} = waited_with_stop!(context)
    interaction = click(approval, context.member, "approved", context)
    approval_log = capture_log(fn -> ApprovalService.decide(interaction) end)

    paused = uncertainty_context()
    %{execution: execution} = paused!(paused, [message_node(), stop_node()])

    uncertainty_log =
      capture_log(fn ->
        Engine.resolve_uncertain(paused.scope, execution.id, :succeeded, %{
          evidence: %{"note" => evidence}
        })
      end)

    exception_log =
      capture_log(fn ->
        :telemetry.execute(
          [:phoenix, :router_dispatch, :exception],
          %{duration: 1},
          %{kind: :error, reason: %RuntimeError{message: exception}, conn: %{assigns: %{}}}
        )
      end)

    Enum.join(
      [
        oauth_log,
        callback_log,
        pumble_log,
        http_log,
        approval_log,
        uncertainty_log,
        exception_log
      ],
      "\n"
    )
  end

  defp planted(label) do
    "P14T01-#{label}-#{System.unique_integer([:positive])}-must-not-leak"
  end

  defp refute_forbidden(log, values) do
    refute_secret_patterns(log)

    for value <- values, is_binary(value) and value != "" do
      refute log =~ value, "forbidden value reached a log line"
    end
  end

  defp refute_secret_patterns(log) do
    for pattern <- @secret_patterns do
      refute Regex.match?(pattern, log), "log matched forbidden pattern #{inspect(pattern)}"
    end
  end

  defp mint_state do
    {:ok, token, _state} = OauthStates.create("install")
    token
  end

  defp signed_callback(body) do
    build_conn()
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("x-pumble-request-timestamp", @callback_timestamp)
    |> Plug.Conn.put_req_header(
      "x-pumble-request-signature",
      Signature.compute(@callback_secret, @callback_timestamp, body)
    )
    |> post(~p"/pumble/callbacks", body)
  end

  defp pumble_input(installation_id, text, attempt_id) do
    %{
      compiled_node: %{
        type: :pumble_action,
        config: %{"action" => "send_message", "channel_id" => "channel-1", "text" => text},
        edges: %{"next" => "end"},
        requires: %{
          "operations" => ["post_message"],
          "scopes" => ["messages:write"],
          "connection_ids" => [],
          "secret_names" => []
        }
      },
      context: %{},
      trigger_snapshot: %{"data" => %{}},
      installation_id: installation_id,
      run_mode: "live",
      effect_key: "inst/exec/node",
      attempt: %{id: attempt_id, number: 1},
      resolver: PumbleAutomation.Connections.Resolver,
      adapters: %{}
    }
  end

  defp http_server(planted) do
    box = start_box()

    pid =
      start_http(
        handler: fn conn ->
          {:ok, _body, conn} = Plug.Conn.read_body(conn)

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, ~s({"secret":"#{planted}"}))
        end
      )

    {pid, HttpTestServer.info(pid), box}
  end

  defp http_input(info, installation_id) do
    %{
      compiled_node: %{
        type: :http_action,
        config: %{
          "method" => "get",
          "url" => "http://http.test.local:#{info.port}/secret",
          "headers" => %{"Authorization" => Templates.secret_placeholder("API_TOKEN")}
        },
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
      installation_id: installation_id,
      run_mode: "live",
      effect_key: "inst/exec/node",
      attempt: %{id: Ecto.UUID.generate(), number: 1},
      adapters: %{}
    }
  end

  defp http_opts(info, box, planted) do
    [
      allow_http: true,
      dns_resolver: fn _host -> {:ok, [@public]} end,
      secrets: %{"API_TOKEN" => "Bearer #{planted}"},
      connect: fn scheme, _address, port, hostname, opts ->
        Agent.update(box, fn ports -> ports ++ [port] end)
        SafeHttp.Transport.connect(scheme, info.ip, port, hostname, opts)
      end
    ]
  end

  defp start_http(opts) do
    start_supervised!({HttpTestServer, opts},
      id: {:http_test_server, System.unique_integer([:positive])}
    )
  end

  defp start_box do
    start_supervised!({Agent, fn -> [] end}, id: {:box, System.unique_integer([:positive])})
  end

  defp approval_context do
    %{installation: installation, member: member} =
      install(tokens: %{bot_user_id: "bot1"})

    %{
      scope: Scope.new(member),
      installation: installation,
      installation_id: installation.id,
      member: member,
      workspace_id: installation.pumble_workspace_id
    }
  end

  defp uncertainty_context do
    %{installation: installation, member: member} = install()
    scope = Scope.new(member)

    %{
      scope: scope,
      installation: installation,
      installation_id: installation.id,
      member: member
    }
  end

  defp waited_with_stop!(context) do
    stop = stop_node()
    approval_node = approval_for(context.member, approved: [stop])
    %{snapshot: snapshot} = claimed!(context, [approval_node])
    assert {:ok, outcome} = NodeRunner.run(NodeRunner.input(snapshot))
    assert {:ok, waiting} = Engine.finalize(snapshot, outcome)
    stored = Repo.get_by!(Approval, execution_id: waiting.id)
    {waiting, stored, stop}
  end

  defp paused!(context, nodes) do
    %{version: version} = activate!(context.scope, context.installation_id, definition(nodes))

    {:ok, execution} =
      Engine.create(context.scope, %{
        workflow_version_id: version.id,
        execution_key: "unc-#{System.unique_integer([:positive])}"
      })

    execution = Repo.get!(Execution, execution.id)
    {:ok, snapshot} = Engine.claim(job_args(execution))

    {:ok, outcome} =
      Outcome.new(%{
        kind: :uncertain,
        error_class: "side_effect_uncertain",
        message: "The remote write may have succeeded.",
        remote_reference: "req-1"
      })

    assert {:ok, paused} = Engine.finalize(snapshot, outcome)
    %{snapshot: snapshot, execution: paused, version: version}
  end

  defp claimed!(context, nodes) do
    %{version: version} = activate!(context.scope, context.installation_id, definition(nodes))

    {:ok, execution} =
      Engine.create(context.scope, %{
        workflow_version_id: version.id,
        execution_key: "approval-#{System.unique_integer([:positive])}",
        trigger_snapshot: %{"channel_id" => "channel-1"}
      })

    execution = Repo.get!(Execution, execution.id)
    {:ok, snapshot} = Engine.claim(job_args(execution))
    %{execution: execution, snapshot: snapshot, version: version}
  end

  defp activate!(scope, installation_id, definition) do
    workflow =
      drafted_workflow(installation_id, %{draft_definition: Definition.encode(definition)})

    {:ok, result} = Workflows.activate_workflow(scope, workflow.id, 0)
    %{version: result.version, workflow: result.workflow}
  end

  defp approval_for(member, opts) do
    {branches, opts} = Keyword.split(opts, [:approved, :rejected, :timed_out])

    :approval
    |> Node.new(
      %{
        prompt: Keyword.get(opts, :prompt, "Ship it?"),
        approver_member_ids: Keyword.get(opts, :approver_member_ids, [member.id]),
        timeout_seconds: Keyword.get(opts, :timeout_seconds, 3600)
      },
      Keyword.take(opts, [:id])
    )
    |> Node.put_branch(:approved, Keyword.get(branches, :approved, [stop_node()]))
    |> Node.put_branch(:rejected, Keyword.get(branches, :rejected, []))
    |> Node.put_branch(:timed_out, Keyword.get(branches, :timed_out, []))
  end

  defp click(approval, member, action, context) do
    %Payload.BlockInteraction{
      workspace_id: context.workspace_id,
      user_id: member.pumble_user_id,
      channel_id: approval.pumble_channel_id,
      source_type: "MESSAGE",
      source_id: approval.pumble_message_id || "msg-1",
      action_type: "BUTTON",
      on_action: approval.public_action_id,
      payload: ApprovalService.button_value(approval, action, context.workspace_id),
      trigger_id: "trig-#{System.unique_integer([:positive])}"
    }
  end

  defp job_args(%Execution{} = execution) do
    %{
      "installation_id" => execution.installation_id,
      "execution_id" => execution.id,
      "expected_node_id" => execution.current_node_id,
      "generation" => execution.lock_version
    }
  end
end
