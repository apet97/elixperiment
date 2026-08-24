defmodule PumbleAutomation.Repo.Migrations.CreateWorkflowVersions do
  @moduledoc """
  Creates `workflow_versions`, the append-only record of what a workflow *is*.

  A draft changes as often as an author saves. A version never changes at all.
  The engine binds an execution to a version id, so the program a run started
  under is the program it finishes under, whatever the author does meanwhile.

  ## Immutability is a rule about writers, not a database trigger

  Section 14.2 of the plan allows a database trigger "only if operationally
  justified". No trigger is created here. The only writer is
  `PumbleAutomation.Workflows.WorkflowVersion`, which offers an insert and
  raises on an update, and the table has no `updated_at` column, so a row that
  changed would be visible as a row whose content no longer hashes to its
  stored `definition_hash`. A trigger would add a privileged object to audit
  and carry across environments for a guarantee the single writer already
  gives. Revisit that if a second writer ever appears.

  ## The tenant cannot drift from the workflow's tenant

  `installation_id` is not merely validated in a changeset. The workflow
  reference is composite:

      FOREIGN KEY (workflow_id, installation_id)
        REFERENCES workflows (id, installation_id)

  which is why `workflows` gains a `(id, installation_id)` unique index it does
  not otherwise need. A version whose tenant differs from its workflow's tenant
  is not a bug to catch in review; it is a row PostgreSQL refuses.

  ## `compiled_definition` and `compiler_version` are nullable

  The compiler is Phase 6. Until it exists, a version carries its source and
  its hash and nothing else, and a row written today stays readable when the
  compiler starts filling those columns. They become mandatory when activation
  is the only path that creates a version.

  ## `workflows.active_version_id` gets its foreign key here

  The column was created without one in `20260815000004`, because the table it
  names did not exist. The reference is added now with `NO ACTION`, not
  `RESTRICT`:

    * deleting a version that a workflow is running is refused either way, so
      the live pointer cannot be orphaned;
    * `NO ACTION` defers that check to the end of the statement, so erasing a
      tenant — which deletes the workflow and its versions in one cascading
      statement — still succeeds. `RESTRICT` is checked per row and would
      abort that cascade.

  Nilifying was rejected: it would turn "somebody deleted the running program"
  into a silent deactivation instead of an error.
  """

  use Ecto.Migration

  def change do
    # The target of the composite foreign key below. `id` is already unique;
    # PostgreSQL requires a unique constraint over the exact referenced pair.
    create unique_index(:workflows, [:id, :installation_id])

    create table(:workflow_versions) do
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

      add :version_number, :integer, null: false

      # What the author wrote, canonicalized before it was hashed.
      add :source_definition, :map, null: false

      # Filled by the Phase 6 compiler. See the module documentation.
      add :compiled_definition, :map
      add :compiler_version, :string

      # Lowercase hex SHA-256 of the canonical encoding of `source_definition`.
      add :definition_hash, :string, null: false, size: 64

      add :required_scopes, {:array, :string}, null: false, default: []
      add :referenced_secret_ids, {:array, :uuid}, null: false, default: []
      add :referenced_connection_ids, {:array, :uuid}, null: false, default: []

      add :created_by_member_id,
          references(:workspace_members, type: :binary_id, on_delete: :nilify_all)

      add :activated_at, :utc_datetime_usec

      # No `updated_at`. A row here is never updated.
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # Monotonic numbering inside one workflow. The allocator takes the workflow
    # row lock before reading `max + 1`; this index is what makes a lost race
    # an error rather than a duplicate.
    create unique_index(:workflow_versions, [:workflow_id, :version_number])

    # The same content is the same version. Re-activating an unchanged draft
    # must reuse the existing version rather than mint a second identical one.
    create unique_index(:workflow_versions, [:workflow_id, :definition_hash])

    # Version history for one tenant's workflow, newest first.
    create index(:workflow_versions, [:installation_id, :workflow_id])

    # The target of the composite foreign keys that bindings and schedules use.
    create unique_index(:workflow_versions, [:id, :installation_id])

    create constraint(:workflow_versions, :workflow_versions_version_number_check,
             check: "version_number >= 1"
           )

    create constraint(:workflow_versions, :workflow_versions_definition_hash_check,
             check: "definition_hash ~ '^[0-9a-f]{64}$'"
           )

    # The deferred reference from `20260815000004`. See the module docs.
    alter table(:workflows) do
      modify :active_version_id,
             references(:workflow_versions, type: :binary_id, on_delete: :nothing),
             from: :binary_id
    end
  end
end
