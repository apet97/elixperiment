defmodule PumbleAutomation.Executions.StepExecution do
  @moduledoc """
  One compiled node's progress inside one execution.

  A loop-free graph visits a node at most once, so `(execution_id, node_id)` is
  identity: two workers that both try to open the same step find one row, and
  the unique index is what makes the second insert fail rather than fork the
  run. Duplicate jobs after that row exists become no-ops in later P7 tasks;
  they do not create a second history.

  ## Input and output are summaries

  `:resolved_input` and `:output` are sanitized, bounded JSON. They are what
  an operator may read later, not what went on the wire. The hash of the
  input is computed here from the canonical encoding
  `PumbleAutomation.Workflows.WorkflowVersion` already uses, so a caller
  cannot claim a hash it did not earn. Secret-looking keys are refused.

  ## The effect key is derived

  Section 18.3 names an effect as `installation_id/execution_id/node_id`.
  That string is written on insert from those three columns and is not
  accepted from the caller.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Workflows.Node
  alias PumbleAutomation.Workflows.WorkflowVersion

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @node_types Node.types() |> Map.keys() |> Enum.sort()

  @max_edge 64
  @max_remote_reference 256
  @max_uncertainty_reason 500

  @cast_fields ~w(installation_id execution_id node_id node_type status resolved_input output
                  selected_edge remote_reference uncertainty_reason attempt_count)a

  @type t :: %__MODULE__{}

  schema "step_executions" do
    field :installation_id, :binary_id
    field :execution_id, :binary_id
    field :node_id, :string
    field :node_type, :string
    field :status, :string, default: "queued"
    field :resolved_input, :map, default: %{}
    field :resolved_input_hash, :string
    field :output, :map, default: %{}
    field :selected_edge, :string
    field :effect_key, :string
    field :remote_reference, :string
    field :uncertainty_reason, :string
    field :attempt_count, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Builds an insert or an update.

  `:resolved_input_hash` and `:effect_key` are ignored when supplied: both are
  computed from columns this changeset already holds.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = step, attrs) do
    step
    |> cast(attrs, @cast_fields)
    |> validate_required([:installation_id, :execution_id, :node_id, :node_type, :status])
    |> validate_inclusion(:status, Execution.statuses())
    |> validate_inclusion(:node_type, @node_types)
    |> validate_uuid(:node_id)
    |> validate_length(:selected_edge, max: @max_edge)
    |> validate_length(:remote_reference, max: @max_remote_reference)
    |> validate_length(:uncertainty_reason, max: @max_uncertainty_reason)
    |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
    |> validate_bounded_map(:resolved_input)
    |> validate_bounded_map(:output)
    |> validate_sanitized_map(:resolved_input)
    |> validate_sanitized_map(:output)
    |> put_input_hash()
    |> put_effect_key()
    |> unique_constraint([:execution_id, :node_id],
      name: :step_executions_execution_id_node_id_index
    )
    |> check_constraint(:status, name: :step_executions_status_check)
    |> check_constraint(:node_type, name: :step_executions_node_type_check)
    |> check_constraint(:attempt_count, name: :step_executions_attempt_count_check)
    |> check_constraint(:resolved_input_hash, name: :step_executions_input_hash_check)
    |> foreign_key_constraint(:execution_id)
    |> foreign_key_constraint(:installation_id)
  end

  @doc "The statuses a step may hold, which are the execution statuses."
  @spec statuses() :: [String.t()]
  def statuses, do: Execution.statuses()

  @doc "The compiled node types a step may name."
  @spec node_types() :: [String.t()]
  def node_types, do: @node_types

  @doc "The greatest encoded size of resolved input or output, in bytes."
  @spec max_payload_bytes() :: pos_integer()
  def max_payload_bytes, do: Execution.max_context_bytes()

  @doc """
  The Section 18.3 effect key for this tenant, run, and node.

  The same three identifiers always produce the same string, which is what
  lets an uncertain write be recognized as the write that already happened.
  """
  @spec effect_key(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) :: String.t()
  def effect_key(installation_id, execution_id, node_id)
      when is_binary(installation_id) and is_binary(execution_id) and is_binary(node_id) do
    installation_id <> "/" <> execution_id <> "/" <> node_id
  end

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

  defp validate_bounded_map(changeset, field) do
    case get_field(changeset, field) do
      nil ->
        changeset

      map ->
        if Execution.json_within?(map, max_payload_bytes()) do
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
        if Execution.sanitized_map?(map) do
          changeset
        else
          add_error(changeset, field, "must not contain secret-looking keys")
        end
    end
  end

  defp put_input_hash(changeset) do
    case get_change(changeset, :resolved_input) do
      nil -> changeset
      input -> put_change(changeset, :resolved_input_hash, WorkflowVersion.definition_hash(input))
    end
  end

  defp put_effect_key(changeset) do
    installation_id = get_field(changeset, :installation_id)
    execution_id = get_field(changeset, :execution_id)
    node_id = get_field(changeset, :node_id)

    if is_binary(installation_id) and is_binary(execution_id) and is_binary(node_id) do
      put_change(changeset, :effect_key, effect_key(installation_id, execution_id, node_id))
    else
      changeset
    end
  end
end
