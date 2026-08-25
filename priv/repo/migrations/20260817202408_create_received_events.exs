defmodule PumbleAutomation.Repo.Migrations.CreateReceivedEvents do
  @moduledoc """
  Creates `received_events`, the ingress ledger one callback becomes.

  The ingress receipt contract fixes the columns: tenant, provider, class, type,
  a database-enforced dedup key, an optional provider id, the raw-body digest,
  bounded sanitized data, clocks, processing state, and a retention date.

  There is no raw-body column. The hash is what replay and integrity checks
  need; the normalized map is what matching and audit may read. A future
  change cannot start retaining credentials by filling in a column that does
  not exist.

  ## Dedup uniqueness is the identity

  `(installation_id, provider, dedup_key)` is unique. Two deliveries that
  name the same key inside one tenant are one receipt. A concurrent insert
  loses on this index and is a normal conflict, not a 500.

  ## Executions may name a receipt

  The earlier executions migration stored `executions.received_event_id`
  without a foreign key because this
  table did not exist. The reference is added here with `ON DELETE SET NULL`:
  retention (30 days for receipts, 90 for executions) must be able to drop a
  receipt without deleting the run it started. Uninstall still cascades from
  `installations` and removes both.
  """

  use Ecto.Migration

  def change do
    create table(:received_events) do
      add :installation_id,
          references(:installations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :provider, :string, null: false
      add :class, :string, null: false
      add :type, :string, null: false
      add :dedup_key, :string, null: false
      add :provider_id, :string
      add :raw_body_hash, :binary, null: false
      add :data, :map, null: false, default: fragment("'{}'::jsonb")
      add :received_at, :utc_datetime_usec, null: false
      add :occurred_at, :utc_datetime_usec, null: false
      add :processing_state, :string, null: false, default: "received"
      add :retain_until, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:received_events, [:id, :installation_id])

    create unique_index(:received_events, [:installation_id, :provider, :dedup_key],
             name: :received_events_installation_id_provider_dedup_key_index
           )

    create index(:received_events, [:installation_id, :processing_state],
             name: :received_events_installation_id_processing_state_index
           )

    # Retention sweeps `WHERE retain_until < now()` across tenants. Leading
    # with the tenant key would not serve that predicate.
    create index(:received_events, [:retain_until], name: :received_events_retain_until_index)

    create constraint(:received_events, :received_events_provider_check,
             check: "provider IN ('pumble','webhook','browser','schedule')"
           )

    create constraint(:received_events, :received_events_class_check,
             check: "class IN ('event','interaction','lifecycle','webhook','manual','schedule')"
           )

    create constraint(:received_events, :received_events_processing_state_check,
             check: "processing_state IN ('received','processed','failed')"
           )

    create constraint(:received_events, :received_events_dedup_key_check,
             check: "char_length(dedup_key) BETWEEN 1 AND 128"
           )

    create constraint(:received_events, :received_events_raw_body_hash_check,
             check: "octet_length(raw_body_hash) = 32"
           )

    create constraint(:received_events, :received_events_retention_window_check,
             check:
               "retain_until > received_at AND retain_until <= received_at + interval '30 days'"
           )

    # Optional pointer from a run to the receipt that created it. SET NULL so
    # a retention delete of the receipt does not take the execution with it.
    alter table(:executions) do
      modify :received_event_id,
             references(:received_events, type: :binary_id, on_delete: :nilify_all),
             from: :binary_id
    end
  end
end
