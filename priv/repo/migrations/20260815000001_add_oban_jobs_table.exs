defmodule PumbleAutomation.Repo.Migrations.AddObanJobsTable do
  @moduledoc """
  Creates the Oban job tables.

  The version is pinned so that a later Oban upgrade cannot silently change an
  already applied migration. A new schema version arrives as a new migration.
  """

  use Ecto.Migration

  @oban_schema_version 14

  def up, do: Oban.Migration.up(version: @oban_schema_version)

  def down, do: Oban.Migration.down(version: 1)
end
