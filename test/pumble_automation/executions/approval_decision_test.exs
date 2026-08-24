defmodule PumbleAutomation.Executions.ApprovalDecisionTest do
  @moduledoc """
  One authorized approve/reject click resumes the compiled branch. Duplicate
  clicks are a no-op. A conflicting, unauthorized, expired, cancelled, or
  uninstalled click returns a safe stale result and does not resume twice.
  """

  use PumbleAutomation.DataCase, async: false
  use Oban.Testing, repo: PumbleAutomation.Repo

  import Ecto.Query, only: [from: 2]
  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Audit.AuditEvent
  alias PumbleAutomation.Executions.Approval
  alias PumbleAutomation.Executions.ApprovalService
  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.NodeRunner
  alias PumbleAutomation.Executions.StepExecution
  alias PumbleAutomation.Executions.Workers.AdvanceExecutionWorker
  alias PumbleAutomation.Executions.Workers.ApprovalDeliveryWorker
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Installations.WorkspaceMember
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Pumble.Payload
  alias PumbleAutomation.PumbleFake
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Node

  @message %{"id" => "approval-msg-1", "channelId" => "channel-1"}

  setup do
    %{installation: installation, member: member} =
      InstallationsFixtures.install(tokens: %{bot_user_id: "bot1"})

    %{
      scope: Scope.new(member),
      installation: installation,
      installation_id: installation.id,
      member: member,
      workspace_id: installation.pumble_workspace_id
    }
  end

  describe "compiled branch resume" do
    test "an approve click records the decision and enqueues the next branch job", context do
      {waiting, approval, stop} = waited_with_stop!(context)

      assert {:ok, {:decided, "Approved."}} =
               ApprovalService.decide(click(approval, context.member, "approved", context))

      stored = Repo.get!(Approval, approval.id)
      assert stored.status == "approved"
      assert stored.decided_by_pumble_user_id == context.member.pumble_user_id
      assert stored.decided_by_member_id == context.member.id
      refute is_nil(stored.decided_at)

      execution = Repo.get!(Execution, waiting.id)
      assert execution.status == "running"
      assert execution.current_node_id == stop.id
      assert execution.lock_version == waiting.lock_version + 1

      step = Repo.get!(StepExecution, approval.step_execution_id)
      assert step.status == "completed"
      assert step.selected_edge == "approved"
      assert step.output["decision"] == "approved"

      assert_enqueued(
        worker: AdvanceExecutionWorker,
        args: %{
          execution_id: waiting.id,
          expected_node_id: stop.id,
          generation: execution.lock_version
        }
      )

      event =
        Repo.one!(
          from audit in AuditEvent,
            where:
              audit.action == "execution.approval_decided" and
                audit.resource_id == ^approval.id
        )

      assert event.actor_type == "pumble_user"
      assert event.actor_id == context.member.pumble_user_id
      assert event.metadata["outcome"] == "approved"
      assert event.metadata["previous_state"] == "waiting_approval"
      assert event.metadata["next_state"] == "running"
    end

    test "a reject click follows the compiled reject edge to completion", context do
      {waiting, approval, _outcome} = waited!(context)

      assert {:ok, {:decided, "Rejected."}} =
               ApprovalService.decide(click(approval, context.member, "rejected", context))

      assert Repo.get!(Approval, approval.id).status == "rejected"
      assert Repo.get!(Execution, waiting.id).status == "completed"
      assert Repo.get!(StepExecution, approval.step_execution_id).selected_edge == "rejected"

      refute_enqueued(
        worker: AdvanceExecutionWorker,
        args: %{execution_id: waiting.id, generation: waiting.lock_version + 1}
      )
    end

    test "decision works after the creating process is gone", context do
      {_waiting, approval, _outcome} = waited!(context)
      reloaded = Repo.get!(Approval, approval.id)

      assert {:ok, {:decided, "Approved."}} =
               ApprovalService.decide(click(reloaded, context.member, "approved", context))

      assert Repo.get!(Approval, approval.id).status == "approved"
    end
  end

  describe "same click twice" do
    test "a second identical click is a no-op and does not enqueue again", context do
      {waiting, approval, stop} = waited_with_stop!(context)
      interaction = click(approval, context.member, "approved", context)

      assert {:ok, {:decided, "Approved."}} = ApprovalService.decide(interaction)
      execution = Repo.get!(Execution, waiting.id)

      assert {:ok, {:duplicate, "This request was already decided."}} =
               ApprovalService.decide(interaction)

      stored = Repo.get!(Approval, approval.id)
      assert stored.status == "approved"
      assert stored.lock_version == 1
      assert Repo.get!(Execution, waiting.id).lock_version == execution.lock_version

      jobs =
        all_enqueued(
          worker: AdvanceExecutionWorker,
          args: %{execution_id: waiting.id, expected_node_id: stop.id}
        )

      assert length(jobs) == 1
    end
  end

  describe "approve vs reject" do
    test "a conflicting click after a decision is stale and does not switch the branch",
         context do
      {waiting, approval, stop} = waited_with_stop!(context)

      assert {:ok, {:decided, "Approved."}} =
               ApprovalService.decide(click(approval, context.member, "approved", context))

      assert {:ok, {:stale, message}} =
               ApprovalService.decide(click(approval, context.member, "rejected", context))

      assert message == ApprovalService.stale_message()
      assert Repo.get!(Approval, approval.id).status == "approved"
      assert Repo.get!(Execution, waiting.id).current_node_id == stop.id
    end
  end

  describe "unauthorized actor" do
    test "a workspace member who is not an approver cannot decide", context do
      other = insert_member(context.installation, "editor")
      {_waiting, approval, _outcome} = waited!(context)

      assert {:ok, {:stale, _message}} =
               ApprovalService.decide(click(approval, other, "approved", context))

      assert Repo.get!(Approval, approval.id).status == "pending"
      assert Repo.get!(Execution, approval.execution_id).status == "waiting_approval"
    end

    test "a callback actor from another workspace cannot decide", context do
      other = InstallationsFixtures.install()
      {_waiting, approval, _outcome} = waited!(context)

      interaction = %{
        click(approval, context.member, "approved", context)
        | workspace_id: other.installation.pumble_workspace_id,
          user_id: other.member.pumble_user_id
      }

      assert {:ok, {:stale, _message}} = ApprovalService.decide(interaction)
      assert Repo.get!(Approval, approval.id).status == "pending"
    end

    test "an approver disabled after the wait was created cannot decide", context do
      {waiting, approval, _outcome} = waited!(context)

      context.member
      |> WorkspaceMember.changeset(%{disabled_at: DateTime.utc_now()})
      |> Repo.update!()

      assert {:ok, {:stale, _message}} =
               ApprovalService.decide(click(approval, context.member, "approved", context))

      assert Repo.get!(Approval, approval.id).status == "pending"
      assert Repo.get!(Execution, waiting.id).status == "waiting_approval"

      refute_enqueued(
        worker: AdvanceExecutionWorker,
        args: %{execution_id: waiting.id, generation: waiting.lock_version + 1}
      )
    end
  end

  describe "expired, cancelled, and uninstalled" do
    test "an expired pending approval does not resume", context do
      {_waiting, approval, _outcome} = waited!(context)

      Repo.update_all(from(a in Approval, where: a.id == ^approval.id),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -60, :second)]
      )

      assert {:ok, {:stale, _message}} =
               ApprovalService.decide(click(approval, context.member, "approved", context))

      assert Repo.get!(Approval, approval.id).status == "pending"
      assert Repo.get!(Execution, approval.execution_id).status == "waiting_approval"
    end

    test "a cancelled wait returns stale and does not resume", context do
      {waiting, approval, _outcome} = waited!(context)
      assert {:ok, cancelled} = Engine.cancel(context.scope, waiting.id)
      assert cancelled.status == "cancelled"

      assert {:ok, {:stale, _message}} =
               ApprovalService.decide(click(approval, context.member, "approved", context))

      assert Repo.get!(Approval, approval.id).status == "cancelled"
      assert Repo.get!(Execution, waiting.id).status == "cancelled"
    end

    test "an uninstalled workspace cannot decide", context do
      {_waiting, approval, _outcome} = waited!(context)

      context.installation
      |> Installation.changeset(%{status: "uninstalled"})
      |> Repo.update!()

      assert {:ok, {:stale, _message}} =
               ApprovalService.decide(click(approval, context.member, "approved", context))

      assert Repo.get!(Approval, approval.id).status == "pending"
    end
  end

  describe "message update failure" do
    test "a failed Pumble update leaves the committed decision in place", context do
      PumbleFake.stub_api_routes(self(), [
        {"POST", "/v1/channels/channel-1/messages", 200, @message},
        {"POST", "/v1/channels/channel-1/messages/approval-msg-1", 500, %{"error" => "busy"}}
      ])

      {_waiting, approval, _outcome} = waited!(context)

      assert :ok =
               perform_job(ApprovalDeliveryWorker, %{
                 installation_id: approval.installation_id,
                 execution_id: approval.execution_id,
                 approval_id: approval.id
               })

      delivered = Repo.get!(Approval, approval.id)
      assert delivered.pumble_message_id == "approval-msg-1"

      handler = "approval-update-#{System.unique_integer([:positive])}"
      test = self()

      :telemetry.attach(
        handler,
        ApprovalService.telemetry_event() ++ [:message_update],
        fn event, measurements, metadata, _config ->
          send(test, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      try do
        assert {:ok, {:decided, "Approved."}} =
                 ApprovalService.decide(click(delivered, context.member, "approved", context))

        assert_receive {:telemetry, _event, %{count: 1}, %{result: :client}}
      after
        :telemetry.detach(handler)
      end

      assert Repo.get!(Approval, approval.id).status == "approved"
      assert Repo.get!(Execution, approval.execution_id).status == "running"
    end
  end

  describe "ignored payloads" do
    test "a picker-shaped payload is ignored so manual ingest can handle it" do
      interaction = %Payload.BlockInteraction{
        workspace_id: "ws-1",
        user_id: "user-1",
        source_type: "MESSAGE",
        source_id: "msg-1",
        trigger_id: "trig-1",
        on_action: "run_workflow",
        payload: "alias-one"
      }

      assert {:ok, :ignored} = ApprovalService.decide(interaction)
    end
  end

  defp waited_with_stop!(context) do
    stop = stop_node()
    approval_node = approval_for(context.member, approved: [stop])
    %{snapshot: snapshot} = claimed!(context, [approval_node])
    assert {:ok, outcome} = NodeRunner.run(NodeRunner.input(snapshot))
    assert {:ok, waiting} = Engine.finalize(snapshot, outcome)
    stored = Repo.get_by!(Approval, execution_id: waiting.id)
    {waiting, stored, stop}
  end

  defp waited!(context) do
    approval_node = approval_for(context.member)
    %{snapshot: snapshot} = claimed!(context, [approval_node])
    assert {:ok, outcome} = NodeRunner.run(NodeRunner.input(snapshot))
    assert {:ok, waiting} = Engine.finalize(snapshot, outcome)
    stored = Repo.get_by!(Approval, execution_id: waiting.id)
    {waiting, stored, outcome}
  end

  defp claimed!(context, nodes, trigger \\ %{"channel_id" => "channel-1"}) do
    %{version: version} = activate!(context.scope, context.installation_id, definition(nodes))

    {:ok, execution} =
      Engine.create(context.scope, %{
        workflow_version_id: version.id,
        execution_key: "approval-#{System.unique_integer([:positive])}",
        trigger_snapshot: trigger
      })

    execution = Repo.get!(Execution, execution.id)
    {:ok, snapshot} = Engine.claim(job_args(execution))
    %{execution: execution, snapshot: snapshot, version: version}
  end

  defp activate!(scope, installation_id, definition) do
    workflow =
      drafted_workflow(installation_id, %{draft_definition: Definition.encode(definition)})

    {:ok, result} = Workflows.activate_workflow(scope, workflow.id, 0)
    %{version: result.version, workflow: result.workflow}
  end

  defp approval_for(member, opts \\ []) do
    {branches, opts} = Keyword.split(opts, [:approved, :rejected, :timed_out])

    :approval
    |> Node.new(
      %{
        prompt: Keyword.get(opts, :prompt, "Ship it?"),
        approver_member_ids: Keyword.get(opts, :approver_member_ids, [member.id]),
        timeout_seconds: Keyword.get(opts, :timeout_seconds, 3600)
      },
      Keyword.take(opts, [:id])
    )
    |> Node.put_branch(:approved, Keyword.get(branches, :approved, [stop_node()]))
    |> Node.put_branch(:rejected, Keyword.get(branches, :rejected, []))
    |> Node.put_branch(:timed_out, Keyword.get(branches, :timed_out, []))
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

  defp click(approval, member, action, context) do
    %Payload.BlockInteraction{
      workspace_id: context.workspace_id,
      user_id: member.pumble_user_id,
      channel_id: approval.pumble_channel_id,
      source_type: "MESSAGE",
      source_id: approval.pumble_message_id || "msg-1",
      action_type: "BUTTON",
      on_action: approval.public_action_id,
      payload: ApprovalService.button_value(approval, action, context.workspace_id),
      trigger_id: "trig-#{System.unique_integer([:positive])}"
    }
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

defmodule PumbleAutomation.Executions.ApprovalServiceDecisionRaceTest do
  @moduledoc """
  Two authorized approvers clicking at once. The row lock picks one winner.
  """

  use ExUnit.Case, async: false
  use Oban.Testing, repo: PumbleAutomation.Repo

  import Ecto.Query, only: [from: 2]
  import PumbleAutomation.WorkflowsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias PumbleAutomation.Executions.Approval
  alias PumbleAutomation.Executions.ApprovalService
  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.NodeRunner
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Installations.Lifecycle
  alias PumbleAutomation.Installations.WorkspaceMember
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Pumble.Payload
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Node

  setup do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  test "concurrent approve and reject produce one winner and one stale result" do
    %{installation: installation, member: owner} = InstallationsFixtures.install()
    on_exit(fn -> cleanup!(installation.id) end)

    other = insert_member(installation, "editor")

    {waiting, approval} =
      waiting_approval!(installation, owner,
        approver_member_ids: [owner.id, other.id],
        approved: [stop_node()]
      )

    workspace_id = installation.pumble_workspace_id

    parent = self()

    clicks = [
      {owner, "approved"},
      {other, "rejected"}
    ]

    tasks =
      Enum.map(clicks, fn {member, action} ->
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go ->
              ApprovalService.decide(click(approval, member, action, workspace_id))
          end
        end)
      end)

    pids =
      Enum.map(1..2, fn _index ->
        receive do
          {:ready, pid} -> pid
        after
          5_000 -> flunk("approver did not reach the barrier")
        end
      end)

    Enum.each(pids, &send(&1, :go))
    results = Enum.map(tasks, &Task.await(&1, 30_000))

    decided = for {:ok, {:decided, _message}} <- results, do: true
    stale = for {:ok, {:stale, _message}} <- results, do: true
    duplicate = for {:ok, {:duplicate, _message}} <- results, do: true

    assert length(decided) == 1
    assert length(stale) + length(duplicate) == 1

    stored = Repo.get!(Approval, approval.id)
    assert stored.status in ~w(approved rejected)
    assert Repo.get!(Execution, waiting.id).status in ~w(running completed)
  end

  test "an unauthorized transition that commits while a click waits wins serialization" do
    %{installation: installation, member: owner} = InstallationsFixtures.install()
    on_exit(fn -> cleanup!(installation.id) end)

    {waiting, approval} = waiting_approval!(installation, owner)
    click = click(approval, owner, "approved", installation.pumble_workspace_id)

    assert_lifecycle_wins_click!(
      installation,
      waiting,
      approval,
      click,
      :mark_unauthorized,
      "revoked"
    )
  end

  test "an uninstall that commits while a click waits wins serialization" do
    %{installation: installation, member: owner} = InstallationsFixtures.install()
    on_exit(fn -> cleanup!(installation.id) end)

    {waiting, approval} = waiting_approval!(installation, owner)
    click = click(approval, owner, "approved", installation.pumble_workspace_id)

    assert_lifecycle_wins_click!(
      installation,
      waiting,
      approval,
      click,
      :uninstall,
      "uninstalled"
    )
  end

  test "a member disable that commits while their click waits wins serialization" do
    %{installation: installation, member: owner} = InstallationsFixtures.install()
    on_exit(fn -> cleanup!(installation.id) end)

    {waiting, approval} = waiting_approval!(installation, owner)
    click = click(approval, owner, "approved", installation.pumble_workspace_id)
    parent = self()

    transition =
      Task.async(fn ->
        Repo.checkout(fn ->
          Repo.transaction(fn ->
            backend_pid = backend_pid()

            member =
              Repo.one!(
                from m in WorkspaceMember,
                  where: m.id == ^owner.id and m.installation_id == ^installation.id,
                  lock: "FOR UPDATE"
              )

            member
            |> WorkspaceMember.changeset(%{disabled_at: DateTime.utc_now()})
            |> Repo.update!()

            send(parent, {:transition_ready, self(), backend_pid})
            await_release!()
          end)
        end)
      end)

    assert_receive {:transition_ready, transition_pid, locker_backend_pid}, 5_000
    assert transition_pid == transition.pid

    click_task = start_click(click)
    assert_receive {:click_ready, click_pid, click_backend_pid}, 5_000
    assert click_pid == click_task.pid
    assert_blocked_by!(click_backend_pid, locker_backend_pid)

    send(transition.pid, :release)
    assert {:ok, _member} = Task.await(transition, 30_000)
    assert {:ok, {:stale, _message}} = Task.await(click_task, 30_000)

    assert Repo.get!(Approval, approval.id).status == "pending"
    assert Repo.get!(Execution, waiting.id).status == "waiting_approval"

    refute_enqueued(
      worker: PumbleAutomation.Executions.Workers.AdvanceExecutionWorker,
      args: %{execution_id: waiting.id, generation: waiting.lock_version + 1}
    )
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

  defp waiting_approval!(installation, owner, opts \\ []) do
    scope = Scope.new(owner)
    approval_node = approval_for(owner, Keyword.put_new(opts, :approved, [stop_node()]))

    workflow =
      drafted_workflow(installation.id, %{
        draft_definition: Definition.encode(definition([approval_node]))
      })

    {:ok, activated} = Workflows.activate_workflow(scope, workflow.id, 0)

    {:ok, execution} =
      Engine.create(scope, %{
        workflow_version_id: activated.version.id,
        execution_key: "approval-race-#{System.unique_integer([:positive])}",
        trigger_snapshot: %{"channel_id" => "channel-1"}
      })

    {:ok, snapshot} = Engine.claim(job_args(execution))
    {:ok, outcome} = NodeRunner.run(NodeRunner.input(snapshot))
    {:ok, waiting} = Engine.finalize(snapshot, outcome)
    {waiting, Repo.get_by!(Approval, execution_id: waiting.id)}
  end

  defp assert_lifecycle_wins_click!(
         installation,
         waiting,
         approval,
         click,
         transition_name,
         expected_status
       ) do
    parent = self()

    transition =
      Task.async(fn ->
        run_lifecycle_transition(parent, installation.id, transition_name)
      end)

    assert_receive {:transition_ready, transition_pid, locker_backend_pid}, 5_000
    assert transition_pid == transition.pid

    click_task = start_click(click)
    assert_receive {:click_ready, click_pid, click_backend_pid}, 5_000
    assert click_pid == click_task.pid
    assert_blocked_by!(click_backend_pid, locker_backend_pid)

    send(transition.pid, :release)
    assert {:ok, %Installation{status: ^expected_status}} = Task.await(transition, 30_000)
    assert {:ok, {:stale, _message}} = Task.await(click_task, 30_000)

    assert Repo.get!(Approval, approval.id).status == "pending"
    assert Repo.get!(Execution, waiting.id).status == "waiting_approval"
  end

  defp run_lifecycle_transition(parent, installation_id, transition_name) do
    Repo.checkout(fn ->
      Repo.transaction(fn ->
        apply_lifecycle_transition(parent, installation_id, transition_name)
      end)
    end)
  end

  defp apply_lifecycle_transition(parent, installation_id, transition_name) do
    backend_pid = backend_pid()
    {:ok, changed} = apply(Lifecycle, transition_name, [installation_id])
    send(parent, {:transition_ready, self(), backend_pid})
    await_release!()
    changed
  end

  defp start_click(click) do
    parent = self()

    Task.async(fn ->
      Repo.checkout(fn ->
        send(parent, {:click_ready, self(), backend_pid()})
        ApprovalService.decide(click)
      end)
    end)
  end

  defp assert_blocked_by!(blocked_pid, locker_pid) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    await_blocked_by!(blocked_pid, locker_pid, deadline)
  end

  defp await_blocked_by!(blocked_pid, locker_pid, deadline) do
    %{rows: [[blocked?]]} =
      Repo.query!("SELECT $1::integer = ANY(pg_blocking_pids($2::integer))", [
        locker_pid,
        blocked_pid
      ])

    cond do
      blocked? ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        await_blocked_by!(blocked_pid, locker_pid, deadline)

      true ->
        flunk("click backend #{blocked_pid} never blocked behind backend #{locker_pid}")
    end
  end

  defp backend_pid do
    %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  defp await_release! do
    receive do
      :release -> :ok
    after
      30_000 -> flunk("transition release was not received")
    end
  end

  defp job_args(%Execution{} = execution) do
    %{
      "installation_id" => execution.installation_id,
      "execution_id" => execution.id,
      "expected_node_id" => execution.current_node_id,
      "generation" => execution.lock_version
    }
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
      []
    )
    |> Node.put_branch(:approved, Keyword.get(branches, :approved, []))
    |> Node.put_branch(:rejected, Keyword.get(branches, :rejected, []))
    |> Node.put_branch(:timed_out, Keyword.get(branches, :timed_out, []))
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

  defp cleanup!(installation_id) do
    Repo.delete_all(
      from j in Oban.Job,
        where: fragment("? ->> 'installation_id' = ?", j.args, ^installation_id)
    )

    InstallationsFixtures.erase!(installation_id)
  end
