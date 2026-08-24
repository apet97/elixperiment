defmodule PumbleAutomation.Executions.FinalizeTest do
  @moduledoc """
  Finalizing a claimed step is one transaction: the attempt, step, context,
  next node, and next job either all exist or none of them do.
  """

  # This module installs table-wide failure triggers for rollback proof.
  use PumbleAutomation.DataCase, async: false
  use Oban.Testing, repo: PumbleAutomation.Repo

  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.Outcome
  alias PumbleAutomation.Executions.StepAttempt
  alias PumbleAutomation.Executions.StepExecution
  alias PumbleAutomation.Executions.Workers.AdvanceExecutionWorker
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
      installation_id: installation.id
    }
  end

  describe "terminal completion" do
    test "a stop node completes the execution and inserts no next job", context do
      stop = stop_node()
      %{snapshot: snapshot, execution: execution} = claimed!(context, [stop])

      {:ok, outcome} =
        Outcome.new(%{kind: :success, edge: "next", output: %{"reason" => "done"}})

      assert {:ok, finalized} = Engine.finalize(snapshot, outcome)
      assert finalized.status == "completed"
      assert finalized.lock_version == snapshot.generation + 1
      assert finalized.context["steps"][stop.id]["output"]["reason"] == "done"

      step = Repo.get!(StepExecution, snapshot.step_execution_id)
      assert step.status == "completed"
      assert step.selected_edge == "next"

      attempt = Repo.get!(StepAttempt, snapshot.attempt_id)
      assert attempt.status == "succeeded"
      assert attempt.ended_at

      refute_enqueued(
        worker: AdvanceExecutionWorker,
        args: %{
          execution_id: execution.id,
          expected_node_id: stop.id,
          generation: finalized.lock_version
        }
      )
    end
  end

  describe "branch edge" do
    test "follows the compiled true edge and enqueues the next step", context do
      true_stop = stop_node()
      false_delay = delay_node()
      condition = condition_node(if_true: [true_stop], if_false: [false_delay])
      %{snapshot: snapshot, execution: execution} = claimed!(context, [condition])

      {:ok, outcome} = Outcome.new(%{kind: :success, edge: "true", output: %{"matched" => true}})

      assert {:ok, finalized} = Engine.finalize(snapshot, outcome)
      assert finalized.status == "running"
      assert finalized.current_node_id == true_stop.id
      assert finalized.context["steps"][condition.id]["output"]["matched"] == true

      next_step =
        Repo.one!(
          from s in StepExecution,
            where: s.execution_id == ^execution.id and s.node_id == ^true_stop.id
        )

      assert next_step.status == "queued"
      assert next_step.node_type == "stop"

      assert_enqueued(
        worker: AdvanceExecutionWorker,
        args: %{
          installation_id: execution.installation_id,
          execution_id: execution.id,
          expected_node_id: true_stop.id,
          generation: finalized.lock_version
        }
      )
    end
  end

  describe "duplicate and stale finalization" do
    test "a second finalize of the same snapshot is a no-op", context do
      %{snapshot: snapshot} = claimed!(context, [stop_node()])
      {:ok, outcome} = Outcome.new(%{kind: :success, edge: "next", output: %{}})

      assert {:ok, first} = Engine.finalize(snapshot, outcome)
      assert first.status == "completed"
      assert {:ok, :noop} = Engine.finalize(snapshot, outcome)
      assert Repo.get!(Execution, snapshot.execution_id).status == "completed"
      assert Repo.get!(StepAttempt, snapshot.attempt_id).status == "succeeded"
    end

    test "a stale generation cannot overwrite a newer state", context do
      %{snapshot: snapshot, execution: execution} = claimed!(context, [stop_node()])

      execution
      |> Execution.changeset(%{lock_version: snapshot.generation + 1})
      |> Repo.update!()

      {:ok, outcome} = Outcome.new(%{kind: :success, edge: "next", output: %{}})
      assert {:ok, :noop} = Engine.finalize(snapshot, outcome)
      assert Repo.get!(Execution, execution.id).status == "running"
      assert Repo.get!(StepAttempt, snapshot.attempt_id).status == "started"
    end

    test "a stale attempt cannot overwrite a finished attempt", context do
      %{snapshot: snapshot} = claimed!(context, [stop_node()])

      from(a in StepAttempt, where: a.id == ^snapshot.attempt_id)
      |> Repo.update_all(set: [status: "succeeded"])

      {:ok, outcome} = Outcome.new(%{kind: :success, edge: "next", output: %{}})
      assert {:ok, :noop} = Engine.finalize(snapshot, outcome)
      assert Repo.get!(Execution, snapshot.execution_id).status == "running"
    end
  end

  describe "waiting and retryable outcomes" do
    test "a delay outcome marks waiting and inserts a scheduled advance job", context do
      delay = delay_node()
      %{snapshot: snapshot, execution: execution} = claimed!(context, [delay])
      resume_at = DateTime.add(DateTime.utc_now(), 60, :second)

      {:ok, outcome} =
        Outcome.new(%{
          kind: :wait_delay,
          edge: "next",
          resume_at: resume_at,
          output: %{"wait_seconds" => 60}
        })

      assert {:ok, finalized} = Engine.finalize(snapshot, outcome)
      assert finalized.status == "waiting_delay"
      assert Repo.get!(StepExecution, snapshot.step_execution_id).status == "waiting_delay"

      assert_enqueued(
        worker: AdvanceExecutionWorker,
        args: %{
          execution_id: execution.id,
          expected_node_id: delay.id,
          generation: finalized.lock_version
        }
      )
    end

    test "the worker evaluates a delay node through perform/1", context do
      %{execution: execution} = queued!(context, [delay_node()])

      assert {:ok, finalized} =
               perform_job(AdvanceExecutionWorker, job_args(execution))

      assert finalized.status == "waiting_delay"
    end
  end

  describe "context size limit" do
    test "an output that overflows context is a committed permanent failure", context do
      %{snapshot: snapshot, execution: execution} = claimed!(context, [stop_node()])

      pad = nearly_full_pad(execution.context)

      execution
      |> Execution.changeset(%{context: Map.put(execution.context, "pad", pad)})
      |> Repo.update!()

      {:ok, outcome} =
        Outcome.new(%{
          kind: :success,
          edge: "next",
          output: %{"blob" => String.duplicate("b", 4096)}
        })

      assert {:ok, finalized} = Engine.finalize(snapshot, outcome)
      assert finalized.status == "failed"
      refute Map.has_key?(finalized.context, "steps")
      assert Repo.get!(StepExecution, snapshot.step_execution_id).status == "failed"
      assert Repo.get!(StepAttempt, snapshot.attempt_id).status == "failed"
    end
  end

  describe "transaction rollback" do
    test "a rejected attempt write leaves the claim recoverable", context do
      %{snapshot: snapshot, execution: execution} = claimed!(context, [stop_node()])
      reject_writes!("step_attempts", "UPDATE")

      {:ok, outcome} = Outcome.new(%{kind: :success, edge: "next", output: %{}})

      assert {:error, %Error{}} = Engine.finalize(snapshot, outcome)
      assert_still_claimed(execution, snapshot)
    end

    test "a rejected step write rolls the attempt close back", context do
      %{snapshot: snapshot, execution: execution} = claimed!(context, [stop_node()])
      reject_writes!("step_executions", "UPDATE")

      {:ok, outcome} = Outcome.new(%{kind: :success, edge: "next", output: %{}})

      assert {:error, %Error{}} = Engine.finalize(snapshot, outcome)
      assert_still_claimed(execution, snapshot)
    end

    test "a rejected execution write rolls the step close back", context do
      %{snapshot: snapshot, execution: execution} = claimed!(context, [stop_node()])
      reject_writes!("executions", "UPDATE")

      {:ok, outcome} = Outcome.new(%{kind: :success, edge: "next", output: %{}})

      assert {:error, %Error{}} = Engine.finalize(snapshot, outcome)
      assert_still_claimed(execution, snapshot)
    end

    test "a rejected next-step insert rolls the completed step back", context do
      true_stop = stop_node()
      condition = condition_node(if_true: [true_stop], if_false: [delay_node()])
      %{snapshot: snapshot, execution: execution} = claimed!(context, [condition])
      reject_writes!("step_executions", "INSERT")

      {:ok, outcome} = Outcome.new(%{kind: :success, edge: "true", output: %{}})

      assert {:error, %Error{}} = Engine.finalize(snapshot, outcome)
      assert_still_claimed(execution, snapshot)
      refute Repo.exists?(from s in StepExecution, where: s.node_id == ^true_stop.id)
    end
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
        execution_key: "fin-#{System.unique_integer([:positive])}"
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

  defp assert_still_claimed(execution, snapshot) do
    stored = Repo.get!(Execution, execution.id)
    assert stored.status == "running"
    assert stored.lock_version == snapshot.generation
    assert Repo.get!(StepExecution, snapshot.step_execution_id).status == "running"
    assert Repo.get!(StepAttempt, snapshot.attempt_id).status == "started"
  end

  defp nearly_full_pad(base) do
    used = base |> Jason.encode!() |> byte_size()
    room = Execution.max_context_bytes() - used - 16

    Enum.find_value(0..64, fn shrink ->
      pad = String.duplicate("a", max(room - shrink, 1))
      context = Map.put(base, "pad", pad)
      if Execution.json_within?(context, Execution.max_context_bytes()), do: pad
    end)
  end

  defp reject_writes!(table, event) do
    suffix = System.unique_integer([:positive])
    name = "reject_#{table}_#{event}_#{suffix}"

    Repo.query!("""
    CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'write rejected';
    END;
    $$
    """)

    Repo.query!("""
    CREATE TRIGGER #{name}
    BEFORE #{event} ON #{table}
    FOR EACH ROW
    EXECUTE FUNCTION #{name}()
    """)

    :ok
  end
