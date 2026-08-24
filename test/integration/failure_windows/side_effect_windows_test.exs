defmodule PumbleAutomation.Integration.SideEffectWindowsTest do
  @moduledoc """
  Network-write crash windows. A timeout after a write may already have
  been delivered, so reconcile pauses instead of retrying.
  """

  use PumbleAutomation.FailureWindowsCase

  alias PumbleAutomation.Executions.Concurrency
  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.NodeRunner
  alias PumbleAutomation.Executions.StepAttempt
  alias PumbleAutomation.FailureInjector
  alias PumbleAutomation.FailureWindowsCase
  alias PumbleAutomation.Pumble.Client
  alias PumbleAutomation.PumbleFake
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition

  test "crash before the Pumble write is an uncertain pause after reconcile" do
    %{installation: installation, member: member} = install!()
    scope = Scope.new(member)
    {:ok, activated} = activate!(scope, installation.id, [message_node()])
    {:ok, execution} = create!(scope, activated.version.id)
    {:ok, snapshot} = Engine.claim(DatabaseRaceCase.job_args(execution))

    FailureInjector.arm(:before_network_write, :kill)
    parent = self()

    FailureWindowsCase.crash_through(fn ->
      Req.Test.allow(Client, parent, self())
      NodeRunner.run(NodeRunner.input(snapshot))
    end)

    assert Repo.get!(Execution, execution.id).status == "running"
    age_attempt!(snapshot.attempt_id)

    assert {:ok, %{paused: 1}} = Engine.reconcile(%{"installation_id" => installation.id})
    assert Repo.get!(Execution, execution.id).status == "paused_uncertain"
  end

  test "crash after an ambiguous Pumble timeout pauses rather than silent-retrying" do
    %{installation: installation, member: member} = install!()
    scope = Scope.new(member)
    {:ok, activated} = activate!(scope, installation.id, [message_node()])
    {:ok, execution} = create!(scope, activated.version.id)
    {:ok, snapshot} = Engine.claim(DatabaseRaceCase.job_args(execution))

    PumbleFake.stub_api_timeout()
    FailureInjector.arm(:after_write_timeout, :kill)
    parent = self()

    FailureWindowsCase.crash_through(fn ->
      Req.Test.allow(Client, parent, self())
      NodeRunner.run(NodeRunner.input(snapshot))
    end)

    assert Repo.get!(Execution, execution.id).status == "running"
    age_attempt!(snapshot.attempt_id)

    assert {:ok, %{paused: 1}} = Engine.reconcile(%{"installation_id" => installation.id})
    paused = Repo.get!(Execution, execution.id)
    assert paused.status == "paused_uncertain"
    assert Repo.get!(StepAttempt, snapshot.attempt_id).status == "uncertain"
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
