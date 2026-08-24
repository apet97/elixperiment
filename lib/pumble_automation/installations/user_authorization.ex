defmodule PumbleAutomation.Installations.UserAuthorization do
  @moduledoc """
  One Pumble user's own authorization inside an installation.

  A bot token can do what the app was granted; some actions must instead happen
  as the person who asked for them. This row holds that person's token, the
  scopes it was granted, and whether it is still usable.

  One row per user per installation. The unique index over
  `(installation_id, pumble_user_id)` is what makes "the authorization for this
  user" a single addressable row, so a re-authorization updates rather than
  accumulating tokens whose order nobody can reason about.

  ## Status

  `active` is usable. `revoked` was withdrawn, by the user or by us. `expired`
  stopped working on its own. Only `active` may be used to call Pumble; the
  other two are kept so that the history explains why a workflow stopped.

  ## Secrets

  `:encrypted_access_token` is ciphertext at rest and is excluded from
  `Inspect`. `:token_key_version` mirrors the envelope's key version for
  rotation reporting.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias PumbleAutomation.Crypto.EncryptedBinary

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(active revoked expired)

  @fields ~w(
    installation_id pumble_user_id encrypted_access_token token_key_version
    scopes status authorized_at revoked_at
  )a

  @derive {Inspect, except: [:encrypted_access_token]}

  @type t :: %__MODULE__{}

  schema "user_authorizations" do
    field :installation_id, :binary_id
    field :pumble_user_id, :string

    field :encrypted_access_token, EncryptedBinary,
      aad: "user_authorizations.encrypted_access_token"

    field :token_key_version, :integer
    field :scopes, {:array, :string}, default: []
    field :status, :string, default: "active"
    field :authorized_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Builds an insert or an update.

  The scope snapshot is normalized to a sorted, unique, non-blank list, so that
  a comparison against a later grant is a comparison of sets and not of the
  order a response happened to use.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = authorization, attrs) do
    authorization
    |> cast(attrs, @fields)
    |> validate_required([:installation_id, :pumble_user_id, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:token_key_version, greater_than: 0, less_than: 256)
    |> normalize_scopes()
    |> unique_constraint([:installation_id, :pumble_user_id])
    |> check_constraint(:status, name: :user_authorizations_status_check)
    |> foreign_key_constraint(:installation_id)
  end

  @doc "The statuses an authorization may hold."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  defp normalize_scopes(changeset) do
    case get_change(changeset, :scopes) do
      nil ->
        changeset

      scopes when is_list(scopes) ->
        normalized =
          scopes
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()
          |> Enum.sort()

        put_change(changeset, :scopes, normalized)

      _other ->
        changeset
    end
  end
end
