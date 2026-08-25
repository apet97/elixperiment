defmodule PumbleAutomation.Repo.Migrations.CreateWorkflows do
  @moduledoc """
  Creates the workflow aggregate: identity, mutable draft, and ownership.

  This table arrives alone because it is the only workflow-schema record that has
  no dependency on a version, a binding, or a schedule. Those tables reference
  this one, so this one comes first.

  ## Deletion policy

  `installation_id` cascades, per `docs/operations/migrations.md`: erasing a
  tenant is one transaction, and a workflow has no meaning outside the
  workspace it was written in.

  The member references nilify. A member row outlives a person's access, but if
  one is ever removed the workflow must survive with its authorship unknown
  rather than disappear with it.

  ## `active_version_id` has no foreign key yet

  It names a row in `workflow_versions`, which does not exist until the
  versioning migration. A foreign key cannot reference an absent table, so the
  column is a plain `binary_id` here and the reference is added with that
  table. Nothing writes the column yet: a draft save sets the draft columns
  only.

  ## Uniqueness

  `(installation_id, slug)` is unique, and partial: the slug is the manual
  alias a person types, so two workflows in one workspace cannot answer to the
  same name, while any number of workflows may have no alias at all.
  """

  use Ecto.Migration

  def change do
    create table(:workflows) do
      add :installation_id,
          references(:installations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :name, :string, null: false
      add :slug, :string
      add :description, :text
      add :draft_definition, :map
      add :draft_revision, :integer, null: false, default: 0
      add :status, :string, null: false, default: "draft"

      # Set by activation, never by a draft save. The foreign key to
      # `workflow_versions` is added with that table.
      add :active_version_id, :binary_id

      add :created_by_member_id,
          references(:workspace_members, type: :binary_id, on_delete: :nilify_all)

      add :updated_by_member_id,
          references(:workspace_members, type: :binary_id, on_delete: :nilify_all)

      add :archived_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # The manual alias. Unique inside a workspace, absent when nobody starts
    # this workflow by hand.
    create unique_index(:workflows, [:installation_id, :slug],
             where: "slug IS NOT NULL",
             name: :workflows_installation_id_slug_index
           )

    # The list screen, and every tenant-scoped query.
    create index(:workflows, [:installation_id, :status])

    # "What is live", which the engine and the deactivation sweep both ask.
    create index(:workflows, [:active_version_id], where: "active_version_id IS NOT NULL")

    create constraint(:workflows, :workflows_status_check,
             check: "status IN ('draft','active','inactive','archived')"
           )

    create constraint(:workflows, :workflows_draft_revision_check, check: "draft_revision >= 0")
  end
end
