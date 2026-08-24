defmodule PumbleAutomation.Repo.Migrations.AddWebhookSigningCredentials do
  @moduledoc """
  Adds the optional, encrypted HMAC credential for generic inbound webhooks.

  The current and overlap secrets are ciphertext envelopes produced by the
  application vault. Their key-version columns make a future bounded rotation
  observable without decrypting every row. No plaintext signing credential is
  stored in this table.
  """

  use Ecto.Migration

  def change do
    alter table(:webhook_endpoints) do
      add :require_signature, :boolean, null: false, default: false
      add :signature_enabled, :boolean, null: false, default: false
      add :signing_secret, :binary
      add :signing_secret_key_version, :integer
      add :previous_signing_secret, :binary
      add :previous_signing_secret_key_version, :integer
      add :previous_signing_secret_expires_at, :utc_datetime_usec
    end

    create constraint(:webhook_endpoints, :webhook_endpoints_signing_secret_pair_check,
             check:
               "(require_signature AND signing_secret IS NOT NULL AND signing_secret_key_version BETWEEN 1 AND 255) OR (NOT require_signature AND signing_secret IS NULL AND signing_secret_key_version IS NULL)"
           )

    create constraint(:webhook_endpoints, :webhook_endpoints_signature_compatibility_check,
             check:
               "(require_signature AND NOT enabled) OR (NOT require_signature AND NOT signature_enabled)"
           )

    create constraint(:webhook_endpoints, :webhook_endpoints_signing_secret_envelope_check,
             check: "signing_secret IS NULL OR octet_length(signing_secret) > 30"
           )

    create constraint(:webhook_endpoints, :webhook_endpoints_previous_signing_secret_pair_check,
             check:
               "(previous_signing_secret IS NULL AND previous_signing_secret_key_version IS NULL AND previous_signing_secret_expires_at IS NULL) OR (require_signature AND previous_signing_secret IS NOT NULL AND previous_signing_secret_key_version BETWEEN 1 AND 255 AND previous_signing_secret_expires_at IS NOT NULL)"
           )

    create constraint(
             :webhook_endpoints,
             :webhook_endpoints_previous_signing_secret_envelope_check,
             check:
               "previous_signing_secret IS NULL OR octet_length(previous_signing_secret) > 30"
           )
  end
end
