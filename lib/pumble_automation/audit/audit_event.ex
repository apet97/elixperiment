defmodule PumbleAutomation.Audit.AuditEvent do
  @moduledoc """
  One recorded, security-relevant thing that happened.

  The schema is deliberately narrow. An audit row answers who did what, to
  what, in which tenant, when, and under which correlation id. It is not a log
  line, not a debugging aid, and not a place to keep a copy of a payload.

  ## Metadata is an allowlist, not a free map

  `:metadata` accepts only the keys in `allowed_metadata_keys/0`, only scalar
  values, and only up to `max_metadata_bytes/0` bytes once encoded. An
  unrecognised key is rejected rather than dropped, because silently discarding
  a field makes a caller believe it recorded something it did not.

  A denylist runs in front of the allowlist and refuses anything that reads like
  a token, secret, code, password, credential, signature, or raw body. The
  allowlist alone would already exclude those; the denylist is what keeps a
  future addition to the allowlist from quietly introducing one, and a test
  holds the two to each other.

  ## Tenancy

  `:installation_id` is required. The single exception is the pre-install OAuth
  namespace, where a callback can fail before any installation row exists; such
  an event carries a correlation id and a safe reason and nothing else. Every
  other action without a tenant is a defect, so the changeset refuses it.

  ## No update, no delete

  This module defines `changeset/1` for insertion only. There is no update
  changeset, and neither this module nor `PumbleAutomation.Audit.Writer`
  exposes a delete. See the migration for the limits of that guarantee.

  ## No hash chain

  There is no prior-event hash. A hash that only this database can verify is
  key-management theater: anyone who can `UPDATE audit_events` can rewrite the
  chain. Tamper-evident storage needs an external log, which this application
  does not operate. The honest guarantee is append-only through the application
  API.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias PumbleAutomation.Error

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # Who can act. `:system` is this application acting on its own schedule,
  # `:job` is a background worker, and the two user types are people.
  @actor_types ~w(system job user pumble_user)

  # The reserved action namespaces. An action is "namespace.verb_phrase".
  # Reserving them now keeps later coverage from inventing a second vocabulary
  # for the same events.
  @action_namespaces ~w(oauth installation credential connection secret workflow execution schedule admin security)

  # The one namespace allowed to record an event with no installation.
  @preinstall_namespace "oauth."

  @action_format ~r/^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$/
  @max_action_length 100
  @max_metadata_bytes 4_096

  # Key names this table refuses on top of `PumbleAutomation.Error`'s secret
  # pattern. Those cover credentials; these cover the other thing an audit row
  # must never become, which is a copy of a request or a response.
  @denied_key_pattern ~r/(body|payload|content|raw|private)/i

  # Scalar, non-identifying, non-sensitive facts about an event. Add to this
  # list only with the same test that guards it in mind.
  @allowed_metadata_keys ~w(
    reason result outcome source http_status attempt count duration_ms
    actor_role scope_name target_kind previous_state next_state retryable
    schema_version changed_field_count resource_name
    timezone previous_timezone schedule_type previous_schedule_type
  )

  @type t :: %__MODULE__{}

  schema "audit_events" do
    field :installation_id, :binary_id
    field :actor_type, :string
    field :actor_id, :string
    field :action, :string
    field :resource_type, :string
    field :resource_id, :string
    field :correlation_id, :string
    field :metadata, :map, default: %{}

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @doc """
  Builds the one and only changeset: an insertion.

  Returns an invalid changeset rather than raising, so that a caller composing
  into an `Ecto.Multi` gets a clean rollback instead of an exception in the
  middle of a transaction.
  """
  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :installation_id,
      :actor_type,
      :actor_id,
      :action,
      :resource_type,
      :resource_id,
      :correlation_id,
      :metadata
    ])
    |> validate_required([:actor_type, :action, :correlation_id])
    |> validate_inclusion(:actor_type, @actor_types)
    |> validate_length(:action, max: @max_action_length)
    |> validate_format(:action, @action_format)
    |> validate_namespace()
    |> validate_tenancy()
    |> validate_metadata()
  end

  @doc "The metadata keys a caller may set, as strings."
  @spec allowed_metadata_keys() :: [String.t()]
  def allowed_metadata_keys, do: @allowed_metadata_keys

  @doc "The maximum encoded size of `:metadata`, in bytes."
  @spec max_metadata_bytes() :: pos_integer()
  def max_metadata_bytes, do: @max_metadata_bytes

  @doc "The action-code namespaces reserved for audit."
  @spec action_namespaces() :: [String.t()]
  def action_namespaces, do: @action_namespaces

  @doc "The actor types an audit row may name."
  @spec actor_types() :: [String.t()]
  def actor_types, do: @actor_types

  @doc "The namespace whose actions may be recorded without an installation."
  @spec preinstall_namespace() :: String.t()
  def preinstall_namespace, do: @preinstall_namespace

  @doc """
  Returns whether a metadata key name is refused outright.

  A key is refused when it reads like a credential, by
  `PumbleAutomation.Error.secret_key_pattern/0`, or like a copy of a request or
  a response, by this module's own pattern. Exposed so that a test can hold the
  allowlist to it and catch an unsafe addition before it ships.
  """
  @spec denied_key?(String.t()) :: boolean()
  def denied_key?(key) when is_binary(key) do
    Regex.match?(Error.secret_key_pattern(), key) or Regex.match?(@denied_key_pattern, key)
  end

  defp validate_namespace(changeset) do
    action = get_field(changeset, :action)

    cond do
      is_nil(action) -> changeset
      namespace_of(action) in @action_namespaces -> changeset
      true -> add_error(changeset, :action, "uses an unreserved namespace")
    end
  end

  defp namespace_of(action), do: action |> String.split(".") |> List.first()

  defp validate_tenancy(changeset) do
    action = get_field(changeset, :action) || ""

    cond do
      not is_nil(get_field(changeset, :installation_id)) ->
        changeset

      String.starts_with?(action, @preinstall_namespace) ->
        changeset

      true ->
        add_error(changeset, :installation_id, "is required outside the pre-install namespace")
    end
  end

  defp validate_metadata(changeset) do
    case get_field(changeset, :metadata) do
      nil ->
        put_change(changeset, :metadata, %{})

      metadata when is_map(metadata) and not is_struct(metadata) ->
        check_metadata(changeset, metadata)

      _other ->
        add_error(changeset, :metadata, "must be a map of scalar values")
    end
  end

  defp check_metadata(changeset, metadata) do
    normalized = Map.new(metadata, fn {key, value} -> {stringify(key), value} end)

    normalized
    |> Enum.reduce(put_change(changeset, :metadata, normalized), fn {key, value}, acc ->
      validate_entry(acc, key, value)
    end)
    |> validate_metadata_size(normalized)
  end

  defp validate_entry(changeset, key, value) do
    cond do
      denied_key?(key) ->
        add_error(changeset, :metadata, "key #{key} names a secret and is never accepted")

      key not in @allowed_metadata_keys ->
        add_error(changeset, :metadata, "key #{key} is not in the metadata allowlist")

      not scalar?(value) ->
        add_error(changeset, :metadata, "value for #{key} must be a string, number, or boolean")

      true ->
        changeset
    end
  end

  defp validate_metadata_size(changeset, metadata) do
    case Jason.encode(metadata) do
      {:ok, encoded} when byte_size(encoded) <= @max_metadata_bytes ->
        changeset

      {:ok, _encoded} ->
        add_error(changeset, :metadata, "exceeds the #{@max_metadata_bytes} byte limit")

      {:error, _reason} ->
        add_error(changeset, :metadata, "is not JSON encodable")
    end
  end

  defp scalar?(value) do
    is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value)
  end

  defp stringify(key) when is_atom(key), do: Atom.to_string(key)
  defp stringify(key) when is_binary(key), do: key
  defp stringify(key), do: inspect(key)
end
