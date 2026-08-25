defmodule PumbleAutomation.Integration.EngineRaceTest do
  @moduledoc """
  Create, claim, finalize, occupancy, and reconcile under two
  real connections. Occupancy-parked queued rows have no job and are not
  missing jobs.
  """

  use PumbleAutomation.DatabaseRaceCase, async: false

  alias PumbleAutomation.Executions.Concurrency
  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.Outcome
  alias PumbleAutomation.Executions.StepAttempt
  alias PumbleAutomation.Executions.Workers.AdvanceExecutionWorker
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition

  test "concurrent duplicate creates produce one execution and one job" do
    %{installation: installation, member: member} = InstallationsFixtures.install()
    on_exit(fn -> DatabaseRaceCase.cleanup!(installation.id) end)

    other = InstallationsFixtures.install()
    on_exit(fn -> DatabaseRaceCase.cleanup!(other.installation.id) end)
    sentinel = tenant_snapshot(other.installation.id)

    scope = Scope.new(member)
    {:ok, activated} = activate!(scope, installation.id, [delay_node()])
    key = "create-#{System.unique_integer([:positive])}"
    attrs = %{workflow_version_id: activated.version.id, execution_key: key}

    results =
      Barrier.race([
        fn -> Engine.create(scope, attrs) end,
        fn -> Engine.create(scope, attrs) end
      ])

    oks = for {:ok, execution} <- results, do: execution
    assert length(oks) == 2
    assert oks |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 1

    stored =
      Repo.all(
        from e in Execution,
          where: e.installation_id == ^installation.id and e.execution_key == ^key
      )

    assert length(stored) == 1

    jobs =
      Repo.all(
        from j in Oban.Job,
          where: j.worker == "PumbleAutomation.Executions.Workers.AdvanceExecutionWorker",
          where: fragment("? ->> 'execution_id' = ?", j.args, ^hd(stored).id)
      )

    assert length(jobs) == 1
    assert_tenant_intact(other.installation.id, sentinel)
  end

  test "concurrent claims open one attempt and no-op the duplicate" do
    %{installation: installation, member: member} = InstallationsFixtures.install()
    on_exit(fn -> DatabaseRaceCase.cleanup!(installation.id) end)

    scope = Scope.new(member)
    {:ok, activated} = activate!(scope, installation.id, [delay_node()])

    {:ok, execution} =
      Engine.create(scope, %{
        workflow_version_id: activated.version.id,
        execution_key: "claim-#{System.unique_integer([:positive])}"
      })

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
    assert Repo.get!(Execution, execution.id).status == "running"

    assert Repo.aggregate(
             from(a in StepAttempt, where: a.installation_id == ^installation.id),
             :count
           ) == 1
  end

  test "concurrent finalize of one claim completes once" do
    %{installation: installation, member: member} = InstallationsFixtures.install()
    on_exit(fn -> DatabaseRaceCase.cleanup!(installation.id) end)

    scope = Scope.new(member)
    {:ok, activated} = activate!(scope, installation.id, [stop_node()])

    {:ok, execution} =
      Engine.create(scope, %{
        workflow_version_id: activated.version.id,
        execution_key: "fin-#{System.unique_integer([:positive])}"
      })

    {:ok, snapshot} = Engine.claim(DatabaseRaceCase.job_args(execution))
    {:ok, outcome} = Outcome.new(%{kind: :success, edge: "next", output: %{}})

    results =
      Barrier.race([
        fn -> Engine.finalize(snapshot, outcome) end,
        fn -> Engine.finalize(snapshot, outcome) end
      ])

    oks = for {:ok, finalized} when is_map(finalized) <- results, do: finalized
    noops = for {:ok, :noop} <- results, do: :noop

    assert length(oks) == 1
    assert length(noops) == 1
    assert hd(oks).status == "completed"
    assert Repo.get!(Execution, execution.id).status == "completed"

    assert Repo.aggregate(
             from(a in StepAttempt,
               where: a.installation_id == ^installation.id and a.status == "succeeded"
             ),
             :count
           ) == 1
  end

  test "concurrent creates admit at most five occupying jobs" do
    %{installation: installation, member: member} = InstallationsFixtures.install()
    on_exit(fn -> DatabaseRaceCase.cleanup!(installation.id) end)

    scope = Scope.new(member)
    {:ok, activated} = activate!(scope, installation.id, [delay_node()])
    workers = Concurrency.max_running() + 2

    funs =
      Enum.map(1..workers, fn index ->
        fn ->
          Engine.create(scope, %{
            workflow_version_id: activated.version.id,
            execution_key: "occ-#{index}-#{System.unique_integer([:positive])}"
          })
        end
      end)

    results = Barrier.race(funs)
    assert Enum.all?(results, &match?({:ok, %Execution{}}, &1))

    queued = Repo.all(from e in Execution, where: e.installation_id == ^installation.id)
    assert length(queued) == workers

    admitted = Enum.count(queued, &Concurrency.incomplete_job?(Repo, &1.id))
    assert admitted == Concurrency.max_running()
    assert Concurrency.slots_used(Repo, installation.id) == Concurrency.max_running()
  end

  test "concurrent reconcile inserts one missing advance job" do
    %{installation: installation, member: member} = InstallationsFixtures.install()
    on_exit(fn -> DatabaseRaceCase.cleanup!(installation.id) end)

    scope = Scope.new(member)
    {:ok, activated} = activate!(scope, installation.id, [delay_node()])

    {:ok, execution} =
      Engine.create(scope, %{
        workflow_version_id: activated.version.id,
        execution_key: "rec-#{System.unique_integer([:positive])}"
      })

    Repo.delete_all(
      from j in Oban.Job,
        where: fragment("? ->> 'execution_id' = ?", j.args, ^execution.id)
    )

    results =
      Barrier.race([
        fn -> Engine.reconcile(%{"installation_id" => installation.id}) end,
        fn -> Engine.reconcile(%{"installation_id" => installation.id}) end
      ])

    assert Enum.all?(results, &match?({:ok, _summary}, &1))

    jobs =
      Repo.all(
        from j in Oban.Job,
          where: j.worker == ^Oban.Worker.to_string(AdvanceExecutionWorker),
          where: fragment("? ->> 'execution_id' = ?", j.args, ^execution.id)
      )

    assert length(jobs) == 1
  end

  defp activate!(scope, installation_id, nodes) do
    workflow =
      drafted_workflow(installation_id, %{
        draft_definition: Definition.encode(definition(nodes))
      })

    Workflows.activate_workflow(scope, workflow.id, 0)
  end
end
