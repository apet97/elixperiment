defmodule PumbleAutomation.ReleaseFixtures.BeforeFailure do
  use Ecto.Migration

  def change do
    create table(:release_fixture_before_failure) do
      add :value, :string, null: false
    end
  end
end
