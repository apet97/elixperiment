defmodule PumbleAutomation.ReleaseFixtures.ExpandSchema do
  use Ecto.Migration

  def up do
    alter table(:release_compat_records) do
      add :new_value, :string
    end

    execute """
    INSERT INTO release_compat_records (id, old_value)
    VALUES ('00000000-0000-0000-0000-000000000001', 'old-shape-write')
    """

    execute """
    INSERT INTO release_compat_records (id, old_value, new_value)
    VALUES ('00000000-0000-0000-0000-000000000002', 'new-shape-write', 'expanded')
    """
  end

  def down do
    alter table(:release_compat_records) do
      remove :new_value
    end
  end
end
