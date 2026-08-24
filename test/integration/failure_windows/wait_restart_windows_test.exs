defmodule PumbleAutomation.Integration.WaitRestartWindowsTest do
  @moduledoc """
  Delay and approval waits survive a process death. There is no in-memory
  timer; reconcile and the durable job are the restart path. Oban test
  mode is `testing: :manual`, which is the local analogue of a paused
  queue during a deploy drain.
  """

  use PumbleAutomation.FailureWindowsCase

  alias PumbleAutomation.Executions.Approval
  alias PumbleAutomation.Executions.ApprovalService
  alias PumbleAutomation.Executions.Concurrency
  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.NodeRunner
  alias PumbleAutomation.Executions.Workers.AdvanceExecutionWorker
  alias PumbleAutomation.FailureInjector
  alias PumbleAutomation.FailureWindowsCase
  alias PumbleAutomation.Pumble.Payload
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Node

  test "a delay wait survives worker death and reconcile" do
    %{installation: installation, member: member} = install!()
    scope = Scope.new(member)
    delay = delay_node()
    {:ok, activated} = activate!(scope, installation.id, [delay, stop_node()])
    {:ok, execution} = create!(scope, activated.version.id)

    assert {:ok, waiting} =
             perform_job(AdvanceExecutionWorker, DatabaseRaceCase.job_args(execution))

    assert waiting.status == "waiting_delay"
    assert Concurrency.incomplete_job?(Repo, waiting.id)

    assert {:ok, %{jobs: 0, paused: 0}} =
             Engine.reconcile(%{"installation_id" => installation.id})

    assert Repo.get!(Execution, waiting.id).status == "waiting_delay"
    assert Concurrency.incomplete_job?(Repo, waiting.id)
  end

  test "an approval wait survives worker death and reconcile" do
    %{installation: installation, member: member} = install!()
    scope = Scope.new(member)
    {:ok, activated} = activate!(scope, installation.id, [approval_for(member)])
    {:ok, execution} = create!(scope, activated.version.id)
    {:ok, snapshot} = Engine.claim(DatabaseRaceCase.job_args(execution))
    {:ok, outcome} = NodeRunner.run(NodeRunner.input(snapshot))
    {:ok, waiting} = Engine.finalize(snapshot, outcome)

    assert waiting.status == "waiting_approval"
    assert %Approval{status: "pending"} = Repo.get_by!(Approval, execution_id: waiting.id)

    assert {:ok, _} = Engine.reconcile(%{"installation_id" => installation.id})
    assert Repo.get!(Execution, waiting.id).status == "waiting_approval"
    assert Repo.get_by!(Approval, execution_id: waiting.id).status == "pending"
  end

  test "an approval decision crash rolls back and a later click still decides" do
    %{installation: installation, member: member} = install!()
    scope = Scope.new(member)
    {:ok, activated} = activate!(scope, installation.id, [approval_for(member)])
    {:ok, execution} = create!(scope, activated.version.id)
    {:ok, snapshot} = Engine.claim(DatabaseRaceCase.job_args(execution))
    {:ok, outcome} = NodeRunner.run(NodeRunner.input(snapshot))
    {:ok, waiting} = Engine.finalize(snapshot, outcome)
    approval = Repo.get_by!(Approval, execution_id: waiting.id)
    interaction = click(approval, member, "approved", installation.pumble_workspace_id)

    FailureInjector.arm(:approval_decision, :kill)
    FailureWindowsCase.crash_through(fn -> ApprovalService.decide(interaction) end)

    assert Repo.get!(Approval, approval.id).status == "pending"
    assert Repo.get!(Execution, waiting.id).status == "waiting_approval"

    assert {:ok, {:decided, _message}} = ApprovalService.decide(interaction)
    assert Repo.get!(Approval, approval.id).status == "approved"
    refute Repo.get!(Execution, waiting.id).status == "waiting_approval"
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
      execution_key: "fw-#{System.unique_integer([:positive])}",
      trigger_snapshot: %{"channel_id" => "channel-1"}
    })
  end

  defp approval_for(member) do
    :approval
    |> Node.new(%{
      prompt: "Ship it?",
      approver_member_ids: [member.id],
      timeout_seconds: 3600
    })
    |> Node.put_branch(:approved, [stop_node()])
    |> Node.put_branch(:rejected, [])
    |> Node.put_branch(:timed_out, [])
  end

  defp click(approval, member, action, workspace_id) do
    %Payload.BlockInteraction{
      workspace_id: workspace_id,
      user_id: member.pumble_user_id,
      channel_id: approval.pumble_channel_id,
      source_type: "MESSAGE",
      source_id: approval.pumble_message_id || "msg-1",
      action_type: "BUTTON",
      on_action: approval.public_action_id,
      payload: ApprovalService.button_value(approval, action, workspace_id),
      trigger_id: "trig-#{System.unique_integer([:positive])}"
    }
  end
end
