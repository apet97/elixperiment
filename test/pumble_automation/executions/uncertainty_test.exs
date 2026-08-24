defmodule PumbleAutomation.Executions.UncertaintyTest do
  @moduledoc """
  Ambiguous writes pause until an owner resolves them. Resolution is
  one-time, audited, and does not dispatch after uninstall.
  """

  use PumbleAutomation.DataCase, async: true
  use Oban.Testing, repo: PumbleAutomation.Repo

  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Audit.AuditEvent
  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Concurrency
  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.Outcome
  alias PumbleAutomation.Executions.StepAttempt
  alias PumbleAutomation.Executions.StepExecution
  alias PumbleAutomation.Executions.Workers.AdvanceExecutionWorker
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

  describe "roles" do
    test "only an owner may resolve uncertainty", context do
      %{execution: execution} = paused!(context, [stop_node()])

      editor = %Scope{context.scope | role: "editor"}
      viewer = %Scope{context.scope | role: "viewer"}

      assert {:error, %Error{class: :permission, code: :capability_denied}} =
               Engine.resolve_uncertain(editor, execution.id, :failed)

      assert {:error, %Error{class: :permission, code: :capability_denied}} =
               Engine.resolve_uncertain(viewer, execution.id, :failed)

      assert {:ok, failed} = Engine.resolve_uncertain(context.scope, execution.id, :failed)
      assert failed.status == "failed"
    end

    test "another workspace's execution is not found", context do
      %{execution: execution} = paused!(context, [stop_node()])
      %{member: other} = InstallationsFixtures.install()

      assert {:error, %Error{class: :not_found, code: :resource_not_found}} =
               Engine.resolve_uncertain(Scope.new(other), execution.id, :failed)
    end
  end

  describe "mark-success continuation" do
    test "marks the effect succeeded and continues at the next compiled node", context do
      next = stop_node()
      %{snapshot: snapshot, execution: execution} = paused!(context, [message_node(), next])

      assert {:ok, continued} =
               Engine.resolve_uncertain(context.scope, execution.id, :succeeded, %{
                 evidence: %{"result" => "posted"}
               })

      assert continued.status == "running"
      assert continued.current_node_id == next.id
      assert continued.context["steps"][snapshot.node_id]["output"]["result"] == "posted"

      step = Repo.get!(StepExecution, snapshot.step_execution_id)
      assert step.status == "completed"
      assert step.selected_edge == "next"
      assert Repo.get!(StepAttempt, snapshot.attempt_id).status == "uncertain"

      next_step =
        Repo.one!(
          from s in StepExecution,
            where: s.execution_id == ^execution.id and s.node_id == ^next.id
        )

      assert next_step.status == "queued"

      assert_enqueued(
        worker: AdvanceExecutionWorker,
        args: %{
          execution_id: execution.id,
          expected_node_id: next.id,
          generation: continued.lock_version
        }
      )
    end
  end

  describe "stop" do
    test "mark failed terminates the execution and inserts no job", context do
      %{snapshot: snapshot, execution: execution} = paused!(context, [stop_node()])

      assert {:ok, failed} = Engine.resolve_uncertain(context.scope, execution.id, "failed")
      assert failed.status == "failed"
      assert Repo.get!(StepExecution, snapshot.step_execution_id).status == "failed"
      assert Repo.get!(StepAttempt, snapshot.attempt_id).status == "uncertain"

      refute_enqueued(
        worker: AdvanceExecutionWorker,
        args: %{execution_id: execution.id, generation: failed.lock_version}
      )

      assert {:ok, again} = Engine.resolve_uncertain(context.scope, execution.id, :failed)
      assert again.status == "failed"
      assert again.lock_version == failed.lock_version
    end

    test "a terminal resolve wakes the oldest parked queued row", context do
      occupying =
        Enum.map(1..Concurrency.max_running(), fn _index ->
          paused!(context, [stop_node()]).execution
        end)

      %{execution: parked} = queued!(context, [stop_node()])
      refute_enqueued(worker: AdvanceExecutionWorker, args: %{execution_id: parked.id})

      assert {:ok, failed} = Engine.resolve_uncertain(context.scope, hd(occupying).id, :failed)
      assert failed.status == "failed"
      assert_enqueued(worker: AdvanceExecutionWorker, args: %{execution_id: parked.id})
    end
  end

  describe "deliberate retry" do
    test "retry requires duplicate-risk acknowledgement and opens a new attempt on claim",
         context do
      %{snapshot: snapshot, execution: execution} = paused!(context, [message_node()])

      assert {:error, %Error{code: :duplicate_risk_unacknowledged}} =
               Engine.resolve_uncertain(context.scope, execution.id, :retry)

      assert {:ok, running} =
               Engine.resolve_uncertain(context.scope, execution.id, :retry, %{
                 acknowledge_duplicate_risk: true
               })

      assert running.status == "running"
      assert running.current_node_id == snapshot.node_id
      assert Repo.get!(StepExecution, snapshot.step_execution_id).status == "running"
      assert Repo.get!(StepAttempt, snapshot.attempt_id).status == "uncertain"

      assert_enqueued(
        worker: AdvanceExecutionWorker,
        args: %{
          execution_id: execution.id,
          expected_node_id: snapshot.node_id,
          generation: running.lock_version
        }
      )

      assert {:ok, claimed} = Engine.claim(job_args(running))
      assert claimed.attempt_number == 2
      assert claimed.attempt_id != snapshot.attempt_id
      assert Repo.get!(StepAttempt, snapshot.attempt_id).status == "uncertain"
      assert Repo.aggregate(StepAttempt, :count) == 2
    end
  end

  describe "uninstall during uncertainty" do
    test "retry is refused and failed still terminates", context do
      %{execution: execution} = paused!(context, [message_node()])

      context.installation
      |> Installation.changeset(%{status: "uninstalled"})
      |> Repo.update!()

      assert {:error, %Error{code: :installation_revoked}} =
               Engine.resolve_uncertain(context.scope, execution.id, :retry, %{
                 acknowledge_duplicate_risk: true
               })

      assert Repo.get!(Execution, execution.id).status == "paused_uncertain"

      assert {:ok, failed} = Engine.resolve_uncertain(context.scope, execution.id, :failed)
      assert failed.status == "failed"
    end
  end

  describe "audit redaction" do
    test "resolution is audited without secret evidence", context do
      %{execution: execution} = paused!(context, [stop_node()])

      assert {:ok, completed} =
               Engine.resolve_uncertain(context.scope, execution.id, :succeeded, %{
                 evidence: %{"token" => "super-secret", "result" => "ok"}
               })

      assert completed.status == "completed"
      step = Repo.one!(from s in StepExecution, where: s.execution_id == ^execution.id)
      refute Map.has_key?(step.output, "token")
      assert step.output["result"] == "ok"

      [event] =
        Repo.all(
          from e in AuditEvent,
            where:
              e.installation_id == ^context.installation_id and
                e.action == "execution.resolved_uncertainty"
        )

      assert event.actor_id == context.scope.member_id
      assert event.metadata["outcome"] == "succeeded"
      assert event.metadata["previous_state"] == "paused_uncertain"
      assert event.metadata["next_state"] == "completed"
      assert event.metadata["actor_role"] == "owner"
      refute inspect(event.metadata) =~ "super-secret"
      refute inspect(event) =~ "super-secret"
    end
  end

  defp paused!(context, nodes) do
    started = queued!(context, nodes)
    {:ok, snapshot} = Engine.claim(job_args(started.execution))

    {:ok, outcome} =
      Outcome.new(%{
        kind: :uncertain,
        error_class: "side_effect_uncertain",
        message: "The remote write may have succeeded.",
        remote_reference: "req-1"
      })

    assert {:ok, execution} = Engine.finalize(snapshot, outcome)
    assert execution.status == "paused_uncertain"

    refute_enqueued(
      worker: AdvanceExecutionWorker,
      args: %{execution_id: execution.id, generation: execution.lock_version}
    )

    %{snapshot: snapshot, execution: execution, version: started.version}
  end

  defp queued!(context, nodes) do
    %{version: version} = activate!(context.scope, context.installation_id, definition(nodes))

    {:ok, execution} =
      Engine.create(context.scope, %{
        workflow_version_id: version.id,
        execution_key: "unc-#{System.unique_integer([:positive])}"
      })

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
end

