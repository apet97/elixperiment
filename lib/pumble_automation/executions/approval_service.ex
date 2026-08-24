defmodule PumbleAutomation.Executions.ApprovalService do
  @moduledoc """
  Creates a pending approval, signs button payloads, and accepts decisions.

  Finalization calls `insert_pending/5` inside the same transaction that
  marks the execution `waiting_approval` and inserts the timeout job. The
  Pumble post happens later in `deliver/1`, so a network call never sits
  under a row lock. Tokens are HMAC-bound to the approval, action,
  workspace, and expiry; only a SHA-256 digest is stored.

  `decide/1` is the matching inbound path. A verified block-interaction
  click locks the approval, execution, and step, records one terminal
  decision, follows the compiled approve/reject edge, and enqueues the
  next job in the same transaction. Updating the Pumble message is a
  later best-effort effect and cannot change the decision.

  `timeout/1` is the deadline path. An early job snoozes. A due pending
  wait records `timed_out`, follows the compiled timeout edge or stops,
  and enqueues the next job atomically. Duplicate jobs are a no-op.
  """

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias PumbleAutomation.Audit.AuditEvent
  alias PumbleAutomation.Audit.Writer
  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Approval
  alias PumbleAutomation.Executions.Concurrency
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.Nodes.Pumble
  alias PumbleAutomation.Executions.Outcome
  alias PumbleAutomation.Executions.StateMachine
  alias PumbleAutomation.Executions.StepExecution
  alias PumbleAutomation.Executions.Workers.AdvanceExecutionWorker
  alias PumbleAutomation.FailureInjection
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Installations.Service
  alias PumbleAutomation.Installations.WorkspaceMember
  alias PumbleAutomation.Logging
  alias PumbleAutomation.Pumble.Blocks
  alias PumbleAutomation.Pumble.Client
  alias PumbleAutomation.Pumble.Client.Error, as: ClientError
  alias PumbleAutomation.Pumble.Payload
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows.CompiledWorkflow
  alias PumbleAutomation.Workflows.Workflow
  alias PumbleAutomation.Workflows.WorkflowVersion

  @actions ~w(approved rejected)
  @max_id 128
  @summary_prompt_bytes 1_200
  @lock_timeout "3s"
  @stale_message "This request is no longer waiting."
  @duplicate_message "This request was already decided."
  @telemetry_event [:pumble_automation, :executions, :approval]

  @doc """
  Inserts the pending approval for a wait outcome, or skips a stub wait.

  Live waits must name timeout and approvers. Unknown, disabled, or
  cross-tenant identities are a validation failure so the run does not sit
  in `waiting_approval` with nobody able to click.
  """
  @spec insert_pending(Ecto.Repo.t(), Execution.t(), StepExecution.t(), map(), Outcome.t()) ::
          {:ok, Approval.t()}
          | {:ok, {:existing, Approval.t()}}
          | {:error, :skip}
          | {:error, Error.t()}
  def insert_pending(repo, execution, step, snapshot, %Outcome{} = outcome) do
    if prepared_wait?(outcome) do
      create_pending(repo, execution, step, snapshot, outcome)
    else
      {:error, :skip}
    end
  end

  @doc "HMAC-SHA256 digest stored for the approval family secret."
  @spec family_digest(String.t(), String.t(), DateTime.t(), binary()) :: binary()
  def family_digest(public_action_id, workspace_id, expires_at, nonce)
      when is_binary(public_action_id) and is_binary(workspace_id) and is_binary(nonce) do
    Approval.digest(mac(public_action_id, "*", workspace_id, expires_at, nonce))
  end

  @doc "Opaque button value bound to one approval action."
  @spec button_value(Approval.t(), String.t(), String.t()) :: String.t()
  def button_value(%Approval{} = approval, action, workspace_id)
      when action in @actions and is_binary(workspace_id) do
    mac =
      mac(
        approval.public_action_id,
        action,
        workspace_id,
        approval.expires_at,
        approval.nonce
      )

    approval.public_action_id <> "." <> action <> "." <> Base.url_encode64(mac, padding: false)
  end

  @doc """
  Checks that `value` is the bound payload for `approval` and `action`.

  A payload minted for another approval, action, workspace, or expiry does
  not match. The comparison is constant-time on the MAC.
  """
  @spec bound_value?(Approval.t(), String.t(), String.t(), String.t()) :: boolean()
  def bound_value?(%Approval{} = approval, action, workspace_id, value)
      when is_binary(value) do
    expected = button_value(approval, action, workspace_id)
    byte_size(expected) == byte_size(value) and Plug.Crypto.secure_compare(expected, value)
  end

  def bound_value?(_approval, _action, _workspace_id, _value), do: false

  @doc """
  Posts the prepared approval message, or no-ops when delivery is obsolete.

  Retryable transport waits and retries. Ambiguous writes pause the execution.
  Permanent failures fail the wait so it cannot sit forever with no message.
  """
  @spec deliver(map()) :: :ok | {:error, atom()} | {:snooze, pos_integer()}
  def deliver(args) when is_map(args) do
    with {:ok, ids} <- parse_delivery(args),
         {:ok, context} <- load_delivery(ids) do
      post_approval(context)
    end
  end

  @doc """
  Accepts one verified block-interaction click as an approval decision.

  The caller must already have verified the Pumble signature. The decision
  actor is the callback user, not a value from the button payload. A
  payload that is not an approval token is `:ignored` so slash/picker
  buttons still reach manual-trigger ingestion.
  """
  @spec decide(Payload.BlockInteraction.t()) ::
          {:ok, :ignored}
          | {:ok, {:decided | :duplicate | :stale, String.t()}}
          | {:error, Error.t()}
  def decide(%Payload.BlockInteraction{} = interaction) do
    case parse_click(interaction) do
      {:ok, click} -> commit_click(click)
      :ignored -> {:ok, :ignored}
    end
  end

  @doc "Safe interactive copy when a click cannot change the wait."
  @spec stale_message() :: String.t()
  def stale_message, do: @stale_message

  @doc "Telemetry prefix for approval decision and message-update events."
  @spec telemetry_event() :: [atom()]
  def telemetry_event, do: @telemetry_event

  @doc "Audit attributes for a newly recorded pending approval."
  @spec request_audit(Approval.t(), Execution.t()) :: map()
  def request_audit(%Approval{} = approval, %Execution{} = execution) do
    %{
      installation_id: execution.installation_id,
      actor_type: "job",
      actor_id: "advance_execution_worker",
      action: "execution.approval_requested",
      resource_type: "approval",
      resource_id: approval.id,
      metadata: %{
        "outcome" => "pending",
        "previous_state" => "running",
        "next_state" => "waiting_approval",
        "result" => "ok",
        "source" => "finalize"
      }
    }
  end

  @doc "Audit attributes when an operator or uninstall cancels a pending approval."
  @spec cancelled_audit(Approval.t(), Execution.t(), map()) :: map()
  def cancelled_audit(%Approval{} = approval, %Execution{} = execution, actor)
      when is_map(actor) do
    %{
      installation_id: execution.installation_id,
      actor_type: Map.get(actor, :actor_type) || Map.get(actor, "actor_type") || "system",
      actor_id: Map.get(actor, :actor_id) || Map.get(actor, "actor_id"),
      action: "execution.approval_cancelled",
      resource_type: "approval",
      resource_id: approval.id,
      metadata:
        %{
          "outcome" => "cancelled",
          "previous_state" => "waiting_approval",
          "next_state" => "cancelled",
          "result" => "ok",
          "source" => Map.get(actor, :source) || Map.get(actor, "source") || "cancel",
          "actor_role" => Map.get(actor, :actor_role) || Map.get(actor, "actor_role")
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
    }
  end

  @doc """
  Resolves a due pending approval along the compiled timeout edge.

  `now` is injected so tests can pin the deadline without sleeping. An early
  wake snoozes. Duplicate, cancelled, decided, and uninstalled jobs no-op.
  Clock-missing rows stay pending.
  """
  @spec timeout(map(), DateTime.t()) :: :ok | {:snooze, pos_integer()} | {:error, Error.t()}
  def timeout(args, now \\ DateTime.utc_now())

  def timeout(args, %DateTime{} = now) when is_map(args) do
    case parse_timeout(args) do
      {:ok, ids} ->
        ids
        |> timeout_multi(now)
        |> transact()
        |> finish_timeout()

      :ok ->
        :ok
    end
  end

  defp timeout_multi(ids, now) do
    Multi.new()
    |> Service.as_multi()
    |> Multi.run(:applied, fn repo, _changes -> apply_timeout(repo, ids, now) end)
    |> Multi.merge(&enqueue_decision_followup/1)
  end

  defp apply_timeout(repo, ids, now) do
    repo.query!("SELECT set_config('lock_timeout', $1, true)", [@lock_timeout])

    case repo.one(
           from installation in Installation,
             where: installation.id == ^ids.installation_id,
             lock: "FOR SHARE"
         ) do
      %Installation{status: "active"} = installation ->
        timeout_in_installation(repo, ids, installation, now)

      _other ->
        {:ok, noop_timeout()}
    end
  end

  defp timeout_in_installation(repo, ids, installation, now) do
    with {:ok, execution} <- lock_execution(repo, ids.installation_id, ids.execution_id),
         {:ok, step} <- lock_current_step(repo, execution),
         {:ok, approval} <- lock_approval(repo, ids.installation_id, ids.approval_id) do
      take_timeout(repo, ids, installation, approval, execution, step, now)
    else
      :missing -> {:ok, noop_timeout()}
    end
  end

  defp take_timeout(repo, ids, installation, approval, execution, step, now) do
    case classify_timeout(ids, approval, execution, step, now) do
      :proceed ->
        persist_and_advance(
          repo,
          %{action: "timed_out", actor_id: nil, source: "timeout_worker"},
          installation,
          approval,
          execution,
          step
        )

      {:snooze, seconds} ->
        {:error, {:snooze, seconds}}

      :noop ->
        {:ok, noop_timeout()}
    end
  end

  defp classify_timeout(ids, approval, execution, step, now) do
    cond do
      approval.status != "pending" ->
        :noop

      not waiting_for_decision?(execution, step) ->
        :noop

      timeout_stale_job?(ids, execution) ->
        :noop

      match?(%DateTime{}, approval.expires_at) != true ->
        :noop

      DateTime.compare(now, approval.expires_at) == :lt ->
        {:snooze, max(1, DateTime.diff(approval.expires_at, now, :second))}

      true ->
        :proceed
    end
  end

  defp timeout_stale_job?(ids, execution) do
    node_mismatch?(ids, execution) or generation_mismatch?(ids, execution)
  end

  defp node_mismatch?(%{expected_node_id: node_id}, execution)
       when is_binary(node_id) and node_id != "" do
    execution.current_node_id != node_id
  end

  defp node_mismatch?(_ids, _execution), do: false

  defp generation_mismatch?(%{generation: generation}, execution) when is_integer(generation) do
    execution.lock_version != generation
  end

  defp generation_mismatch?(%{generation: generation}, execution) when is_binary(generation) do
    case Integer.parse(generation) do
      {value, ""} -> execution.lock_version != value
      _invalid -> true
    end
  end

  defp generation_mismatch?(_ids, _execution), do: false

  defp noop_timeout, do: %{result: :noop, job: nil, wake: []}

  defp parse_timeout(args) do
    with {:ok, installation_id} <- uuid(args, :installation_id),
         {:ok, execution_id} <- uuid(args, :execution_id),
         {:ok, approval_id} <- uuid(args, :approval_id) do
      {:ok,
       %{
         installation_id: installation_id,
         execution_id: execution_id,
         approval_id: approval_id,
         expected_node_id: Map.get(args, :expected_node_id) || Map.get(args, "expected_node_id"),
         generation: Map.get(args, :generation) || Map.get(args, "generation")
       }}
    else
      _invalid -> :ok
    end
  end

  defp prepared_wait?(%Outcome{kind: :wait_approval, output: output}) when is_map(output) do
    Map.has_key?(output, "timeout_seconds")
  end

  defp prepared_wait?(_outcome), do: false

  defp create_pending(repo, execution, step, snapshot, outcome) do
    with {:ok, installation} <- load_installation(repo, execution.installation_id),
         {:ok, approvers} <-
           resolve_approvers(repo, execution.installation_id, compiled_approver_ids(snapshot)),
         {:ok, channel_id} <- require_channel(outcome.output, snapshot) do
      insert_row(repo, execution, step, installation, approvers, channel_id, outcome)
    end
  end

  defp compiled_approver_ids(%{compiled_node: %{config: config}}) when is_map(config) do
    config["approver_member_ids"] || []
  end

  defp compiled_approver_ids(_snapshot), do: []

  defp load_installation(repo, installation_id) do
    query =
      from installation in Installation,
        where: installation.id == ^installation_id,
        select: %{id: installation.id, pumble_workspace_id: installation.pumble_workspace_id}

    case repo.one(query) do
      %{pumble_workspace_id: workspace_id} = installation
      when is_binary(workspace_id) and workspace_id != "" ->
        {:ok, installation}

      _missing ->
        {:error,
         Error.new(:validation, :unauthorized_approvers,
           message: "The approval names an approver this workspace cannot use."
         )}
    end
  end

  defp resolve_approvers(repo, installation_id, ids) when is_list(ids) and ids != [] do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case resolve_approver(repo, installation_id, id) do
        {:ok, member} -> {:cont, {:ok, [member | acc]}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, members} -> {:ok, Enum.reverse(members)}
      other -> other
    end
  end

  defp resolve_approvers(_repo, _installation_id, _ids) do
    {:error,
     Error.new(:validation, :no_approvers,
       message: "The approval step does not name an approver.",
       details: %{field: "approver_member_ids"}
     )}
  end

  defp resolve_approver(repo, installation_id, id) when is_binary(id) do
    query =
      from member in WorkspaceMember,
        where: member.installation_id == ^installation_id,
        where: is_nil(member.disabled_at),
        where: member.id == ^id or member.pumble_user_id == ^id,
        limit: 1

    case Ecto.UUID.cast(id) do
      {:ok, _uuid} -> repo.one(query)
      :error -> repo.one(by_pumble_user(installation_id, id))
    end
    |> case do
      %WorkspaceMember{} = member ->
        {:ok, member}

      nil ->
        {:error,
         Error.new(:validation, :unauthorized_approvers,
           message: "The approval names an approver this workspace cannot use.",
           details: %{field: "approver_member_ids"}
         )}
    end
  end

  defp resolve_approver(_repo, _installation_id, _id) do
    {:error,
     Error.new(:validation, :unauthorized_approvers,
       message: "The approval names an approver this workspace cannot use.",
       details: %{field: "approver_member_ids"}
     )}
  end

  defp by_pumble_user(installation_id, pumble_user_id) do
    from member in WorkspaceMember,
      where: member.installation_id == ^installation_id,
      where: is_nil(member.disabled_at),
      where: member.pumble_user_id == ^pumble_user_id,
      limit: 1
  end

  defp require_channel(output, snapshot) do
    case output["channel_id"] || snapshot_channel(snapshot) do
      id when is_binary(id) and id != "" ->
        if Regex.match?(~r/\A[A-Za-z0-9_-]{1,64}\z/, id) do
          {:ok, id}
        else
          {:error,
           Error.new(:validation, :invalid_pumble_target,
             message: "The approval has no Pumble channel.",
             details: %{field: "channel_id"}
           )}
        end

      _missing ->
        {:error,
         Error.new(:validation, :invalid_pumble_target,
           message: "The approval has no Pumble channel.",
           details: %{field: "channel_id"}
         )}
    end
  end

  defp snapshot_channel(%{trigger_snapshot: snapshot}) when is_map(snapshot) do
    data = Map.get(snapshot, "data")
    Map.get(snapshot, "channel_id") || (is_map(data) && Map.get(data, "channel_id"))
  end

  defp snapshot_channel(_snapshot), do: nil

  defp insert_row(repo, execution, step, installation, members, channel_id, outcome) do
    case pending_for_step(repo, step.id) do
      %Approval{} = approval ->
        {:ok, {:existing, approval}}

      nil ->
        public_action_id = Ecto.UUID.generate()
        nonce = :crypto.strong_rand_bytes(Approval.nonce_bytes())
        expires_at = expiry(outcome)
        workspace_id = installation.pumble_workspace_id

        attrs = %{
          installation_id: execution.installation_id,
          execution_id: execution.id,
          step_execution_id: step.id,
          public_action_id: public_action_id,
          token_digest: family_digest(public_action_id, workspace_id, expires_at, nonce),
          nonce: nonce,
          allowed_approvers: allowed_approvers(members),
          pumble_channel_id: channel_id,
          expires_at: expires_at
        }

        insert_fresh(repo, attrs, step)
    end
  end

  # Nested transaction so a unique race rolls back only this insert. A
  # constraint error on the finalize connection would abort the wait.
  defp insert_fresh(repo, attrs, step) do
    changeset = Approval.changeset(%Approval{}, attrs)

    case repo.transaction(fn -> repo.insert(changeset) end) do
      {:ok, {:ok, approval}} ->
        {:ok, approval}

      {:ok, {:error, changeset}} ->
        reuse_or_invalid(repo, step, changeset)

      {:error, _reason} ->
        reuse_pending(repo, step)
    end
  end

  defp pending_for_step(repo, step_id) do
    repo.one(
      from approval in Approval,
        where: approval.step_execution_id == ^step_id and approval.status == "pending"
    )
  end

  defp reuse_or_invalid(repo, step, changeset) do
    if unique_step_taken?(changeset) do
      reuse_pending(repo, step)
    else
      {:error,
       Error.new(:validation, :invalid_approval,
         message: "The approval could not be recorded.",
         details: %{errors: inspect(changeset.errors)}
       )}
    end
  end

  defp unique_step_taken?(changeset) do
    Keyword.has_key?(changeset.errors, :step_execution_id)
  end

  defp reuse_pending(repo, step) do
    case pending_for_step(repo, step.id) do
      %Approval{} = approval ->
        {:ok, {:existing, approval}}

      nil ->
        {:error,
         Error.new(:validation, :invalid_approval, message: "The approval could not be recorded.")}
    end
  end

  defp allowed_approvers(members) do
    %{
      "member_ids" => Enum.map(members, & &1.id),
      "pumble_user_ids" => Enum.map(members, & &1.pumble_user_id)
    }
  end

  defp expiry(%Outcome{resume_at: %DateTime{} = resume_at}), do: resume_at

  defp expiry(%Outcome{output: %{"timeout_seconds" => seconds}}) when is_integer(seconds) do
    DateTime.add(DateTime.utc_now(), seconds, :second)
  end

  defp expiry(_outcome), do: DateTime.add(DateTime.utc_now(), 3600, :second)

  defp parse_delivery(args) do
    with {:ok, installation_id} <- uuid(args, :installation_id),
         {:ok, execution_id} <- uuid(args, :execution_id),
         {:ok, approval_id} <- uuid(args, :approval_id) do
      {:ok,
       %{
         installation_id: installation_id,
         execution_id: execution_id,
         approval_id: approval_id
       }}
    else
      _invalid -> :ok
    end
  end

  defp uuid(attrs, field) do
    value = Map.get(attrs, field) || Map.get(attrs, Atom.to_string(field))

    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> :error
    end
  end

  defp load_delivery(ids) do
    case loaded_rows(ids) do
      {:ok, context} -> ready_to_deliver(context)
      :ok -> :ok
    end
  end

  defp loaded_rows(ids) do
    approval =
      Repo.one(
        from approval in Approval,
          where:
            approval.id == ^ids.approval_id and
              approval.installation_id == ^ids.installation_id and
              approval.execution_id == ^ids.execution_id
      )

    execution =
      Repo.one(
        from execution in Execution,
          where:
            execution.id == ^ids.execution_id and
              execution.installation_id == ^ids.installation_id
      )

    installation =
      Repo.one(
        from installation in Installation,
          where: installation.id == ^ids.installation_id
      )

    if approval && execution && installation do
      {:ok, %{approval: approval, execution: execution, installation: installation}}
    else
      Scope.record_if_foreign(Approval, ids.approval_id, ids.installation_id, :approvals)
      :ok
    end
  end

  defp ready_to_deliver(
         %{approval: approval, execution: execution, installation: installation} = context
       ) do
    if pending_unsent?(approval) and waiting?(execution) and installation.status == "active" do
      {:ok, context}
    else
      :ok
    end
  end

  defp pending_unsent?(%Approval{status: "pending", pumble_message_id: id})
       when id in [nil, ""] do
    true
  end

  defp pending_unsent?(_approval), do: false

  defp waiting?(%Execution{status: "waiting_approval", cancelled_at: nil}), do: true
  defp waiting?(_execution), do: false

  defp post_approval(%{approval: approval, execution: execution, installation: installation}) do
    workspace_id = installation.pumble_workspace_id
    channel_id = approval.pumble_channel_id

    with {:ok, text} <- summary_text(approval, execution),
         {:ok, payload} <-
           Blocks.approval_message(
             text,
             {"Approve", approval.public_action_id,
              button_value(approval, "approved", workspace_id)},
             {"Reject", approval.public_action_id,
              button_value(approval, "rejected", workspace_id)}
           ) do
      client = Client.new(execution.installation_id, :bot, correlation_id: execution.id)

      case Client.post_message(client, channel_id, payload) do
        {:ok, response} ->
          confirm_delivery(approval, channel_id, response)

        {:error, %ClientError{} = error} ->
          handle_send_error(error, execution, approval)
      end
    else
      {:error, %ClientError{}} -> halt_delivery(execution, approval, :fail, "validation")
    end
  end

  defp summary_text(%Approval{} = approval, %Execution{} = execution) do
    name = workflow_title(execution)
    deadline = DateTime.to_iso8601(approval.expires_at)
    prompt = prompt_text(approval, execution)
    short_id = String.slice(execution.id, 0, 8)

    text =
      "Approval requested for #{name} (execution #{short_id}). Deadline: #{deadline}. #{prompt}"

    {:ok, clip(text, Blocks.max_text_bytes())}
  end

  defp workflow_title(%Execution{} = execution) do
    query =
      from workflow in Workflow,
        where:
          workflow.id == ^execution.workflow_id and
            workflow.installation_id == ^execution.installation_id,
        select: workflow.name

    case Repo.one(query) do
      name when is_binary(name) and name != "" -> name
      _missing -> "workflow"
    end
  end

  defp prompt_text(%Approval{}, %Execution{} = execution) do
    query =
      from step in StepExecution,
        where:
          step.execution_id == ^execution.id and
            step.installation_id == ^execution.installation_id and
            step.node_id == ^execution.current_node_id,
        select: step.output,
        limit: 1

    case Repo.one(query) do
      %{"prompt" => prompt} when is_binary(prompt) and prompt != "" ->
        clip(prompt, @summary_prompt_bytes)

      _missing ->
        "This workflow needs your approval."
    end
  end

  defp confirm_delivery(%Approval{} = approval, channel_id, response) do
    message_id = provider_message_id(response) || "unknown"

    case Approval.record_message(approval, %{
           pumble_channel_id: channel_id,
           pumble_message_id: clip(message_id, @max_id)
         }) do
      {:ok, _approval} -> :ok
      {:error, %Error{code: :approval_not_pending}} -> :ok
      {:error, %Error{}} -> :ok
    end
  end

  defp handle_send_error(%ClientError{} = error, execution, approval) do
    {:ok, outcome} = Pumble.from_client(error, %{effect_key: execution.id})

    case outcome.kind do
      :retryable_error -> retry_delivery(outcome)
      :uncertain -> halt_delivery(execution, approval, :pause_uncertain, outcome.error_class)
      _other -> halt_delivery(execution, approval, :fail, outcome.error_class)
    end
  end

  defp retry_delivery(%Outcome{output: %{"retry_after" => seconds}})
       when is_integer(seconds) and seconds > 0 do
    {:snooze, seconds}
  end

  defp retry_delivery(_outcome), do: {:error, :retry}

  defp halt_delivery(%Execution{} = execution, %Approval{} = approval, command, reason) do
    multi =
      Multi.new()
      |> Service.as_multi()
      |> Multi.run(:halted, fn repo, _changes ->
        apply_halt(repo, execution, approval, command, reason)
      end)
      |> Multi.merge(&enqueue_wake/1)

    case Repo.transaction(multi) do
      {:ok, _changes} -> :ok
      {:error, _step, _reason, _changes} -> :ok
    end
  end

  defp apply_halt(repo, execution, approval, command, reason) do
    query =
      from stored in Execution,
        where:
          stored.id == ^execution.id and stored.installation_id == ^execution.installation_id,
        lock: "FOR UPDATE"

    case repo.one(query) do
      %Execution{status: "waiting_approval"} = locked ->
        persist_halt(repo, locked, approval, command, reason)

      %Execution{} ->
        {:ok, %{wake: []}}

      nil ->
        {:ok, %{wake: []}}
    end
  end

  defp persist_halt(repo, execution, approval, command, reason) do
    with {:ok, exec_plan} <- StateMachine.transition(:execution, execution.status, command),
         {:ok, _approvals} <- maybe_cancel_approval(repo, approval, command),
         {:ok, _step} <- halt_step(repo, execution, exec_plan.to, command, reason),
         {:ok, updated} <- halt_execution(repo, execution, exec_plan.to, reason) do
      wake =
        if command == :fail, do: Concurrency.admissions(repo, updated.installation_id), else: []

      {:ok, %{execution: updated, wake: wake}}
    end
  end

  defp maybe_cancel_approval(repo, %Approval{} = approval, :fail) do
    query =
      from stored in Approval,
        where: stored.id == ^approval.id and stored.status == "pending"

    {_count, rows} =
      repo.update_all(query,
        set: Approval.cancel_set(DateTime.utc_now()),
        inc: [lock_version: 1]
      )

    {:ok, rows}
  end

  defp maybe_cancel_approval(_repo, _approval, _command), do: {:ok, []}

  defp halt_step(repo, execution, to, command, reason) do
    query =
      from step in StepExecution,
        where:
          step.execution_id == ^execution.id and
            step.installation_id == ^execution.installation_id and
            step.node_id == ^execution.current_node_id,
        lock: "FOR UPDATE"

    case repo.one(query) do
      %StepExecution{} = step ->
        attrs =
          %{status: to}
          |> maybe_uncertainty(command, reason)

        step
        |> StepExecution.changeset(attrs)
        |> repo.update()
        |> case do
          {:ok, updated} -> {:ok, updated}
          {:error, _changeset} -> {:error, halt_failed()}
        end

      nil ->
        {:ok, nil}
    end
  end

  defp maybe_uncertainty(attrs, :pause_uncertain, reason) do
    Map.put(attrs, :uncertainty_reason, clip(reason, 500))
  end

  defp maybe_uncertainty(attrs, _command, _reason), do: attrs

  defp halt_execution(repo, execution, to, _reason) do
    execution
    |> Execution.changeset(%{status: to, lock_version: execution.lock_version + 1})
    |> repo.update()
    |> case do
      {:ok, updated} -> {:ok, updated}
      {:error, _changeset} -> {:error, halt_failed()}
    end
  end

  defp enqueue_wake(%{halted: %{wake: wake}}) when is_list(wake) and wake != [] do
    wake
    |> Enum.with_index()
    |> Enum.reduce(Multi.new() |> Service.as_multi(), fn {execution, index}, multi ->
      PumbleAutomation.Oban.insert(multi, {:wake, index}, fn _changes ->
        AdvanceExecutionWorker.new(%{
          installation_id: execution.installation_id,
          execution_id: execution.id,
          expected_node_id: execution.current_node_id,
          generation: execution.lock_version
        })
      end)
    end)
  end

  defp enqueue_wake(_changes), do: Multi.new() |> Service.as_multi()

  defp mac(public_action_id, action, workspace_id, expires_at, nonce) do
    :crypto.mac(
      :hmac,
      :sha256,
      signing_key(),
      public_action_id <>
        "\n" <>
        action <>
        "\n" <>
        workspace_id <>
        "\n" <>
        Integer.to_string(DateTime.to_unix(expires_at, :microsecond)) <>
        "\n" <> nonce
    )
  end

  defp signing_key do
    Application.fetch_env!(:pumble_automation, PumbleAutomationWeb.Endpoint)
    |> Keyword.fetch!(:secret_key_base)
  end

  defp provider_message_id(%{"id" => id}) when is_binary(id) and id != "", do: id
  defp provider_message_id(%{"message" => %{"id" => id}}) when is_binary(id) and id != "", do: id
  defp provider_message_id(_response), do: nil

  defp clip(value, max) when is_binary(value) do
    value
    |> binary_part(0, min(byte_size(value), max))
    |> trim_partial_codepoint()
  end

  defp clip(_value, _max), do: ""

  defp trim_partial_codepoint(value) do
    if String.valid?(value) do
      value
    else
      value
      |> binary_part(0, byte_size(value) - 1)
      |> trim_partial_codepoint()
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp parse_click(%Payload.BlockInteraction{payload: value} = interaction)
       when is_binary(value) do
    case String.split(value, ".", parts: 3) do
      [public_action_id, action, mac] when action in @actions and mac != "" ->
        parse_click_id(public_action_id, action, value, interaction)

      _other ->
        :ignored
    end
  end

  defp parse_click(_interaction), do: :ignored

  defp parse_click_id(public_action_id, action, value, interaction) do
    case Ecto.UUID.cast(public_action_id) do
      {:ok, id} ->
        {:ok,
         %{
           public_action_id: id,
           action: action,
           value: value,
           actor_id: interaction.user_id,
           workspace_id: interaction.workspace_id,
           channel_id: interaction.channel_id,
           source_id: interaction.source_id,
           on_action: interaction.on_action
         }}

      :error ->
        :ignored
    end
  end

  defp commit_click(click) do
    FailureInjection.crash(:approval_decision)

    click
    |> decision_multi()
    |> transact()
    |> finish_decision()
  end

  defp decision_multi(click) do
    Multi.new()
    |> Service.as_multi()
    |> Multi.run(:applied, fn repo, _changes -> apply_decision(repo, click) end)
    |> Multi.merge(&enqueue_decision_followup/1)
  end

  defp apply_decision(repo, click) do
    repo.query!("SELECT set_config('lock_timeout', $1, true)", [@lock_timeout])

    case installation_for_workspace(repo, click.workspace_id) do
      {:ok, installation} -> decide_in_workspace(repo, click, installation)
      :error -> {:ok, stale_result()}
    end
  end

  defp installation_for_workspace(repo, workspace_id) do
    query =
      from installation in Installation,
        where: installation.pumble_workspace_id == ^workspace_id,
        lock: "FOR SHARE"

    case repo.one(query) do
      %Installation{} = installation -> {:ok, installation}
      nil -> :error
    end
  end

  defp decide_in_workspace(repo, click, installation) do
    case approval_by_public_id(repo, installation.id, click.public_action_id) do
      %Approval{} = approval -> lock_and_classify(repo, click, installation, approval)
      nil -> {:ok, stale_result()}
    end
  end

  defp approval_by_public_id(repo, installation_id, public_action_id) do
    repo.one(
      from approval in Approval,
        where:
          approval.public_action_id == ^public_action_id and
            approval.installation_id == ^installation_id
    )
  end

  defp lock_and_classify(repo, click, installation, approval) do
    with {:ok, execution} <- lock_execution(repo, installation.id, approval.execution_id),
         {:ok, step} <- lock_current_step(repo, execution),
         {:ok, locked} <- lock_approval(repo, installation.id, approval.id) do
      take_classified(repo, click, installation, locked, execution, step)
    else
      :missing -> {:ok, stale_result()}
    end
  end

  defp lock_execution(repo, installation_id, execution_id) do
    query =
      from execution in Execution,
        where: execution.id == ^execution_id and execution.installation_id == ^installation_id,
        lock: "FOR UPDATE"

    case repo.one(query) do
      %Execution{} = execution ->
        {:ok, execution}

      nil ->
        Scope.record_if_foreign(Execution, execution_id, installation_id, :approvals)
        :missing
    end
  end

  defp lock_current_step(repo, %Execution{} = execution) do
    query =
      from step in StepExecution,
        where:
          step.execution_id == ^execution.id and
            step.installation_id == ^execution.installation_id and
            step.node_id == ^execution.current_node_id,
        lock: "FOR UPDATE"

    case repo.one(query) do
      %StepExecution{} = step -> {:ok, step}
      nil -> :missing
    end
  end

  defp lock_approval(repo, installation_id, approval_id) do
    query =
      from approval in Approval,
        where: approval.id == ^approval_id and approval.installation_id == ^installation_id,
        lock: "FOR UPDATE"

    case repo.one(query) do
      %Approval{} = approval ->
        {:ok, approval}

      nil ->
        Scope.record_if_foreign(Approval, approval_id, installation_id, :approvals)
        :missing
    end
  end

  defp take_classified(repo, click, installation, approval, execution, step) do
    case classify_click(repo, click, installation, approval, execution, step) do
      :proceed -> persist_and_advance(repo, click, installation, approval, execution, step)
      :duplicate -> {:ok, duplicate_result()}
      :unauthorized -> {:ok, unauthorized_result(repo, click, approval, execution)}
      :stale -> {:ok, stale_result()}
    end
  end

  defp classify_click(repo, click, installation, approval, execution, step) do
    cond do
      installation.status != "active" ->
        :stale

      not authentic_click?(click, approval) ->
        :stale

      not allowed_actor?(repo, approval, click.actor_id) ->
        :unauthorized

      approval.status == "pending" ->
        classify_pending(approval, execution, step)

      approval.status == click.action ->
        :duplicate

      true ->
        :stale
    end
  end

  defp authentic_click?(click, approval) do
    click.on_action == approval.public_action_id and authentic_token?(approval, click)
  end

  defp classify_pending(approval, execution, step) do
    if expired?(approval) or not waiting_for_decision?(execution, step) do
      :stale
    else
      :proceed
    end
  end

  defp waiting_for_decision?(%Execution{} = execution, %StepExecution{} = step) do
    execution.status == "waiting_approval" and is_nil(execution.cancelled_at) and
      step.status == "waiting_approval"
  end

  defp expired?(%Approval{expires_at: %DateTime{} = expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) != :lt
  end

  defp expired?(_approval), do: true

  defp authentic_token?(%Approval{} = approval, click) do
    workspace_id = click.workspace_id

    expected =
      family_digest(
        approval.public_action_id,
        workspace_id,
        approval.expires_at,
        approval.nonce
      )

    byte_size(approval.token_digest) == byte_size(expected) and
      Plug.Crypto.secure_compare(approval.token_digest, expected) and
      bound_value?(approval, click.action, workspace_id, click.value)
  end

  defp allowed_actor?(repo, %Approval{} = approval, actor_id) when is_binary(actor_id) do
    case member_id_for(approval, actor_id) do
      member_id when is_binary(member_id) ->
        query =
          from member in WorkspaceMember,
            where:
              member.id == ^member_id and
                member.installation_id == ^approval.installation_id and
                member.pumble_user_id == ^actor_id and is_nil(member.disabled_at),
            lock: "FOR SHARE"

        match?(%WorkspaceMember{}, repo.one(query))

      _missing ->
        false
    end
  end

  defp allowed_actor?(_repo, _approval, _actor_id), do: false

  defp persist_and_advance(repo, decision, installation, approval, execution, step) do
    with {:ok, compiled} <- load_compiled(repo, execution),
         {:ok, plan} <- advance_plan(execution, step, compiled, decision.action) do
      case persist_decision(repo, approval, decision) do
        {:ok, decided} ->
          complete_advance(repo, decision, installation, decided, execution, step, compiled, plan)

        {:lost, result} ->
          {:ok, result}
      end
    else
      {:error, %Error{code: :unknown_outcome_label}} ->
        fail_after_timeout(repo, decision, installation, approval, execution, step)

      {:error, %Error{}} = error ->
        error
    end
  end

  defp complete_advance(repo, decision, installation, decided, execution, step, compiled, plan) do
    with {:ok, _step} <- complete_step(repo, step, decision, plan),
         {:ok, updated} <- finish_wait_execution(repo, execution, plan),
         {:ok, _next} <- insert_next_step(repo, updated, compiled, plan) do
      {:ok, decided_result(repo, decision, installation, decided, updated, plan)}
    end
  end

  defp fail_after_timeout(repo, decision, installation, approval, execution, step) do
    if decision.action == "timed_out" do
      plan = fail_timeout_plan(execution)

      case persist_decision(repo, approval, decision) do
        {:ok, decided} ->
          complete_advance(repo, decision, installation, decided, execution, step, %{}, plan)

        {:lost, result} ->
          {:ok, result}
      end
    else
      {:error, compiled_missing()}
    end
  end

  defp fail_timeout_plan(execution) do
    %{
      execution_to: "failed",
      step_to: "failed",
      current_node_id: execution.current_node_id,
      insert_next?: false,
      selected_edge: "timed_out",
      job: nil
    }
  end

  defp load_compiled(repo, %Execution{} = execution) do
    query =
      from version in WorkflowVersion,
        where:
          version.id == ^execution.workflow_version_id and
            version.installation_id == ^execution.installation_id

    case repo.one(query) do
      %WorkflowVersion{} = version -> CompiledWorkflow.decode(version.compiled_definition)
      nil -> {:error, compiled_missing()}
    end
  end

  defp advance_plan(execution, step, %CompiledWorkflow{} = compiled, action) do
    node = Map.get(compiled.nodes, execution.current_node_id)

    with :ok <- approval_node(node),
         {:ok, _resume} <- StateMachine.transition(:execution, execution.status, :resume),
         {:ok, _step_resume} <- StateMachine.transition(:step, step.status, :resume),
         {:ok, followed} <- Outcome.follow(node.edges, action) do
      {:ok, plan_for_edge(execution, action, followed)}
    else
      {:error, %Error{} = error} -> {:error, error}
      :error -> {:error, compiled_missing()}
    end
  end

  defp approval_node(%{type: :approval}), do: :ok
  defp approval_node(_node), do: :error

  defp plan_for_edge(execution, action, :end) do
    %{
      execution_to: "completed",
      step_to: "completed",
      current_node_id: execution.current_node_id,
      insert_next?: false,
      selected_edge: action,
      job: nil
    }
  end

  defp plan_for_edge(execution, action, {:continue, next_id}) do
    generation = execution.lock_version + 1

    %{
      execution_to: "running",
      step_to: "completed",
      current_node_id: next_id,
      insert_next?: true,
      selected_edge: action,
      job: %{
        args: %{
          installation_id: execution.installation_id,
          execution_id: execution.id,
          expected_node_id: next_id,
          generation: generation
        },
        opts: []
      }
    }
  end

  defp persist_decision(repo, %Approval{} = approval, decision) do
    now = DateTime.utc_now()
    actor_id = Map.get(decision, :actor_id)

    query =
      from stored in Approval,
        where:
          stored.id == ^approval.id and stored.status == "pending" and
            stored.lock_version == ^approval.lock_version,
        select: stored

    case repo.update_all(query,
           set: [
             status: decision.action,
             decided_at: now,
             decided_by_pumble_user_id: actor_id,
             decided_by_member_id: member_id_for(approval, actor_id),
             lock_version: approval.lock_version + 1,
             updated_at: now
           ]
         ) do
      {1, [row]} -> {:ok, row}
      {0, _rows} -> {:lost, lost_race_result(repo, approval.id, decision.action)}
    end
  end

  defp lost_race_result(repo, approval_id, action) do
    case repo.one(from stored in Approval, where: stored.id == ^approval_id) do
      %Approval{status: ^action} -> duplicate_result()
      _other -> stale_result()
    end
  end

  defp member_id_for(%Approval{allowed_approvers: approvers}, actor_id) when is_map(approvers) do
    users = List.wrap(Map.get(approvers, "pumble_user_ids"))
    ids = List.wrap(Map.get(approvers, "member_ids"))

    users
    |> Enum.zip(ids)
    |> Enum.find_value(fn {user_id, member_id} -> user_id == actor_id && member_id end)
  end

  defp member_id_for(_approval, _actor_id), do: nil

  defp complete_step(repo, %StepExecution{} = step, decision, plan) do
    output =
      (step.output || %{})
      |> Map.merge(%{
        "decision" => decision.action,
        "decided_at" => DateTime.to_iso8601(DateTime.utc_now())
      })
      |> put_present("decided_by_pumble_user_id", Map.get(decision, :actor_id))

    step
    |> StepExecution.changeset(%{
      status: plan.step_to,
      output: output,
      selected_edge: plan.selected_edge
    })
    |> repo.update()
    |> case do
      {:ok, updated} -> {:ok, updated}
      {:error, _changeset} -> {:error, decision_failed()}
    end
  end

  defp finish_wait_execution(repo, %Execution{} = execution, plan) do
    execution
    |> Execution.changeset(%{
      status: plan.execution_to,
      current_node_id: plan.current_node_id,
      lock_version: execution.lock_version + 1
    })
    |> repo.update()
    |> case do
      {:ok, updated} -> {:ok, updated}
      {:error, _changeset} -> {:error, decision_failed()}
    end
  end

  defp insert_next_step(_repo, _execution, _compiled, %{insert_next?: false}), do: {:ok, nil}

  defp insert_next_step(repo, execution, compiled, %{insert_next?: true}) do
    case Map.fetch(compiled.nodes, execution.current_node_id) do
      {:ok, node} ->
        %StepExecution{}
        |> StepExecution.changeset(%{
          installation_id: execution.installation_id,
          execution_id: execution.id,
          node_id: execution.current_node_id,
          node_type: Atom.to_string(node.type),
          status: "queued"
        })
        |> repo.insert()
        |> case do
          {:ok, step} -> {:ok, step}
          {:error, _changeset} -> {:error, decision_failed()}
        end

      :error ->
        {:error, compiled_missing()}
    end
  end

  defp decided_result(repo, decision, installation, %Approval{} = approval, execution, plan) do
    wake =
      if Execution.terminal?(execution.status) do
        Concurrency.admissions(repo, execution.installation_id)
      else
        []
      end

    %{
      result: result_for(decision.action),
      message: decided_message(decision.action),
      action: decision.action,
      approval: approval,
      execution: execution,
      installation: installation,
      job: plan.job,
      wake: wake,
      audit: decision_audit(decision, approval, execution)
    }
  end

  defp log_decision(applied) when is_map(applied) do
    execution = Map.get(applied, :execution)
    approval = Map.get(applied, :approval)
    installation = Map.get(applied, :installation)

    Logging.event(:info, "approval.decision", %{
      operation: "approval.decision",
      event_type: "approval",
      status: Map.get(applied, :result) || Map.get(applied, :action),
      installation_id: logging_id(installation) || (execution && execution.installation_id),
      execution_id: execution && execution.id,
      workflow_id: execution && execution.workflow_id,
      version_id: execution && execution.workflow_version_id,
      step_id: approval && approval.step_execution_id
    })
  end

  defp logging_id(%Installation{id: id}), do: id
  defp logging_id(_other), do: nil

  defp result_for("timed_out"), do: :timed_out
  defp result_for(_action), do: :decided

  defp decided_message("approved"), do: "Approved."
  defp decided_message("rejected"), do: "Rejected."
  defp decided_message("timed_out"), do: "This request timed out."
  defp decided_message(_action), do: @stale_message

  defp decision_audit(decision, approval, execution) do
    source = Map.get(decision, :source) || "pumble_callback"
    timed_out? = decision.action == "timed_out"

    %{
      installation_id: execution.installation_id,
      actor_type: if(timed_out?, do: "job", else: "pumble_user"),
      actor_id: Map.get(decision, :actor_id) || if(timed_out?, do: "approval_timeout_worker"),
      action:
        if(timed_out?, do: "execution.approval_timed_out", else: "execution.approval_decided"),
      resource_type: "approval",
      resource_id: approval.id,
      metadata: %{
        "outcome" => decision.action,
        "previous_state" => "waiting_approval",
        "next_state" => execution.status,
        "result" => "ok",
        "source" => source
      }
    }
  end

  defp stale_result, do: %{result: :stale, message: @stale_message, job: nil, wake: []}

  defp duplicate_result,
    do: %{result: :duplicate, message: @duplicate_message, job: nil, wake: []}

  defp unauthorized_result(repo, click, approval, execution) do
    %{
      result: :stale,
      message: @stale_message,
      job: nil,
      wake: [],
      audit: unauthorized_audit(repo, click, approval, execution)
    }
  end

  defp unauthorized_audit(repo, click, approval, execution) do
    if already_audited_unauthorized?(repo, approval.id, click.actor_id) do
      nil
    else
      %{
        installation_id: execution.installation_id,
        actor_type: "pumble_user",
        actor_id: click.actor_id,
        action: "execution.approval_unauthorized",
        resource_type: "approval",
        resource_id: approval.id,
        metadata: %{
          "outcome" => "unauthorized",
          "previous_state" => "waiting_approval",
          "next_state" => execution.status,
          "result" => "denied",
          "source" => "pumble_callback"
        }
      }
    end
  end

  defp already_audited_unauthorized?(repo, approval_id, actor_id)
       when is_binary(approval_id) and is_binary(actor_id) do
    repo.exists?(
      from event in AuditEvent,
        where: event.action == "execution.approval_unauthorized",
        where: event.resource_id == ^approval_id,
        where: event.actor_id == ^actor_id
    )
  end

  defp already_audited_unauthorized?(_repo, _approval_id, _actor_id), do: true

  defp enqueue_decision_followup(%{applied: applied}) when is_map(applied) do
    Multi.new()
    |> Service.as_multi()
    |> enqueue_specs(decision_jobs(applied))
    |> maybe_append_audit(applied)
  end

  defp enqueue_decision_followup(_changes) do
    Multi.new()
    |> Service.as_multi()
    |> Multi.put(:job, nil)
  end

  defp maybe_append_audit(multi, %{audit: audit}) when is_map(audit) do
    Writer.append(multi, :audit, fn _changes -> audit end)
  end

  defp maybe_append_audit(multi, _applied), do: multi

  defp decision_jobs(%{job: job, wake: wake}) do
    specs = if job, do: [job], else: []
    specs ++ Enum.map(wake, &wake_job/1)
  end

  defp wake_job(%Execution{} = execution) do
    %{
      args: %{
        installation_id: execution.installation_id,
        execution_id: execution.id,
        expected_node_id: execution.current_node_id,
        generation: execution.lock_version
      },
      opts: []
    }
  end

  defp enqueue_specs(multi, []), do: Multi.put(multi, :job, nil)

  defp enqueue_specs(multi, [spec]) do
    PumbleAutomation.Oban.insert(multi, :job, fn _changes -> next_job_changeset(spec) end)
  end

  defp enqueue_specs(multi, specs) do
    specs
    |> Enum.with_index()
    |> Enum.reduce(multi, fn {spec, index}, acc ->
      PumbleAutomation.Oban.insert(acc, {:job, index}, fn _changes ->
        next_job_changeset(spec)
      end)
    end)
  end

  defp next_job_changeset(%{args: args, opts: opts}) do
    AdvanceExecutionWorker.new(args, opts)
  end

  defp finish_decision({:ok, %{applied: %{result: :decided} = applied}}) do
    log_decision(applied)
    emit_approval(applied)
    update_message_best_effort(applied)
    {:ok, {:decided, applied.message}}
  end

  defp finish_decision({:ok, %{applied: %{result: result, message: message}} = changes}) do
    log_decision(changes.applied)
    emit_approval(changes.applied)
    {:ok, {result, message}}
  end

  defp finish_decision({:error, :lock, %Error{} = error, _changes}) do
    Logging.event(:warning, "approval.decision", %{
      operation: "approval.decision",
      event_type: "approval",
      status: "error",
      error_code: error.code,
      error_class: error.class
    })

    emit_approval_error(error)
    {:error, error}
  end

  defp finish_decision({:error, _step, %Error{retryable?: true} = error, _changes}) do
    {:error, error}
  end

  defp finish_decision({:error, _step, %Error{}, _changes}) do
    {:ok, {:stale, @stale_message}}
  end

  defp finish_decision({:error, _step, %{result: :stale}, _changes}) do
    {:ok, {:stale, @stale_message}}
  end

  defp finish_decision({:error, _step, _reason, _changes}) do
    {:error, decision_failed()}
  end

  defp finish_timeout({:ok, %{applied: %{result: :timed_out} = applied}}) do
    emit_approval(applied)
    update_message_best_effort(applied)
    :ok
  end

  defp finish_timeout({:ok, _changes}), do: :ok

  defp finish_timeout({:error, :applied, {:snooze, seconds}, _changes})
       when is_integer(seconds) and seconds > 0 do
    {:snooze, seconds}
  end

  defp finish_timeout({:error, :lock, %Error{} = error, _changes}), do: {:error, error}

  defp finish_timeout({:error, _step, %Error{retryable?: true} = error, _changes}) do
    {:error, error}
  end

  defp finish_timeout({:error, _step, %Error{}, _changes}), do: :ok

  defp finish_timeout({:error, _step, _reason, _changes}) do
    {:error, decision_failed()}
  end

  defp transact(multi) do
    Repo.transaction(multi)
  rescue
    exception in Postgrex.Error ->
      if lock_timeout?(exception) do
        {:error, :lock, lock_timeout_error(), %{}}
      else
        {:error, :database, exception, %{}}
      end

    exception in DBConnection.ConnectionError ->
      {:error, :database, exception, %{}}
  end

  defp lock_timeout?(%Postgrex.Error{postgres: %{code: code}})
       when code in [:lock_not_available, :query_canceled],
       do: true

  defp lock_timeout?(_exception), do: false

  defp lock_timeout_error do
    Error.new(:timeout, :lock_timeout,
      retryable?: true,
      message: "This request could not be completed."
    )
  end

  defp update_message_best_effort(%{approval: approval, execution: execution, action: action}) do
    case post_decision_message(approval, execution, action) do
      :ok ->
        emit_update(:ok)
        :ok

      :skipped ->
        :ok

      {:error, reason} ->
        Logger.warning("approval message update failed after a committed decision")
        emit_update(reason)
        :ok
    end
  end

  defp post_decision_message(%Approval{} = approval, %Execution{} = execution, action) do
    channel_id = present(approval.pumble_channel_id)
    message_id = present(approval.pumble_message_id)

    if channel_id && message_id do
      client = Client.new(execution.installation_id, :bot, correlation_id: execution.id)

      with {:ok, payload} <- Blocks.message(final_text(action)),
           {:ok, _response} <- Client.reply(client, channel_id, message_id, payload) do
        :ok
      else
        {:error, %ClientError{}} -> {:error, :client}
      end
    else
      :skipped
    end
  end

  defp final_text("approved"), do: "This request was approved."
  defp final_text("rejected"), do: "This request was rejected."
  defp final_text("timed_out"), do: "This request timed out."
  defp final_text(_action), do: "This request is no longer waiting."

  defp present(id) when is_binary(id) and id != "", do: id
  defp present(_id), do: nil

  defp emit_update(result) do
    :telemetry.execute(
      @telemetry_event ++ [:message_update],
      %{count: 1},
      %{result: result}
    )

    :ok
  end

  defp emit_approval(applied) when is_map(applied) do
    approval = Map.get(applied, :approval)
    execution = Map.get(applied, :execution)
    status = approval_metric_status(applied)

    PumbleAutomation.Telemetry.execute(
      @telemetry_event ++ [:stop],
      %{duration_ms: approval_duration_ms(approval), count: 1},
      %{
        operation: "approval",
        status: status,
        type: if(status == "timed_out", do: "expired", else: "decision"),
        installation_id: execution && execution.installation_id,
        execution_id: execution && execution.id,
        step_id: approval && approval.step_execution_id
      }
    )
  end

  defp emit_approval_error(%Error{} = error) do
    PumbleAutomation.Telemetry.execute(
      @telemetry_event ++ [:stop],
      %{duration_ms: 0, count: 1},
      %{operation: "approval", status: "error", type: "decision", error_class: error.class}
    )
  end

  defp approval_metric_status(%{action: action}) when is_binary(action), do: action
  defp approval_metric_status(%{result: result}) when is_atom(result), do: Atom.to_string(result)
  defp approval_metric_status(_applied), do: "unknown"

  defp approval_duration_ms(%Approval{inserted_at: inserted, decided_at: decided}) do
    duration_ms(inserted, decided || DateTime.utc_now())
  end

  defp approval_duration_ms(_approval), do: 0

  defp duration_ms(%DateTime{} = from, %DateTime{} = to) do
    max(0, DateTime.diff(to, from, :millisecond))
  end

  defp duration_ms(_from, _to), do: 0

  defp compiled_missing do
    Error.new(:internal, :compiled_workflow_missing,
      retryable?: true,
      message: "This request could not be completed."
    )
  end

  defp decision_failed do
    Error.new(:internal, :approval_decision_failed,
      retryable?: true,
      message: "This request could not be completed."
    )
  end

  defp halt_failed do
    Error.new(:internal, :approval_delivery_failed,
      message: "The approval delivery could not be finalized."
    )
  end
end
