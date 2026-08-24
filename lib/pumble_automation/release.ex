defmodule PumbleAutomation.Release do
  @moduledoc """
  One-shot tasks that run from an assembled OTP release.

  Migrations are deliberately not part of the application supervision tree.
  A deployment invokes `bin/migrate` before it starts or readies new web
  instances. `Ecto.Migrator.with_repo/2` starts only the repository and its
  dependencies, while the PostgreSQL advisory lock configured on the Repo
  serializes concurrent migration runners.
  """

  alias Ecto.Adapters.SQL

  @app :pumble_automation
  # Ecto acquires its configured migration lock after ensuring the
  # schema_migrations table exists. A release-level lock must cover that first
  # table creation too, otherwise two runners on a brand-new database can race
  # in PostgreSQL's catalog before Ecto reaches its own lock.
  @release_migration_lock 4_789_124_662_030_941
  @release_migration_lock_retry_ms 100

  @doc """
  Applies every pending migration for each repository in the release.

  The function raises on connection, lock, or migration failure so the
  one-shot process exits non-zero and the deployment can leave the previous
  release serving.
  """
  @spec migrate() :: :ok
  def migrate do
    _ = Application.load(@app)

    @app
    |> Application.fetch_env!(:ecto_repos)
    |> Enum.each(fn repo ->
      {:ok, _migrated_versions, _started_apps} =
        Ecto.Migrator.with_repo(repo, &migrate_repo/1)
    end)

    :ok
  end

  defp migrate_repo(repo) do
    adapter = repo.__adapter__()
    adapter_meta = Ecto.Adapter.lookup_meta(repo)

    adapter.checkout(adapter_meta, [timeout: :infinity], fn ->
      acquire_release_lock!(repo)

      try do
        Ecto.Migrator.run(repo, :up, all: true)
      after
        release_release_lock!(repo)
      end
    end)
  end

  defp acquire_release_lock!(repo) do
    %{rows: [[acquired?]]} =
      SQL.query!(
        repo,
        "SELECT pg_try_advisory_lock($1)",
        [@release_migration_lock],
        timeout: :infinity
      )

    if acquired? do
      :ok
    else
      # A blocking pg_advisory_lock query keeps a virtual transaction open.
      # CREATE INDEX CONCURRENTLY in the lock holder then waits for that
      # virtual transaction while the waiter waits for the advisory lock. A
      # try-lock releases its virtual transaction between attempts and avoids
      # that PostgreSQL wait cycle.
      receive do
      after
        @release_migration_lock_retry_ms -> acquire_release_lock!(repo)
      end
    end
  end

  defp release_release_lock!(repo) do
    %{rows: [[true]]} =
      SQL.query!(repo, "SELECT pg_advisory_unlock($1)", [@release_migration_lock])

    :ok
  end
end
