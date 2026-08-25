defmodule PumbleAutomation.Installations.OauthState do
  @moduledoc """
  One outstanding OAuth redirect, recognised by the digest of its state token.

  The token itself is 256 random bits held only by the browser, in the URL of
  the round trip. This table stores `:sha256` of it and nothing else, so a copy
  of the database does not let anyone complete someone else's authorization.
  Use `digest/1` on both sides: on the way out to store, and on the way back to
  look up.

  ## One-time and short-lived

  A state is consumable once. `OauthStates.consume/1` sets `:consumed_at` in a
  dedicated atomic update before the callback exchanges the code. A state that
  already has a value is refused. A later exchange or database failure cannot
  make the state replayable. `:expires_at` is ten minutes out by convention.
  An expired state is treated as absent because the
  caller must not learn whether a token ever existed.

  ## Intent

  The intent fixes what the callback is allowed to do, and is decided before the
  redirect, never inferred from what comes back:

    * `install` — a first installation.
    * `reinstall` — a workspace that already has a row.
    * `signin` — a browser session for an existing member.
    * `connect_user` — a user authorization inside an existing installation.

  ## Return path is a key, not a path

  `:return_path_key` names an entry in an application-owned table of
  destinations. Storing a real path here would make this row an open-redirect
  primitive the moment anything reflected it.

  `:installation_id` is a hint only: `install` has no installation yet, so the
  column is nullable and the callback still verifies what it acts on.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @intents ~w(install reinstall signin connect_user)

  @fields ~w(
    state_digest intent installation_id return_path_key expires_at consumed_at
    request_metadata
  )a

  @derive {Inspect, except: [:state_digest]}

  @type t :: %__MODULE__{}

  schema "oauth_states" do
    field :state_digest, :binary
    field :intent, :string
    field :installation_id, :binary_id
    field :return_path_key, :string
    field :expires_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec
    field :request_metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Builds an insert or an update.

  The digest must be exactly the 32 bytes `digest/1` produces. A shorter value
  usually means a caller stored a raw token, so it is refused rather than
  stored.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = state, attrs) do
    state
    |> cast(attrs, @fields)
    |> validate_required([:state_digest, :intent, :expires_at])
    |> validate_inclusion(:intent, @intents)
    |> validate_digest()
    |> validate_metadata()
    |> unique_constraint(:state_digest)
    |> check_constraint(:intent, name: :oauth_states_intent_check)
    |> foreign_key_constraint(:installation_id)
  end

  @doc """
  Returns the SHA-256 digest of a state token.

  The only supported way to turn a token into a row identifier.
  """
  @spec digest(binary()) :: binary()
  def digest(token) when is_binary(token), do: :crypto.hash(:sha256, token)

  @doc "The number of bytes `digest/1` returns."
  @spec digest_bytes() :: pos_integer()
  def digest_bytes, do: 32

  @doc "The intents a state may carry."
  @spec intents() :: [String.t()]
  def intents, do: @intents

  @doc """
  Returns whether the state can still be used at `now`.

  A consumed or expired state is unusable, and callers treat unusable and
  missing as the same answer.
  """
  @spec usable?(t(), DateTime.t()) :: boolean()
  def usable?(%__MODULE__{consumed_at: nil, expires_at: expires_at}, now) do
    DateTime.compare(expires_at, now) == :gt
  end

  def usable?(%__MODULE__{}, _now), do: false

  defp validate_digest(changeset) do
    case get_field(changeset, :state_digest) do
      nil ->
        changeset

      digest when is_binary(digest) and byte_size(digest) == 32 ->
        changeset

      _other ->
        add_error(changeset, :state_digest, "must be a 32 byte SHA-256 digest")
    end
  end

  defp validate_metadata(changeset) do
    case get_field(changeset, :request_metadata) do
      nil -> put_change(changeset, :request_metadata, %{})
      map when is_map(map) and not is_struct(map) -> changeset
      _other -> add_error(changeset, :request_metadata, "must be a map")
    end
  end
end
