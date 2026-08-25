defmodule PumbleAutomation.Ingress.ReceivedEvent do
  @moduledoc """
  One accepted callback, as the ingress ledger stores it.

  A row here is the durable identity of a delivery: which tenant, which
  provider and class, which dedup key, the digest of the raw body, and a
  bounded sanitized snapshot. Matching and execution creation read
  this row; they do not re-parse the wire body.

  ## No raw body

  There is no column that could hold the bytes Pumble or a webhook caller
  posted. `:raw_body_hash` is SHA-256 of those bytes. `:data` is the
  normalized remainder after secrets have been refused. That is the whole
  payload this table is allowed to remember.

  ## Dedup uniqueness is database-enforced

  `(installation_id, provider, dedup_key)` is unique. A second insert of the
  same key is a changeset conflict, which callers treat as "this delivery
  already exists" rather than as a server error.

  ## Retention is a date, not a comment

  `:retain_until` must fall after `:received_at` and at most thirty days
  later, matching the configured receipt-retention window. An out-of-range
  value cannot persist.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias PumbleAutomation.Error

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @providers ~w(pumble webhook browser schedule)
  @classes ~w(event interaction lifecycle webhook manual schedule)
  @processing_states ~w(received processed failed)

  @max_dedup_key 128
  @max_provider_id 256
  @max_type 64
  @max_data_bytes 64 * 1024
  @hash_bytes 32
  @retention_days 30

  @fields ~w(installation_id provider class type dedup_key provider_id raw_body_hash
             data received_at occurred_at processing_state retain_until)a

  @derive {Inspect, except: [:raw_body_hash]}

  @type t :: %__MODULE__{}

  schema "received_events" do
    field :installation_id, :binary_id
    field :provider, :string
    field :class, :string
    field :type, :string
    field :dedup_key, :string
    field :provider_id, :string
    field :raw_body_hash, :binary, redact: true
    field :data, :map, default: %{}
    field :received_at, :utc_datetime_usec
    field :occurred_at, :utc_datetime_usec
    field :processing_state, :string, default: "received"
    field :retain_until, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Builds an insert or a processing-state update.

  `:installation_id`, `:provider`, `:class`, `:type`, `:dedup_key`, and
  `:raw_body_hash` are required. Missing clocks default to now, and a missing
  retention date defaults to thirty days after receipt.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = event, attrs) do
    event
    |> cast(attrs, @fields)
    |> put_received_at()
    |> put_occurred_at()
    |> put_retain_until()
    |> validate_required([
      :installation_id,
      :provider,
      :class,
      :type,
      :dedup_key,
      :raw_body_hash,
      :received_at,
      :occurred_at,
      :processing_state,
      :retain_until
    ])
    |> validate_inclusion(:provider, @providers)
    |> validate_inclusion(:class, @classes)
    |> validate_inclusion(:processing_state, @processing_states)
    |> validate_length(:type, min: 1, max: @max_type)
    |> validate_length(:dedup_key, min: 1, max: @max_dedup_key)
    |> validate_length(:provider_id, min: 1, max: @max_provider_id)
    |> validate_raw_body_hash()
    |> validate_retention_window()
    |> validate_bounded_data()
    |> validate_sanitized_data()
    |> unique_constraint(:dedup_key,
      name: :received_events_installation_id_provider_dedup_key_index
    )
    |> check_constraint(:provider, name: :received_events_provider_check)
    |> check_constraint(:class, name: :received_events_class_check)
    |> check_constraint(:processing_state, name: :received_events_processing_state_check)
    |> check_constraint(:dedup_key, name: :received_events_dedup_key_check)
    |> check_constraint(:raw_body_hash, name: :received_events_raw_body_hash_check)
    |> check_constraint(:retain_until, name: :received_events_retention_window_check)
    |> foreign_key_constraint(:installation_id)
  end

  @doc "The providers a receipt may name."
  @spec providers() :: [String.t()]
  def providers, do: @providers

  @doc "The ingress classes a receipt may name."
  @spec classes() :: [String.t()]
  def classes, do: @classes

  @doc "The SHA-256 digest of a raw callback body."
  @spec hash_body(binary()) :: binary()
  def hash_body(raw) when is_binary(raw), do: :crypto.hash(:sha256, raw)

  @doc "The number of bytes `hash_body/1` returns."
  @spec hash_bytes() :: pos_integer()
  def hash_bytes, do: @hash_bytes

  @doc "How many days a receipt is retained after it arrives."
  @spec retention_days() :: pos_integer()
  def retention_days, do: @retention_days

  @doc "The greatest encoded size of `:data`, in bytes."
  @spec max_data_bytes() :: pos_integer()
  def max_data_bytes, do: @max_data_bytes

  @doc """
  Receipts whose retention date is strictly before `now`.

  The predicate is the one `received_events_retain_until_index` was built for.
  """
  @spec due_for_retention(DateTime.t()) :: Ecto.Query.t()
  def due_for_retention(%DateTime{} = now) do
    from e in __MODULE__, where: e.retain_until < ^now
  end

  defp put_received_at(changeset) do
    case get_field(changeset, :received_at) do
      nil -> put_change(changeset, :received_at, DateTime.utc_now())
      _received_at -> changeset
    end
  end

  defp put_occurred_at(changeset) do
    case get_field(changeset, :occurred_at) do
      nil -> put_change(changeset, :occurred_at, get_field(changeset, :received_at))
      _occurred_at -> changeset
    end
  end

  defp put_retain_until(changeset) do
    case get_field(changeset, :retain_until) do
      nil ->
        case get_field(changeset, :received_at) do
          %DateTime{} = received_at ->
            put_change(changeset, :retain_until, DateTime.add(received_at, @retention_days, :day))

          _missing ->
            changeset
        end

      _retain_until ->
        changeset
    end
  end

  defp validate_raw_body_hash(changeset) do
    case get_field(changeset, :raw_body_hash) do
      nil ->
        changeset

      hash when is_binary(hash) and byte_size(hash) == @hash_bytes ->
        changeset

      _other ->
        add_error(changeset, :raw_body_hash, "must be a 32 byte SHA-256 digest")
    end
  end

  defp validate_retention_window(changeset) do
    received_at = get_field(changeset, :received_at)
    retain_until = get_field(changeset, :retain_until)

    cond do
      is_nil(received_at) or is_nil(retain_until) ->
        changeset

      DateTime.compare(retain_until, received_at) != :gt ->
        add_error(changeset, :retain_until, "must be after received_at")

      DateTime.compare(retain_until, DateTime.add(received_at, @retention_days, :day)) == :gt ->
        add_error(changeset, :retain_until, "must be within #{@retention_days} days of receipt")

      true ->
        changeset
    end
  end

  defp validate_bounded_data(changeset) do
    case get_field(changeset, :data) do
      nil ->
        changeset

      data ->
        if json_within?(data, @max_data_bytes) do
          changeset
        else
          add_error(changeset, :data, "is too large")
        end
    end
  end

  defp validate_sanitized_data(changeset) do
    case get_field(changeset, :data) do
      nil ->
        changeset

      data ->
        if sanitized_map?(data) do
          changeset
        else
          add_error(changeset, :data, "must not contain secret-looking keys")
        end
    end
  end

  defp json_within?(map, max_bytes)
       when is_map(map) and is_integer(max_bytes) and max_bytes > 0 do
    case Jason.encode(map) do
      {:ok, json} -> byte_size(json) <= max_bytes
      {:error, _reason} -> false
    end
  end

  defp json_within?(_map, _max_bytes), do: false

  defp sanitized_map?(map) when is_map(map) and not is_struct(map) do
    Enum.all?(map, fn {key, value} ->
      not secret_key?(key) and sanitized_value?(value)
    end)
  end

  defp sanitized_map?(_map), do: false

  defp sanitized_value?(value) when is_map(value) and not is_struct(value),
    do: sanitized_map?(value)

  defp sanitized_value?(value) when is_list(value), do: Enum.all?(value, &sanitized_value?/1)
  defp sanitized_value?(_value), do: true

  defp secret_key?(key) when is_atom(key), do: key |> Atom.to_string() |> secret_key?()
  defp secret_key?(key) when is_binary(key), do: Regex.match?(Error.secret_key_pattern(), key)
  defp secret_key?(_key), do: false
end
