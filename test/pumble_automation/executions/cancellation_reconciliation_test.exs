defmodule PumbleAutomation.Executions.CancellationReconciliationTest do
  @moduledoc """
  Operator cancel, per-workspace occupancy, fair wake-up, and bounded
  reconciliation of recoverable gaps.
  """

  use PumbleAutomation.DataCase, async: true
  use Oban.Testing, repo: PumbleAutomation.Repo

  import PumbleAutomation.ExecutionsFixtures
  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Audit.AuditEvent
  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Approval
  alias PumbleAutomation.Executions.Concurrency
  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.Outcome
  alias PumbleAutomation.Executions.StepAttempt
  alias PumbleAutomation.Executions.StepExecution
  alias PumbleAutomation.Executions.Workers.AdvanceExecutionWorker
  alias PumbleAutomation.Executions.Workers.ApprovalDeliveryWorker
  alias PumbleAutomation.Executions.Workers.ApprovalTimeoutWorker
  alias PumbleAutomation.Executions.Workers.ReconciliationWorker
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition

  setup do
    %{installation: installation, member: member} = InstallationsFixtures.install()
    scope = Scope.new(member)

    %{
      scope: scope,
      installation: installation,
      installation_id: installation.id,
      member: member
    }
  end

  describe "cancel pending" do
    test "queued executions stop immediately and claim is a no-op", context do
      %{execution: execution} = queued!(context, [delay_node()])

      assert {:ok, cancelled} =
               Engine.cancel(context.scope, execution.id, %{reason: "operator stop"})

      assert cancelled.status == "cancelled"
      assert cancelled.cancelled_at
      assert cancelled.cancelled_by_member_id == context.member.id
      assert cancelled.cancellation_reason == "operator stop"
      assert Repo.get!(StepExecution, hd(steps(execution.id)).id).status == "cancelled"

      assert {:ok, :noop} = Engine.claim(job_args(execution))
      assert audited?(context, execution.id, "queued", "cancelled")
    end

    test "a viewer cannot cancel; another workspace is not found", context do
      %{execution: execution} = queued!(context, [stop_node()])
      viewer = %Scope{context.scope | role: "viewer"}
      %{member: other} = InstallationsFixtures.install()

      assert {:error, %Error{class: :permission, code: :capability_denied}} =
               Engine.cancel(viewer, execution.id)

      assert {:error, %Error{class: :not_found, code: :resource_not_found}} =
               Engine.cancel(Scope.new(other), execution.id)

      assert Repo.get!(Execution, execution.id).status == "queued"
    end

    test "duplicate cancel is idempotent and completed runs refuse", context do
      %{execution: execution} = queued!(context, [stop_node()])
      assert {:ok, first} = Engine.cancel(context.scope, execution.id)
      assert {:ok, second} = Engine.cancel(context.scope, execution.id)
      assert second.status == "cancelled"
      assert second.lock_version == first.lock_version

      %{execution: done} = queued!(context, [stop_node()])
      {:ok, snapshot} = Engine.claim(job_args(done))
      {:ok, outcome} = Outcome.new(%{kind: :success, edge: "next", output: %{}})
      assert {:ok, completed} = Engine.finalize(snapshot, outcome)
      assert completed.status == "completed"

      assert {:error, %Error{class: :conflict, code: :illegal_transition}} =
               Engine.cancel(context.scope, completed.id)
    end
  end

  describe "cancel running" do
    test "records the request and finalize does not start the next step", context do
      next = stop_node()
      %{snapshot: snapshot, execution: execution} = claimed!(context, [message_node(), next])

      assert {:ok, requested} = Engine.cancel(context.scope, execution.id, %{reason: "halt"})
      assert requested.status == "running"
      assert requested.cancelled_at

      {:ok, outcome} = Outcome.new(%{kind: :success, edge: "next", output: %{"posted" => true}})
      assert {:ok, halted} = Engine.finalize(snapshot, outcome)
      assert halted.status == "cancelled"
      assert halted.current_node_id == snapshot.node_id
      assert halted.context["steps"][snapshot.node_id]["output"]["posted"] == true

      attempt = Repo.get!(StepAttempt, snapshot.attempt_id)
      assert attempt.status == "succeeded"

      refute_enqueued(
        worker: AdvanceExecutionWorker,
        args: %{execution_id: execution.id, expected_node_id: next.id}
      )
    end
  end

  describe "cancel waiting and approval" do
    test "waiting_delay stops immediately", context do
      %{snapshot: snapshot, execution: execution} = claimed!(context, [delay_node()])
      resume_at = DateTime.add(DateTime.utc_now(), 60, :second)

      {:ok, outcome} =
        Outcome.new(%{kind: :wait_delay, edge: "next", resume_at: resume_at, output: %{}})

      assert {:ok, waiting} = Engine.finalize(snapshot, outcome)
      assert waiting.status == "waiting_delay"

      assert {:ok, cancelled} = Engine.cancel(context.scope, execution.id)
      assert cancelled.status == "cancelled"
      assert Repo.get!(StepExecution, snapshot.step_execution_id).status == "cancelled"
    end

    test "waiting_approval cancels the pending approval row", context do
      %{snapshot: snapshot, execution: execution} =
        claimed!(context, [approval_node(approved: [stop_node()])])

      {:ok, outcome} = Outcome.new(%{kind: :wait_approval, edge: "approved", output: %{}})
      assert {:ok, waiting} = Engine.finalize(snapshot, outcome)
      assert waiting.status == "waiting_approval"

      step = Repo.get!(StepExecution, snapshot.step_execution_id)
      pending = approval(step)

      assert {:ok, cancelled} = Engine.cancel(context.scope, execution.id)
      assert cancelled.status == "cancelled"
      assert Repo.get!(Approval, pending.id).status == "cancelled"
    end
  end

  describe "cancel-all" do
    test "an owner cancels every in-flight run; an editor is refused", context do
      one = queued!(context, [delay_node()]).execution
      two = queued!(context, [stop_node()]).execution
      editor = %Scope{context.scope | role: "editor"}

      assert {:error, %Error{class: :permission, code: :capability_denied}} =
               Engine.cancel_all(editor, %{})

      assert {:ok, %{count: 2}} = Engine.cancel_all(context.scope, %{reason: "drain"})
      assert Repo.get!(Execution, one.id).status == "cancelled"
      assert Repo.get!(Execution, two.id).status == "cancelled"

      [event] =
        Repo.all(
          from e in AuditEvent,
            where:
              e.installation_id == ^context.installation_id and
                e.action == "execution.cancelled" and
                fragment("(? ->> 'count')::int = 2", e.metadata)
        )

      assert event.metadata["count"] == 2
    end
  end

  describe "concurrency limits" do
    test "excess creates stay queued without a job and the oldest wakes first", context do
      %{version: version} =
        activate!(context.scope, context.installation_id, definition([stop_node()]))

      admitted =
        Enum.map(1..Concurrency.max_running(), fn _index ->
          create!(context.scope, version)
        end)

      first_parked = create!(context.scope, version)
      second_parked = create!(context.scope, version)

      Enum.each(
        admitted,
        &assert_enqueued(worker: AdvanceExecutionWorker, args: %{execution_id: &1.id})
      )

      refute_enqueued(worker: AdvanceExecutionWorker, args: %{execution_id: first_parked.id})
      refute_enqueued(worker: AdvanceExecutionWorker, args: %{execution_id: second_parked.id})

      oldest = hd(admitted)
      assert {:ok, _} = Engine.cancel(context.scope, oldest.id)

      assert_enqueued(worker: AdvanceExecutionWorker, args: %{execution_id: first_parked.id})
      refute_enqueued(worker: AdvanceExecutionWorker, args: %{execution_id: second_parked.id})
    end
  end

  describe "missing-job repair" do
    test "a runnable queued execution without a job is repaired", context do
      %{execution: execution} = queued!(context, [delay_node()])
      delete_jobs!(execution.id)
      refute_enqueued(worker: AdvanceExecutionWorker, args: %{execution_id: execution.id})

      assert {:ok, %{jobs: 1, count: 1}} =
               Engine.reconcile(%{
                 "installation_id" => context.installation_id,
                 "actor" => context.scope
               })

      assert_enqueued(
        worker: AdvanceExecutionWorker,
        args: %{
          execution_id: execution.id,
          expected_node_id: execution.current_node_id,
          generation: 0
        }
      )

      assert {:ok, %{count: 0, jobs: 0}} =
               Engine.reconcile(%{"installation_id" => context.installation_id})
    end

    test "waiting_approval without a timeout job is restored at expiry", context do
      %{snapshot: snapshot, execution: execution} =
        claimed!(context, [approval_node(approved: [stop_node()])])

      {:ok, outcome} = Outcome.new(%{kind: :wait_approval, output: %{}})
      assert {:ok, waiting} = Engine.finalize(snapshot, outcome)
      expires_at = DateTime.add(DateTime.utc_now(), 120, :second)

      approval(Repo.get!(StepExecution, snapshot.step_execution_id), %{expires_at: expires_at})
      delete_jobs!(execution.id)

      assert {:ok, %{jobs: 2}} =
               Engine.reconcile(%{"installation_id" => context.installation_id})

      assert_enqueued(
        worker: ApprovalTimeoutWorker,
        args: %{
          execution_id: execution.id,
          expected_node_id: execution.current_node_id,
          generation: waiting.lock_version
        }
      )

      assert_enqueued(worker: ApprovalDeliveryWorker, args: %{execution_id: execution.id})
    end
  end

  describe "stale attempt" do
    test "before a possible effect the step is retried", context do
      %{snapshot: snapshot, execution: execution} = claimed!(context, [delay_node()])
      age_attempt!(snapshot.attempt_id)

      assert {:ok, %{jobs: 1}} =
               Engine.reconcile(%{"installation_id" => context.installation_id})

      assert Repo.get!(StepAttempt, snapshot.attempt_id).status == "cancelled"
      assert Repo.get!(Execution, execution.id).status == "running"

      assert_enqueued(
        worker: AdvanceExecutionWorker,
        args: %{
          execution_id: execution.id,
          expected_node_id: execution.current_node_id,
          generation: snapshot.generation
        }
      )
    end

    test "after a possible write the execution pauses as uncertain", context do
      %{snapshot: snapshot, execution: execution} = claimed!(context, [message_node()])
      age_attempt!(snapshot.attempt_id)

      assert {:ok, %{paused: 1}} =
               Engine.reconcile(%{"installation_id" => context.installation_id})

      stored = Repo.get!(Execution, execution.id)
      assert stored.status == "paused_uncertain"
      attempt = Repo.get!(StepAttempt, snapshot.attempt_id)
      assert attempt.status == "uncertain"
      assert attempt.diagnostics["effect_key"] == snapshot.effect_key
      assert attempt.diagnostics["attempt"] == snapshot.attempt_number
      assert attempt.diagnostics["request_summary"] == snapshot.node_type
      assert attempt.diagnostics["dispatch_state"] == "unknown"
      assert attempt.diagnostics["duplicate_risk"]
      refute Map.has_key?(attempt.diagnostics, "dispatched")
      refute Map.has_key?(attempt.diagnostics, "bytes_may_have_left")
      assert is_binary(attempt.diagnostics["guidance"])
      assert Repo.get!(StepExecution, snapshot.step_execution_id).status == "paused_uncertain"
    end
  end

  describe "duplicate reconciliation and uninstall" do
    test "the worker is idempotent and uninstall wins over resume", context do
      %{execution: execution} = queued!(context, [stop_node()])
      delete_jobs!(execution.id)

      assert :ok =
               ReconciliationWorker.perform(%Oban.Job{
                 args: %{"installation_id" => context.installation_id}
               })

      assert_enqueued(worker: AdvanceExecutionWorker, args: %{execution_id: execution.id})

      context.installation
      |> Installation.changeset(%{status: "uninstalled"})
      |> Repo.update!()

      assert {:ok, %{cancelled: 1}} =
               Engine.reconcile(%{"installation_id" => context.installation_id})

      assert Repo.get!(Execution, execution.id).status == "cancelled"
    end
  end

  defp claimed!(context, nodes) do
    started = queued!(context, nodes)
    {:ok, snapshot} = Engine.claim(job_args(started.execution))
    Map.put(started, :snapshot, snapshot)
  end

  defp queued!(context, nodes) do
    %{version: version} = activate!(context.scope, context.installation_id, definition(nodes))
    execution = create!(context.scope, version)
    %{execution: execution, version: version}
  end

  defp activate!(scope, installation_id, definition) do
    workflow =
      drafted_workflow(installation_id, %{draft_definition: Definition.encode(definition)})

    {:ok, result} = Workflows.activate_workflow(scope, workflow.id, 0)
    %{version: result.version, workflow: result.workflow}
  end

  defp create!(scope, version) do
    {:ok, execution} =
      Engine.create(scope, %{
        workflow_version_id: version.id,
        execution_key: "cr-#{System.unique_integer([:positive])}"
      })

    Repo.get!(Execution, execution.id)
  end

  defp job_args(%Execution{} = execution) do
    %{
      "installation_id" => execution.installation_id,
      "execution_id" => execution.id,
      "expected_node_id" => execution.current_node_id,
      "generation" => execution.lock_version
    }
  end

  defp steps(execution_id) do
    Repo.all(from s in StepExecution, where: s.execution_id == ^execution_id)
  end

  defp delete_jobs!(execution_id) do
    Repo.delete_all(
      from j in Oban.Job,
        where: fragment("? ->> 'execution_id' = ?", j.args, ^execution_id)
    )
  end

  defp age_attempt!(attempt_id) do
    cutoff =
      DateTime.add(DateTime.utc_now(), -(Concurrency.stale_after_seconds() + 60), :second)

    Repo.update_all(from(a in StepAttempt, where: a.id == ^attempt_id), set: [started_at: cutoff])
  end

  defp audited?(context, execution_id, from, to) do
    events =
      Repo.all(
        from e in AuditEvent,
          where:
            e.installation_id == ^context.installation_id and
              e.action == "execution.cancelled" and
              e.resource_id == ^execution_id
      )

    assert [%AuditEvent{} = event] = events
    assert event.metadata["previous_state"] == from
    assert event.metadata["next_state"] == to
    true
  end
