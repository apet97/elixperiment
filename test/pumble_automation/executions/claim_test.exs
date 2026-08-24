defmodule PumbleAutomation.Executions.ClaimTest do
  @moduledoc """
  One worker attempt owns a runnable step. Duplicates, stale jobs, cancels,
  and uninstalls exit as a no-op without creating a second attempt.
  """

  use PumbleAutomation.DataCase, async: true
  use Oban.Testing, repo: PumbleAutomation.Repo

  import PumbleAutomation.WorkflowsFixtures

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
    %{version: version} = activate!(scope, installation.id)

    {:ok, execution} =
      Engine.create(scope, %{
        workflow_version_id: version.id,
        execution_key: "claim-#{System.unique_integer([:positive])}"
      })

    %{
      scope: scope,
      installation: installation,
      execution: execution,
      job_args: job_args(execution)
    }
  end

  describe "claim/1" do
    test "marks the execution and step running and returns a bounded snapshot", context do
      assert {:ok, snapshot} = Engine.claim(context.job_args)

      assert snapshot.execution_id == context.execution.id
      assert snapshot.installation_id == context.execution.installation_id
      assert snapshot.node_id == context.execution.current_node_id
      assert snapshot.node_type == "delay"
      assert snapshot.generation == 1
      assert snapshot.attempt_number == 1
      assert snapshot.run_mode == "live"

      assert snapshot.effect_key ==
               StepExecution.effect_key(
                 context.execution.installation_id,
                 context.execution.id,
                 context.execution.current_node_id
               )

      refute Map.has_key?(snapshot, :trigger)
      assert snapshot.compiled_node.type == :delay
      assert is_map(snapshot.compiled_node.config)
      assert is_map(snapshot.compiled_node.edges)

      stored = Repo.get!(Execution, context.execution.id)
      assert stored.status == "running"
      assert stored.lock_version == 1

      step = Repo.get!(StepExecution, snapshot.step_execution_id)
      assert step.status == "running"
      assert step.attempt_count == 1

      assert [attempt] =
               Repo.all(from a in StepAttempt, where: a.step_execution_id == ^step.id)

      assert attempt.id == snapshot.attempt_id
      assert attempt.status == "started"
    end

    test "the worker claims, evaluates, and finalizes through perform/1", context do
      assert {:ok, execution} = perform_job(AdvanceExecutionWorker, context.job_args)
      assert execution.status == "waiting_delay"
      assert Repo.get!(Execution, context.execution.id).status == "waiting_delay"
    end

    test "a duplicate job is a no-op and does not open a second attempt", context do
      assert {:ok, _snapshot} = Engine.claim(context.job_args)
      assert {:ok, :noop} = Engine.claim(context.job_args)

      assert Repo.aggregate(StepAttempt, :count) == 1
      assert Repo.get!(Execution, context.execution.id).lock_version == 1
    end

    test "cancel-before-claim is a no-op", context do
      context.execution
      |> Execution.changeset(%{
        status: "cancelled",
        cancelled_at: DateTime.utc_now(),
        cancellation_reason: "operator"
      })
      |> Repo.update!()

      assert {:ok, :noop} = Engine.claim(context.job_args)
      assert Repo.aggregate(StepAttempt, :count) == 0
      assert Repo.get!(Execution, context.execution.id).status == "cancelled"
    end

    test "uninstall-before-claim is a no-op", context do
      context.installation
      |> Installation.changeset(%{status: "uninstalled"})
      |> Repo.update!()

      assert {:ok, :noop} = Engine.claim(context.job_args)
      assert Repo.aggregate(StepAttempt, :count) == 0
      assert Repo.get!(Execution, context.execution.id).status == "queued"
    end

    test "an already-completed step is a stale no-op", context do
      mark!(context.execution, "completed")

      assert {:ok, :noop} = Engine.claim(context.job_args)
      assert Repo.aggregate(StepAttempt, :count) == 0
    end

    test "a waiting execution is a stale no-op for the original job", context do
      {:ok, snapshot} = Engine.claim(context.job_args)

      {:ok, outcome} =
        Outcome.new(%{
          kind: :wait_delay,
          edge: "next",
          resume_at: DateTime.add(DateTime.utc_now(), 60, :second),
          output: %{}
        })

      assert {:ok, waiting} = Engine.finalize(snapshot, outcome)
      assert waiting.status == "waiting_delay"

      assert {:ok, :noop} = Engine.claim(context.job_args)
      assert Repo.get!(Execution, context.execution.id).status == "waiting_delay"
    end

    test "inserts the current step when the row is missing", context do
      Repo.delete_all(from s in StepExecution, where: s.execution_id == ^context.execution.id)

      assert {:ok, snapshot} = Engine.claim(context.job_args)
      assert snapshot.node_id == context.execution.current_node_id
      assert Repo.get!(StepExecution, snapshot.step_execution_id).status == "running"
    end
  end

  defp activate!(scope, installation_id) do
    workflow =
      drafted_workflow(installation_id, %{
        draft_definition: Definition.encode(definition([delay_node()]))
      })

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

  defp mark!(%Execution{} = execution, status) do
    execution
    |> Execution.changeset(%{status: status})
    |> Repo.update!()

    Repo.update_all(
      from(s in StepExecution, where: s.execution_id == ^execution.id),
      set: [status: status]
    )
  end
end

defmodule PumbleAutomation.Executions.ClaimConcurrencyTest do
  @moduledoc """
  Two workers claiming one queued execution. The unique winner is the row
  lock, so this cannot run inside the SQL sandbox.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import PumbleAutomation.WorkflowsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.StepAttempt
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

  test "a two-worker barrier race has exactly one winner" do
    %{installation: installation, member: member} = InstallationsFixtures.install()
    on_exit(fn -> cleanup!(installation.id) end)

    scope = Scope.new(member)

    workflow =
      drafted_workflow(installation.id, %{
        draft_definition: Definition.encode(definition([delay_node()]))
      })

    {:ok, activated} = Workflows.activate_workflow(scope, workflow.id, 0)

    {:ok, execution} =
      Engine.create(scope, %{
        workflow_version_id: activated.version.id,
        execution_key: "race-#{System.unique_integer([:positive])}"
      })

    args = %{
      "installation_id" => execution.installation_id,
      "execution_id" => execution.id,
      "expected_node_id" => execution.current_node_id,
      "generation" => 0
    }

    parent = self()

    tasks =
      Enum.map(1..2, fn _index ->
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> Engine.claim(args)
          end
        end)
      end)

    pids =
      Enum.map(1..2, fn _index ->
        receive do
          {:ready, pid} -> pid
        after
          5_000 -> flunk("worker did not reach the barrier")
        end
      end)

    Enum.each(pids, &send(&1, :go))
    results = Enum.map(tasks, &Task.await(&1, 30_000))

    snapshots = for {:ok, snapshot} when is_map(snapshot) <- results, do: snapshot
    noops = for {:ok, :noop} <- results, do: :noop

    assert length(snapshots) == 1
    assert length(noops) == 1

    stored = Repo.get!(Execution, execution.id)
    assert stored.status == "running"
    assert stored.lock_version == 1

    assert Repo.aggregate(
             from(a in StepAttempt, where: a.installation_id == ^installation.id),
             :count
           ) == 1
  end

  defp cleanup!(installation_id) do
    Repo.delete_all(
      from j in Oban.Job,
        where: fragment("? ->> 'installation_id' = ?", j.args, ^installation_id)
    )

    InstallationsFixtures.erase!(installation_id)
  end
end
