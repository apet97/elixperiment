defmodule PumbleAutomation.Repo.Migrations.CreateConnections do
  @moduledoc """
  Creates `connections`, one tenant's reusable outbound HTTP configuration.

  Plan Section 14.5 fixes the columns: a tenant, a unique name, the single type
  `http`, a base URL, configuration that carries no secret value, the secret
  ids it references, and a status.

  ## The type column has exactly one legal value

  A check constraint pins `type` to `'http'`. The column exists so a second
  type is an additive migration rather than a new table, and the constraint
  exists so a second type cannot arrive by accident, without the validation
  rules that would have to come with it.

  ## Secrets are referenced twice, on purpose

  `secret_headers` holds the authoritative list of `{header, secret_id}` pairs.
  `referenced_secret_ids` holds the same ids flattened into an array column,
  written by the changeset from `secret_headers`. The array is what makes
  "which connections still use this secret" one indexable query instead of a
  JSON scan of every row, and `connection_test.exs` asserts the two never
  disagree.

  There is no foreign key from either column to `secrets`. A reference living
  inside JSON cannot carry one, and duplicating the constraint on the array
  alone would enforce it in one place and not the other. Tenant membership of
  every referenced secret is checked in `PumbleAutomation.Connections` on every
  write, and deletion of a referenced secret is refused there.

  ## No script, no retry code, no templated secret

  There is deliberately no column for any of those. A connection is a finite
  description of where a request may go and which fixed headers it carries.
  Everything that decides *what* to send lives in the workflow definition, and
  everything that performs the request is the P10 transport.
  """

  use Ecto.Migration

  def change do
    create table(:connections) do
      add :installation_id,
          references(:installations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :name, :string, null: false, size: 100
      add :type, :string, null: false, default: "http", size: 16

      # Scheme, host, and optional port only. No userinfo, no path, no query,
      # no fragment. Normalized by the changeset before it is stored.
      add :base_origin, :string, null: false, size: 255

      # Optional. Begins with "/", never ends with one, never contains "..".
      add :base_path_prefix, :string, size: 255

      # Fixed literal headers. Never an authorization header: authorization
      # arrives only through `secret_headers`.
      add :headers, :map, null: false, default: %{}

      # `[%{"header" => "authorization", "secret_id" => uuid}, ...]`.
      add :secret_headers, {:array, :map}, null: false, default: []

      # Denormalized from `secret_headers`. See the module documentation.
      add :referenced_secret_ids, {:array, :uuid}, null: false, default: []

      add :enabled, :boolean, null: false, default: true

      # Which generation of the outbound policy this row was written under, so
      # a later, stricter policy can find the rows that predate it.
      add :policy_version, :integer, null: false, default: 1

      add :created_by_member_id,
          references(:workspace_members, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:connections, [:installation_id, :name])

    # "Which connections in this tenant still use this secret", answered
    # without reading the JSON column.
    create index(:connections, [:referenced_secret_ids], using: "GIN")

    # The target of any later composite foreign key.
    create unique_index(:connections, [:id, :installation_id])

    create constraint(:connections, :connections_type_check, check: "type = 'http'")

    create constraint(:connections, :connections_base_origin_check,
             check: "base_origin ~ '^https://'"
           )

    create constraint(:connections, :connections_policy_version_check,
             check: "policy_version >= 1"
           )
  end
end
