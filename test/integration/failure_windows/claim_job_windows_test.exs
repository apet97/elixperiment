defmodule PumbleAutomation.Integration.ClaimJobWindowsTest do
  @moduledoc """
  Claim, duplicate-job, and two-worker crash windows. Recovery is reconcile
  or a later claim of the same generation — never an exactly-once assertion.
  """

  use PumbleAutomation.FailureWindowsCase

  alias PumbleAutomation.Executions.Concurrency
  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.Outcome
  alias PumbleAutomation.Executions.StepAttempt
  alias PumbleAutomation.Executions.Workers.AdvanceExecutionWorker
  alias PumbleAutomation.FailureInjector
  alias PumbleAutomation.FailureWindowsCase
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition

  test "crash before claim commit leaves the execution queued for the same job" do
    %{installation: installation, member: member} = install!()
    scope = Scope.new(member)
    {:ok, activated} = activate!(scope, installation.id, [delay_node()])
    {:ok, execution} = create!(scope, activated.version.id)
    args = DatabaseRaceCase.job_args(execution)

    FailureInjector.arm(:before_claim_commit, :kill)
    FailureWindowsCase.crash_through(fn -> Engine.claim(args) end)

    stored = Repo.get!(Execution, execution.id)
    assert stored.status == "queued"
    assert stored.lock_version == execution.lock_version

    assert Repo.aggregate(
             from(a in StepAttempt, where: a.installation_id == ^installation.id),
             :count
           ) == 0

    assert {:ok, snapshot} = Engine.claim(args)
    assert is_map(snapshot)
    assert Repo.get!(Execution, execution.id).status == "running"
  end

  test "crash after claim is repaired as a retry on a read-only delay" do
    %{installation: installation, member: member} = install!()
    scope = Scope.new(member)
    {:ok, activated} = activate!(scope, installation.id, [delay_node()])
    {:ok, execution} = create!(scope, activated.version.id)
    args = DatabaseRaceCase.job_args(execution)

    FailureInjector.arm(:after_claim, :kill)
    FailureWindowsCase.crash_through(fn -> Engine.claim(args) end)

    stored = Repo.get!(Execution, execution.id)
    assert stored.status == "running"
    attempt = Repo.one!(from a in StepAttempt, where: a.installation_id == ^installation.id)
    assert attempt.status == "started"
    age_attempt!(attempt.id)

    assert {:ok, %{jobs: 1}} = Engine.reconcile(%{"installation_id" => installation.id})
    assert Repo.get!(StepAttempt, attempt.id).status == "cancelled"
    assert Repo.get!(Execution, execution.id).status == "running"

    assert_enqueued(
      worker: AdvanceExecutionWorker,
      args: %{
        execution_id: execution.id,
        expected_node_id: stored.current_node_id,
        generation: stored.lock_version
      }
    )
  end

  test "a duplicate Oban job after a committed claim is a no-op" do
    %{installation: installation, member: member} = install!()
    scope = Scope.new(member)
    {:ok, activated} = activate!(scope, installation.id, [stop_node()])
    {:ok, execution} = create!(scope, activated.version.id)
    args = DatabaseRaceCase.job_args(execution)

    assert {:ok, snapshot} = Engine.claim(args)
    assert {:ok, :noop} = Engine.claim(args)

    {:ok, outcome} = Outcome.new(%{kind: :success, edge: "next", output: %{}})
    assert {:ok, finalized} = Engine.finalize(snapshot, outcome)
    assert finalized.status == "completed"
    assert {:ok, :noop} = Engine.finalize(snapshot, outcome)
  end

  test "two workers racing a claim open one attempt" do
    %{installation: installation, member: member} = install!()
    scope = Scope.new(member)
    {:ok, activated} = activate!(scope, installation.id, [delay_node()])
    {:ok, execution} = create!(scope, activated.version.id)
    args = DatabaseRaceCase.job_args(execution)

    results =
      Barrier.race([
        fn -> Engine.claim(args) end,
        fn -> Engine.claim(args) end
      ])

    snapshots = for {:ok, snapshot} when is_map(snapshot) <- results, do: snapshot
    noops = for {:ok, :noop} <- results, do: :noop

    assert length(snapshots) == 1
    assert length(noops) == 1

    assert Repo.aggregate(
             from(a in StepAttempt, where: a.installation_id == ^installation.id),
             :count
           ) == 1
  end

  test "crash after finalize before job return keeps the committed wait" do
    %{installation: installation, member: member} = install!()
    scope = Scope.new(member)
    {:ok, activated} = activate!(scope, installation.id, [delay_node(), stop_node()])
    {:ok, execution} = create!(scope, activated.version.id)
    original = DatabaseRaceCase.job_args(execution)
    job = %Oban.Job{id: 1, args: original, worker: Oban.Worker.to_string(AdvanceExecutionWorker)}

    FailureInjector.arm(:after_finalize_before_job_return, :kill)
    FailureWindowsCase.crash_through(fn -> AdvanceExecutionWorker.perform(job) end)

    waiting = Repo.get!(Execution, execution.id)
    assert waiting.status == "waiting_delay"

    assert {:ok, :noop} = Engine.claim(original)
    assert Repo.get!(Execution, execution.id).status == "waiting_delay"
    assert Concurrency.incomplete_job?(Repo, waiting.id)
  end

  test "crash before the next-job insert rolls the finalize back" do
    %{installation: installation, member: member} = install!()
    scope = Scope.new(member)
    {:ok, activated} = activate!(scope, installation.id, [delay_node(), stop_node()])
    {:ok, execution} = create!(scope, activated.version.id)
    {:ok, snapshot} = Engine.claim(DatabaseRaceCase.job_args(execution))

    FailureInjector.arm(:before_next_job_insert, :kill)

    FailureWindowsCase.crash_through(fn ->
      {:ok, outcome} =
        Outcome.new(%{
          kind: :wait_delay,
          edge: "next",
          output: %{},
          resume_at: DateTime.utc_now()
        })

      Engine.finalize(snapshot, outcome)
    end)

    stored = Repo.get!(Execution, execution.id)
    assert stored.status == "running"
    attempt = Repo.get!(StepAttempt, snapshot.attempt_id)
    assert attempt.status == "started"
  end

  test "crash before finalize leaves the started attempt for reconcile" do
    %{installation: installation, member: member} = install!()
    scope = Scope.new(member)
    {:ok, activated} = activate!(scope, installation.id, [message_node()])
    {:ok, execution} = create!(scope, activated.version.id)
    {:ok, snapshot} = Engine.claim(DatabaseRaceCase.job_args(execution))
    {:ok, outcome} = Outcome.new(%{kind: :success, edge: "next", output: %{}})

    FailureInjector.arm(:before_finalize, :kill)
    FailureWindowsCase.crash_through(fn -> Engine.finalize(snapshot, outcome) end)

    assert Repo.get!(Execution, execution.id).status == "running"
    age_attempt!(snapshot.attempt_id)

    assert {:ok, %{paused: 1}} = Engine.reconcile(%{"installation_id" => installation.id})
    assert Repo.get!(Execution, execution.id).status == "paused_uncertain"
  end

  defp install! do
    installed = InstallationsFixtures.install()
    on_exit(fn -> DatabaseRaceCase.cleanup!(installed.installation.id) end)
    installed
  end

  defp activate!(scope, installation_id, nodes) do
    workflow =
      drafted_workflow(installation_id, %{
        draft_definition: Definition.encode(definition(nodes))
      })

    Workflows.activate_workflow(scope, workflow.id, 0)
  end

  defp create!(scope, workflow_version_id) do
    Engine.create(scope, %{
      workflow_version_id: workflow_version_id,
      execution_key: "fw-#{System.unique_integer([:positive])}"
    })
  end

  defp age_attempt!(attempt_id) do
    cutoff =
      DateTime.add(DateTime.utc_now(), -(Concurrency.stale_after_seconds() + 60), :second)

    Repo.update_all(from(a in StepAttempt, where: a.id == ^attempt_id), set: [started_at: cutoff])
  end
end
