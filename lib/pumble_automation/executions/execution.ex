defmodule PumbleAutomation.Executions.Execution do
  @moduledoc """
  One run of one immutable workflow version.

  A row here is the durable execution state machine: which program is
  running, which step is current, what context it has accumulated, and whether
  anybody has asked it to stop. Workers claim it, finalize it, and wait on it;
  they do not invent a second copy of that state in memory.

  ## The execution key is identity for ingress

  `:execution_key` is unique inside one installation. Two deliveries that name
  the same key are one run. The insert is what collapses them; the execution
  service returns the existing row when the unique index refuses a second.

  ## Lineage

  A run that starts from an event has no parent: `:root_execution_id` is nil
  and `:lineage_depth` is 0. A derived run names its root and counts how far
  it is from that root. Depth three is the configured final hop; the
  check constraint is that number, not a reminder in a comment.

  ## Optimistic locking

  `:lock_version` is the same claim token `PumbleAutomation.Workflows.Schedule`
  uses. Two workers that read version 7 both try to write 8, and one of them
  updates a row. The loser sees zero rows and treats the job as stale.

  ## Context is bounded and sanitized

  `:context` and `:trigger_snapshot` are JSONB. They hold what a later step
  may read, never a secret value. A document larger than the 256 KiB context limit
  is a validation error, not a database crash. Keys that read like credentials
  are refused on write.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias PumbleAutomation.Error
  alias PumbleAutomation.Limits

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(queued running waiting_delay waiting_approval paused_uncertain completed failed cancelled)
  @terminal ~w(completed failed cancelled)

  @max_execution_key 256
  @max_cancellation_reason 500

  @fields ~w(installation_id workflow_id workflow_version_id received_event_id execution_key
             status current_node_id context trigger_snapshot root_execution_id lineage_depth
             cancelled_at cancelled_by_member_id cancellation_reason lock_version)a

  @type t :: %__MODULE__{}

  schema "executions" do
    field :installation_id, :binary_id
    field :workflow_id, :binary_id
    field :workflow_version_id, :binary_id
    field :received_event_id, :binary_id
    field :execution_key, :string
    field :status, :string, default: "queued"
    field :current_node_id, :string
    field :context, :map, default: %{}
    field :trigger_snapshot, :map, default: %{}
    field :root_execution_id, :binary_id
    field :lineage_depth, :integer, default: 0
    field :cancelled_at, :utc_datetime_usec
    field :cancelled_by_member_id, :binary_id
    field :cancellation_reason, :string
    field :lock_version, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Builds an insert or an update.

  `:installation_id`, `:workflow_id`, `:workflow_version_id`, and
  `:execution_key` are required. The tenant on those parents is enforced by
  composite foreign keys, not by this changeset guessing.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = execution, attrs) do
    execution
    |> cast(attrs, @fields)
    |> validate_required([
      :installation_id,
      :workflow_id,
      :workflow_version_id,
      :execution_key,
      :status
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:execution_key, min: 1, max: @max_execution_key)
    |> validate_length(:cancellation_reason, max: @max_cancellation_reason)
    |> validate_number(:lock_version, greater_than_or_equal_to: 0)
    |> validate_number(:lineage_depth,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: max_lineage_depth()
    )
    |> validate_uuid(:current_node_id)
    |> validate_uuid(:received_event_id)
    |> validate_uuid(:root_execution_id)
    |> validate_lineage()
    |> validate_bounded_map(:context, max_context_bytes())
    |> validate_bounded_map(:trigger_snapshot, max_context_bytes())
    |> validate_sanitized_map(:context)
    |> validate_sanitized_map(:trigger_snapshot)
    |> unique_constraint(:execution_key, name: :executions_installation_id_execution_key_index)
    |> check_constraint(:status, name: :executions_status_check)
    |> check_constraint(:execution_key, name: :executions_execution_key_check)
    |> check_constraint(:lock_version, name: :executions_lock_version_check)
    |> check_constraint(:lineage_depth, name: :executions_lineage_depth_check)
    |> check_constraint(:root_execution_id, name: :executions_lineage_root_check)
    |> foreign_key_constraint(:installation_id)
    |> foreign_key_constraint(:workflow_id)
    |> foreign_key_constraint(:workflow_version_id)
    |> foreign_key_constraint(:root_execution_id)
    |> foreign_key_constraint(:received_event_id)
  end

  @doc "The statuses a run may hold."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "The statuses that have no ordinary outgoing transition."
  @spec terminal_statuses() :: [String.t()]
  def terminal_statuses, do: @terminal

  @doc "Whether `status` is terminal."
  @spec terminal?(term()) :: boolean()
  def terminal?(status) when is_atom(status), do: terminal?(Atom.to_string(status))
  def terminal?(status) when is_binary(status), do: status in @terminal
  def terminal?(_status), do: false

  @doc "The greatest encoded size of context or a trigger snapshot, in bytes."
  @spec max_context_bytes() :: pos_integer()
  def max_context_bytes, do: Limits.get(:context_size_bytes)

  @doc "The greatest allowed lineage depth."
  @spec max_lineage_depth() :: pos_integer()
  def max_lineage_depth, do: Limits.get(:lineage_depth)

  @doc """
  Whether `map` encodes as JSON of at most `max_bytes`.

  A value that cannot be encoded is not within the bound: callers treat that
  as overflow too, so a hostile payload cannot crash the insert.
  """
  @spec json_within?(term(), pos_integer()) :: boolean()
  def json_within?(map, max_bytes) when is_map(map) and is_integer(max_bytes) and max_bytes > 0 do
    case Jason.encode(map) do
      {:ok, json} -> byte_size(json) <= max_bytes
      {:error, _reason} -> false
    end
  end

  def json_within?(_map, _max_bytes), do: false

  @doc "Whether `map` has no key that `PumbleAutomation.Error` treats as a secret."
  @spec sanitized_map?(term()) :: boolean()
  def sanitized_map?(map) when is_map(map) and not is_struct(map) do
    Enum.all?(map, fn {key, value} ->
      not secret_key?(key) and sanitized_value?(value)
    end)
  end

  def sanitized_map?(_map), do: false

  defp sanitized_value?(value) when is_map(value) and not is_struct(value),
    do: sanitized_map?(value)

  defp sanitized_value?(value) when is_list(value), do: Enum.all?(value, &sanitized_value?/1)
  defp sanitized_value?(_value), do: true

  defp secret_key?(key) when is_atom(key), do: key |> Atom.to_string() |> secret_key?()
  defp secret_key?(key) when is_binary(key), do: Regex.match?(Error.secret_key_pattern(), key)
  defp secret_key?(_key), do: false

  defp validate_uuid(changeset, field) do
    case get_field(changeset, field) do
      nil ->
        changeset

      value ->
        case Ecto.UUID.cast(value) do
          {:ok, uuid} -> put_change(changeset, field, uuid)
          :error -> add_error(changeset, field, "must be a UUID")
        end
    end
  end

  defp validate_lineage(changeset) do
    depth = get_field(changeset, :lineage_depth) || 0
    root = get_field(changeset, :root_execution_id)

    cond do
      depth == 0 and not is_nil(root) ->
        add_error(changeset, :root_execution_id, "must be blank for a root execution")

      depth > 0 and is_nil(root) ->
        add_error(changeset, :root_execution_id, "must name the root execution")

      true ->
        changeset
    end
  end

  defp validate_bounded_map(changeset, field, max_bytes) do
    case get_field(changeset, field) do
      nil ->
        changeset

      map ->
        if json_within?(map, max_bytes) do
          changeset
        else
          add_error(changeset, field, "is too large")
        end
    end
  end

  defp validate_sanitized_map(changeset, field) do
    case get_field(changeset, field) do
      nil ->
        changeset

      map ->
        if sanitized_map?(map) do
          changeset
        else
          add_error(changeset, field, "must not contain secret-looking keys")
        end
    end
  end
end
