defmodule PumbleAutomation.ReleaseFixtures.TransactionalFailure do
  use Ecto.Migration

  def up do
    create table(:release_fixture_transaction_rolled_back) do
      add :value, :string, null: false
    end

    execute "SELECT 1 / 0"
  end

  def down do
    drop table(:release_fixture_transaction_rolled_back)
  end
end
