defmodule PumbleAutomation.Repo.Migrations.CreateExecutions do
  @moduledoc """
  Creates the durable execution ledger: runs, steps, attempts, and approvals.

  Plan Section 14.4 is the column list. The engine in later P7 tasks reads and
  writes these rows; this migration is the constraint set those tasks inherit.

  ## Tenant alignment is a foreign key, not a review comment

  Every child names `installation_id` and references its parent with a
  composite key `(parent_id, installation_id)`. A step whose tenant is not its
  execution's tenant, or an approval whose step is not that execution's step,
  is a row PostgreSQL refuses.

  ## Uniqueness that identity depends on lives here

  * one execution per `(installation_id, execution_key)`;
  * one step per `(execution_id, node_id)`;
  * one attempt per `(step_execution_id, attempt_number)`;
  * one approval per step.

  Application code still validates. These indexes are what two concurrent
  writers cannot talk their way around.

  ## Attempts never gain `updated_at`

  An attempt is the external-effect ledger. A correction is a new attempt, not
  an update, the same rule `workflow_versions` already follows. No trigger is
  added: the only writer raises on a persisted struct, and a row whose
  timestamps include an update would be visible as a row that should not exist.

  ## `received_event_id` has no foreign key yet

  Ingress persists received events in P8. The column is here so an execution
  can name the event that created it without waiting for that table; the
  reference is added with it.
  """

  use Ecto.Migration

  def change do
    create_executions()
    create_step_executions()
    create_step_attempts()
    create_approvals()
  end

  defp create_executions do
    create table(:executions) do
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

      # Set by P8 ingress. See the module documentation.
      add :received_event_id, :binary_id

      add :execution_key, :string, null: false
      add :status, :string, null: false, default: "queued"
      add :current_node_id, :string

      add :context, :map, null: false, default: fragment("'{}'::jsonb")
      add :trigger_snapshot, :map, null: false, default: fragment("'{}'::jsonb")

      add :root_execution_id, :binary_id
      add :lineage_depth, :integer, null: false, default: 0

      add :cancelled_at, :utc_datetime_usec

      add :cancelled_by_member_id,
          references(:workspace_members, type: :binary_id, on_delete: :nilify_all)

      add :cancellation_reason, :string
      add :lock_version, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:executions, [:id, :installation_id])

    create unique_index(:executions, [:installation_id, :execution_key])

    create index(:executions, [:installation_id, :status])
    create index(:executions, [:installation_id, :workflow_id])

    create constraint(:executions, :executions_status_check,
             check:
               "status IN ('queued','running','waiting_delay','waiting_approval','paused_uncertain','completed','failed','cancelled')"
           )

    create constraint(:executions, :executions_execution_key_check,
             check: "char_length(execution_key) BETWEEN 1 AND 256"
           )

    create constraint(:executions, :executions_lock_version_check, check: "lock_version >= 0")

    create constraint(:executions, :executions_lineage_depth_check,
             check: "lineage_depth >= 0 AND lineage_depth <= 3"
           )

    create constraint(:executions, :executions_lineage_root_check,
             check:
               "(lineage_depth = 0 AND root_execution_id IS NULL) OR (lineage_depth > 0 AND root_execution_id IS NOT NULL)"
           )

    alter table(:executions) do
      modify :root_execution_id,
             references(:executions,
               type: :binary_id,
               on_delete: :delete_all,
               with: [installation_id: :installation_id]
             ),
             from: :binary_id
    end
  end

  defp create_step_executions do
    create table(:step_executions) do
      add :installation_id,
          references(:installations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :execution_id,
          references(:executions,
            type: :binary_id,
            on_delete: :delete_all,
            with: [installation_id: :installation_id]
          ),
          null: false

      add :node_id, :string, null: false
      add :node_type, :string, null: false
      add :status, :string, null: false, default: "queued"

      add :resolved_input, :map, null: false, default: fragment("'{}'::jsonb")
      add :resolved_input_hash, :string, size: 64
      add :output, :map, null: false, default: fragment("'{}'::jsonb")
      add :selected_edge, :string
      add :effect_key, :string
      add :remote_reference, :string
      add :uncertainty_reason, :string
      add :attempt_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:step_executions, [:execution_id, :node_id])
    create unique_index(:step_executions, [:id, :installation_id])
    create unique_index(:step_executions, [:id, :execution_id, :installation_id])
    create index(:step_executions, [:installation_id, :execution_id])

    create constraint(:step_executions, :step_executions_status_check,
             check:
               "status IN ('queued','running','waiting_delay','waiting_approval','paused_uncertain','completed','failed','cancelled')"
           )

    create constraint(:step_executions, :step_executions_node_type_check,
             check:
               "node_type IN ('condition','delay','approval','pumble_action','http_action','stop')"
           )

    create constraint(:step_executions, :step_executions_attempt_count_check,
             check: "attempt_count >= 0"
           )

    create constraint(:step_executions, :step_executions_input_hash_check,
             check: "resolved_input_hash IS NULL OR resolved_input_hash ~ '^[0-9a-f]{64}$'"
           )
  end

  defp create_step_attempts do
    create table(:step_attempts) do
      add :installation_id,
          references(:installations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :step_execution_id,
          references(:step_executions,
            type: :binary_id,
            on_delete: :delete_all,
            with: [installation_id: :installation_id]
          ),
          null: false

      add :attempt_number, :integer, null: false
      add :status, :string, null: false, default: "started"
      add :oban_job_id, :bigint
      add :started_at, :utc_datetime_usec, null: false
      add :ended_at, :utc_datetime_usec
      add :error_class, :string
      add :error_code, :string
      add :remote_status, :integer
      add :remote_request_id, :string
      add :retry_at, :utc_datetime_usec
      add :duration_ms, :integer
      add :diagnostics, :map, null: false, default: fragment("'{}'::jsonb")

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:step_attempts, [:step_execution_id, :attempt_number])
    create index(:step_attempts, [:installation_id, :step_execution_id])

    create constraint(:step_attempts, :step_attempts_status_check,
             check: "status IN ('started','succeeded','failed','uncertain','cancelled')"
           )

    create constraint(:step_attempts, :step_attempts_attempt_number_check,
             check: "attempt_number >= 1"
           )

    create constraint(:step_attempts, :step_attempts_duration_ms_check,
             check: "duration_ms IS NULL OR duration_ms >= 0"
           )
  end

  defp create_approvals do
    create table(:approvals) do
      add :installation_id,
          references(:installations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :execution_id,
          references(:executions,
            type: :binary_id,
            on_delete: :delete_all,
            with: [installation_id: :installation_id]
          ),
          null: false

      add :step_execution_id,
          references(:step_executions,
            type: :binary_id,
            on_delete: :delete_all,
            with: [execution_id: :execution_id, installation_id: :installation_id]
          ),
          null: false

      add :status, :string, null: false, default: "pending"
      add :public_action_id, :string, null: false
      add :token_digest, :binary, null: false
      add :nonce, :binary, null: false
      add :allowed_approvers, :map, null: false, default: fragment("'{}'::jsonb")
      add :pumble_channel_id, :string
      add :pumble_message_id, :string
      add :expires_at, :utc_datetime_usec, null: false
      add :decided_at, :utc_datetime_usec
      add :decided_by_pumble_user_id, :string

      add :decided_by_member_id,
          references(:workspace_members, type: :binary_id, on_delete: :nilify_all)

      add :lock_version, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:approvals, [:step_execution_id])
    create unique_index(:approvals, [:public_action_id])
    create unique_index(:approvals, [:token_digest])
    create index(:approvals, [:installation_id, :status])

    create constraint(:approvals, :approvals_status_check,
             check: "status IN ('pending','approved','rejected','timed_out','cancelled')"
           )

    create constraint(:approvals, :approvals_lock_version_check, check: "lock_version >= 0")

    create constraint(:approvals, :approvals_token_digest_check,
             check: "octet_length(token_digest) = 32"
           )
  end
end
