defmodule PumbleAutomation.Installations.UserSession do
  @moduledoc """
  One browser session, recognised by the digest of its opaque token.

  The token is random bytes in a `Secure`, `HttpOnly`, `SameSite=Lax` cookie and
  is never written here: the table stores `:sha256` of it, through `digest/1`.
  There is deliberately no column that could hold the raw value, so no future
  change can add one by accident.

  ## Two expiries

  `:idle_expires_at` moves forward as the session is used and ends a session
  someone walked away from. `:absolute_expires_at` does not move and ends a
  session that has simply lived too long, however active it was. A session is
  usable only while both are in the future and `:revoked_at` is still null; an
  expired session is treated as absent.

  Rotate the session after sign-in, after a role change, and after a sensitive
  action: insert a new row and revoke the old one, rather than editing this one.

  `:user_agent_hash` is a hash, not a user agent string. It is a weak signal for
  detecting a stolen cookie, and it is stored hashed because the raw value is
  identifying and this table does not need it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @fields ~w(
    workspace_member_id token_digest issued_at last_used_at idle_expires_at
    absolute_expires_at revoked_at user_agent_hash
  )a

  @derive {Inspect, except: [:token_digest, :user_agent_hash]}

  @type t :: %__MODULE__{}

  schema "user_sessions" do
    field :workspace_member_id, :binary_id
    field :token_digest, :binary
    field :issued_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec
    field :idle_expires_at, :utc_datetime_usec
    field :absolute_expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :user_agent_hash, :binary

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Builds an insert or an update.

  Refuses a digest that is not the 32 bytes `digest/1` produces, and an idle
  expiry later than the absolute one, which would make the absolute limit a
  decoration.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = session, attrs) do
    session
    |> cast(attrs, @fields)
    |> validate_required([
      :workspace_member_id,
      :token_digest,
      :issued_at,
      :idle_expires_at,
      :absolute_expires_at
    ])
    |> validate_digest(:token_digest)
    |> validate_user_agent_hash()
    |> validate_expiry_order()
    |> unique_constraint(:token_digest)
    |> check_constraint(:idle_expires_at, name: :user_sessions_expiry_order_check)
    |> foreign_key_constraint(:workspace_member_id)
  end

  @doc "Returns the SHA-256 digest of a session token or a user agent string."
  @spec digest(binary()) :: binary()
  def digest(value) when is_binary(value), do: :crypto.hash(:sha256, value)

  @doc "The number of bytes `digest/1` returns."
  @spec digest_bytes() :: pos_integer()
  def digest_bytes, do: 32

  @doc """
  Returns whether the session may still be used at `now`.

  Revoked, idle-expired, and absolutely expired all answer false.
  """
  @spec usable?(t(), DateTime.t()) :: boolean()
  def usable?(%__MODULE__{revoked_at: nil} = session, now) do
    DateTime.compare(session.idle_expires_at, now) == :gt and
      DateTime.compare(session.absolute_expires_at, now) == :gt
  end

  def usable?(%__MODULE__{}, _now), do: false

  defp validate_digest(changeset, field) do
    case get_field(changeset, field) do
      nil -> changeset
      digest when is_binary(digest) and byte_size(digest) == 32 -> changeset
      _other -> add_error(changeset, field, "must be a 32 byte SHA-256 digest")
    end
  end

  defp validate_user_agent_hash(changeset) do
    case get_field(changeset, :user_agent_hash) do
      nil -> changeset
      _hash -> validate_digest(changeset, :user_agent_hash)
    end
  end

  defp validate_expiry_order(changeset) do
    idle = get_field(changeset, :idle_expires_at)
    absolute = get_field(changeset, :absolute_expires_at)

    if is_nil(idle) or is_nil(absolute) or DateTime.compare(idle, absolute) != :gt do
      changeset
    else
      add_error(changeset, :idle_expires_at, "cannot be after the absolute expiry")
    end
  end
end
