defmodule PumbleAutomation.Integration.WorkflowRaceTest do
  @moduledoc """
  Activation, schedule dispatch, and approval decision races.
  """

  use PumbleAutomation.DatabaseRaceCase, async: false

  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Approval
  alias PumbleAutomation.Executions.ApprovalService
  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.NodeRunner
  alias PumbleAutomation.Executions.Workers.ScheduleDispatcherWorker
  alias PumbleAutomation.Installations.WorkspaceMember
  alias PumbleAutomation.Pumble.Payload
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Definition.Trigger
  alias PumbleAutomation.Workflows.Node
  alias PumbleAutomation.Workflows.Schedule
  alias PumbleAutomation.Workflows.TriggerBinding
  alias PumbleAutomation.Workflows.Workflow
  alias PumbleAutomation.Workflows.WorkflowVersion

  test "concurrent activations produce one winner and one revision conflict" do
    %{installation: installation, member: member} = InstallationsFixtures.install()
    on_exit(fn -> DatabaseRaceCase.cleanup!(installation.id) end)

    other = InstallationsFixtures.install()
    on_exit(fn -> DatabaseRaceCase.cleanup!(other.installation.id) end)
    sentinel = tenant_snapshot(other.installation.id)

    scope = Scope.new(member)

    workflow =
      drafted_workflow(installation.id, %{
        draft_definition: Definition.encode(definition([delay_node()]))
      })

    results =
      Barrier.race([
        fn -> Workflows.activate_workflow(scope, workflow.id, 0) end,
        fn -> Workflows.activate_workflow(scope, workflow.id, 0) end
      ])

    oks = for {:ok, result} <- results, do: result
    errors = for {:error, %Error{} = error} <- results, do: error

    assert length(oks) == 1
    assert length(errors) == 1
    assert hd(errors).code == :draft_revision_conflict

    stored = Repo.get!(Workflow, workflow.id)
    assert stored.status == "active"
    assert stored.active_version_id == hd(oks).version.id

    versions = Repo.all(from v in WorkflowVersion, where: v.workflow_id == ^workflow.id)
    assert length(versions) == 1

    enabled =
      Repo.all(
        from b in TriggerBinding,
          where: b.workflow_version_id == ^hd(oks).version.id and b.enabled
      )

    assert length(enabled) == 1
    assert_tenant_intact(other.installation.id, sentinel)
  end

  test "two dispatchers create one execution for one occurrence" do
    %{installation: installation, member: member} = InstallationsFixtures.install()
    on_exit(fn -> DatabaseRaceCase.cleanup!(installation.id) end)

    scope = Scope.new(member)
    {_activated, schedule} = activate_clock!(scope, installation.id)
    occurrence = DateTime.add(DateTime.utc_now(), -30, :second)

    schedule
    |> Schedule.changeset(%{next_run_at: occurrence})
    |> Repo.update!()

    now = DateTime.utc_now()

    results =
      Barrier.race([
        fn -> ScheduleDispatcherWorker.dispatch_due(now) end,
        fn -> ScheduleDispatcherWorker.dispatch_due(now) end
      ])

    assert Enum.all?(results, &match?({:ok, _summary}, &1))

    stored = Repo.all(from e in Execution, where: e.installation_id == ^installation.id)
    assert length(stored) == 1
    assert hd(stored).execution_key == Schedule.occurrence_key(schedule, occurrence)
  end

  test "concurrent approve and reject produce one winner" do
    %{installation: installation, member: owner} = InstallationsFixtures.install()
    on_exit(fn -> DatabaseRaceCase.cleanup!(installation.id) end)

    editor = insert_member(installation, "editor")
    scope = Scope.new(owner)
    workspace_id = installation.pumble_workspace_id

    approval_node =
      approval_for(owner, approver_member_ids: [owner.id, editor.id], approved: [stop_node()])

    workflow =
      drafted_workflow(installation.id, %{
        draft_definition: Definition.encode(definition([approval_node]))
      })

    {:ok, activated} = Workflows.activate_workflow(scope, workflow.id, 0)

    {:ok, execution} =
      Engine.create(scope, %{
        workflow_version_id: activated.version.id,
        execution_key: "appr-#{System.unique_integer([:positive])}",
        trigger_snapshot: %{"channel_id" => "channel-1"}
      })

    {:ok, snapshot} = Engine.claim(DatabaseRaceCase.job_args(execution))
    {:ok, outcome} = NodeRunner.run(NodeRunner.input(snapshot))
    {:ok, waiting} = Engine.finalize(snapshot, outcome)
    approval = Repo.get_by!(Approval, execution_id: waiting.id)

    results =
      Barrier.race([
        fn -> ApprovalService.decide(click(approval, owner, "approved", workspace_id)) end,
        fn -> ApprovalService.decide(click(approval, editor, "rejected", workspace_id)) end
      ])

    decided = for {:ok, {:decided, _message}} <- results, do: true
    stale = for {:ok, {kind, _message}} when kind in [:stale, :duplicate] <- results, do: true

    assert length(decided) == 1
    assert length(stale) == 1

    stored = Repo.get!(Approval, approval.id)
    assert stored.status in ~w(approved rejected)
    refute Repo.get!(Execution, waiting.id).status == "waiting_approval"
  end

  defp activate_clock!(scope, installation_id) do
    definition =
      Definition.new(
        Trigger.new(:schedule, %{
          schedule_type: :every_minutes,
          interval: 15,
          timezone: "Etc/UTC"
        }),
        [delay_node(), stop_node()]
      )

    workflow =
      drafted_workflow(installation_id, %{draft_definition: Definition.encode(definition)})

    {:ok, activated} = Workflows.activate_workflow(scope, workflow.id, 0)

    schedule =
      Repo.one!(from s in Schedule, where: s.workflow_id == ^workflow.id and s.enabled)

    {activated, schedule}
  end

  defp approval_for(member, opts) do
    {branches, opts} = Keyword.split(opts, [:approved, :rejected, :timed_out])

    :approval
    |> Node.new(
      %{
        prompt: "Ship it?",
        approver_member_ids: Keyword.get(opts, :approver_member_ids, [member.id]),
        timeout_seconds: 3600
      },
      Keyword.drop(opts, [:approver_member_ids])
    )
    |> Node.put_branch(:approved, Keyword.get(branches, :approved, []))
    |> Node.put_branch(:rejected, Keyword.get(branches, :rejected, []))
    |> Node.put_branch(:timed_out, Keyword.get(branches, :timed_out, []))
  end

  defp click(approval, member, action, workspace_id) do
    %Payload.BlockInteraction{
      workspace_id: workspace_id,
      user_id: member.pumble_user_id,
      channel_id: approval.pumble_channel_id,
      source_type: "MESSAGE",
      source_id: "msg-1",
      action_type: "BUTTON",
      on_action: approval.public_action_id,
      payload: ApprovalService.button_value(approval, action, workspace_id),
      trigger_id: "trig-#{System.unique_integer([:positive])}"
    }
  end

  defp insert_member(installation, role) do
    %WorkspaceMember{}
    |> WorkspaceMember.changeset(%{
      installation_id: installation.id,
      pumble_user_id: "pumble-user-#{System.unique_integer([:positive])}",
      role: role
    })
    |> Repo.insert!()
  end
end
