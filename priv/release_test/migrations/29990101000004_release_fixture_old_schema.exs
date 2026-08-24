defmodule PumbleAutomation.ReleaseFixtures.OldSchema do
  use Ecto.Migration

  def change do
    create table(:release_compat_records) do
      add :old_value, :string, null: false
    end
  end
end
