defmodule PumbleAutomation.Executions.Workers.RetentionWorker do
  @moduledoc """
  Runs the time-based retention sweep and the uninstalled-tenant purge.

  `PumbleAutomation.Installations.Lifecycle.uninstall/2` enqueues this job for
  one installation's `deletion_scheduled_at`. A sweep with no installation id
  deletes due receipt, execution, audit, OAuth, and session rows according to
  `PumbleAutomation.Retention`. Oban cron runs that sweep daily. Pause/run-once
  live on `PumbleAutomation.Maintenance`. Tenant purge jobs are never paused.

  ## The installation row is kept

  Only its data goes. The row survives with status `deleted` so that the audit
  history, whose foreign key is `on_delete: :nothing`, still names a workspace,
  and so that a workspace that reinstalls later is recognised as the same
  workspace rather than becoming a second tenant.

  ## Tenant scoping

  Every tenant delete is scoped to one installation id. `user_sessions` carries
  no installation column, so it is scoped through that installation's members
  and is deleted before them.

  ## Resumable batches

  Each batch is its own statement and commits on its own. A job that dies
  halfway leaves the batches it finished deleted, and the retry continues from
  what is left rather than starting again.

  ## It never re-enables anything

  The guards are ordered so that the job can only ever move a tenant further
  along: an installation that is missing, or no longer `uninstalled` — a
  reinstall makes it `active` again — is left completely alone, and a window
  that has not passed is snoozed. A failure therefore leaves the tenant
  uninstalled and blocked, which is the safe state, and the job is retried.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 20,
    unique: [period: :infinity, keys: [:installation_id], states: :incomplete]

  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Maintenance
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Retention

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"installation_id" => installation_id}}) do
    now = DateTime.utc_now()

    case Repo.get(Installation, installation_id) do
      nil -> :ok
      %Installation{status: "uninstalled"} = installation -> run(installation, now)
      %Installation{} -> :ok
    end
  end

  def perform(%Oban.Job{args: args}) do
    Maintenance.perform(:retention, args)
  end

  @doc "How many rows one delete statement removes."
  @spec batch_size() :: pos_integer()
  def batch_size, do: Retention.batch_size()

  @doc """
  Deletes one tenant's rows and marks the installation deleted.

  Exposed so that a test can run the purge without going through the queue.
  """
  @spec purge(Installation.t()) :: {:ok, Installation.t()} | {:error, term()}
  def purge(%Installation{} = installation), do: Retention.purge_tenant(installation)

  defp run(%Installation{deletion_scheduled_at: nil}, _now), do: :ok

  defp run(%Installation{} = installation, now) do
    case DateTime.compare(now, installation.deletion_scheduled_at) do
      :lt -> {:snooze, DateTime.diff(installation.deletion_scheduled_at, now, :second) + 1}
      _due -> finish(purge(installation))
    end
  end

  defp finish({:ok, _installation}), do: :ok
  defp finish({:error, reason}), do: {:error, reason}
end
