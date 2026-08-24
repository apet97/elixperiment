defmodule PumbleAutomation.Executions.Nodes.DelayNodeTest do
  @moduledoc """
  Delay waits are a stored resume_at plus a scheduled Oban job. Nothing
  here uses Process.sleep or a process timer. A wake job either snoozes,
  continues once, or no-ops.
  """

  use PumbleAutomation.DataCase, async: true
  use Oban.Testing, repo: PumbleAutomation.Repo

  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.NodeRunner
  alias PumbleAutomation.Executions.Nodes.Delay
  alias PumbleAutomation.Executions.Outcome
  alias PumbleAutomation.Executions.StepExecution
  alias PumbleAutomation.Executions.Workers.AdvanceExecutionWorker
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.CompiledWorkflow
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Node
  alias PumbleAutomation.Workflows.Node.DelayConfig

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

  describe "duration resolution" do
    test "a fixed duration waits until now plus that many seconds" do
      assert {:ok, outcome} = Delay.run(runner_input(%{"duration_seconds" => 60}))
      assert outcome.kind == :wait_delay
      assert outcome.edge == Outcome.linear()
      assert outcome.output["wait_seconds"] == 60
      assert %DateTime{} = outcome.resume_at
      assert DateTime.diff(outcome.resume_at, DateTime.utc_now(), :second) in 58..61
      assert outcome.output["resume_at"] == DateTime.to_iso8601(outcome.resume_at)
    end

    test "NodeRunner uses the delay node without a stub adapter" do
      assert {:ok, outcome} = NodeRunner.run(runner_input(%{"duration_seconds" => 12}))
      assert outcome.kind == :wait_delay
      assert outcome.output["wait_seconds"] == 12
    end

    test "a compiled template duration renders to a whole number of seconds" do
      input =
        runner_input(%{"duration_seconds" => duration_template()}, %{"wait" => 45})

      assert {:ok, outcome} = Delay.run(input)
      assert outcome.kind == :wait_delay
      assert outcome.output["wait_seconds"] == 45
    end

    test "a numeric string duration is accepted" do
      assert {:ok, outcome} = Delay.run(runner_input(%{"duration_seconds" => "30"}))
      assert outcome.output["wait_seconds"] == 30
    end

    test "the 365-day boundary is accepted and one extra second is permanent" do
      max = DelayConfig.max_seconds()
      assert {:ok, allowed} = Delay.run(runner_input(%{"duration_seconds" => max}))
      assert allowed.kind == :wait_delay
      assert allowed.output["wait_seconds"] == max

      assert {:ok, overflow} = Delay.run(runner_input(%{"duration_seconds" => max + 1}))
      assert overflow.kind == :permanent_error
      assert overflow.error_class == "validation"
      assert overflow.message =~ "365 days"
    end

    test "zero, missing, and non-numeric durations are permanent" do
      assert {:ok, zero} = Delay.run(runner_input(%{"duration_seconds" => 0}))
      assert zero.kind == :permanent_error
      assert zero.error_class == "validation"

      assert {:ok, missing} = Delay.run(runner_input(%{}))
      assert missing.kind == :permanent_error
      assert missing.message == "The delay step does not name a duration."

      assert {:ok, text} = Delay.run(runner_input(%{"duration_seconds" => "soon"}))
      assert text.kind == :permanent_error

      overflow_template =
        runner_input(%{"duration_seconds" => duration_template()}, %{
          "wait" => DelayConfig.max_seconds() + 1
        })

      assert {:ok, template_overflow} = Delay.run(overflow_template)
      assert template_overflow.kind == :permanent_error
      assert template_overflow.error_class == "validation"
    end
  end

  describe "durable wait" do
    test "finalize stores resume_at and inserts the scheduled job in one transaction",
         context do
      delay = delay_node()
      %{snapshot: snapshot, execution: execution} = claimed!(context, [delay])
      resume_at = DateTime.add(DateTime.utc_now(), 90, :second)

      {:ok, outcome} =
        Outcome.new(%{
          kind: :wait_delay,
          edge: "next",
          resume_at: resume_at,
          output: %{"wait_seconds" => 90}
        })

      assert {:ok, waiting} = Engine.finalize(snapshot, outcome)
      assert waiting.status == "waiting_delay"
      assert waiting.workflow_version_id == execution.workflow_version_id

      step = Repo.get!(StepExecution, snapshot.step_execution_id)
      assert step.status == "waiting_delay"
      assert step.output["resume_at"] == DateTime.to_iso8601(resume_at)

      assert_enqueued(
        worker: AdvanceExecutionWorker,
        args: %{
          execution_id: execution.id,
          expected_node_id: delay.id,
          generation: waiting.lock_version
        }
      )
    end

    test "a restart keeps the wait in the row and the scheduled job, not a timer", context do
      delay = delay_node()
      stop = Node.new(:stop, %{reason: "after-wait"})
      %{execution: execution} = queued!(context, [delay, stop])

      assert {:ok, waiting} =
               perform_job(AdvanceExecutionWorker, job_args(Repo.get!(Execution, execution.id)))

      assert waiting.status == "waiting_delay"
      step = Repo.get_by!(StepExecution, execution_id: execution.id, node_id: delay.id)
      assert is_binary(step.output["resume_at"])

      due_now!(step)

      assert {:ok, advanced} = perform_job(AdvanceExecutionWorker, job_args(waiting))
      assert advanced.status == "running"
      assert advanced.current_node_id == stop.id
      assert advanced.workflow_version_id == waiting.workflow_version_id
      assert steps_for(execution.id) |> Enum.count(&(&1.node_id == stop.id)) == 1

      assert {:ok, completed} = perform_job(AdvanceExecutionWorker, job_args(advanced))
      assert completed.status == "completed"
      assert completed.context["steps"][stop.id]["output"]["reason"] == "after-wait"
    end
  end

  describe "wake" do
    test "an early job snoozes and does not open the next step", context do
      delay = delay_node()
      stop = Node.new(:stop, %{reason: "after-wait"})

      waiting =
        wait_until!(context, [delay, stop], DateTime.add(DateTime.utc_now(), 120, :second))

      assert {:snooze, seconds} = perform_job(AdvanceExecutionWorker, job_args(waiting))
      assert seconds >= 1
      stored = Repo.get!(Execution, waiting.id)
      assert stored.status == "waiting_delay"
      assert stored.lock_version == waiting.lock_version
      assert steps_for(waiting.id) |> Enum.count(&(&1.node_id == stop.id)) == 0
    end

    test "a late job continues once along the linear edge", context do
      delay = delay_node()
      stop = Node.new(:stop, %{reason: "after-wait"})
      waiting = wait_until!(context, [delay, stop], DateTime.add(DateTime.utc_now(), -2, :second))

      assert {:ok, advanced} = perform_job(AdvanceExecutionWorker, job_args(waiting))
      assert advanced.status == "running"
      assert advanced.current_node_id == stop.id
      assert steps_for(waiting.id) |> Enum.count(&(&1.node_id == stop.id)) == 1
    end

    test "a duplicate wake does not insert a second next step", context do
      delay = delay_node()
      stop = Node.new(:stop, %{reason: "after-wait"})
      waiting = wait_until!(context, [delay, stop], DateTime.add(DateTime.utc_now(), -2, :second))
      args = job_args(waiting)

      assert {:ok, first} = perform_job(AdvanceExecutionWorker, args)
      assert :ok = perform_job(AdvanceExecutionWorker, args)
      assert {:ok, :noop} = Engine.claim(args)

      stored = Repo.get!(Execution, waiting.id)
      assert stored.status == "running"
      assert stored.current_node_id == stop.id
      assert stored.lock_version == first.lock_version
      assert steps_for(waiting.id) |> Enum.count(&(&1.node_id == stop.id)) == 1
    end
  end

  describe "cancel, uninstall, and version binding" do
    test "cancel while waiting stops immediately and the wake job is a no-op", context do
      delay = delay_node()
      stop = Node.new(:stop, %{reason: "after-wait"})
      waiting = wait_until!(context, [delay, stop], DateTime.add(DateTime.utc_now(), -1, :second))

      assert {:ok, cancelled} = Engine.cancel(context.scope, waiting.id)
      assert cancelled.status == "cancelled"
      assert :ok = perform_job(AdvanceExecutionWorker, job_args(waiting))
      stored = Repo.get!(Execution, waiting.id)
      assert stored.status == "cancelled"
      assert steps_for(waiting.id) |> Enum.count(&(&1.node_id == stop.id)) == 0
    end

    test "uninstall refuses the wake so no next effect starts", context do
      delay = delay_node()
      stop = Node.new(:stop, %{reason: "after-wait"})
      waiting = wait_until!(context, [delay, stop], DateTime.add(DateTime.utc_now(), -1, :second))

      context.installation
      |> Installation.changeset(%{status: "uninstalled"})
      |> Repo.update!()

      assert :ok = perform_job(AdvanceExecutionWorker, job_args(waiting))
      stored = Repo.get!(Execution, waiting.id)
      assert stored.status == "waiting_delay"
      assert steps_for(waiting.id) |> Enum.count(&(&1.node_id == stop.id)) == 0
    end

    test "deactivation leaves the in-flight wait bound to the original version", context do
      delay = delay_node()
      first_stop = Node.new(:stop, %{reason: "original"})

      waiting =
        wait_until!(context, [delay, first_stop], DateTime.add(DateTime.utc_now(), -1, :second))

      version_id = waiting.workflow_version_id
      assert {:ok, _} = Workflows.deactivate_workflow(context.scope, waiting.workflow_id)

      workflow = Repo.get!(Workflows.Workflow, waiting.workflow_id)

      {:ok, drafted} =
        Workflows.update_draft(
          context.scope,
          workflow.id,
          definition([delay_node(), Node.new(:stop, %{reason: "edited"})]),
          workflow.draft_revision
        )

      {:ok, activated} =
        Workflows.activate_workflow(context.scope, drafted.id, drafted.draft_revision)

      assert activated.version.id != version_id

      assert {:ok, advanced} = perform_job(AdvanceExecutionWorker, job_args(waiting))
      assert advanced.workflow_version_id == version_id
      assert {:ok, completed} = perform_job(AdvanceExecutionWorker, job_args(advanced))
      assert completed.status == "completed"
      assert completed.context["steps"][first_stop.id]["output"]["reason"] == "original"
    end

    test "reconciliation repairs a missing wait job from stored resume_at", context do
      delay = delay_node()
      resume_at = DateTime.add(DateTime.utc_now(), 180, :second)
      waiting = wait_until!(context, [delay], resume_at)

      Repo.delete_all(
        from j in Oban.Job,
          where: fragment("? ->> 'execution_id' = ?", j.args, ^waiting.id)
      )

      assert {:ok, %{jobs: 1}} =
               Engine.reconcile(%{"installation_id" => context.installation_id})

      assert_enqueued(
        worker: AdvanceExecutionWorker,
        args: %{
          execution_id: waiting.id,
          expected_node_id: delay.id,
          generation: waiting.lock_version
        }
      )
    end
  end

  defp runner_input(config, trigger_data \\ %{}) do
    %{
      compiled_node: %{
        type: :delay,
        config: config,
        edges: %{"next" => CompiledWorkflow.end_target()},
        requires: %{
          "operations" => [],
          "scopes" => [],
          "connection_ids" => [],
          "secret_names" => []
        }
      },
      context: %{},
      trigger_snapshot: %{"data" => trigger_data},
      installation_id: Ecto.UUID.generate(),
      run_mode: "live",
      effect_key: "inst/exec/node",
      attempt: %{id: Ecto.UUID.generate(), number: 1},
      resolver: PumbleAutomation.Connections.Resolver,
      adapters: %{}
    }
  end

  defp duration_template do
    %{"template" => [%{"path" => %{"root" => "trigger", "path" => ["data", "wait"]}}]}
  end

  defp wait_until!(context, nodes, resume_at) do
    %{snapshot: snapshot} = claimed!(context, nodes)

    {:ok, outcome} =
      Outcome.new(%{
        kind: :wait_delay,
        edge: "next",
        resume_at: resume_at,
        output: %{"wait_seconds" => 1}
      })

    assert {:ok, waiting} = Engine.finalize(snapshot, outcome)
    assert waiting.status == "waiting_delay"
    waiting
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
        execution_key: "delay-#{System.unique_integer([:positive])}"
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

  defp due_now!(%StepExecution{} = step) do
    output =
      Map.put(
        step.output || %{},
        "resume_at",
        DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -2, :second))
      )

    step
    |> StepExecution.changeset(%{output: output})
    |> Repo.update!()
  end

  defp steps_for(execution_id) do
    Repo.all(from s in StepExecution, where: s.execution_id == ^execution_id)
  end
end

defmodule PumbleAutomation.Executions.Nodes.DelayNodeJobInsertTest do
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

  test "a rejected delay job insert rolls the waiting transition back" do
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
        execution_key: "delay-jobfail-#{System.unique_integer([:positive])}"
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
        output: %{"wait_seconds" => 30}
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
    name = "reject_delay_oban_jobs_#{suffix}"

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
