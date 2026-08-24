defmodule PumbleAutomation.Workflows.Schedule do
  @moduledoc """
  The one durable fact a clock-driven workflow needs: when it next runs.

  A schedule row is a projection of the version's schedule trigger, in the same
  sense that `PumbleAutomation.Workflows.TriggerBinding` is a projection of the
  other trigger classes. The authoritative configuration is in the version. The
  columns here are the ones a dispatcher's `WHERE` clause and its recomputation
  need, and nothing else.

  ## `next_run_at` is UTC; `timezone` is what it was computed from

  "Every weekday at 09:00 in `Europe/Belgrade`" is not a fixed offset — it
  moves twice a year. Storing only the local rule would make the due query
  compute zones for every row it examines; storing only the instant would lose
  the rule. So the row stores both, the query compares UTC, and only the
  recomputation after a run reads the zone.

  ## Timezone validation is a shape check, not an existence check

  `valid_timezone?/1` still only checks the shape of an IANA identifier, so
  `Europe/Atlantis` passes. Existence is `ScheduleCalculator`'s job: activation
  and the dispatcher refuse a zone tzdata does not know.

  ## Claiming a due schedule

  The dispatcher first locks a candidate installation and workflow. It then
  locks the due row with `FOR UPDATE SKIP LOCKED` (`lock_due/2`) in the same
  transaction. This order matches activation. Two dispatchers cannot hold the
  same row, and a dispatcher does not wait behind a contended row. `claim/2`
  remains the optimistic `lock_version` update for callers that already read
  the row without a lock: two writers that both saw version 7 both try to write
  8, and exactly one updates.

  ## Disabled never runs

  The due query filters on `enabled`, and the unique index that says a workflow
  has one clock is itself partial on `enabled`. Superseding a schedule is
  disabling the old row and inserting a new one in one transaction; the old row
  stays as history and can never be selected again.

  ## First run, edit, and disable

  Activation and reactivation compute `next_run_at` with `first_run_at/2` from
  the transaction's activation time. The calculator is exclusive, so the first
  fire is strictly after that instant. Missed slots before activation are not
  caught up; the dispatcher's misfire policy applies only to an enabled row
  that is already due.

  Editing a draft does not touch this table. A new activation disables the
  previous enabled row and inserts a new projection in the same transaction.

  Deactivation disables the enabled row so unclaimed future occurrences are
  not selected. The dispatcher locks a due row with `FOR UPDATE SKIP LOCKED`
  before `Engine.create/2`. An occurrence whose create already committed may
  still run, bound to the version it named. That is the documented race, not
  a defect.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias PumbleAutomation.Error
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Workflows.Definition.ScheduleConfig
  alias PumbleAutomation.Workflows.Node.Config
  alias PumbleAutomation.Workflows.ScheduleCalculator

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @schedule_types ~w(once every_minutes every_hours daily weekly)
  @dispatch_statuses ~w(enqueued skipped failed)

  @timezone_max 64

  # An IANA identifier is one to three slash-separated components of letters,
  # digits, and `_ + - .`, beginning with a letter. Shape only. See the module
  # documentation.
  @timezone_format ~r/\A[A-Za-z][A-Za-z0-9_+-]*(\/[A-Za-z0-9_+.-]+){0,2}\z/

  @fields ~w(installation_id workflow_id workflow_version_id schedule_type config timezone
             next_run_at enabled lock_version last_run_at last_dispatched_at
             last_dispatch_status dispatch_count)a

  @type t :: %__MODULE__{}

  schema "schedules" do
    field :installation_id, :binary_id
    field :workflow_id, :binary_id
    field :workflow_version_id, :binary_id
    field :schedule_type, :string
    field :config, :map, default: %{}
    field :timezone, :string, default: "Etc/UTC"
    field :next_run_at, :utc_datetime_usec
    field :enabled, :boolean, default: true
    field :lock_version, :integer, default: 0
    field :last_run_at, :utc_datetime_usec
    field :last_dispatched_at, :utc_datetime_usec
    field :last_dispatch_status, :string
    field :dispatch_count, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Builds an insert, or the disable that supersedes one."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = schedule, attrs) do
    schedule
    |> cast(attrs, @fields)
    |> validate_required([
      :installation_id,
      :workflow_id,
      :workflow_version_id,
      :schedule_type,
      :timezone
    ])
    |> validate_inclusion(:schedule_type, @schedule_types)
    |> validate_inclusion(:last_dispatch_status, @dispatch_statuses)
    |> validate_length(:timezone, min: 1, max: @timezone_max)
    |> validate_format(:timezone, @timezone_format)
    |> validate_number(:lock_version, greater_than_or_equal_to: 0)
    |> validate_number(:dispatch_count, greater_than_or_equal_to: 0)
    |> unique_constraint(:workflow_id, name: :schedules_enabled_workflow_index)
    |> check_constraint(:schedule_type, name: :schedules_schedule_type_check)
    |> check_constraint(:timezone, name: :schedules_timezone_check)
    |> foreign_key_constraint(:workflow_id)
    |> foreign_key_constraint(:workflow_version_id)
    |> foreign_key_constraint(:installation_id)
  end

  @doc "The schedule types a row may hold."
  @spec schedule_types() :: [String.t()]
  def schedule_types, do: @schedule_types

  @doc "The outcomes a dispatch attempt may record."
  @spec dispatch_statuses() :: [String.t()]
  def dispatch_statuses, do: @dispatch_statuses

  @doc """
  The first UTC instant this clock should fire after `reference`.

  `reference` is activation or reactivation time. The calculator is exclusive,
  so the first fire is strictly after that instant. There is no catch-up of
  slots that would have fallen before activation. A `once` clock whose `run_at`
  is not after `reference` is `:terminal`.
  """
  @spec first_run_at(ScheduleConfig.t() | map(), DateTime.t()) ::
          {:ok, DateTime.t()} | {:ok, :terminal} | {:error, Error.t()}
  def first_run_at(config, %DateTime{} = reference) do
    ScheduleCalculator.next(config, reference)
  end

  @doc """
  Insert attributes for one enabled schedule projection of `config`.

  `next_run_at` is `first_run_at/2` from `reference`, or `nil` when the clock
  is already terminal. An unknown timezone or invalid configuration fails
  rather than stamping `reference` itself.
  """
  @spec projection_attrs(
          %{
            installation_id: Ecto.UUID.t(),
            workflow_id: Ecto.UUID.t(),
            workflow_version_id: Ecto.UUID.t()
          },
          ScheduleConfig.t(),
          DateTime.t()
        ) :: {:ok, map()} | {:error, Error.t()}
  def projection_attrs(
        %{
          installation_id: installation_id,
          workflow_id: workflow_id,
          workflow_version_id: workflow_version_id
        },
        %ScheduleConfig{} = config,
        %DateTime{} = reference
      ) do
    case first_run_field(config, reference) do
      {:ok, next_run_at} ->
        {:ok,
         %{
           installation_id: installation_id,
           workflow_id: workflow_id,
           workflow_version_id: workflow_version_id,
           schedule_type: Atom.to_string(config.schedule_type),
           config: Config.encode(config),
           timezone: config.timezone || "Etc/UTC",
           next_run_at: next_run_at,
           enabled: true
         }}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  @doc """
  Whether `timezone` has the shape of an IANA identifier.

  Shape only. A zone that does not exist passes. See the module documentation.
  """
  @spec valid_timezone?(term()) :: boolean()
  def valid_timezone?(timezone) when is_binary(timezone) do
    byte_size(timezone) in 1..@timezone_max and Regex.match?(@timezone_format, timezone)
  end

  def valid_timezone?(_timezone), do: false

  @doc """
  The query for every schedule due at `now`, oldest first.

  The predicate is `enabled AND next_run_at <= now`, which is exactly the shape
  of the `(enabled, next_run_at)` index: equality on the leading column, range
  on the trailing one.
  """
  @spec due(DateTime.t()) :: Ecto.Query.t()
  def due(%DateTime{} = now) do
    from s in __MODULE__,
      where: s.enabled and not is_nil(s.next_run_at) and s.next_run_at <= ^now,
      order_by: [asc: s.next_run_at]
  end

  @doc """
  Due schedules locked with `FOR UPDATE SKIP LOCKED`, oldest first.

  Must run inside an open transaction. Rows another dispatcher already holds
  are skipped rather than waited on, so two dispatchers cannot process the
  same schedule at once. `limit` bounds one batch.
  """
  @spec lock_due(DateTime.t(), pos_integer()) :: Ecto.Query.t()
  def lock_due(%DateTime{} = now, limit) when is_integer(limit) and limit > 0 do
    from s in __MODULE__,
      where: s.enabled and not is_nil(s.next_run_at) and s.next_run_at <= ^now,
      order_by: [asc: s.next_run_at, asc: s.id],
      limit: ^limit,
      lock: "FOR UPDATE SKIP LOCKED"
  end

  @doc """
  The execution key for one firing of `schedule` at `scheduled_at`.

  Unique per `(schedule, instant)` so a retried dispatcher cannot create a
  second run for the same occurrence.
  """
  @spec occurrence_key(t(), DateTime.t()) :: String.t()
  def occurrence_key(%__MODULE__{id: id}, %DateTime{} = scheduled_at) when is_binary(id) do
    instant = DateTime.from_unix!(DateTime.to_unix(scheduled_at, :microsecond), :microsecond)
    "schedule:#{id}:#{DateTime.to_iso8601(instant)}"
  end

  @doc """
  Takes a due schedule, or reports that another dispatcher took it first.

  `updates` carries the new `:next_run_at` and any dispatch metadata. The write
  matches on the `lock_version` the caller read and increments it, so the loser
  of a race updates nothing and gets `:error`.
  """
  @spec claim(t(), keyword()) :: {:ok, t()} | :error
  def claim(%__MODULE__{id: id, lock_version: lock_version}, updates \\ []) do
    set =
      updates
      |> Keyword.take([:next_run_at, :last_run_at, :last_dispatched_at, :last_dispatch_status])
      |> Keyword.merge(lock_version: lock_version + 1, updated_at: DateTime.utc_now())

    query =
      from s in __MODULE__,
        where: s.id == ^id and s.lock_version == ^lock_version and s.enabled,
        select: s

    case Repo.update_all(query, set: set, inc: [dispatch_count: 1]) do
      {1, [claimed]} -> {:ok, claimed}
      {0, _rows} -> :error
    end
  end

  defp first_run_field(config, reference) do
    case first_run_at(config, reference) do
      {:ok, :terminal} -> {:ok, nil}
      {:ok, %DateTime{} = next} -> {:ok, next}
      {:error, %Error{} = error} -> {:error, error}
    end
  end
end
