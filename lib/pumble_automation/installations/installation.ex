defmodule PumbleAutomation.Installations.Installation do
  @moduledoc """
  One Pumble workspace that installed this application.

  This row is the tenant. Every other tenant-owned table reaches it directly or
  through a mandatory parent, and every tenant-scoped query starts from its id.

  ## The workspace id never changes

  `:pumble_workspace_id` is an opaque string owned by Pumble. It is unique, and
  it is immutable after insert: changing it would silently move every row of one
  workspace under another workspace's identity, which is the worst outcome this
  schema can produce. The changeset refuses the change, and the unique index
  refuses a second row for the same workspace.

  A reinstall is therefore an update of the existing row, not a new one.

  ## Lifecycle

      active ──> degraded ──> active
        │  ╲         │
        │   ╲        ▼
        │    ──> revoked ──> active
        ▼             │
      uninstalled <───┘
        │  ╲
        │   ──> active        (reinstall)
        ▼
      deleted                 (terminal)

  `degraded` means the credential still exists but the workspace is not fully
  usable, usually after a scope or permission change. `revoked` means the token
  no longer works. `uninstalled` means the workspace removed the app; the row
  and its audit history stay until `deletion_scheduled_at` passes and the tenant
  data is erased, which is when the status becomes `deleted`.

  A status is only ever set through `changeset/2`, which refuses a transition
  the lifecycle does not allow, and the database refuses any value outside the
  set.

  ## Secrets

  `:encrypted_bot_token` is ciphertext in the database and plaintext in the
  struct, so the struct excludes it from `Inspect`. `:token_key_version` mirrors
  the key version inside the envelope as a plain integer, so a rotation can
  report progress without decrypting anything.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias PumbleAutomation.Crypto.EncryptedBinary

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(active degraded revoked uninstalled deleted)

  # Which status may follow which. Staying put is always allowed, so that an
  # update that does not touch the status is never rejected.
  @transitions %{
    "active" => ~w(active degraded revoked uninstalled),
    "degraded" => ~w(degraded active revoked uninstalled),
    "revoked" => ~w(revoked active uninstalled),
    "uninstalled" => ~w(uninstalled active deleted),
    "deleted" => ~w(deleted)
  }

  @fields ~w(
    pumble_workspace_id status workspace_name_snapshot bot_user_id
    encrypted_bot_token token_key_version bot_scopes user_scopes
    installed_by_pumble_user_id authorized_at revoked_at uninstalled_at
    deletion_scheduled_at
  )a

  @derive {Inspect, except: [:encrypted_bot_token]}

  @type t :: %__MODULE__{}

  schema "installations" do
    field :pumble_workspace_id, :string
    field :status, :string, default: "active"
    field :workspace_name_snapshot, :string
    field :bot_user_id, :string

    field :encrypted_bot_token, EncryptedBinary, aad: "installations.encrypted_bot_token"

    field :token_key_version, :integer
    field :bot_scopes, {:array, :string}, default: []
    field :user_scopes, {:array, :string}, default: []
    field :installed_by_pumble_user_id, :string
    field :authorized_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :uninstalled_at, :utc_datetime_usec
    field :deletion_scheduled_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Builds an insert or an update.

  Rejects an attempt to change `:pumble_workspace_id` on a persisted row, a
  status outside `statuses/0`, and a transition outside the documented
  lifecycle. Scope arrays are normalized to a sorted, unique, non-blank list, so
  that two writes of the same requested-scope snapshot produce the same row and
  a comparison never depends on configuration order. These arrays do not prove
  which scopes Pumble granted.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = installation, attrs) do
    installation
    |> cast(attrs, @fields)
    |> validate_required([:pumble_workspace_id, :status])
    |> validate_immutable(:pumble_workspace_id)
    |> validate_inclusion(:status, @statuses)
    |> validate_transition()
    |> validate_number(:token_key_version, greater_than: 0, less_than: 256)
    |> normalize_scopes(:bot_scopes)
    |> normalize_scopes(:user_scopes)
    |> validate_token_key_version()
    |> unique_constraint(:pumble_workspace_id)
    |> check_constraint(:status, name: :installations_status_check)
  end

  @doc "The statuses an installation may hold."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "The statuses that may follow `status`."
  @spec next_statuses(String.t()) :: [String.t()]
  def next_statuses(status), do: Map.get(@transitions, status, [])

  defp validate_immutable(changeset, field) do
    case {Map.fetch!(changeset.data, field), get_change(changeset, field)} do
      {nil, _change} -> changeset
      {_current, nil} -> changeset
      {_current, _change} -> add_error(changeset, field, "cannot be changed")
    end
  end

  defp validate_transition(changeset) do
    case {changeset.data.status, get_change(changeset, :status)} do
      {_current, nil} -> changeset
      {nil, _next} -> changeset
      {current, next} -> check_transition(changeset, current, next)
    end
  end

  defp check_transition(changeset, current, next) do
    if next in Map.get(@transitions, current, []) do
      changeset
    else
      add_error(changeset, :status, "cannot move from #{current} to #{next}")
    end
  end

  defp validate_token_key_version(changeset) do
    token = get_field(changeset, :encrypted_bot_token)
    version = get_field(changeset, :token_key_version)

    if is_nil(token) or not is_nil(version) do
      changeset
    else
      add_error(changeset, :token_key_version, "is required when a bot token is stored")
    end
  end

  defp normalize_scopes(changeset, field) do
    case get_change(changeset, field) do
      nil ->
        changeset

      scopes when is_list(scopes) ->
        put_change(changeset, field, normalize_scope_list(scopes))

      _other ->
        changeset
    end
  end

  defp normalize_scope_list(scopes) do
    scopes
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end
end
