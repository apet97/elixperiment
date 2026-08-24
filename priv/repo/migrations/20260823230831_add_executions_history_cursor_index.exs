defmodule PumbleAutomation.Repo.Migrations.AddExecutionsHistoryCursorIndex do
  @moduledoc """
  Keeps tenant execution-history cursor pages on an ordered index.

  The query orders by `inserted_at DESC, id DESC` and applies a small limit.
  Without the matching suffix, PostgreSQL scans and sorts every execution in
  the tenant before it can return one page.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @index_name "executions_installation_history_cursor_index"

  def up do
    ensure_index()
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS " <> @index_name)
  end

  defp ensure_index do
    %{rows: rows} =
      repo().query!(
        """
        SELECT index.indisvalid,
               index.indrelid = 'executions'::regclass,
               index.indisunique,
               index.indnkeyatts,
               pg_get_indexdef(index.indexrelid, 1, true),
               pg_get_indexdef(index.indexrelid, 2, true),
               pg_get_indexdef(index.indexrelid, 3, true),
               index.indoption::text,
               index.indpred IS NULL,
               index.indexprs IS NULL
        FROM pg_class AS relation
        JOIN pg_index AS index ON index.indexrelid = relation.oid
        WHERE relation.relname = $1
          AND relation.relnamespace = current_schema()::regnamespace
        """,
        [@index_name]
      )

    case rows do
      [] ->
        create_index()

      [[true, true, false, 3, "installation_id", "inserted_at", "id", "0 3 3", true, true]] ->
        :ok

      [[false, true, false, 3, "installation_id", "inserted_at", "id", "0 3 3", true, true]] ->
        repo().query!("DROP INDEX CONCURRENTLY " <> @index_name)
        create_index()

      _other ->
        raise "existing #{@index_name} does not match the required execution-history index"
    end
  end

  defp create_index do
    repo().query!(
      "CREATE INDEX CONCURRENTLY #{@index_name} " <>
        "ON executions (installation_id, inserted_at DESC, id DESC)"
    )
  end
end
