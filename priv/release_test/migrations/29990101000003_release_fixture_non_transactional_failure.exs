defmodule PumbleAutomation.ReleaseFixtures.NonTransactionalFailure do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    create table(:release_fixture_non_transactional_partial) do
      add :value, :string, null: false
    end

    execute "SELECT 1 / 0"
  end

  def down do
    drop table(:release_fixture_non_transactional_partial)
  end
end
