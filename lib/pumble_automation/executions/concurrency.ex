defmodule PumbleAutomation.Executions.Concurrency do
  @moduledoc """
  Per-workspace running limits and fair admission of queued executions.

  Section 31 allows five occupying executions per workspace. Occupying
  statuses hold a slot. Excess creates stay `queued` without an advance job
  until a slot frees; the oldest queued row is admitted first.

  Admission is an indexed query plus the installation row lock the engine
  already takes on create. Unique Oban keys are the backstop if two
  finalizers wake the same parked row.
  """

  import Ecto.Query, only: [from: 2]

  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.Workers.AdvanceExecutionWorker
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Limits

  @occupying ~w(running waiting_delay waiting_approval paused_uncertain)
  @incomplete_job_states ~w(available scheduled executing retryable)
  # Matches Oban Lifeline `rescue_after` in config/config.exs.
  @stale_after_seconds 30 * 60

  @doc "Section 31 running executions per workspace."
  @spec max_running() :: pos_integer()
  def max_running, do: Limits.get(:running_executions)

  @doc "Statuses that hold a concurrency slot."
  @spec occupying_statuses() :: [String.t()]
  def occupying_statuses, do: @occupying

  @doc "How long a started attempt may run before reconciliation treats it as stale."
  @spec stale_after_seconds() :: pos_integer()
  def stale_after_seconds, do: @stale_after_seconds

  @doc "Oban worker name stored on advance jobs."
  @spec advance_worker() :: String.t()
  def advance_worker, do: Oban.Worker.to_string(AdvanceExecutionWorker)

  @doc "Oban worker name stored on approval delivery jobs."
  @spec approval_delivery_worker() :: String.t()
  def approval_delivery_worker do
    "PumbleAutomation.Executions.Workers.ApprovalDeliveryWorker"
  end

  @doc "Oban worker name stored on approval timeout jobs."
  @spec approval_timeout_worker() :: String.t()
  def approval_timeout_worker do
    "PumbleAutomation.Executions.Workers.ApprovalTimeoutWorker"
  end

  @doc "Oban states that mean a job has not finished."
  @spec incomplete_job_states() :: [String.t()]
  def incomplete_job_states, do: @incomplete_job_states

  @doc "How many occupying rows this tenant currently holds."
  @spec occupying_count(Ecto.Repo.t(), Ecto.UUID.t()) :: non_neg_integer()
  def occupying_count(repo, installation_id) when is_binary(installation_id) do
    repo.aggregate(
      from(execution in Execution,
        where: execution.installation_id == ^installation_id and execution.status in ^@occupying
      ),
      :count
    )
  end

  @doc "Queued executions that already have an incomplete advance job."
  @spec admitted_queued_count(Ecto.Repo.t(), Ecto.UUID.t()) :: non_neg_integer()
  def admitted_queued_count(repo, installation_id) when is_binary(installation_id) do
    repo.aggregate(admitted_queued_query(installation_id), :count)
  end

  @doc "Occupying rows plus admitted queued rows."
  @spec slots_used(Ecto.Repo.t(), Ecto.UUID.t()) :: non_neg_integer()
  def slots_used(repo, installation_id) when is_binary(installation_id) do
    occupying_count(repo, installation_id) + admitted_queued_count(repo, installation_id)
  end

  @doc "How many more executions may be admitted right now."
  @spec open_slots(Ecto.Repo.t(), Ecto.UUID.t()) :: non_neg_integer()
  def open_slots(repo, installation_id) when is_binary(installation_id) do
    max(max_running() - slots_used(repo, installation_id), 0)
  end

  @doc """
  Oldest parked queued executions that may take an open slot.

  Returns an empty list when the installation is not `active`. Uninstall
  wins over resume.
  """
  @spec admissions(Ecto.Repo.t(), Ecto.UUID.t()) :: [Execution.t()]
  def admissions(repo, installation_id) when is_binary(installation_id) do
    if installation_active?(repo, installation_id) do
      take_parked(repo, installation_id, open_slots(repo, installation_id))
    else
      []
    end
  end

  @doc "Whether `execution_id` already has an incomplete advance job."
  @spec incomplete_job?(Ecto.Repo.t(), Ecto.UUID.t()) :: boolean()
  def incomplete_job?(repo, execution_id) when is_binary(execution_id) do
    query =
      from job in Oban.Job,
        where: job.worker == ^advance_worker(),
        where: job.state in ^@incomplete_job_states,
        where: fragment("? ->> 'execution_id' = ?", job.args, ^execution_id)

    repo.exists?(query)
  end

  @doc "Whether the installation may still dispatch or be resumed."
  @spec installation_active?(Ecto.Repo.t(), Ecto.UUID.t()) :: boolean()
  def installation_active?(repo, installation_id) when is_binary(installation_id) do
    query =
      from installation in Installation,
        where: installation.id == ^installation_id,
        select: installation.status

    repo.one(query) == "active"
  end

  defp take_parked(_repo, _installation_id, 0), do: []

  defp take_parked(repo, installation_id, limit) when limit > 0 do
    repo.all(parked_query(installation_id, limit))
  end

  defp parked_query(installation_id, limit) do
    from execution in Execution,
      as: :exec,
      where: execution.installation_id == ^installation_id,
      where: execution.status == "queued",
      where: is_nil(execution.cancelled_at),
      where: not exists(incomplete_job_subquery()),
      order_by: [asc: execution.inserted_at, asc: execution.id],
      limit: ^limit
  end

  defp admitted_queued_query(installation_id) do
    from execution in Execution,
      as: :exec,
      where: execution.installation_id == ^installation_id,
      where: execution.status == "queued",
      where: is_nil(execution.cancelled_at),
      where: exists(incomplete_job_subquery())
  end

  defp incomplete_job_subquery do
    from job in Oban.Job,
      where: job.worker == ^advance_worker(),
      where: job.state in ^@incomplete_job_states,
      where: fragment("? ->> 'execution_id' = ?::text", job.args, parent_as(:exec).id)
  end
end
