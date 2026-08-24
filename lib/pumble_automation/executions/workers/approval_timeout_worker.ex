defmodule PumbleAutomation.Executions.Workers.ApprovalTimeoutWorker do
  @moduledoc """
  Wakes a pending approval at its deadline and follows the compiled timeout edge.

  Job args are identifiers only. The worker locks the approval and execution.
  An early wake snoozes. A due pending wait records `timed_out`, resumes the
  compiled timeout branch or stops, and enqueues the next job in one
  transaction. Duplicate jobs and already-decided waits are successful no-ops.
  """

  use Oban.Worker,
    queue: :executions,
    max_attempts: 20,
    unique: [keys: [:approval_id], states: :incomplete]

  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Approval
  alias PumbleAutomation.Executions.ApprovalService

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    case ApprovalService.timeout(args) do
      :ok -> :ok
      {:snooze, seconds} -> {:snooze, seconds}
      {:error, %Error{retryable?: true}} -> {:error, :retry}
      {:error, %Error{}} -> :ok
    end
  end

  @doc "The scheduled Oban job spec that wakes this approval at expiry."
  @spec job_spec(Approval.t(), String.t(), integer()) :: map()
  def job_spec(%Approval{} = approval, node_id, generation)
      when is_binary(node_id) and is_integer(generation) do
    %{
      worker: __MODULE__,
      args: %{
        installation_id: approval.installation_id,
        execution_id: approval.execution_id,
        approval_id: approval.id,
        expected_node_id: node_id,
        generation: generation
      },
      opts: scheduled_opts(approval.expires_at)
    }
  end

  defp scheduled_opts(%DateTime{} = expires_at), do: [scheduled_at: expires_at]
  defp scheduled_opts(_expires_at), do: []
end
