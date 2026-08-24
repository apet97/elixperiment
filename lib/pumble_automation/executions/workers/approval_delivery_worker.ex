defmodule PumbleAutomation.Executions.Workers.ApprovalDeliveryWorker do
  @moduledoc """
  Posts the Pumble approval message after the wait row and timeout job exist.

  Job args are identifiers only. The worker loads the pending approval,
  reconstructs the signed buttons, and calls `Pumble.Client`. Duplicate jobs
  and already-cancelled waits are successful no-ops. Ambiguous sends pause
  the execution; permanent failures fail it so the wait cannot sit forever.
  """

  use Oban.Worker,
    queue: :executions,
    max_attempts: 5,
    unique: [keys: [:approval_id], states: :incomplete]

  alias PumbleAutomation.Executions.Approval
  alias PumbleAutomation.Executions.ApprovalService

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    ApprovalService.deliver(args)
  end

  @doc "The Oban job spec that posts the approval message."
  @spec job_spec(Approval.t()) :: map()
  def job_spec(%Approval{} = approval) do
    %{
      worker: __MODULE__,
      args: %{
        installation_id: approval.installation_id,
        execution_id: approval.execution_id,
        approval_id: approval.id
      },
      opts: []
    }
  end
end
