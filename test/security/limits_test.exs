defmodule PumbleAutomation.Security.LimitsTest do
  @moduledoc """
  Section 31 resource limits and P13-T02 rate limits: catalog, owners,
  quotas, HTTP statuses, telemetry, and trusted proxies.
  """

  use PumbleAutomationWeb.ConnCase, async: false
  use Oban.Testing, repo: PumbleAutomation.Repo

  import Phoenix.LiveViewTest
  import PumbleAutomation.DataCase, only: [errors_on: 1]
  import PumbleAutomation.IngressFixtures
  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Connections.SafeHttp
  alias PumbleAutomation.Connections.UrlPolicy
  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Concurrency
  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.History
  alias PumbleAutomation.Executions.Nodes.Approval
  alias PumbleAutomation.Executions.Nodes.Delay
  alias PumbleAutomation.Executions.Outcome
  alias PumbleAutomation.Executions.RetryPolicy
  alias PumbleAutomation.Executions.Workers.AdvanceExecutionWorker
  alias PumbleAutomation.Ingress.RateLimiter
  alias PumbleAutomation.Ingress.WebhookEndpoint
  alias PumbleAutomation.Ingress.WebhookService
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Limits
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.CompiledWorkflow
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Definition.Trigger
  alias PumbleAutomation.Workflows.Limits, as: StructuralLimits
  alias PumbleAutomation.Workflows.Node.ApprovalConfig
  alias PumbleAutomation.Workflows.Node.DelayConfig
  alias PumbleAutomation.Workflows.ScheduleCalculator
  alias PumbleAutomation.Workflows.Templates
  alias PumbleAutomationWeb.BrowserSession
  alias PumbleAutomationWeb.Plugs.CacheRawBody
  alias PumbleAutomationWeb.Plugs.TrustedProxies

  setup do
    previous_limits = Application.get_env(:pumble_automation, :limits)
    previous_proxies = Application.get_env(:pumble_automation, :trusted_proxies)
    RateLimiter.reset()
    WebhookService.reset_rate_table()

    on_exit(fn ->
      Application.put_env(:pumble_automation, :limits, previous_limits)
      Application.put_env(:pumble_automation, :trusted_proxies, previous_proxies)
      _ = Supervisor.restart_child(PumbleAutomation.Supervisor, RateLimiter)
      RateLimiter.reset()
    end)

    :ok
  end

  describe "catalog" do
    test "Section 31 defaults and hard caps are the documented numbers" do
      assert Limits.default(:workflow_nodes) == 50
      assert Limits.default(:branch_depth) == 8
      assert Limits.default(:definition_size_bytes) == 256 * 1024
      assert Limits.default(:active_workflows) == 25
      assert Limits.default(:total_workflows) == 100
      assert Limits.default(:schedules_per_workspace) == 100
      assert Limits.default(:running_executions) == 5
      assert Limits.default(:queued_executions) == 1_000
      assert Limits.default(:context_size_bytes) == 256 * 1024
      assert Limits.default(:template_source_bytes) == 16 * 1024
      assert Limits.default(:template_expansion_bytes) == 64 * 1024
      assert Limits.default(:pumble_callback_body_bytes) == 1_048_576
      assert Limits.default(:generic_webhook_body_bytes) == 512 * 1024
      assert Limits.default(:http_request_body_bytes) == 256 * 1024
      assert Limits.default(:http_response_body_bytes) == 1_048_576
      assert Limits.default(:redirects) == 3
      assert Limits.default(:retries) == 5
      assert Limits.default(:delay_seconds) == 365 * 24 * 60 * 60
      assert Limits.default(:execution_lifetime_seconds) == 30 * 24 * 60 * 60
      assert Limits.default(:lineage_depth) == 3
      assert Limits.default(:lineage_descendants) == 8

      assert Limits.hard_cap(:redirects) == 3
      assert Limits.hard_cap(:retries) == 5
      assert Limits.hard_cap(:delay_seconds) == Limits.default(:delay_seconds)

      assert Limits.hard_cap(:execution_lifetime_seconds) ==
               Limits.default(:execution_lifetime_seconds)

      assert Limits.hard_cap(:lineage_depth) == 3
      assert Limits.hard_cap(:lineage_descendants) == 32
    end

    test "runtime overrides are clamped to the hard cap" do
      put_limits(%{workflow_nodes: 10_000, redirects: 99})

      assert Limits.get(:workflow_nodes) == Limits.hard_cap(:workflow_nodes)
      assert Limits.get(:redirects) == 3
    end

    test "owners read the catalog at the current process env" do
      put_limits(%{
        workflow_nodes: 7,
        running_executions: 2,
        retries: 2,
        delay_seconds: 12,
        pumble_callback_body_bytes: 2048,
        generic_webhook_body_bytes: 1024,
        history_page_size: 4,
        history_page_max: 6
      })

      assert StructuralLimits.max_nodes() == 7
      assert Concurrency.max_running() == 2
      assert RetryPolicy.max_attempts() == 2
      assert DelayConfig.max_seconds() == 12
      assert ApprovalConfig.max_seconds() == 12
      assert ScheduleCalculator.max_horizon_seconds() == 12
      assert CacheRawBody.max_body_bytes() == 2048
      assert WebhookService.max_body_bytes() == 1024
      assert History.page_size() == 4
    end
  end

  describe "structural and template boundaries" do
    test "node, depth, definition, and template owners accept the limit and refuse limit+1" do
      put_limits(%{
        workflow_nodes: 2,
        branch_depth: 1,
        definition_size_bytes: 64,
        template_source_bytes: 4,
        template_expansion_bytes: 8
      })

      assert :ok = StructuralLimits.check_nodes(2)
      assert {:error, %Error{code: :too_many_nodes}} = StructuralLimits.check_nodes(3)

      assert :ok = StructuralLimits.check_depth(1)
      assert {:error, %Error{code: :branch_too_deep}} = StructuralLimits.check_depth(2)

      assert :ok = StructuralLimits.check_size(%{"ok" => true})

      assert {:error, %Error{code: :definition_too_large}} =
               StructuralLimits.check_size(%{"pad" => String.duplicate("x", 80)})

      assert {:ok, _} = Templates.render("abcd", %{})
      assert {:error, %Error{code: :template_too_large}} = Templates.render("abcde", %{})

      put_limits(%{template_source_bytes: 16_384, template_expansion_bytes: 8})

      template = %{"template" => [%{"path" => %{"root" => "trigger", "path" => ["x"]}}]}

      assert {:ok, _} = Templates.render(template, %{"trigger" => %{"x" => "12345678"}})

      assert {:error, %Error{code: :template_expansion_too_large}} =
               Templates.render(template, %{"trigger" => %{"x" => "123456789"}})
    end
  end

  describe "delay, approval, retry, HTTP, context, and lineage owners" do
    test "delay and approval accept the catalog ceiling and refuse one extra second" do
      put_limits(%{delay_seconds: 10})

      assert {:ok, allowed} = Delay.run(delay_input(10))
      assert allowed.kind == :wait_delay

      assert {:ok, overflow} = Delay.run(delay_input(11))
      assert overflow.kind == :permanent_error

      assert {:ok, approval_ok} = Approval.run(approval_input(10))
      assert approval_ok.kind == :wait_approval

      assert {:ok, approval_over} = Approval.run(approval_input(11))
      assert approval_over.kind == :permanent_error
    end

    test "retry policy exhausts at the catalog attempt limit" do
      put_limits(%{retries: 2})

      assert RetryPolicy.decide(%{error_class: "transient_transport", attempt_number: 1}) ==
               :retry

      assert RetryPolicy.decide(%{error_class: "transient_transport", attempt_number: 2}) == :fail
    end

    test "HTTP request bodies at the cap are prepared and one extra byte is refused" do
      put_limits(%{http_request_body_bytes: 16, http_response_body_bytes: 32, redirects: 2})

      assert SafeHttp.max_request_bytes() == 16
      assert SafeHttp.max_body_bytes() == 32
      assert SafeHttp.max_redirects() == 2

      target = %UrlPolicy{
        scheme: "http",
        hostname: "example.test",
        port: 80,
        addresses: [{1, 1, 1, 1}],
        expires_at: DateTime.add(DateTime.utc_now(), 10_000, :millisecond)
      }

      connect = fn _scheme, _address, _port, _hostname, _opts -> {:error, :econnrefused} end
      at_limit = String.duplicate("a", 16)
      over = at_limit <> "x"

      assert {:error, %Error{code: code}} =
               SafeHttp.request(target, %{method: :post, path: "/", body: at_limit},
                 connect: connect
               )

      refute code == :request_too_large

      assert {:error, %Error{code: :request_too_large}} =
               SafeHttp.request(target, %{method: :post, path: "/", body: over}, connect: connect)
    end

    test "context and lineage accept the limit and refuse limit+1", %{conn: _conn} do
      put_limits(%{context_size_bytes: 64, lineage_depth: 1})
      %{version: version} = version_fixture()

      at =
        Execution.changeset(%Execution{}, %{
          installation_id: version.installation_id,
          workflow_id: version.workflow_id,
          workflow_version_id: version.id,
          execution_key: "ctx-ok",
          status: "queued",
          context: %{"a" => "1"}
        })

      refute errors_on(at)[:context]

      over =
        Execution.changeset(%Execution{}, %{
          installation_id: version.installation_id,
          workflow_id: version.workflow_id,
          workflow_version_id: version.id,
          execution_key: "ctx-over",
          status: "queued",
          context: %{"blob" => String.duplicate("x", 80)}
        })

      assert %{context: ["is too large"]} = errors_on(over)

      root = Ecto.UUID.generate()

      depth_ok =
        Execution.changeset(%Execution{}, %{
          installation_id: version.installation_id,
          workflow_id: version.workflow_id,
          workflow_version_id: version.id,
          execution_key: "lin-ok",
          status: "queued",
          lineage_depth: 1,
          root_execution_id: root
        })

      refute errors_on(depth_ok)[:lineage_depth]

      depth_over =
        Execution.changeset(%Execution{}, %{
          installation_id: version.installation_id,
          workflow_id: version.workflow_id,
          workflow_version_id: version.id,
          execution_key: "lin-over",
          status: "queued",
          lineage_depth: 2,
          root_execution_id: root
        })

      assert errors_on(depth_over)[:lineage_depth]
    end
  end

  describe "workspace quotas" do
    test "total workflows accept the limit and refuse the next create" do
      put_limits(%{total_workflows: 1})
      %{scope: scope} = install_scope()

      assert {:ok, _} = Workflows.create_workflow(scope, %{name: "One"})

      assert {:error, %Error{code: :total_workflows_limit}} =
               Workflows.create_workflow(scope, %{name: "Two"})
    end

    test "active workflows accept the limit and refuse another activation" do
      put_limits(%{active_workflows: 1})
      %{scope: scope, installation: installation} = install_scope()

      first =
        drafted_workflow(installation.id, %{
          name: "A",
          slug: "a-#{unique()}",
          draft_definition: Definition.encode(definition([delay_node()]))
        })

      second =
        drafted_workflow(installation.id, %{
          name: "B",
          slug: "b-#{unique()}",
          draft_definition: Definition.encode(definition([delay_node()]))
        })

      assert {:ok, activated} = Workflows.activate_workflow(scope, first.id, 0)

      assert {:error, %Error{code: :active_workflows_limit}} =
               Workflows.activate_workflow(scope, second.id, 0)

      assert {:ok, _} =
               Workflows.reactivate_workflow(scope, first.id, activated.version.version_number)
    end

    test "schedules accept the limit and refuse another clock" do
      put_limits(%{schedules_per_workspace: 1})
      %{scope: scope, installation: installation} = install_scope()
      first = drafted_schedule(installation.id, "s1")
      second = drafted_schedule(installation.id, "s2")

      assert {:ok, _} = Workflows.activate_workflow(scope, first.id, 0)

      assert {:error, %Error{code: :schedules_limit}} =
               Workflows.activate_workflow(scope, second.id, 0)
    end

    test "queued executions accept the limit and refuse the next distinct create" do
      put_limits(%{queued_executions: 1})
      %{scope: scope, version: version} = activated()

      assert {:ok, first} =
               Engine.create(scope, %{
                 workflow_version_id: version.id,
                 execution_key: "q-#{unique()}"
               })

      assert {:error, %Error{code: :queued_executions_limit, retryable?: true}} =
               Engine.create(scope, %{
                 workflow_version_id: version.id,
                 execution_key: "q-#{unique()}"
               })

      assert {:ok, again} =
               Engine.create(scope, %{
                 workflow_version_id: version.id,
                 execution_key: first.execution_key
               })

      assert again.id == first.id
    end
  end

  describe "history pages" do
    test "list_index clamps the requested page to the catalog max" do
      put_limits(%{history_page_size: 1, history_page_max: 2})
      %{scope: scope, version: version} = activated()

      for _index <- 1..3 do
        {:ok, _} =
          Engine.create(scope, %{
            workflow_version_id: version.id,
            execution_key: "h-#{unique()}"
          })
      end

      assert {:ok, %{entries: entries, next_cursor: cursor}} =
               History.list_index(scope, limit: 50)

      assert length(entries) == 2
      assert is_binary(cursor)
    end
  end

  describe "context growth across steps" do
    test "a later step that would overflow context fails the run as resource_limit" do
      put_limits(%{context_size_bytes: 180})
      context = install_scope()
      true_stop = stop_node()
      condition = condition_node(if_true: [true_stop], if_false: [delay_node()])
      %{snapshot: snapshot} = claimed!(context, [condition])

      {:ok, small} = Outcome.new(%{kind: :success, edge: "true", output: %{"n" => 1}})
      assert {:ok, continued} = Engine.finalize(snapshot, small)
      assert continued.status == "running"

      {:ok, next} = Engine.claim(job_args(continued))
      blob = String.duplicate("x", 200)
      {:ok, huge} = Outcome.new(%{kind: :success, edge: "next", output: %{"blob" => blob}})
      assert {:ok, failed} = Engine.finalize(next, huge)
      assert failed.status == "failed"
    end
  end

  describe "execution lifetime" do
    test "a delay that would resume after the deadline fails without waiting" do
      put_limits(%{execution_lifetime_seconds: 1})
      context = install_scope()
      delay = delay_node()
      %{snapshot: snapshot} = claimed!(context, [delay])

      {:ok, wait} =
        Outcome.new(%{
          kind: :wait_delay,
          resume_at: DateTime.add(DateTime.utc_now(), 60, :second),
          output: %{"wait_seconds" => 60}
        })

      assert {:ok, failed} = Engine.finalize(snapshot, wait)
      assert failed.status == "failed"
    end

    test "an expired claim is finalized before the node runner" do
      put_limits(%{execution_lifetime_seconds: 1})
      context = install_scope()
      %{execution: execution} = queued!(context, [delay_node()])

      execution
      |> Ecto.Changeset.change(%{
        inserted_at: DateTime.add(DateTime.utc_now(), -120, :second)
      })
      |> Repo.update!()

      assert {:ok, %Execution{status: "failed"}} =
               perform_job(AdvanceExecutionWorker, job_args(Repo.get!(Execution, execution.id)))
    end
  end

  describe "rate limits" do
    test "callback failures skip HMAC once the catalog rate is reached" do
      put_limits(%{callback_failures_per_minute: 2})

      unsigned = fn ->
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post(~p"/pumble/callbacks", ~s({"messageType":"SLASH_COMMAND"}))
      end

      first = unsigned.()
      second = unsigned.()
      third = unsigned.()

      assert response(first, 401) == "unauthorized"
      assert response(second, 401) == "unauthorized"
      assert response(third, 429) == "too many requests"
      assert get_resp_header(third, "retry-after") == ["60"]
    end

    test "manual and expensive UI keys refuse at limit+1" do
      put_limits(%{manual_runs_per_minute: 1, expensive_ui_per_minute: 1})
      %{scope: scope} = install_scope()

      assert :ok = RateLimiter.check_manual_run(scope.installation_id)

      assert {:error, %Error{class: :rate_limited}} =
               RateLimiter.check_manual_run(scope.installation_id)

      assert :ok = RateLimiter.check_expensive_ui(scope, :validate)

      assert {:error, %Error{class: :rate_limited}} =
               RateLimiter.check_expensive_ui(scope, :validate)
    end

    test "concurrent webhook and manual checks honour the per-key limit" do
      put_limits(%{manual_runs_per_minute: 5})
      id = Ecto.UUID.generate()
      endpoint_id = Ecto.UUID.generate()

      manual =
        1..20
        |> Task.async_stream(
          fn _index -> RateLimiter.check_manual_run(id) end,
          max_concurrency: 20,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      webhook =
        1..20
        |> Task.async_stream(
          fn _index ->
            RateLimiter.check({:webhook_endpoint, endpoint_id},
              limit: 5,
              source: :webhook_endpoint
            )
          end,
          max_concurrency: 20,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(manual, &(&1 == :ok)) == 5
      assert Enum.count(webhook, &(&1 == :ok)) == 5
    end

    test "restarting the limiter empties counts and fails closed while it is down" do
      assert :ok = RateLimiter.check({:manual_run, "restart"}, limit: 1)

      assert :ok = Supervisor.terminate_child(PumbleAutomation.Supervisor, RateLimiter)

      assert {:error, %Error{class: :rate_limited}} =
               RateLimiter.check({:manual_run, "restart"}, limit: 100)

      assert {:ok, _pid} = Supervisor.restart_child(PumbleAutomation.Supervisor, RateLimiter)
      assert :ok = RateLimiter.check({:manual_run, "restart"}, limit: 1)
    end

    test "on-demand validate is rate-limited and phx-change is not", %{conn: conn} do
      put_limits(%{expensive_ui_per_minute: 1})

      %{session_token: token, installation: installation} =
        InstallationsFixtures.install(role: "editor")

      workflow =
        drafted_workflow(installation.id, %{
          draft_definition: Definition.encode(definition([delay_node()]))
        })

      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}")

      view |> element("#workflow-validation-run") |> render_click()
      html = view |> element("#workflow-validation-run") |> render_click()
      assert html =~ "The rate limit was reached."
    end
  end

  describe "inbound HTTP statuses" do
    test "an over-limit webhook body is 413 and a queued quota is 422", %{conn: conn} do
      %{scope: scope, installation: installation} = install_scope()
      %{version: version} = activate_webhook!(scope, installation.id)
      token = WebhookEndpoint.generate_token()
      endpoint = webhook_endpoint(version, %{token: token})

      too_big = json_of_size(WebhookService.max_body_bytes() + 1)

      assert_raise Plug.Parsers.RequestTooLargeError, fn ->
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header(
          "authorization",
          "Bearer " <> Base.url_encode64(token, padding: false)
        )
        |> Phoenix.ConnTest.post(~p"/hooks/#{endpoint.public_id}", too_big)
      end

      put_limits(%{queued_executions: 1})
      first = post_webhook(conn, endpoint.public_id, token, %{"n" => 1})
      assert json_response(first, 202)

      second = post_webhook(Phoenix.ConnTest.build_conn(), endpoint.public_id, token, %{"n" => 2})
      assert json_response(second, 422)["error"] == "queued_executions_limit"
    end
  end

  describe "trusted proxies and telemetry" do
    test "X-Forwarded-For is ignored when no proxies are configured" do
      Application.put_env(:pumble_automation, :trusted_proxies, [])

      conn =
        Phoenix.ConnTest.build_conn()
        |> Map.put(:remote_ip, {8, 8, 8, 8})
        |> Plug.Conn.put_req_header("x-forwarded-for", "9.9.9.9")
        |> TrustedProxies.call([])

      assert conn.remote_ip == {8, 8, 8, 8}
    end

    test "a trusted proxy may rewrite the peer from X-Forwarded-For" do
      Application.put_env(:pumble_automation, :trusted_proxies, [{{10, 0, 0, 1}, 32}])

      conn =
        Phoenix.ConnTest.build_conn()
        |> Map.put(:remote_ip, {10, 0, 0, 1})
        |> Plug.Conn.put_req_header("x-forwarded-for", "203.0.113.9")
        |> TrustedProxies.call([])

      assert conn.remote_ip == {203, 0, 113, 9}
    end

    test "limit-hit telemetry names the source and never a payload" do
      handler = "limits-#{System.unique_integer([:positive])}"
      test = self()

      :ok =
        :telemetry.attach(
          handler,
          Limits.telemetry_event(),
          fn _event, _measurements, metadata, _config ->
            send(test, {:hit, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      Limits.record_hit(:queued_executions, Ecto.UUID.generate())
      assert_receive {:hit, metadata}
      assert metadata.source == "queued_executions"
      assert is_binary(metadata.installation_id)
      refute Map.has_key?(metadata, :payload)
      refute Map.has_key?(metadata, :body)
      refute Map.has_key?(metadata, :ip)
      refute is_map_key(metadata, "payload")
    end
  end

  defp put_limits(overrides) when is_map(overrides) do
    current = Application.get_env(:pumble_automation, :limits, %{})
    Application.put_env(:pumble_automation, :limits, Map.merge(current, overrides))
  end

  defp install_scope do
    %{installation: installation, member: member} = InstallationsFixtures.install()
    %{scope: Scope.new(member), installation: installation, installation_id: installation.id}
  end

  defp activated(nodes \\ [delay_node()]) do
    context = install_scope()

    %{version: version, workflow: workflow} =
      activate!(context.scope, context.installation_id, definition(nodes))

    Map.merge(context, %{version: version, workflow: workflow})
  end

  defp version_fixture do
    %{installation: installation} = InstallationsFixtures.install()
    workflow = drafted_workflow(installation.id)
    %{version: PumbleAutomation.WorkflowsFixtures.version(workflow), workflow: workflow}
  end

  defp activate!(scope, installation_id, definition) do
    workflow =
      drafted_workflow(installation_id, %{
        name: "Limit #{unique()}",
        slug: "limit-#{unique()}",
        draft_definition: Definition.encode(definition)
      })

    {:ok, result} = Workflows.activate_workflow(scope, workflow.id, 0)
    %{version: result.version, workflow: result.workflow}
  end

  defp activate_webhook!(scope, installation_id) do
    workflow =
      drafted_workflow(installation_id, %{
        name: "Hook #{unique()}",
        slug: "hook-#{unique()}",
        draft_definition:
          Definition.encode(Definition.new(Trigger.new(:webhook, %{}), [delay_node()]))
      })

    {:ok, result} = Workflows.activate_workflow(scope, workflow.id, 0)
    result
  end

  defp drafted_schedule(installation_id, prefix) do
    drafted_workflow(installation_id, %{
      name: prefix,
      slug: "#{prefix}-#{unique()}",
      draft_definition:
        Definition.encode(
          Definition.new(
            Trigger.new(:schedule, %{
              schedule_type: :daily,
              time_of_day: "09:00",
              timezone: "Etc/UTC"
            }),
            [delay_node()]
          )
        )
    })
  end

  defp claimed!(context, nodes) do
    started = queued!(context, nodes)
    {:ok, snapshot} = Engine.claim(job_args(started.execution))
    Map.put(started, :snapshot, snapshot)
  end

  defp queued!(context, nodes) do
    %{version: version} = activate!(context.scope, context.installation_id, definition(nodes))

    {:ok, execution} =
      Engine.create(context.scope, %{
        workflow_version_id: version.id,
        execution_key: "lim-#{unique()}"
      })

    %{execution: Repo.get!(Execution, execution.id), version: version}
  end

  defp job_args(%Execution{} = execution) do
    %{
      "installation_id" => execution.installation_id,
      "execution_id" => execution.id,
      "expected_node_id" => execution.current_node_id,
      "generation" => execution.lock_version
    }
  end

  defp delay_input(seconds) do
    %{
      compiled_node: %{
        type: :delay,
        config: %{"duration_seconds" => seconds},
        edges: %{"next" => CompiledWorkflow.end_target()},
        requires: %{
          "operations" => [],
          "scopes" => [],
          "connection_ids" => [],
          "secret_names" => []
        }
      },
      context: %{},
      trigger_snapshot: %{},
      installation_id: Ecto.UUID.generate(),
      run_mode: "live",
      effect_key: "inst/exec/node",
      attempt: %{id: Ecto.UUID.generate(), number: 1},
      resolver: PumbleAutomation.Connections.Resolver,
      adapters: %{}
    }
  end

  defp approval_input(seconds) do
    %{
      compiled_node: %{
        type: :approval,
        config: %{
          "timeout_seconds" => seconds,
          "approver_member_ids" => ["member-1"],
          "prompt" => "Approve?"
        },
        edges: %{},
        requires: %{
          "operations" => [],
          "scopes" => [],
          "connection_ids" => [],
          "secret_names" => []
        }
      },
      context: %{},
      trigger_snapshot: %{}
    }
  end

  defp post_webhook(conn, public_id, token, body) do
    conn
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header(
      "authorization",
      "Bearer " <> Base.url_encode64(token, padding: false)
    )
    |> Phoenix.ConnTest.post(~p"/hooks/#{public_id}", Jason.encode!(body))
  end

  defp json_of_size(bytes) do
    envelope = ~s({"pad":""})
    padding = bytes - byte_size(envelope)
    ~s({"pad":"#{String.duplicate("x", padding)}"})
  end

  defp log_in(conn, token) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Test.put_req_cookie(BrowserSession.cookie(), token)
  end

  defp unique, do: System.unique_integer([:positive])
end

defmodule PumbleAutomation.Security.LimitsConcurrencyTest do
  @moduledoc """
  Workflow and schedule quota races against a real database. See
  `WorkflowVersionConcurrencyTest` for why `:auto` is required.
  """

  use ExUnit.Case, async: false

  import PumbleAutomation.WorkflowsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias PumbleAutomation.Error
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Definition.Trigger

  setup do
    Sandbox.mode(Repo, :auto)
    previous = Application.get_env(:pumble_automation, :limits)

    on_exit(fn ->
      Application.put_env(:pumble_automation, :limits, previous)
      Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  test "concurrent workflow creates honour the total quota" do
    current = Application.get_env(:pumble_automation, :limits, %{})
    Application.put_env(:pumble_automation, :limits, Map.put(current, :total_workflows, 1))

    %{installation: installation, member: member} = InstallationsFixtures.install()
    on_exit(fn -> InstallationsFixtures.erase!(installation.id) end)
    scope = Scope.new(member)

    results =
      1..2
      |> Task.async_stream(
        fn index ->
          Workflows.create_workflow(scope, %{
            name: "Race #{index}-#{System.unique_integer([:positive])}"
          })
        end,
        max_concurrency: 2,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    oks = for {:ok, workflow} <- results, do: workflow
    errors = for {:error, %Error{code: :total_workflows_limit}} <- results, do: :limit

    assert length(oks) == 1
    assert length(errors) == 1
  end

  test "concurrent schedule activations honour the schedule quota" do
    current = Application.get_env(:pumble_automation, :limits, %{})

    Application.put_env(
      :pumble_automation,
      :limits,
      Map.put(current, :schedules_per_workspace, 1)
    )

    %{installation: installation, member: member} = InstallationsFixtures.install()
    on_exit(fn -> InstallationsFixtures.erase!(installation.id) end)
    scope = Scope.new(member)

    workflows =
      for prefix <- ["a", "b"] do
        drafted_workflow(installation.id, %{
          name: prefix,
          slug: "#{prefix}-#{System.unique_integer([:positive])}",
          draft_definition:
            Definition.encode(
              Definition.new(
                Trigger.new(:schedule, %{
                  schedule_type: :daily,
                  time_of_day: "09:00",
                  timezone: "Etc/UTC"
                }),
                [delay_node()]
              )
            )
        })
      end

    results =
      workflows
      |> Task.async_stream(
        fn workflow -> Workflows.activate_workflow(scope, workflow.id, 0) end,
        max_concurrency: 2,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    oks = for {:ok, result} <- results, do: result
    errors = for {:error, %Error{code: :schedules_limit}} <- results, do: :limit

    assert length(oks) == 1
    assert length(errors) == 1
  end
end
