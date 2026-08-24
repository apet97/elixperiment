defmodule PumbleAutomation.Executions.ApprovalRequestTest do
  @moduledoc """
  Approval waits create a durable row and timeout job, then a separate
  worker posts the Pumble message. Tokens are stored as hashes. Delivery
  never happens inside the finalization transaction.
  """

  use PumbleAutomation.DataCase, async: true
  use Oban.Testing, repo: PumbleAutomation.Repo

  import Ecto.Query, only: [from: 2]
  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Executions.Approval
  alias PumbleAutomation.Executions.ApprovalService
  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.NodeRunner
  alias PumbleAutomation.Executions.Nodes.Approval, as: ApprovalNode
  alias PumbleAutomation.Executions.Workers.ApprovalDeliveryWorker
  alias PumbleAutomation.Executions.Workers.ApprovalTimeoutWorker
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Installations.WorkspaceMember
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Pumble.Blocks
  alias PumbleAutomation.PumbleFake
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.CompiledWorkflow
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

  describe "authorized and unauthorized setup" do
    test "a workspace member id is accepted and the wait is durable", context do
      approval = approval_for(context.member)
      %{snapshot: snapshot, execution: execution} = claimed!(context, [approval])

      assert {:ok, outcome} = NodeRunner.run(NodeRunner.input(snapshot))
      assert outcome.kind == :wait_approval
      assert outcome.output["timeout_seconds"] == 3600
      assert outcome.output["approver_count"] == 1
      refute Map.has_key?(outcome.output, "approver_member_ids")

      assert {:ok, waiting} = Engine.finalize(snapshot, outcome)
      assert waiting.status == "waiting_approval"

      stored = Repo.get_by!(Approval, execution_id: execution.id)
      assert stored.status == "pending"
      assert stored.pumble_channel_id == "channel-1"
      assert is_nil(stored.pumble_message_id)
      assert stored.allowed_approvers["member_ids"] == [context.member.id]
      assert stored.allowed_approvers["pumble_user_ids"] == [context.member.pumble_user_id]
      assert stored.expires_at == outcome.resume_at

      assert_enqueued(
        worker: ApprovalTimeoutWorker,
        args: %{
          execution_id: execution.id,
          expected_node_id: approval.id,
          generation: waiting.lock_version
        }
      )

      assert_enqueued(
        worker: ApprovalDeliveryWorker,
        args: %{
          execution_id: execution.id,
          approval_id: stored.id
        }
      )
    end

    test "a Pumble user id that belongs to this workspace is accepted", context do
      approval =
        approval_for(context.member, approver_member_ids: [context.member.pumble_user_id])

      %{snapshot: snapshot} = claimed!(context, [approval])

      assert {:ok, outcome} = NodeRunner.run(NodeRunner.input(snapshot))
      assert {:ok, waiting} = Engine.finalize(snapshot, outcome)
      assert waiting.status == "waiting_approval"
    end

    test "a member from another workspace fails instead of waiting", context do
      other = InstallationsFixtures.install()
      approval = approval_for(other.member)
      %{snapshot: snapshot, execution: execution} = claimed!(context, [approval])

      assert {:ok, outcome} = NodeRunner.run(NodeRunner.input(snapshot))
      assert {:ok, failed} = Engine.finalize(snapshot, outcome)
      assert failed.status == "failed"
      assert Repo.get_by(Approval, execution_id: execution.id) == nil
      refute_enqueued(worker: ApprovalDeliveryWorker)
    end

    test "a disabled member is refused", context do
      approver = insert_member(context.installation, "editor")

      approver
      |> WorkspaceMember.changeset(%{disabled_at: DateTime.utc_now()})
      |> Repo.update!()

      approval = approval_for(approver)
      %{snapshot: snapshot} = claimed!(context, [approval])

      assert {:ok, outcome} = NodeRunner.run(NodeRunner.input(snapshot))
      assert {:ok, failed} = Engine.finalize(snapshot, outcome)
      assert failed.status == "failed"
      assert Repo.get_by(Approval, execution_id: snapshot.execution_id) == nil
    end

    test "role and group selectors are refused before a wait is created" do
      input = runner_input(%{"timeout_seconds" => 60, "approver_member_ids" => ["owners"]})
      assert {:ok, outcome} = ApprovalNode.run(input)
      assert outcome.kind == :permanent_error
      assert outcome.output["field"] == "approver_member_ids"
    end

    test "a missing channel fails finalization instead of waiting invisibly", context do
      approval = approval_for(context.member)
      %{snapshot: snapshot} = claimed!(context, [approval], %{"data" => %{"text" => "hi"}})

      assert {:ok, outcome} = NodeRunner.run(NodeRunner.input(snapshot))
      assert {:ok, failed} = Engine.finalize(snapshot, outcome)
      assert failed.status == "failed"
    end
  end

  describe "token hash" do
    test "the database stores a digest, not the button payload", context do
      {waiting, approval, outcome} = waited!(context)
      workspace_id = context.workspace_id
      approve = ApprovalService.button_value(approval, "approved", workspace_id)
      reject = ApprovalService.button_value(approval, "rejected", workspace_id)

      assert byte_size(approval.token_digest) == Approval.digest_bytes()

      assert approval.token_digest ==
               ApprovalService.family_digest(
                 approval.public_action_id,
                 workspace_id,
                 approval.expires_at,
                 approval.nonce
               )

      refute inspect(approval) =~ approve
      refute inspect(waiting) =~ approve
      refute inspect(outcome) =~ approve
      assert ApprovalService.bound_value?(approval, "approved", workspace_id, approve)
      assert ApprovalService.bound_value?(approval, "rejected", workspace_id, reject)
      refute ApprovalService.bound_value?(approval, "rejected", workspace_id, approve)
      refute ApprovalService.bound_value?(approval, "approved", "other-workspace", approve)
    end

    test "a payload minted for one approval cannot authorize another", context do
      {_waiting, first, _outcome} = waited!(context)
      {_waiting, second, _outcome} = waited!(context)
      workspace_id = context.workspace_id
      value = ApprovalService.button_value(first, "approved", workspace_id)

      refute ApprovalService.bound_value?(second, "approved", workspace_id, value)
      assert first.token_digest != second.token_digest
      assert first.public_action_id != second.public_action_id
    end
  end

  describe "message send statuses and timeout" do
    test "a confirmed send stores channel and message ids", context do
      PumbleFake.stub_api_routes(self(), [
        {"POST", "/v1/channels/channel-1/messages", 200, @message}
      ])

      {_waiting, approval, _outcome} = waited!(context)

      assert :ok =
               perform_job(ApprovalDeliveryWorker, %{
                 installation_id: approval.installation_id,
                 execution_id: approval.execution_id,
                 approval_id: approval.id
               })

      stored = Repo.get!(Approval, approval.id)
      assert stored.pumble_channel_id == "channel-1"
      assert stored.pumble_message_id == "approval-msg-1"
      assert stored.status == "pending"

      assert_receive {:pumble_api_request, request}
      body = Jason.decode!(request.body)
      assert body["text"] =~ "Approval requested"
      refute body["text"] =~ "bot-access-token"
      [approve, reject] = Enum.at(body["blocks"], 1)["elements"]
      assert approve["value"] != reject["value"]
      assert approve["onAction"] == approval.public_action_id
      refute inspect(Blocks.redact_interactive(body)) =~ approve["value"]
    end

    test "a multibyte prompt clipped at the byte boundary stays valid UTF-8", context do
      PumbleFake.stub_api_routes(self(), [
        {"POST", "/v1/channels/channel-1/messages", 200, @message}
      ])

      prompt = String.duplicate("a", 1_199) <> "😀"
      {_waiting, approval, _outcome} = waited!(context, prompt: prompt)

      assert :ok = perform_job(ApprovalDeliveryWorker, delivery_args(approval))
      assert_receive {:pumble_api_request, request}

      text = Jason.decode!(request.body)["text"]
      assert String.valid?(text)
      assert byte_size(text) <= Blocks.max_text_bytes()
      assert text =~ String.duplicate("a", 1_199)
      refute text =~ "😀"
      assert Repo.get!(Approval, approval.id).pumble_message_id == "approval-msg-1"
    end

    test "401 and 403 fail the wait; 429 retries; timeout pauses", context do
      {_waiting, approval, _outcome} = waited!(context)
      args = delivery_args(approval)

      PumbleFake.stub_api_routes(self(), [
        {"POST", "/v1/channels/channel-1/messages", 401, %{"message" => "no"}}
      ])

      assert :ok = ApprovalService.deliver(args)
      assert Repo.get!(Execution, approval.execution_id).status == "failed"
      assert Repo.get!(Approval, approval.id).status == "cancelled"

      {_waiting, retry_approval, _outcome} = waited!(context)

      PumbleFake.stub_api_routes(self(), [
        {"POST", "/v1/channels/channel-1/messages", 429, %{"message" => "slow"}}
      ])

      result = ApprovalService.deliver(delivery_args(retry_approval))
      assert result in [{:error, :retry}, {:snooze, 1}] or match?({:snooze, _seconds}, result)
      assert Repo.get!(Execution, retry_approval.execution_id).status == "waiting_approval"

      {_waiting, timeout_approval, _outcome} = waited!(context)
      PumbleFake.stub_api(fn conn -> Req.Test.transport_error(conn, :timeout) end)
      assert :ok = ApprovalService.deliver(delivery_args(timeout_approval))
      assert Repo.get!(Execution, timeout_approval.execution_id).status == "paused_uncertain"
      assert Repo.get!(Approval, timeout_approval.id).status == "pending"
    end

    test "retry after an uncertain delivery reuses the pending approval", context do
      {_waiting, approval, _outcome} = waited!(context)
      PumbleFake.stub_api(fn conn -> Req.Test.transport_error(conn, :timeout) end)
      assert :ok = ApprovalService.deliver(delivery_args(approval))

      execution = Repo.get!(Execution, approval.execution_id)
      assert execution.status == "paused_uncertain"

      assert {:ok, retried} =
               Engine.resolve_uncertain(context.scope, execution.id, :retry, %{
                 acknowledge_duplicate_risk: true
               })

      assert retried.status == "running"

      {:ok, snapshot} =
        Engine.claim(%{
          "installation_id" => retried.installation_id,
          "execution_id" => retried.id,
          "expected_node_id" => retried.current_node_id,
          "generation" => retried.lock_version
        })

      assert {:ok, outcome} = NodeRunner.run(NodeRunner.input(snapshot))
      assert {:ok, waiting} = Engine.finalize(snapshot, outcome)
      assert waiting.status == "waiting_approval"
      assert Repo.get!(Approval, approval.id).status == "pending"
    end
  end

  describe "timeout job transaction" do
    test "the timeout job and delivery job commit with the waiting row", context do
      approval = approval_for(context.member)
      %{snapshot: snapshot, execution: execution} = claimed!(context, [approval])
      assert {:ok, outcome} = NodeRunner.run(NodeRunner.input(snapshot))
      assert {:ok, waiting} = Engine.finalize(snapshot, outcome)

      jobs =
        Repo.all(
          from j in Oban.Job, where: fragment("? ->> 'execution_id' = ?", j.args, ^execution.id)
        )

      workers = Enum.map(jobs, & &1.worker) |> Enum.sort()

      assert "PumbleAutomation.Executions.Workers.ApprovalTimeoutWorker" in workers
      assert "PumbleAutomation.Executions.Workers.ApprovalDeliveryWorker" in workers

      timeout =
        Enum.find(jobs, fn job ->
          job.worker == "PumbleAutomation.Executions.Workers.ApprovalTimeoutWorker" and
            job.state == "scheduled"
        end)

      assert timeout
      assert DateTime.diff(timeout.scheduled_at, outcome.resume_at, :second) in -1..1
      assert waiting.status == "waiting_approval"
    end

    test "reconciliation restores a missing delivery job", context do
      {_waiting, approval, _outcome} = waited!(context)

      Repo.delete_all(
        from j in Oban.Job,
          where: j.worker == "PumbleAutomation.Executions.Workers.ApprovalDeliveryWorker"
      )

      assert {:ok, result} = Engine.reconcile(%{"installation_id" => context.installation_id})
      assert result.jobs >= 1
      assert_enqueued(worker: ApprovalDeliveryWorker, args: %{approval_id: approval.id})
    end
  end

  describe "uninstall and cancel before send" do
    test "cancel before send does not post a message", context do
      PumbleFake.stub_api_routes(self(), [
        {"POST", "/v1/channels/channel-1/messages", 200, @message}
      ])

      {waiting, approval, _outcome} = waited!(context)
      assert {:ok, cancelled} = Engine.cancel(context.scope, waiting.id)
      assert cancelled.status == "cancelled"
      assert Repo.get!(Approval, approval.id).status == "cancelled"

      assert :ok = perform_job(ApprovalDeliveryWorker, delivery_args(approval))
      refute_received {:pumble_api_request, _}
      assert is_nil(Repo.get!(Approval, approval.id).pumble_message_id)
    end

    test "uninstall before send does not post a message", context do
      PumbleFake.stub_api_routes(self(), [
        {"POST", "/v1/channels/channel-1/messages", 200, @message}
      ])

      {_waiting, approval, _outcome} = waited!(context)

      context.installation
      |> Installation.changeset(%{status: "uninstalled"})
      |> Repo.update!()

      assert :ok = perform_job(ApprovalDeliveryWorker, delivery_args(approval))
      refute_received {:pumble_api_request, _}
      assert Repo.get!(Execution, approval.execution_id).status == "waiting_approval"
    end
  end

  describe "redacted blocks" do
    test "interactive values are stripped from the operator copy", context do
      {_waiting, approval, _outcome} = waited!(context)
      workspace_id = context.workspace_id
      value = ApprovalService.button_value(approval, "approved", workspace_id)

      {:ok, payload} =
        Blocks.approval_message(
          "Approve this run",
          {"Approve", approval.public_action_id, value},
          {"Reject", approval.public_action_id,
           ApprovalService.button_value(approval, "rejected", workspace_id)}
        )

      redacted = Blocks.redact_interactive(payload)
      refute inspect(redacted) =~ value

      assert get_in(redacted, ["blocks", Access.at(1), "elements", Access.at(0), "value"]) ==
               "[REDACTED]"

      refute inspect(approval) =~ value
    end
  end

  defp waited!(context, approval_opts \\ []) do
    approval_node = approval_for(context.member, approval_opts)
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

  defp runner_input(config) do
    %{
      compiled_node: %{
        type: :approval,
        config: config,
        edges: %{
          "approved" => CompiledWorkflow.end_target(),
          "rejected" => CompiledWorkflow.end_target(),
          "timed_out" => CompiledWorkflow.end_target()
        },
        requires: %{
          "operations" => ["post_message"],
          "scopes" => [],
          "connection_ids" => [],
          "secret_names" => []
        }
      },
      context: %{},
      trigger_snapshot: %{"channel_id" => "channel-1"},
      installation_id: Ecto.UUID.generate(),
      run_mode: "live",
      effect_key: "inst/exec/node",
      attempt: %{id: Ecto.UUID.generate(), number: 1},
      resolver: PumbleAutomation.Connections.Resolver,
      adapters: %{}
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

  defp delivery_args(%Approval{} = approval) do
    %{
      "installation_id" => approval.installation_id,
      "execution_id" => approval.execution_id,
      "approval_id" => approval.id
    }
  end
end

defmodule PumbleAutomation.Executions.ApprovalRequestJobInsertTest do
  @moduledoc """
  Job-insert failure cannot run inside the SQL sandbox: Oban's unique insert
  disconnects the connection when a trigger on `oban_jobs` raises.
  """

  use ExUnit.Case, async: false
  use Oban.Testing, repo: PumbleAutomation.Repo

  import Ecto.Query, only: [from: 2]
  import PumbleAutomation.WorkflowsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Approval
  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.NodeRunner
  alias PumbleAutomation.Executions.StepAttempt
  alias PumbleAutomation.Executions.StepExecution
  alias PumbleAutomation.InstallationsFixtures
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

  test "a rejected approval job insert rolls the waiting transition back" do
    %{installation: installation, member: member} = InstallationsFixtures.install()
    on_exit(fn -> cleanup!(installation.id) end)

    scope = Scope.new(member)

    approval =
      Node.new(:approval, %{
        prompt: "Ship it?",
        approver_member_ids: [member.id],
        timeout_seconds: 60
      })
      |> Node.put_branch(:approved, [stop_node()])

    workflow =
      drafted_workflow(installation.id, %{
        draft_definition: Definition.encode(definition([approval]))
      })

    {:ok, activated} = Workflows.activate_workflow(scope, workflow.id, 0)

    {:ok, execution} =
      Engine.create(scope, %{
        workflow_version_id: activated.version.id,
        execution_key: "approval-jobfail-#{System.unique_integer([:positive])}",
        trigger_snapshot: %{"channel_id" => "channel-1"}
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

    {:ok, outcome} = NodeRunner.run(NodeRunner.input(snapshot))
    assert {:error, %Error{}} = Engine.finalize(snapshot, outcome)

    stored = Repo.get!(Execution, execution.id)
    assert stored.status == "running"
    assert stored.lock_version == snapshot.generation
    assert Repo.get!(StepExecution, snapshot.step_execution_id).status == "running"
    assert Repo.get!(StepAttempt, snapshot.attempt_id).status == "started"
    assert Repo.get_by(Approval, execution_id: execution.id) == nil
  end

  defp reject_job_insert!(execution_id) do
    suffix = System.unique_integer([:positive])
    name = "reject_approval_oban_jobs_#{suffix}"

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