end

defmodule PumbleAutomation.Executions.FinalizeJobInsertTest do
  @moduledoc """
  Job-insert failure cannot run inside the SQL sandbox: Oban's unique insert
  disconnects the connection when a trigger on `oban_jobs` raises. The WHEN
  clause keeps the trigger from touching other tests' jobs.
  """

  use ExUnit.Case, async: false
  use Oban.Testing, repo: PumbleAutomation.Repo

  import Ecto.Query, only: [from: 2]
  import PumbleAutomation.WorkflowsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.Outcome
  alias PumbleAutomation.Executions.StepAttempt
  alias PumbleAutomation.Executions.StepExecution
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

  test "a rejected job insert rolls the durable transition back" do
    %{installation: installation, member: member} = InstallationsFixtures.install()
    on_exit(fn -> cleanup!(installation.id) end)

    scope = Scope.new(member)
    delay = delay_node()

    workflow =
      drafted_workflow(installation.id, %{
        draft_definition: Definition.encode(definition([delay]))
      })

    {:ok, activated} = Workflows.activate_workflow(scope, workflow.id, 0)

    {:ok, execution} =
      Engine.create(scope, %{
        workflow_version_id: activated.version.id,
        execution_key: "jobfail-#{System.unique_integer([:positive])}"
      })

    args = %{
      "installation_id" => execution.installation_id,
      "execution_id" => execution.id,
      "expected_node_id" => execution.current_node_id,
      "generation" => execution.lock_version
    }

    {:ok, snapshot} = Engine.claim(args)
    {_name, drop} = reject_job_insert!(execution.id)
    on_exit(drop)

    {:ok, outcome} =
      Outcome.new(%{
        kind: :wait_delay,
        edge: "next",
        resume_at: DateTime.add(DateTime.utc_now(), 30, :second),
        output: %{}
      })

    assert {:error, %Error{}} = Engine.finalize(snapshot, outcome)

    stored = Repo.get!(Execution, execution.id)
    assert stored.status == "running"
    assert stored.lock_version == snapshot.generation
    assert Repo.get!(StepExecution, snapshot.step_execution_id).status == "running"
    assert Repo.get!(StepAttempt, snapshot.attempt_id).status == "started"
  end

  defp reject_job_insert!(execution_id) do
    suffix = System.unique_integer([:positive])
    name = "reject_oban_jobs_#{suffix}"

    Repo.query!("""
    CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'job insert rejected';
    END;
    $$
    """)

    Repo.query!("""
    CREATE TRIGGER #{name}
    BEFORE INSERT ON oban_jobs
    FOR EACH ROW
    WHEN ((NEW.args ->> 'execution_id') = '#{execution_id}')
    EXECUTE FUNCTION #{name}()
    """)

    drop = fn ->
      Repo.query!("DROP TRIGGER IF EXISTS #{name} ON oban_jobs")
      Repo.query!("DROP FUNCTION IF EXISTS #{name}()")
    end

    {name, drop}
  end

  defp cleanup!(installation_id) do
    Repo.delete_all(
      from j in Oban.Job,
        where: fragment("? ->> 'installation_id' = ?", j.args, ^installation_id)
    )

    InstallationsFixtures.erase!(installation_id)
  end
end