end

defmodule PumbleAutomationWeb.ApprovalDecisionCallbackTest do
  @moduledoc """
  A signed block-interaction callback records the approval decision.
  """

  use PumbleAutomationWeb.ConnCase, async: false
  use Oban.Testing, repo: PumbleAutomation.Repo

  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Executions.Approval
  alias PumbleAutomation.Executions.ApprovalService
  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.NodeRunner
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Pumble.Signature
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Node

  @secret "test-signing-secret"
  @timestamp "1767225600000"

  test "a signed approve click is acknowledged and resumes the wait" do
    %{installation: installation, member: member} =
      InstallationsFixtures.install(tokens: %{bot_user_id: "bot1"})

    scope = Scope.new(member)
    approval_node = approval_for(member)

    workflow =
      drafted_workflow(installation.id, %{
        draft_definition: Definition.encode(definition([approval_node]))
      })

    {:ok, activated} = Workflows.activate_workflow(scope, workflow.id, 0)

    {:ok, execution} =
      Engine.create(scope, %{
        workflow_version_id: activated.version.id,
        execution_key: "approval-http-#{System.unique_integer([:positive])}",
        trigger_snapshot: %{"channel_id" => "channel-1"}
      })

    execution = Repo.get!(Execution, execution.id)

    {:ok, snapshot} =
      Engine.claim(%{
        "installation_id" => execution.installation_id,
        "execution_id" => execution.id,
        "expected_node_id" => execution.current_node_id,
        "generation" => execution.lock_version
      })

    {:ok, outcome} = NodeRunner.run(NodeRunner.input(snapshot))
    {:ok, waiting} = Engine.finalize(snapshot, outcome)
    approval = Repo.get_by!(Approval, execution_id: waiting.id)

    value = ApprovalService.button_value(approval, "approved", installation.pumble_workspace_id)

    body =
      Jason.encode!(%{
        "messageType" => "BLOCK_INTERACTION",
        "workspaceId" => installation.pumble_workspace_id,
        "userId" => member.pumble_user_id,
        "channelId" => "channel-1",
        "sourceType" => "MESSAGE",
        "sourceId" => "msg-1",
        "actionType" => "BUTTON",
        "onAction" => approval.public_action_id,
        "payload" => value,
        "triggerId" => "trig-1",
        "loadingTimeout" => 0
      })

    conn =
      build_conn()
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-pumble-request-timestamp", @timestamp)
      |> Plug.Conn.put_req_header(
        "x-pumble-request-signature",
        Signature.compute(@secret, @timestamp, body)
      )
      |> post(~p"/pumble/callbacks", body)

    assert json_response(conn, 200) == %{"message" => "Approved."}
    assert Repo.get!(Approval, approval.id).status == "approved"
    assert Repo.get!(Execution, waiting.id).status == "running"
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
end