end

defmodule PumbleAutomation.Executions.ConcurrencyLimitRaceTest do
  @moduledoc """
  Many workers creating at once must not exceed the per-workspace running limit.
  """

  use ExUnit.Case, async: false
  use Oban.Testing, repo: PumbleAutomation.Repo

  import Ecto.Query, only: [from: 2]
  import PumbleAutomation.WorkflowsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias PumbleAutomation.Executions.Concurrency
  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition

  setup do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  test "concurrent creates admit at most the running limit" do
    %{installation: installation, member: member} = InstallationsFixtures.install()
    on_exit(fn -> cleanup!(installation.id) end)

    scope = Scope.new(member)

    workflow =
      drafted_workflow(installation.id, %{
        draft_definition: Definition.encode(definition([delay_node()]))
      })

    {:ok, activated} = Workflows.activate_workflow(scope, workflow.id, 0)
    parent = self()
    workers = Concurrency.max_running() + 4

    tasks =
      Enum.map(1..workers, fn index ->
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go ->
              Engine.create(scope, %{
                workflow_version_id: activated.version.id,
                execution_key: "race-#{index}-#{System.unique_integer([:positive])}"
              })
          end
        end)
      end)

    pids =
      Enum.map(1..workers, fn _index ->
        receive do
          {:ready, pid} -> pid
        after
          5_000 -> flunk("creator did not reach the barrier")
        end
      end)

    Enum.each(pids, &send(&1, :go))
    results = Enum.map(tasks, &Task.await(&1, 30_000))

    assert Enum.all?(results, &match?({:ok, %Execution{}}, &1))

    queued =
      Repo.all(from e in Execution, where: e.installation_id == ^installation.id)

    assert length(queued) == workers

    admitted =
      Enum.count(queued, fn execution ->
        Concurrency.incomplete_job?(Repo, execution.id)
      end)

    assert admitted == Concurrency.max_running()
    assert Concurrency.slots_used(Repo, installation.id) == Concurrency.max_running()
  end

  defp cleanup!(installation_id) do
    Repo.delete_all(
      from j in Oban.Job,
        where: fragment("? ->> 'installation_id' = ?", j.args, ^installation_id)
    )

    InstallationsFixtures.erase!(installation_id)
  end
end
