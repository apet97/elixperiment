defmodule PumbleAutomation.Health.RepoProbe do
  @moduledoc """
  The production readiness probes.

  Each probe answers one question with the cheapest query that can answer it,
  and returns a `PumbleAutomation.Error` rather than raising, so that
  `PumbleAutomation.Health` can report every check even when the first one
  fails. Errors carry only the fact of the failure. Nothing here reads a
  connection string, a host, or a credential into a message or into details.
  """

  @behaviour PumbleAutomation.Health

  alias Ecto.Migrator
  alias PumbleAutomation.Error
  alias PumbleAutomation.Repo

  @doc """
  Runs `SELECT 1` against the repository under the given timeout.

  The query is trivial on purpose. It proves that a connection can be checked
  out of the pool and that PostgreSQL answers, which is exactly what readiness
  needs, and it cannot be slowed down by table size or by a lock.
  """
  @impl PumbleAutomation.Health
  def ping(timeout) do
    case Repo.query("SELECT 1", [], timeout: timeout) do
      {:ok, %{rows: [[1]]}} -> :ok
      _other -> {:error, unavailable(:database_unavailable, "The database is unavailable.")}
    end
  end

  @doc """
  Reports whether every migration shipped in this release has been applied.

  A node whose schema is behind is not ready. It compiles and it connects, but
  its queries reference columns the database does not have yet, so it would
  serve errors. During a rolling deployment this check holds the new nodes out
  of the load balancer until the migration has run.

  The pending count is kept in the log details only. Version numbers are not
  returned to a caller, because they describe the deployment.
  """
  @impl PumbleAutomation.Health
  def migration_status do
    case Enum.filter(Migrator.migrations(Repo), fn {status, _version, _name} ->
           status == :down
         end) do
      [] ->
        :ok

      pending ->
        {:error,
         Error.new(:dependency, :migrations_pending,
           message: "The database schema is behind this release.",
           retryable?: true,
           details: %{pending_count: length(pending)}
         )}
    end
  end

  @doc """
  Reports whether the durable job runtime is configured and supervised.

  The check is deliberately shallow: the Oban supervisor is registered and the
  application holds its configuration. It does not inspect a queue, because
  queue depth is a capacity signal, not a readiness signal, and a node that is
  merely busy must not be pulled out of the load balancer.
  """
  @impl PumbleAutomation.Health
  def queue_status do
    if is_pid(Oban.whereis(Oban)) and configured?() do
      :ok
    else
      {:error, unavailable(:job_runtime_unavailable, "The job runtime is unavailable.")}
    end
  end

  defp configured? do
    match?({:ok, _config}, Application.fetch_env(:pumble_automation, Oban))
  end

  defp unavailable(code, message) do
    Error.new(:dependency, code, message: message, retryable?: true)
  end
end
