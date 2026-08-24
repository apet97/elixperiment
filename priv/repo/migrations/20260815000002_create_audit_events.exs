defmodule PumbleAutomation.Repo.Migrations.CreateAuditEvents do
  @moduledoc """
  Creates the append-only audit table.

  ## Append only, honestly

  The application exposes no update and no delete for these rows, and nothing
  in this table is ever rewritten in place, which is why there is no
  `updated_at` column: a row with an update timestamp invites an update.

  That is an application guarantee, not a storage guarantee. Anyone holding
  database credentials keeps full authority over these rows. This migration
  installs no trigger and makes no tamper-proof claim; durable evidence needs
  shipped, off-host log storage, which is an operations concern rather than a
  schema one.

  ## Why `installation_id` has no foreign key yet

  The installations table does not exist at this point in the build, and audit
  has to be available before the first OAuth mutation so that a failed install
  is accountable. The column is a plain `binary_id` for now; the migration that
  creates installations adds the constraint.

  The column is also nullable, for one justified case only: an OAuth failure
  that happens before an installation row exists. The schema refuses a null for
  any action outside that namespace.
  """

  use Ecto.Migration

  def change do
    create table(:audit_events) do
      add :installation_id, :binary_id
      add :actor_type, :string, null: false
      add :actor_id, :string
      add :action, :string, null: false
      add :resource_type, :string
      add :resource_id, :string
      add :correlation_id, :string, null: false
      add :metadata, :map, null: false, default: fragment("'{}'::jsonb")

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    # The tenant timeline: "what happened in this installation, newest first".
    # It is the read every operator and every support request starts from.
    create index(:audit_events, [:installation_id, :inserted_at])

    # The same timeline narrowed to one action code, for questions such as
    # "when was a credential last rotated here".
    create index(:audit_events, [:installation_id, :action, :inserted_at])

    # Correlation stitches one request or one job across tables. Pre-install
    # failures have no installation, so this is the only way to find them.
    create index(:audit_events, [:correlation_id])

    # "Everything that ever touched this resource", for incident review.
    create index(:audit_events, [:resource_type, :resource_id])

    # "Everything this actor ever did", for the same reason.
    create index(:audit_events, [:actor_type, :actor_id])
  end
end
