defmodule PumbleAutomation.Executions.ApprovalTimeoutTest do
  @moduledoc """
  A due timeout job records one terminal approval outcome. Early jobs snooze.
  Duplicate jobs no-op. Cancel and uninstall invalidate the token. Missing
  timeout jobs are repaired. Request, timeout, cancel, and unauthorized
  attempts are audited at a bounded rate.
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
  alias PumbleAutomation.Executions.Workers.ApprovalTimeoutWorker
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Installations.WorkspaceMember
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Pumble.Payload
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Node
  alias PumbleAutomation.Workflows.WorkflowVersion

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

  describe "early, late, and duplicate timeout" do
    test "an early job snoozes and leaves the wait pending", context do
      {waiting, approval, _stop} = waited_with_timeout_branch!(context)

      assert {:snooze, seconds} =
               perform_job(ApprovalTimeoutWorker, timeout_args(waiting, approval))

      assert seconds >= 1
      assert Repo.get!(Approval, approval.id).status == "pending"
      assert Repo.get!(Execution, waiting.id).status == "waiting_approval"

      refute_enqueued(
        worker: AdvanceExecutionWorker,
        args: %{generation: waiting.lock_version + 1}
      )
    end

    test "a late job follows the compiled timeout branch once", context do
      {waiting, approval, stop} = waited_with_timeout_branch!(context)
      due_now!(approval)

      assert :ok = perform_job(ApprovalTimeoutWorker, timeout_args(waiting, approval))

      stored = Repo.get!(Approval, approval.id)
      assert stored.status == "timed_out"
      refute is_nil(stored.decided_at)

      execution = Repo.get!(Execution, waiting.id)
      assert execution.status == "running"
      assert execution.current_node_id == stop.id

      step = Repo.get!(StepExecution, approval.step_execution_id)
      assert step.status == "completed"
      assert step.selected_edge == "timed_out"
      assert step.output["decision"] == "timed_out"

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
              audit.action == "execution.approval_timed_out" and
                audit.resource_id == ^approval.id
        )

      assert event.actor_type == "job"
      assert event.actor_id == "approval_timeout_worker"
      assert event.metadata["outcome"] == "timed_out"
      assert event.metadata["source"] == "timeout_worker"
    end

    test "a duplicate due job does not insert a second next step", context do
      {waiting, approval, stop} = waited_with_timeout_branch!(context)
      due_now!(approval)
      args = timeout_args(waiting, approval)

      assert :ok = perform_job(ApprovalTimeoutWorker, args)
      assert :ok = perform_job(ApprovalTimeoutWorker, args)
      assert :ok = ApprovalService.timeout(args)

      stored = Repo.get!(Execution, waiting.id)
      assert stored.status == "running"
      assert stored.current_node_id == stop.id
      assert Repo.get!(Approval, approval.id).status == "timed_out"

      jobs =
        all_enqueued(
          worker: AdvanceExecutionWorker,
          args: %{execution_id: waiting.id, expected_node_id: stop.id}
        )

      assert length(jobs) == 1
    end
  end

  describe "timeout branch and terminal stop" do
    test "an empty timeout branch completes the execution", context do
      {waiting, approval, _outcome} = waited!(context)
      due_now!(approval)

      assert :ok = ApprovalService.timeout(timeout_args(waiting, approval))
      assert Repo.get!(Approval, approval.id).status == "timed_out"
      assert Repo.get!(Execution, waiting.id).status == "completed"
      assert Repo.get!(StepExecution, approval.step_execution_id).selected_edge == "timed_out"

      refute_enqueued(
        worker: AdvanceExecutionWorker,
        args: %{execution_id: waiting.id, generation: waiting.lock_version + 1}
      )
    end

    test "an unreadable compiled graph leaves the wait pending", context do
      {waiting, approval, _outcome} = waited!(context)
      due_now!(approval)

      Repo.update_all(
        from(v in WorkflowVersion, where: v.id == ^waiting.workflow_version_id),
        set: [compiled_definition: %{}]
      )

      assert :ok = ApprovalService.timeout(timeout_args(waiting, approval))

      assert Repo.get!(Approval, approval.id).status == "pending"
      assert Repo.get!(Execution, waiting.id).status == "waiting_approval"
    end
  end

  describe "cancel and uninstall" do
    test "cancel marks the approval cancelled and invalidates the token", context do
      {waiting, approval, _outcome} = waited!(context)
      value = ApprovalService.button_value(approval, "approved", context.workspace_id)

      assert {:ok, cancelled} = Engine.cancel(context.scope, waiting.id)
      assert cancelled.status == "cancelled"

      stored = Repo.get!(Approval, approval.id)
      assert stored.status == "cancelled"
      refute ApprovalService.bound_value?(stored, "approved", context.workspace_id, value)

      assert {:ok, {:stale, message}} =
               ApprovalService.decide(click(approval, context.member, "approved", context))

      assert message == ApprovalService.stale_message()
      assert Repo.get!(Execution, waiting.id).status == "cancelled"

      event =
        Repo.one!(
          from audit in AuditEvent,
            where:
              audit.action == "execution.approval_cancelled" and
                audit.resource_id == ^approval.id
        )

      assert event.actor_type == "user"
      assert event.metadata["outcome"] == "cancelled"
    end

    test "uninstall refuses the timeout so no next effect starts", context do
      {waiting, approval, stop} = waited_with_timeout_branch!(context)
      due_now!(approval)

      context.installation
      |> Installation.changeset(%{status: "uninstalled"})
      |> Repo.update!()

      assert :ok = perform_job(ApprovalTimeoutWorker, timeout_args(waiting, approval))
      assert Repo.get!(Approval, approval.id).status == "pending"
      assert Repo.get!(Execution, waiting.id).status == "waiting_approval"
      assert steps_for(waiting.id) |> Enum.count(&(&1.node_id == stop.id)) == 0
    end
  end

  describe "missing job repair" do
    test "reconciliation restores a missing timeout job at expiry", context do
      {waiting, approval, _stop} = waited_with_timeout_branch!(context)

      Repo.delete_all(
        from j in Oban.Job,
          where: j.worker == "PumbleAutomation.Executions.Workers.ApprovalTimeoutWorker"
      )

      assert {:ok, result} = Engine.reconcile(%{"installation_id" => context.installation_id})
      assert result.jobs >= 1

      assert_enqueued(
        worker: ApprovalTimeoutWorker,
        args: %{
          execution_id: waiting.id,
          approval_id: approval.id,
          generation: waiting.lock_version
        }
      )

      assert {:ok, %{jobs: 0, count: 0}} =
               Engine.reconcile(%{"installation_id" => context.installation_id})
    end
  end

  describe "audit" do
    test "creating the wait records a request event", context do
      {_waiting, approval, _outcome} = waited!(context)

      event =
        Repo.one!(
          from audit in AuditEvent,
            where:
              audit.action == "execution.approval_requested" and
                audit.resource_id == ^approval.id
        )

      assert event.actor_type == "job"
      assert event.metadata["outcome"] == "pending"
      assert event.metadata["next_state"] == "waiting_approval"
    end

    test "an unauthorized authentic click is audited once", context do
      other = insert_member(context.installation, "editor")
      {_waiting, approval, _outcome} = waited!(context)
      interaction = click(approval, other, "approved", context)

      assert {:ok, {:stale, _message}} = ApprovalService.decide(interaction)
      assert {:ok, {:stale, _message}} = ApprovalService.decide(interaction)
      assert Repo.get!(Approval, approval.id).status == "pending"

      events =
        Repo.all(
          from audit in AuditEvent,
            where:
              audit.action == "execution.approval_unauthorized" and
                audit.resource_id == ^approval.id
        )

      assert length(events) == 1
      assert hd(events).actor_id == other.pumble_user_id
      assert hd(events).metadata["result"] == "denied"
    end
  end

  defp waited_with_timeout_branch!(context) do
    stop = stop_node()
    approval_node = approval_for(context.member, timed_out: [stop])
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

  defp claimed!(context, nodes) do
    %{version: version} =
      activate!(context.scope, context.installation_id, definition(nodes))

    {:ok, execution} =
      Engine.create(context.scope, %{
        workflow_version_id: version.id,
        execution_key: "approval-timeout-#{System.unique_integer([:positive])}",
        trigger_snapshot: %{"channel_id" => "channel-1"}
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

  defp timeout_args(%Execution{} = execution, %Approval{} = approval) do
    %{
      "installation_id" => execution.installation_id,
      "execution_id" => execution.id,
      "approval_id" => approval.id,
      "expected_node_id" => execution.current_node_id,
      "generation" => execution.lock_version
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

  defp due_now!(%Approval{} = approval) do
    Repo.update_all(from(a in Approval, where: a.id == ^approval.id),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -2, :second)]
    )
  end

  defp steps_for(execution_id) do
    Repo.all(from s in StepExecution, where: s.execution_id == ^execution_id)
  end
end

defmodule PumbleAutomation.Executions.ApprovalTimeoutRaceTest do
  @moduledoc """
  A due timeout serializes with an authorized click and installation lifecycle
  locks. One terminal decision wins, and a completed uninstall prevents work.
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
  alias PumbleAutomation.Executions.StepExecution
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Installations.Lifecycle
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

  test "concurrent decision and timeout produce one winner" do
    %{installation: installation, member: member} = InstallationsFixtures.install()
    on_exit(fn -> cleanup!(installation.id) end)

    scope = Scope.new(member)
    workspace_id = installation.pumble_workspace_id
    approval_node = approval_for(member, approved: [stop_node()], timed_out: [stop_node()])

    workflow =
      drafted_workflow(installation.id, %{
        draft_definition: Definition.encode(definition([approval_node]))
      })

    {:ok, activated} = Workflows.activate_workflow(scope, workflow.id, 0)

    {:ok, execution} =
      Engine.create(scope, %{
        workflow_version_id: activated.version.id,
        execution_key: "approval-timeout-race-#{System.unique_integer([:positive])}",
        trigger_snapshot: %{"channel_id" => "channel-1"}
      })

    args = %{
      "installation_id" => execution.installation_id,
      "execution_id" => execution.id,
      "expected_node_id" => execution.current_node_id,
      "generation" => execution.lock_version
    }

    {:ok, snapshot} = Engine.claim(args)
    {:ok, outcome} = NodeRunner.run(NodeRunner.input(snapshot))
    {:ok, waiting} = Engine.finalize(snapshot, outcome)
    approval = Repo.get_by!(Approval, execution_id: waiting.id)
    due = DateTime.add(approval.expires_at, 1, :second)
    timeout_args = timeout_args(waiting, approval)
    parent = self()

    tasks = [
      Task.async(fn ->
        send(parent, {:ready, self()})

        receive do
          :go -> ApprovalService.decide(click(approval, member, "approved", workspace_id))
        end
      end),
      Task.async(fn ->
        send(parent, {:ready, self()})

        receive do
          :go -> ApprovalService.timeout(timeout_args, due)
        end
      end)
    ]

    pids =
      Enum.map(1..2, fn _index ->
        receive do
          {:ready, pid} -> pid
        after
          5_000 -> flunk("racer did not reach the barrier")
        end
      end)

    Enum.each(pids, &send(&1, :go))
    _results = Enum.map(tasks, &Task.await(&1, 30_000))

    stored = Repo.get!(Approval, approval.id)
    assert stored.status in ~w(approved timed_out)
    assert Repo.get!(Execution, waiting.id).status in ~w(running completed)
  end

  test "an uninstall that commits while a timeout waits prevents the timeout effect" do
    %{installation: installation, member: member} = InstallationsFixtures.install()
    on_exit(fn -> cleanup!(installation.id) end)

    stop = stop_node()
    scope = Scope.new(member)
    approval_node = approval_for(member, timed_out: [stop])

    workflow =
      drafted_workflow(installation.id, %{
        draft_definition: Definition.encode(definition([approval_node]))
      })

    {:ok, activated} = Workflows.activate_workflow(scope, workflow.id, 0)

    {:ok, execution} =
      Engine.create(scope, %{
        workflow_version_id: activated.version.id,
        execution_key: "approval-timeout-uninstall-race-#{System.unique_integer([:positive])}",
        trigger_snapshot: %{"channel_id" => "channel-1"}
      })

    args = %{
      "installation_id" => execution.installation_id,
      "execution_id" => execution.id,
      "expected_node_id" => execution.current_node_id,
      "generation" => execution.lock_version
    }

    {:ok, snapshot} = Engine.claim(args)
    {:ok, outcome} = NodeRunner.run(NodeRunner.input(snapshot))
    {:ok, waiting} = Engine.finalize(snapshot, outcome)
    approval = Repo.get_by!(Approval, execution_id: waiting.id)
    due = DateTime.add(approval.expires_at, 1, :second)
    parent = self()

    uninstall =
      Task.async(fn ->
        hold_uninstall(parent, installation.id)
      end)

    uninstall_ref = Process.monitor(uninstall.pid)

    assert_receive {:uninstall_ready, uninstall_pid, locker_backend_pid}, 5_000
    assert uninstall_pid == uninstall.pid

    timeout = start_timeout(parent, timeout_args(waiting, approval), due)
    timeout_ref = Process.monitor(timeout.pid)

    assert_receive {:timeout_ready, timeout_pid, timeout_backend_pid}, 5_000
    assert timeout_pid == timeout.pid
    assert_blocked_by!(timeout_backend_pid, locker_backend_pid)
    refute_receive {:DOWN, ^timeout_ref, :process, ^timeout_pid, _reason}, 0

    send(uninstall.pid, :release)

    assert {:ok, %Installation{status: "uninstalled"}} = Task.await(uninstall, 30_000)
    assert :ok = Task.await(timeout, 30_000)
    assert_receive {:DOWN, ^uninstall_ref, :process, ^uninstall_pid, :normal}, 5_000
    assert_receive {:DOWN, ^timeout_ref, :process, ^timeout_pid, :normal}, 5_000

    assert Repo.get!(Approval, approval.id).status == "pending"
    assert Repo.get!(Execution, waiting.id).status == "waiting_approval"

    assert Repo.aggregate(
             from(step in StepExecution,
               where: step.execution_id == ^waiting.id and step.node_id == ^stop.id
             ),
             :count
           ) == 0

    refute_enqueued(
      worker: PumbleAutomation.Executions.Workers.AdvanceExecutionWorker,
      args: %{execution_id: waiting.id, expected_node_id: stop.id}
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

  defp timeout_args(%Execution{} = execution, %Approval{} = approval) do
    %{
      "installation_id" => execution.installation_id,
      "execution_id" => execution.id,
      "approval_id" => approval.id,
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

  defp hold_uninstall(parent, installation_id) do
    Repo.checkout(fn ->
      Repo.transaction(fn ->
        backend_pid = backend_pid()
        {:ok, uninstalled} = Lifecycle.uninstall(installation_id)
        send(parent, {:uninstall_ready, self(), backend_pid})
        await_release!()
        uninstalled
      end)
    end)
  end

  defp start_timeout(parent, args, due) do
    Task.async(fn ->
      Repo.checkout(fn ->
        send(parent, {:timeout_ready, self(), backend_pid()})
        ApprovalService.timeout(args, due)
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
        flunk("timeout backend #{blocked_pid} never blocked behind backend #{locker_pid}")
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
      30_000 -> flunk("uninstall release was not received")
    end
  end

  defp cleanup!(installation_id) do
    Repo.delete_all(
      from j in Oban.Job,
        where: fragment("? ->> 'installation_id' = ?", j.args, ^installation_id)
    )

    InstallationsFixtures.erase!(installation_id)
  end
end
