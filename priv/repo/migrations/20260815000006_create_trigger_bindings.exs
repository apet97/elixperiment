defmodule PumbleAutomation.Repo.Migrations.CreateTriggerBindings do
  @moduledoc """
  Creates `trigger_bindings`: the index ingress reads instead of every workflow.

  An inbound Pumble event arrives with a workspace, an event name, and a
  channel. Answering "which workflows want this" by loading every active
  workflow and parsing its definition costs one scan and one JSON parse per
  event. This table answers it with one index lookup.

  ## A binding is a projection, never the source

  The authoritative trigger configuration lives in the version's
  `source_definition`. A binding carries only what a lookup must compare
  against: the class, the type, the discriminators, and a normalized filter
  summary. Nothing reads a binding to decide *how* to run; it decides only
  *whether* to look further. That is why a binding may be rebuilt from its
  version at any time, and why activation replaces bindings rather than editing
  them.

  ## The version reference is composite

      FOREIGN KEY (workflow_version_id, installation_id)
        REFERENCES workflow_versions (id, installation_id)

  so a binding cannot name another tenant's version, and cascades with it.
  Because a version is immutable, a binding always points at a program that
  cannot change underneath it.

  ## Uniqueness with absent discriminators

  A binding's identity is `(version, kind, type, channel_id, user_id, alias)`,
  and most of those are `NULL` for most kinds: a `manual` binding has no
  channel, a `pumble_event` binding has no alias. Under PostgreSQL's default
  rule two `NULL`s are distinct, which would let the same binding be inserted
  twice. The index therefore declares `NULLS NOT DISTINCT`, so "no channel" is
  one value rather than infinitely many.

  ## The manual alias is unique among enabled bindings only

  Two workflows may both have owned the alias `deploy` over time; only one may
  answer to it now. The partial unique index carries `WHERE enabled AND alias
  IS NOT NULL`, which is the same shape as the `workflows` slug index and lets
  a disabled binding keep its history without blocking its successor.
  """

  use Ecto.Migration

  def change do
    create table(:trigger_bindings) do
      add :installation_id,
          references(:installations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :workflow_version_id,
          references(:workflow_versions,
            type: :binary_id,
            on_delete: :delete_all,
            with: [installation_id: :installation_id]
          ),
          null: false

      # The trigger class, from `Definition.Trigger.types/0`.
      add :kind, :string, null: false

      # The class-specific discriminator: a Pumble event name, a manual entry
      # point, a schedule type. Absent for a class that has only one form.
      add :type, :string

      add :channel_id, :string
      add :user_id, :string
      add :alias, :string

      add :filter_config, :map, null: false, default: fragment("'{}'::jsonb")
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    # The event-lookup index. Column order matches the predicate ingress writes:
    # tenant first, then class, then the event name, then the channel.
    create index(:trigger_bindings, [:installation_id, :kind, :type, :channel_id],
             where: "enabled",
             name: :trigger_bindings_lookup_index
           )

    # One materialized binding per trigger identity per version.
    create unique_index(
             :trigger_bindings,
             [:workflow_version_id, :kind, :type, :channel_id, :user_id, :alias],
             nulls_distinct: false,
             name: :trigger_bindings_identity_index
           )

    # The manual alias a person types. See the module documentation.
    create unique_index(:trigger_bindings, [:installation_id, :alias],
             where: "enabled AND alias IS NOT NULL",
             name: :trigger_bindings_enabled_alias_index
           )

    create constraint(:trigger_bindings, :trigger_bindings_kind_check,
             check: "kind IN ('pumble_event','manual','schedule','webhook','manual_test')"
           )
  end
end
