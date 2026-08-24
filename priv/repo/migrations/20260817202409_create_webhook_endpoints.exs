defmodule PumbleAutomation.Repo.Migrations.CreateWebhookEndpoints do
  @moduledoc """
  Creates `webhook_endpoints`, one tenant-owned inbound URL and its credentials.

  P8-T01 fixes the columns: an opaque public id, the current token digest, an
  optional previous digest with an overlap expiry, the workflow/version the
  endpoint is bound to, enabled, last-used, and per-endpoint / per-IP rate
  settings.

  There is no plaintext token column. The token is 256 random bits, shown
  once at creation, and stored as a keyed SHA-256 digest. Rotation keeps the
  previous digest only until `previous_token_expires_at`.

  ## Uninstall and deactivation

  `installation_id` cascades, so tenant erasure removes every endpoint.
  Workflow and version references are composite and also cascade: an endpoint
  cannot outlive the program it is bound to, and cannot name another tenant's
  workflow. Deactivation itself does not delete versions, so an endpoint stays
  until a later task disables or replaces it.

  ## Public id is globally unique on purpose

  Lookup is `POST /webhooks/:public_id` with no workspace in the path. The
  public id is the only handle the URL carries, so it is unique across
  tenants the same way `approvals.public_action_id` is.
  """

  use Ecto.Migration

  def change do
    create table(:webhook_endpoints) do
      add :installation_id,
          references(:installations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :workflow_id,
          references(:workflows,
            type: :binary_id,
            on_delete: :delete_all,
            with: [installation_id: :installation_id]
          ),
          null: false

      add :workflow_version_id,
          references(:workflow_versions,
            type: :binary_id,
            on_delete: :delete_all,
            with: [installation_id: :installation_id]
          ),
          null: false

      add :public_id, :string, null: false
      add :token_digest, :binary, null: false
      add :previous_token_digest, :binary
      add :previous_token_expires_at, :utc_datetime_usec
      add :enabled, :boolean, null: false, default: true
      add :last_used_at, :utc_datetime_usec
      add :rate_limit_per_minute, :integer, null: false, default: 60
      add :rate_limit_per_ip_per_minute, :integer, null: false, default: 30

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:webhook_endpoints, [:id, :installation_id])
    create unique_index(:webhook_endpoints, [:public_id])
    create unique_index(:webhook_endpoints, [:token_digest])
    create index(:webhook_endpoints, [:installation_id, :enabled])
    create index(:webhook_endpoints, [:installation_id, :workflow_id])

    create constraint(:webhook_endpoints, :webhook_endpoints_public_id_check,
             check: "char_length(public_id) BETWEEN 16 AND 64"
           )

    create constraint(:webhook_endpoints, :webhook_endpoints_token_digest_check,
             check: "octet_length(token_digest) = 32"
           )

    create constraint(:webhook_endpoints, :webhook_endpoints_previous_token_digest_check,
             check: "previous_token_digest IS NULL OR octet_length(previous_token_digest) = 32"
           )

    create constraint(:webhook_endpoints, :webhook_endpoints_previous_token_pair_check,
             check:
               "(previous_token_digest IS NULL AND previous_token_expires_at IS NULL) OR (previous_token_digest IS NOT NULL AND previous_token_expires_at IS NOT NULL)"
           )

    create constraint(:webhook_endpoints, :webhook_endpoints_rate_limit_per_minute_check,
             check: "rate_limit_per_minute BETWEEN 1 AND 10000"
           )

    create constraint(
             :webhook_endpoints,
             :webhook_endpoints_rate_limit_per_ip_per_minute_check,
             check: "rate_limit_per_ip_per_minute BETWEEN 1 AND 10000"
           )
  end
end
