defmodule PumbleAutomation.Installations.WorkspaceMember do
  @moduledoc """
  A person who may use this application inside one installation.

  A member is local: the row exists because someone signed in to this
  application, and its role is this application's authority, not Pumble's. A
  Pumble workspace admin is not automatically an owner here, and losing a Pumble
  role does not silently change what someone can do here.

  ## Roles

    * `owner` — installation, members, secrets, activation, deletion, and the
      resolution of anything uncertain.
    * `editor` — workflows, tests, activation, and execution retry or cancel.
    * `viewer` — reads workflows and sanitized executions.

  Approver identity in a workflow is a separate concept and is never derived
  from this role.

  ## Disabling instead of deleting

  `:disabled_at` withdraws access while keeping the row, so that every
  execution, audit event, and secret that names this member still resolves to a
  person. Deleting a member would break that history.

  `:profile_snapshot` is a cached copy of the display fields Pumble returned. It
  exists so a screen can name a person without an API call, and it is a
  snapshot: never treated as current, never used for authorization.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @roles ~w(owner editor viewer)

  @fields ~w(installation_id pumble_user_id role profile_snapshot disabled_at)a

  @type t :: %__MODULE__{}

  schema "workspace_members" do
    field :installation_id, :binary_id
    field :pumble_user_id, :string
    field :role, :string, default: "viewer"
    field :profile_snapshot, :map, default: %{}
    field :disabled_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Builds an insert or an update.

  The profile snapshot must be a plain map. It is stored as given, so callers
  put display fields there and nothing else.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = member, attrs) do
    member
    |> cast(attrs, @fields)
    |> validate_required([:installation_id, :pumble_user_id, :role])
    |> validate_inclusion(:role, @roles)
    |> validate_profile_snapshot()
    |> unique_constraint([:installation_id, :pumble_user_id])
    |> check_constraint(:role, name: :workspace_members_role_check)
    |> foreign_key_constraint(:installation_id)
  end

  @doc "The local roles a member may hold, most privileged first."
  @spec roles() :: [String.t()]
  def roles, do: @roles

  defp validate_profile_snapshot(changeset) do
    case get_field(changeset, :profile_snapshot) do
      nil -> put_change(changeset, :profile_snapshot, %{})
      map when is_map(map) and not is_struct(map) -> changeset
      _other -> add_error(changeset, :profile_snapshot, "must be a map")
    end
  end
end
