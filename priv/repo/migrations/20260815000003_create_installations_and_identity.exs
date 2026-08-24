defmodule PumbleAutomation.Repo.Migrations.CreateInstallationsAndIdentity do
  @moduledoc """
  Creates the tenant and the identities that resolve to it.

  Five tables arrive together because they are one invariant, not five: every
  identity row must resolve to exactly one installation, and a table added later
  would spend the interval unable to state that. `installations` is the tenant;
  `user_authorizations`, `workspace_members`, and `oauth_states` point at it;
  `user_sessions` reaches it through its member.

  ## Deletion policy

  Tenant-owned rows cascade from `installations`, per
  `docs/operations/migrations.md`: erasing a tenant is one transaction, not a
  cleanup job. `user_sessions` cascades from `workspace_members` for the same
  reason. `oauth_states.installation_id` is a nullable hint, so it nilifies.

  `audit_events.installation_id` is the exception. It gets `on_delete: :nothing`
  because the audit history must outlive everything else in the tenant: a
  cascade would erase the record of the uninstall along with the workspace, and
  a nilify would keep rows that no longer say which workspace they describe.

  The rule in `docs/operations/migrations.md` against `:nothing` guards against
  a foreign-key error during tenant deletion. That failure mode does not arise
  here: an installation ends its life as a `deleted` *status* with its data
  erased around it, not as a deleted row (see
  `PumbleAutomation.Installations.Installation`). If a hard delete is ever
  introduced, it must decide what happens to the audit trail first, which is
  exactly the conversation `:nothing` forces.

  ## Secrets

  Every credential column is `:binary` holding an authenticated-encryption
  envelope, and every token column is a 32 byte digest. No table here has a
  column that could hold a raw token.
  """

  use Ecto.Migration

  def change do
    create_installations()
    create_user_authorizations()
    create_workspace_members()
    create_oauth_states()
    create_user_sessions()
    link_audit_events()
  end

  defp create_installations do
    create table(:installations) do
      add :pumble_workspace_id, :string, null: false
      add :status, :string, null: false, default: "active"
      add :workspace_name_snapshot, :string
      add :bot_user_id, :string
      add :encrypted_bot_token, :binary
      add :token_key_version, :integer
      add :bot_scopes, {:array, :string}, null: false, default: []
      add :user_scopes, {:array, :string}, null: false, default: []
      add :installed_by_pumble_user_id, :string
      add :authorized_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      add :uninstalled_at, :utc_datetime_usec
      add :deletion_scheduled_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # Identity. One row per workspace, forever: a reinstall updates this row.
    create unique_index(:installations, [:pumble_workspace_id])

    # The operator's list, and the input to every lifecycle sweep.
    create index(:installations, [:status])

    # "What is due for erasure", which is a scan of a few rows, not the table.
    create index(:installations, [:deletion_scheduled_at],
             where: "deletion_scheduled_at IS NOT NULL",
             name: :installations_deletion_scheduled_at_index
           )

    create constraint(:installations, :installations_status_check,
             check: "status IN ('active','degraded','revoked','uninstalled','deleted')"
           )
  end

  defp create_user_authorizations do
    create table(:user_authorizations) do
      add :installation_id,
          references(:installations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :pumble_user_id, :string, null: false
      add :encrypted_access_token, :binary
      add :token_key_version, :integer
      add :scopes, {:array, :string}, null: false, default: []
      add :status, :string, null: false, default: "active"
      add :authorized_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:user_authorizations, [:installation_id, :pumble_user_id])
    create index(:user_authorizations, [:installation_id, :status])

    create constraint(:user_authorizations, :user_authorizations_status_check,
             check: "status IN ('active','revoked','expired')"
           )
  end

  defp create_workspace_members do
    create table(:workspace_members) do
      add :installation_id,
          references(:installations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :pumble_user_id, :string, null: false
      add :role, :string, null: false, default: "viewer"
      add :profile_snapshot, :map, null: false, default: fragment("'{}'::jsonb")
      add :disabled_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:workspace_members, [:installation_id, :pumble_user_id])
    create index(:workspace_members, [:installation_id, :role])

    create constraint(:workspace_members, :workspace_members_role_check,
             check: "role IN ('owner','editor','viewer')"
           )
  end

  defp create_oauth_states do
    create table(:oauth_states) do
      add :state_digest, :binary, null: false
      add :intent, :string, null: false

      add :installation_id,
          references(:installations, type: :binary_id, on_delete: :nilify_all)

      add :return_path_key, :string
      add :expires_at, :utc_datetime_usec, null: false
      add :consumed_at, :utc_datetime_usec
      add :request_metadata, :map, null: false, default: fragment("'{}'::jsonb")

      timestamps(type: :utc_datetime_usec)
    end

    # The callback lookup, and the guarantee that a state is one row.
    create unique_index(:oauth_states, [:state_digest])

    # The sweep that deletes states past their expiry plus the audit window.
    create index(:oauth_states, [:expires_at])

    create index(:oauth_states, [:installation_id])

    create constraint(:oauth_states, :oauth_states_intent_check,
             check: "intent IN ('install','reinstall','signin','connect_user')"
           )
  end

  defp create_user_sessions do
    create table(:user_sessions) do
      add :workspace_member_id,
          references(:workspace_members, type: :binary_id, on_delete: :delete_all),
          null: false

      add :token_digest, :binary, null: false
      add :issued_at, :utc_datetime_usec, null: false
      add :last_used_at, :utc_datetime_usec
      add :idle_expires_at, :utc_datetime_usec, null: false
      add :absolute_expires_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
      add :user_agent_hash, :binary

      timestamps(type: :utc_datetime_usec)
    end

    # Every request that carries a cookie is this lookup.
    create unique_index(:user_sessions, [:token_digest])

    # "Sign this person out everywhere", after a role change or a revocation.
    create index(:user_sessions, [:workspace_member_id])

    # The two expiry sweeps.
    create index(:user_sessions, [:absolute_expires_at])
    create index(:user_sessions, [:idle_expires_at])

    create constraint(:user_sessions, :user_sessions_expiry_order_check,
             check: "idle_expires_at <= absolute_expires_at"
           )
  end

  defp link_audit_events do
    alter table(:audit_events) do
      modify :installation_id,
             references(:installations, type: :binary_id, on_delete: :nothing),
             from: :binary_id
    end
  end
end