defmodule PumbleAutomation.Executions.UncertaintyConcurrencyTest do
  @moduledoc """
  Two owners resolving one paused execution. The row lock picks one winner.
  """

  use ExUnit.Case, async: false
  use Oban.Testing, repo: PumbleAutomation.Repo

  import Ecto.Query, only: [from: 2]
  import PumbleAutomation.WorkflowsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.Outcome
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

  test "concurrent resolution has one winner" do
    %{installation: installation, member: member} = InstallationsFixtures.install()
    on_exit(fn -> cleanup!(installation.id) end)

    scope = Scope.new(member)
    stop = stop_node()

    workflow =
      drafted_workflow(installation.id, %{
        draft_definition: Definition.encode(definition([stop]))
      })

    {:ok, activated} = Workflows.activate_workflow(scope, workflow.id, 0)

    {:ok, execution} =
      Engine.create(scope, %{
        workflow_version_id: activated.version.id,
        execution_key: "unc-race-#{System.unique_integer([:positive])}"
      })

    args = %{
      "installation_id" => execution.installation_id,
      "execution_id" => execution.id,
      "expected_node_id" => execution.current_node_id,
      "generation" => execution.lock_version
    }

    {:ok, snapshot} = Engine.claim(args)

    {:ok, outcome} =
      Outcome.new(%{
        kind: :uncertain,
        error_class: "ambiguous_transport",
        message: "No definitive response."
      })

    assert {:ok, paused} = Engine.finalize(snapshot, outcome)
    assert paused.status == "paused_uncertain"

    parent = self()

    tasks =
      Enum.map(1..2, fn _index ->
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> Engine.resolve_uncertain(scope, execution.id, :failed)
          end
        end)
      end)

    pids =
      Enum.map(1..2, fn _index ->
        receive do
          {:ready, pid} -> pid
        after
          5_000 -> flunk("resolver did not reach the barrier")
        end
      end)

    Enum.each(pids, &send(&1, :go))
    results = Enum.map(tasks, &Task.await(&1, 30_000))

    oks = for {:ok, resolved} <- results, do: resolved
    assert length(oks) == 2
    assert Enum.all?(oks, &(&1.status == "failed"))

    stored = Repo.get!(Execution, execution.id)
    assert stored.status == "failed"

    versions = oks |> Enum.map(& &1.lock_version) |> Enum.uniq()
    assert length(versions) == 1
  end

  defp cleanup!(installation_id) do
    Repo.delete_all(
      from j in Oban.Job,
        where: fragment("? ->> 'installation_id' = ?", j.args, ^installation_id)
    )

    InstallationsFixtures.erase!(installation_id)
  end
end
