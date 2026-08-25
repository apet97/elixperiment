defmodule PumbleAutomation.Repo.Migrations.CreateSecrets do
  @moduledoc """
  Creates `secrets`, the write-only store for one tenant's named credentials.

  The secret-storage contract fixes the columns: a tenant, a unique name, an
  authenticated ciphertext, the key version that ciphertext claims, a value
  fingerprint, a description, and the rotation and last-used timestamps.

  ## `value` is a ciphertext column, and its name is load bearing

  The column is read and written through
  `PumbleAutomation.Crypto.EncryptedBinary` with associated data `secrets.value`.
  That associated data is literally `"table.column"`, so renaming either half
  makes every stored row fail authentication. A rename is therefore a data
  migration that re-encrypts, never an `ALTER TABLE ... RENAME`.

  ## No read-back column, and no soft delete

  There is no plaintext column and no digest a reader could grind offline: the
  fingerprint is domain separated and salted with the tenant id, so it answers
  "is this the same value as before" and nothing else.

  There is also no `deleted_at`. A secret can only be deleted when no active
  workflow version and no connection references it, which is checked in
  `PumbleAutomation.Connections`. A soft delete would keep a live ciphertext
  reachable for the sake of a row nobody may reference, which is the opposite
  of what a secret store should do.

  ## Names are identifiers, not prose

  A template refers to a secret as `{{ secret.API_TOKEN }}`, so the name has
  to survive that grammar. The check constraint is the
  same one the changeset applies: an uppercase identifier, at most 64
  characters.
  """

  use Ecto.Migration

  def change do
    create table(:secrets) do
      add :installation_id,
          references(:installations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :name, :string, null: false, size: 64

      # AES-256-GCM envelope. See the module documentation.
      add :value, :binary, null: false

      add :kind, :string, null: false, size: 32

      # The envelope's key version, duplicated as an integer so that a rotation
      # can find stale rows without decrypting them.
      add :key_version, :integer, null: false

      # Lowercase hex SHA-256 of a tenant-salted, domain-separated encoding of
      # the value. Detects "the same value again", proves nothing else.
      add :value_fingerprint, :string, null: false, size: 64

      add :description, :string, size: 500

      add :last_rotated_at, :utc_datetime_usec
      add :last_used_at, :utc_datetime_usec

      add :created_by_member_id,
          references(:workspace_members, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    # One name means one secret inside one workspace. This is what makes
    # `{{ secret.API_TOKEN }}` resolvable without an id in the template.
    create unique_index(:secrets, [:installation_id, :name])

    # The target of any later composite foreign key, so a row that references a
    # secret cannot reference one from another tenant.
    create unique_index(:secrets, [:id, :installation_id])

    create constraint(:secrets, :secrets_name_check, check: "name ~ '^[A-Z][A-Z0-9_]{0,63}$'")

    create constraint(:secrets, :secrets_value_fingerprint_check,
             check: "value_fingerprint ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:secrets, :secrets_key_version_check,
             check: "key_version >= 1 AND key_version <= 255"
           )
  end
end
