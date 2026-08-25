defmodule PumbleAutomation.Repo.Migrations.RetentionIndexes do
  @moduledoc """
  Adds indexes the retention sweep uses to delete due rows in batches.

  Tenant-owned predicates lead with `installation_id` so a sweep never has to
  scan another workspace. Partial indexes match the due predicates exactly:
  terminal executions, consumed OAuth states, and revoked sessions. Receipts
  already have `received_events_retain_until_index`. Audit already has
  `(installation_id, inserted_at)`; the extra `inserted_at` index covers
  pre-install rows whose tenant is null.
  """

  use Ecto.Migration

  def change do
    create index(:executions, [:installation_id, :updated_at],
             where: "status IN ('completed','failed','cancelled')",
             name: :executions_retention_index
           )

    create index(:audit_events, [:inserted_at],
             where: "installation_id IS NULL",
             name: :audit_events_preinstall_retention_index
           )

    create index(:oauth_states, [:consumed_at],
             where: "consumed_at IS NOT NULL",
             name: :oauth_states_consumed_retention_index
           )

    create index(:user_sessions, [:revoked_at],
             where: "revoked_at IS NOT NULL",
             name: :user_sessions_revoked_retention_index
           )
  end
end
