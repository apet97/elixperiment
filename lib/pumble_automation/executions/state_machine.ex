defmodule PumbleAutomation.Executions.StateMachine do
  @moduledoc """
  Valid execution, step, attempt, and approval transitions as pure functions.

  Workers and operator actions ask this module what a command would do. It
  returns a plan or a typed conflict. It never writes a row and it never
  mutates an Ecto struct: the caller applies the plan inside the transaction
  that already locked the row. Invalid and stale commands therefore cannot
  corrupt state, because they never become writes.

  ## Terminal states do not leave

  `completed`, `failed`, and `cancelled` (and the attempt/approval terminals)
  accept only the command that would put them there already, and that command
  is an idempotent stay. Every other command is a conflict.

  ## Deactivation is not uninstall

  Deactivating a workflow refuses new executions and leaves in-flight runs
  alone. Uninstalling or revoking the installation refuses
  both new executions and new external effects. Cancelling those in-flight
  rows is handled by the execution service; this module only says whether an
  effect may still dispatch.
  """

  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Approval
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.StepAttempt

  @type entity :: :execution | :step | :attempt | :approval

  @type command ::
          :start
          | :wait_delay
          | :wait_approval
          | :resume
          | :pause_uncertain
          | :complete
          | :fail
          | :cancel
          | :request_cancellation
          | :retry
          | :succeed
          | :approve
          | :reject
          | :timeout
          | {:resolve_uncertain, String.t() | atom()}

  @type plan :: %{
          entity: entity(),
          command: command(),
          from: String.t(),
          to: String.t(),
          idempotent?: boolean()
        }

  @execution_edges %{
    {"queued", :start} => "running",
    {"queued", :cancel} => "cancelled",
    {"running", :wait_delay} => "waiting_delay",
    {"running", :wait_approval} => "waiting_approval",
    {"running", :pause_uncertain} => "paused_uncertain",
    {"running", :complete} => "completed",
    {"running", :fail} => "failed",
    {"running", :cancel} => "cancelled",
    {"waiting_delay", :resume} => "running",
    {"waiting_delay", :cancel} => "cancelled",
    {"waiting_approval", :resume} => "running",
    {"waiting_approval", :cancel} => "cancelled",
    {"waiting_approval", :fail} => "failed",
    {"waiting_approval", :pause_uncertain} => "paused_uncertain",
    {"paused_uncertain", :cancel} => "cancelled"
  }

  @execution_idempotent %{
    {"running", :start} => true,
    {"running", :resume} => true,
    {"running", :retry} => true,
    {"waiting_delay", :wait_delay} => true,
    {"waiting_approval", :wait_approval} => true,
    {"paused_uncertain", :pause_uncertain} => true,
    {"completed", :complete} => true,
    {"failed", :fail} => true,
    {"cancelled", :cancel} => true
  }

  @uncertain_targets ~w(running failed completed)

  @attempt_edges %{
    {"started", :succeed} => "succeeded",
    {"started", :fail} => "failed",
    {"started", :pause_uncertain} => "uncertain",
    {"started", :cancel} => "cancelled"
  }

  @attempt_idempotent %{
    {"succeeded", :succeed} => true,
    {"failed", :fail} => true,
    {"uncertain", :pause_uncertain} => true,
    {"cancelled", :cancel} => true
  }

  @approval_edges %{
    {"pending", :approve} => "approved",
    {"pending", :reject} => "rejected",
    {"pending", :timeout} => "timed_out",
    {"pending", :cancel} => "cancelled"
  }

  @approval_idempotent %{
    {"approved", :approve} => true,
    {"rejected", :reject} => true,
    {"timed_out", :timeout} => true,
    {"cancelled", :cancel} => true
  }

  @doc "The statuses `entity` may hold."
  @spec states(entity()) :: [String.t()]
  def states(:execution), do: Execution.statuses()
  def states(:step), do: Execution.statuses()
  def states(:attempt), do: StepAttempt.statuses()
  def states(:approval), do: Approval.statuses()

  @doc "The commands this module understands, besides `{:resolve_uncertain, target}`."
  @spec commands() :: [atom()]
  def commands do
    [
      :start,
      :wait_delay,
      :wait_approval,
      :resume,
      :pause_uncertain,
      :complete,
      :fail,
      :cancel,
      :request_cancellation,
      :retry,
      :succeed,
      :approve,
      :reject,
      :timeout
    ]
  end

  @doc "Whether `status` is terminal for `entity`."
  @spec terminal?(entity(), term()) :: boolean()
  def terminal?(:execution, status), do: Execution.terminal?(status)
  def terminal?(:step, status), do: Execution.terminal?(status)
  def terminal?(:attempt, status), do: status(status) in StepAttempt.terminal_statuses()
  def terminal?(:approval, status), do: status(status) in Approval.decisions()

  @doc """
  Plans the transition `command` would make from `from` on `entity`.

  Returns `{:ok, plan}` when the command is legal, including an idempotent
  stay when the entity is already in the command's destination. Returns a
  `:conflict` error when the command would move backwards, leave a terminal
  state, or skip a required pause such as uncertainty.
  """
  @spec transition(entity(), term(), command()) :: {:ok, plan()} | {:error, Error.t()}
  def transition(entity, from, command) do
    from = status(from)
    command = normalize_command(command)
    apply_transition(entity, from, command)
  end

  @doc """
  Whether a new execution may be created for this workflow and installation.

  Both must be `active`. Deactivation, archival, and any installation status
  other than `active` refuse a new run.
  """
  @spec admit_new_execution?(term(), term()) :: boolean()
  def admit_new_execution?(workflow_status, installation_status) do
    status(workflow_status) == "active" and status(installation_status) == "active"
  end

  @doc """
  Whether an already-created execution may dispatch a new external effect.

  Deactivating the workflow does not stop in-flight work. An installation that
  is no longer `active` does: no new effect starts for a tenant that has been
  revoked, uninstalled, or deleted.
  """
  @spec dispatch_effect?(term(), term(), term()) :: boolean()
  def dispatch_effect?(execution_status, _workflow_status, installation_status) do
    not Execution.terminal?(execution_status) and status(installation_status) == "active"
  end

  defp apply_transition(entity, from, {:resolve_uncertain, target})
       when entity in [:execution, :step] do
    resolve_uncertain(entity, from, target)
  end

  defp apply_transition(entity, from, {:resolve_uncertain, target}) do
    conflict(entity, {:resolve_uncertain, target}, from)
  end

  defp apply_transition(entity, from, command) when entity in [:execution, :step] do
    lookup(entity, from, command, @execution_edges, @execution_idempotent)
  end

  defp apply_transition(:attempt, from, command) do
    lookup(:attempt, from, command, @attempt_edges, @attempt_idempotent)
  end

  defp apply_transition(:approval, from, command) do
    lookup(:approval, from, command, @approval_edges, @approval_idempotent)
  end

  defp resolve_uncertain(entity, from, target) do
    cond do
      from == "paused_uncertain" and target in @uncertain_targets ->
        ok(entity, {:resolve_uncertain, target}, from, target, false)

      from == target and target in @uncertain_targets ->
        ok(entity, {:resolve_uncertain, target}, from, target, true)

      true ->
        conflict(entity, {:resolve_uncertain, target}, from)
    end
  end

  defp lookup(entity, from, command, edges, idempotent) do
    edge_command = lookup_command(command)

    cond do
      Map.has_key?(edges, {from, edge_command}) ->
        ok(entity, command, from, Map.fetch!(edges, {from, edge_command}), false)

      Map.has_key?(idempotent, {from, edge_command}) ->
        ok(entity, command, from, from, true)

      true ->
        conflict(entity, command, from)
    end
  end

  defp ok(entity, command, from, to, idempotent?) do
    {:ok,
     %{
       entity: entity,
       command: command,
       from: from,
       to: to,
       idempotent?: idempotent?
     }}
  end

  defp conflict(entity, command, from) do
    {:error,
     Error.new(:conflict, :illegal_transition,
       message: "The execution cannot make that transition.",
       details: %{entity: entity, command: inspect(command), from: from}
     )}
  end

  defp normalize_command({:resolve_uncertain, target}), do: {:resolve_uncertain, status(target)}
  defp normalize_command(command) when is_atom(command), do: command

  defp lookup_command(:request_cancellation), do: :cancel
  defp lookup_command(command), do: command

  defp status(value) when is_atom(value), do: Atom.to_string(value)
  defp status(value) when is_binary(value), do: value
end
