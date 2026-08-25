defmodule PumbleAutomation.Repo.Migrations.CreateSchedules do
  @moduledoc """
  Creates `schedules`: the due-work queue a clock reads.

  Like a trigger binding, a schedule is a projection. The authoritative
  schedule configuration lives in the version's `source_definition`; this row
  carries the one fact the dispatcher needs to sort on, which is
  `next_run_at`, plus enough configuration to compute the next one.

  ## `next_run_at` is UTC, and the timezone is carried beside it

  A daily 09:00 schedule in `Europe/Belgrade` is not a fixed UTC instant: it
  moves twice a year. So the row stores both — the timezone the author chose,
  and the UTC instant the next run falls on under that timezone. The
  dispatcher's query only ever compares UTC, and only the recomputation after a
  run needs the zone.

  **Timezone validation here is a format check only.** No time zone database is
  a dependency of this application yet, so `Europe/Atlantis` is refused for its
  shape and accepted for its existence. The schedule calculator owns real schedule
  computation and is where a zone must be resolved against a real database;
  `PumbleAutomation.Workflows.Schedule` carries the same note.

  ## The due query, and the index that serves it

      WHERE enabled AND next_run_at <= now()

  `(enabled, next_run_at)` is the matching index: equality on the leading
  column, range on the trailing one, so the scan starts at the first due row
  and stops at the first row that is not.

  ## One enabled schedule per workflow

  The schedule schema's unique active identity is a partial unique
  index on `workflow_id WHERE enabled`. A workflow has one clock. Superseded
  schedules stay as disabled rows so the history of what was dispatched still
  resolves.

  ## `lock_version` is for the dispatcher, not for the editor

  Two dispatcher runs must not both claim the same due schedule. The claim is
  an optimistic update that carries the version it read; the loser sees zero
  rows and moves on rather than dispatching a duplicate.
  """

  use Ecto.Migration

  def change do
    create table(:schedules) do
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

      add :schedule_type, :string, null: false
      add :config, :map, null: false, default: fragment("'{}'::jsonb")
      add :timezone, :string, null: false, default: "Etc/UTC"

      add :next_run_at, :utc_datetime_usec
      add :enabled, :boolean, null: false, default: true
      add :lock_version, :integer, null: false, default: 0

      # Last dispatch metadata. `last_run_at` is when the clock fired;
      # `last_dispatched_at` is when a job was actually enqueued for it.
      add :last_run_at, :utc_datetime_usec
      add :last_dispatched_at, :utc_datetime_usec
      add :last_dispatch_status, :string
      add :dispatch_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    # The due-schedule query. See the module documentation.
    create index(:schedules, [:enabled, :next_run_at], name: :schedules_due_index)

    # One clock per workflow at a time.
    create unique_index(:schedules, [:workflow_id],
             where: "enabled",
             name: :schedules_enabled_workflow_index
           )

    create index(:schedules, [:installation_id, :workflow_id])

    create constraint(:schedules, :schedules_schedule_type_check,
             check: "schedule_type IN ('once','every_minutes','every_hours','daily','weekly')"
           )

    # Shape only, never existence. See the module documentation.
    create constraint(:schedules, :schedules_timezone_check,
             check: "timezone ~ '^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+.-]+){0,2}$'"
           )

    create constraint(:schedules, :schedules_lock_version_check, check: "lock_version >= 0")

    create constraint(:schedules, :schedules_dispatch_count_check, check: "dispatch_count >= 0")
  end
end
