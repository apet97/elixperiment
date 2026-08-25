defmodule PumbleAutomation.Observability.TelemetryTest do
  @moduledoc """
  Domain telemetry events are stable, low-cardinality when adapted into
  metrics, and isolated from handler failure. Durations use documented units.
  """

  use PumbleAutomationWeb.ConnCase, async: false
  use Oban.Testing, repo: PumbleAutomation.Repo

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import PumbleAutomation.InstallationsFixtures
  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Executions.Approval
  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.NodeRunner
  alias PumbleAutomation.Executions.Outcome
  alias PumbleAutomation.Executions.Workers.AdvanceExecutionWorker
  alias PumbleAutomation.Executions.Workers.ApprovalTimeoutWorker
  alias PumbleAutomation.Ingress.AutomationEvent
  alias PumbleAutomation.Ingress.Deduplication
  alias PumbleAutomation.Ingress.TriggerMatcher
  alias PumbleAutomation.Limits
  alias PumbleAutomation.Pumble.Signature
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Telemetry
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Node
  alias PumbleAutomation.Workflows.Workflow

  @secret "test-signing-secret"
  @timestamp "1767225600000"

  setup do
    %{installation: installation, member: member} =
      install(tokens: %{bot_user_id: "bot1"})

    %{
      installation: installation,
      installation_id: installation.id,
      member: member,
      scope: Scope.new(member)
    }
  end

  describe "catalog and documentation" do
    test "every product metric has a source event and is documented" do
      docs = File.read!("docs/operations/metrics.md")
      events = Telemetry.events()

      for row <- Telemetry.section32() do
        assert docs =~ row.name, "#{row.name} missing from docs/operations/metrics.md"
        refute Map.get(row, :deferred)
        assert is_list(Map.fetch!(events, row.event))
        assert is_atom(row.measurement)
      end

      assert docs =~ "Alert candidate"
      assert docs =~ "native time"
      assert docs =~ "duration_ms"
      refute docs =~ "prometheus"
      refute docs =~ "statsd"
    end

    test "metric specs declare duration units and omit identifier tags" do
      metrics = Telemetry.metrics()
      duration_names = [:duration, :duration_ms, :age_ms, :lag_ms]

      for metric <- metrics, List.last(metric.name) in duration_names do
        assert metric.unit in [:millisecond, {:native, :millisecond}],
               inspect(metric.name)
      end

      for metric <- PumbleAutomationWeb.Telemetry.metrics() ++ metrics do
        tags = List.wrap(Map.get(metric, :tags))

        for tag <- tags do
          refute tag in Telemetry.id_keys(), "#{inspect(metric.name)} tags #{tag}"
        end
      end

      assert Enum.any?(PumbleAutomationWeb.Telemetry.metrics(), fn metric ->
               metric.event_name == Telemetry.events().callback_verify
             end)
    end
  end

  describe "metric adapter" do
    test "drops identifiers and secret-looking values from metric tags" do
      tags =
        Telemetry.metric_tags(%{
          operation: "post_message",
          type: "pumble_action",
          status: 503,
          error_class: :remote_transient,
          installation_id: Ecto.UUID.generate(),
          workflow_id: Ecto.UUID.generate(),
          execution_id: Ecto.UUID.generate(),
          step_id: Ecto.UUID.generate(),
          attempt_id: Ecto.UUID.generate(),
          job_id: 99,
          user_id: "U123",
          workspace_id: "workspace-1",
          correlation_id: "corr",
          effect_key: "inst/exec/node",
          token: "bot-access-token",
          body: "private text"
        })

      assert tags.operation == "post_message"
      assert tags.type == "pumble_action"
      assert tags.status_class == "5xx"
      assert tags.error_class == "remote_transient"
      refute Map.has_key?(tags, :status)
      refute Map.has_key?(tags, :installation_id)
      refute Map.has_key?(tags, :execution_id)
      refute Map.has_key?(tags, :workspace_id)
      refute Map.has_key?(tags, :token)
      refute Map.has_key?(tags, :body)
      refute inspect(tags) =~ "bot-access-token"
      refute inspect(tags) =~ "private text"

      assert MapSet.disjoint?(Telemetry.tag_keys(), Telemetry.id_keys())
    end

    test "a raising handler does not fail execute" do
      event = Telemetry.events().limits_hit
      handler = "boom-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler,
          event,
          fn _event, _measurements, _metadata, _config ->
            raise "metric adapter boom"
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      log =
        capture_log(fn ->
          assert :ok = Telemetry.execute(event, %{count: 1}, %{source: "test", token: "secret"})
        end)

      assert log =~ "metric adapter boom"
    end
  end

  describe "event emission" do
    test "callback verification emits ok and unauthorized", _context do
      attach!([Telemetry.events().callback_verify])
      body = ~s({"type":"NEW_MESSAGE"})

      conn =
        build_conn()
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("x-pumble-request-timestamp", @timestamp)
        |> Plug.Conn.put_req_header(
          "x-pumble-request-signature",
          Signature.compute(@secret, @timestamp, body)
        )
        |> post(~p"/pumble/callbacks", body)

      assert conn.status in [200, 400]

      assert_receive {:telemetry, [:pumble_automation, :pumble, :callback, :verify], %{count: 1},
                      %{status: "ok"}}

      bad =
        build_conn()
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("x-pumble-request-timestamp", @timestamp)
        |> Plug.Conn.put_req_header("x-pumble-request-signature", "deadbeef")
        |> post(~p"/pumble/callbacks", body)

      assert bad.status == 401

      assert_receive {:telemetry, [:pumble_automation, :pumble, :callback, :verify], %{count: 1},
                      %{status: "unauthorized"}}
    end

    test "dedup records new then duplicate without high-cardinality keys", %{
      installation_id: installation_id
    } do
      attach!([Telemetry.events().dedup_record])

      request = %{
        installation_id: installation_id,
        class: "event",
        type: "NEW_MESSAGE",
        provider_id: "RID-telemetry",
        raw_body: "body",
        signature: "sig",
        received_at: ~U[2026-01-01 00:00:00.000000Z]
      }

      assert {:ok, :new, _event} = Deduplication.record(request)
      assert {:ok, :duplicate, _again} = Deduplication.record(request)

      assert_receive {:telemetry, [:pumble_automation, :ingress, :dedup, :record], %{count: 1},
                      %{outcome: "new", class: "event"}}

      assert_receive {:telemetry, [:pumble_automation, :ingress, :dedup, :record], %{count: 1},
                      %{outcome: "duplicate", class: "event"}}

      refute_received {:telemetry, [:pumble_automation, :ingress, :dedup, :record], _,
                       %{raw_body: _}}
    end

    test "trigger matching emits a bounded match count", %{installation_id: installation_id} do
      attach!([Telemetry.events().matcher_match])
      live_event_binding!(installation_id)

      matches =
        TriggerMatcher.match(%AutomationEvent{
          installation_id: installation_id,
          type: "NEW_MESSAGE",
          channel_id: "channel-1",
          occurred_at: DateTime.utc_now(),
          occurred_at_source: :received,
          delivery_key: "dk-#{System.unique_integer([:positive])}",
          data: %{text: "hello"}
        })

      assert length(matches) == 1

      assert_receive {:telemetry, [:pumble_automation, :ingress, :matcher, :match], %{count: 1},
                      metadata}

      assert metadata.kind == "pumble_event"
      assert metadata.type == "NEW_MESSAGE"
      refute Map.has_key?(metadata, :binding_id)
    end

    test "finalize emits step duration, transition, retry, and uncertainty", context do
      events = [
        Telemetry.events().step_stop,
        Telemetry.events().transition,
        Telemetry.events().retry,
        Telemetry.events().uncertain,
        Telemetry.events().execution_stop
      ]

      attach!(events)

      %{snapshot: snapshot} = claimed!(context, [stop_node()])

      {:ok, outcome} =
        Outcome.new(%{
          kind: :retryable_error,
          error_class: "transient_transport",
          message: "upstream timeout"
        })

      assert {:ok, retried} = Engine.finalize(snapshot, outcome)
      assert retried.status == "running"

      assert_receive {:telemetry, [:pumble_automation, :executions, :step, :stop], measurements,
                      step_meta}

      assert is_integer(measurements.duration_ms)
      assert measurements.duration_ms >= 0
      assert step_meta.type == "stop"
      assert step_meta.kind == "retryable_error"
      assert step_meta.error_class == "transient_transport"

      assert_receive {:telemetry, [:pumble_automation, :executions, :retry], %{count: 1},
                      %{type: "stop"}}

      {:ok, snapshot2} = Engine.claim(job_args(retried))

      {:ok, uncertain} =
        Outcome.new(%{
          kind: :uncertain,
          error_class: "side_effect_uncertain",
          message: "write may have landed"
        })

      assert {:ok, paused} = Engine.finalize(snapshot2, uncertain)
      assert paused.status == "paused_uncertain"

      assert_receive {:telemetry, [:pumble_automation, :executions, :uncertain], %{count: 1},
                      %{status: "paused_uncertain"}}

      refute_received {:telemetry, [:pumble_automation, :executions, :stop], _, _}
    end

    test "a terminal step records millisecond execution duration", context do
      attach!([Telemetry.events().execution_stop, Telemetry.events().step_stop])
      %{snapshot: snapshot} = claimed!(context, [stop_node()])
      {:ok, outcome} = Outcome.new(%{kind: :success, edge: "next", output: %{}})

      assert {:ok, finalized} = Engine.finalize(snapshot, outcome)
      assert finalized.status == "completed"

      assert_receive {:telemetry, [:pumble_automation, :executions, :stop], measurements,
                      %{status: "completed"}}

      assert is_integer(measurements.duration_ms)
      assert measurements.duration_ms >= 0
    end

    test "approval timeout emits duration with expired type", context do
      attach!([Telemetry.events().approval_stop])
      {waiting, approval, _stop} = waited_with_timeout_branch!(context)
      due_now!(approval)

      assert :ok = perform_job(ApprovalTimeoutWorker, timeout_args(waiting, approval))

      assert_receive {:telemetry, [:pumble_automation, :executions, :approval, :stop],
                      measurements, metadata}

      assert is_integer(measurements.duration_ms)
      assert measurements.duration_ms >= 0
      assert metadata.status == "timed_out"
      assert metadata.type == "expired"
      refute Map.has_key?(metadata, :token_digest)
    end

    test "reconciliation emits a status event", context do
      attach!([Telemetry.events().reconcile])
      %{execution: execution} = queued!(context, [stop_node()])
      delete_jobs!(execution.id)

      assert {:ok, %{jobs: 1}} = Engine.reconcile(%{"installation_id" => context.installation_id})

      assert_receive {:telemetry, [:pumble_automation, :executions, :reconcile], measurements,
                      %{status: "ok", operation: "reconcile"}}

      assert measurements.jobs >= 1
    end

    test "queue snapshot and schedule lag use millisecond age", context do
      attach!([Telemetry.events().queue_snapshot, Telemetry.events().schedule_lag])

      {:ok, _job} =
        %{
          installation_id: context.installation_id,
          execution_id: Ecto.UUID.generate(),
          expected_node_id: Ecto.UUID.generate(),
          generation: 0
        }
        |> AdvanceExecutionWorker.new(
          scheduled_at: DateTime.add(DateTime.utc_now(), -30, :second)
        )
        |> Oban.insert()

      %{version: version} =
        activate!(context.scope, context.installation_id, definition([stop_node()]))

      schedule(version, %{
        next_run_at: DateTime.add(DateTime.utc_now(), -90, :second),
        enabled: true
      })

      assert :ok = Telemetry.dispatch_queue_snapshot()

      queue_ms = receive_queue_snapshot_with_work()
      assert is_integer(queue_ms.depth)
      assert queue_ms.depth >= 1
      assert is_integer(queue_ms.age_ms)
      assert queue_ms.age_ms >= 0

      lag_ms = receive_schedule_lag_with_work()
      assert is_integer(lag_ms.lag_ms)
      assert lag_ms.lag_ms >= 1_000
    end

    test "limit hits keep tenant ids off metric tags" do
      attach!([Telemetry.events().limits_hit])
      installation_id = Ecto.UUID.generate()
      assert :ok = Limits.record_hit(:callback_failures, installation_id)

      assert_receive {:telemetry, [:pumble_automation, :limits, :hit], %{count: 1}, metadata}
      assert metadata.source == "callback_failures"
      assert metadata.installation_id == installation_id

      tags = Telemetry.metric_tags(metadata)
      assert tags.source == "callback_failures"
      refute Map.has_key?(tags, :installation_id)
    end
  end

  defp attach!(events) do
    handler = "telemetry-test-#{System.unique_integer([:positive])}"
    test = self()

    :ok =
      :telemetry.attach_many(
        handler,
        events,
        fn event, measurements, metadata, _config ->
          send(test, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # The telemetry poller can emit an empty snapshot into the mailbox first.
  # Keep the explicit dispatch; ignore empty polls until the fixture's work shows.
  defp receive_queue_snapshot_with_work(deadline \\ System.monotonic_time(:millisecond) + 2_000) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:telemetry, [:pumble_automation, :oban, :queue], measurements, %{queue: "executions"}} ->
        if measurements.depth >= 1 do
          measurements
        else
          receive_queue_snapshot_with_work(deadline)
        end
    after
      timeout -> flunk("expected an executions queue snapshot with depth >= 1")
    end
  end

  defp receive_schedule_lag_with_work(deadline \\ System.monotonic_time(:millisecond) + 2_000) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:telemetry, [:pumble_automation, :schedule, :lag], measurements,
       %{operation: "schedule_lag"}} ->
        if measurements.lag_ms >= 1_000 do
          measurements
        else
          receive_schedule_lag_with_work(deadline)
        end
    after
      timeout -> flunk("expected a schedule lag snapshot of at least 1s")
    end
  end

  defp claimed!(context, nodes, attrs \\ %{}) do
    started = queued!(context, nodes, attrs)
    {:ok, snapshot} = Engine.claim(job_args(started.execution))
    Map.put(started, :snapshot, snapshot)
  end

  defp queued!(context, nodes, attrs \\ %{}) do
    %{version: version} = activate!(context.scope, context.installation_id, definition(nodes))

    {:ok, execution} =
      Engine.create(
        context.scope,
        Map.merge(
          %{
            workflow_version_id: version.id,
            execution_key: "tel-#{System.unique_integer([:positive])}"
          },
          attrs
        )
      )

    %{execution: Repo.get!(Execution, execution.id), version: version}
  end

  defp activate!(scope, installation_id, definition) do
    workflow =
      drafted_workflow(installation_id, %{draft_definition: Definition.encode(definition)})

    {:ok, result} = Workflows.activate_workflow(scope, workflow.id, 0)
    %{version: result.version, workflow: result.workflow}
  end

  defp job_args(%Execution{} = execution) do
    %{
      "installation_id" => execution.installation_id,
      "execution_id" => execution.id,
      "expected_node_id" => execution.current_node_id,
      "generation" => execution.lock_version
    }
  end

  defp live_event_binding!(installation_id) do
    workflow = drafted_workflow(installation_id)
    stored = version(workflow)

    workflow
    |> Workflow.changeset(%{status: "active", active_version_id: stored.id})
    |> Repo.update!()

    trigger_binding(stored, %{
      kind: "pumble_event",
      type: "NEW_MESSAGE",
      channel_id: "channel-1",
      filter_config: %{"keyword" => nil, "ignore_bot_messages" => false}
    })
  end

  defp waited_with_timeout_branch!(context) do
    stop = stop_node()
    approval_node = approval_for(context.member, timed_out: [stop])

    %{snapshot: snapshot} =
      claimed!(context, [approval_node], %{trigger_snapshot: %{"channel_id" => "channel-1"}})

    assert {:ok, outcome} = NodeRunner.run(NodeRunner.input(snapshot))
    assert {:ok, waiting} = Engine.finalize(snapshot, outcome)
    stored = Repo.get_by!(Approval, execution_id: waiting.id)
    {waiting, stored, stop}
  end

  defp approval_for(member, opts) do
    {branches, _opts} = Keyword.split(opts, [:approved, :rejected, :timed_out])

    :approval
    |> Node.new(
      %{
        prompt: "Ship it?",
        approver_member_ids: [member.id],
        timeout_seconds: 3600
      },
      []
    )
    |> Node.put_branch(:approved, [stop_node()])
    |> Node.put_branch(:rejected, [])
    |> Node.put_branch(:timed_out, Keyword.get(branches, :timed_out, []))
  end

  defp due_now!(%Approval{} = approval) do
    approval
    |> Ecto.Changeset.change(%{expires_at: DateTime.add(DateTime.utc_now(), -1, :second)})
    |> Repo.update!()
  end

  defp timeout_args(%Execution{} = execution, %Approval{} = approval) do
    %{
      "installation_id" => execution.installation_id,
      "execution_id" => execution.id,
      "approval_id" => approval.id,
      "expected_node_id" => execution.current_node_id,
      "generation" => execution.lock_version
    }
  end

  defp delete_jobs!(execution_id) do
    Repo.delete_all(
      from job in Oban.Job,
        where: fragment("? ->> 'execution_id' = ?", job.args, ^execution_id)
    )
  end
end
