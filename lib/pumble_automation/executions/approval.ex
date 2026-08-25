defmodule PumbleAutomation.Executions.Approval do
  @moduledoc """
  One approval pause: who may decide, and what they decided.

  The Pumble message carries an opaque public action id and a token this table
  never stores in plaintext. `:token_digest` is SHA-256 of that token, the
  same rule `PumbleAutomation.Installations.OauthState` already follows, so a
  copy of the database does not let anyone press the button as someone else.

  ## Insert pending, decide once

  `changeset/2` inserts a pending row. It raises for a persisted struct.
  `decide/2` is the only update: a single `UPDATE ... WHERE status = 'pending'`
  that records the decision. Two concurrent clicks serialize on the row; the
  second statement sees `pending` gone and matches nothing. Duplicate valid
  clicks therefore return a conflict rather than a second resume, which is
  what the approval contract requires.

  `:lock_version` is the same optimistic token executions use, so a stale UI
  that still shows pending cannot overwrite a decision it did not see.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending approved rejected timed_out cancelled)
  @decisions ~w(approved rejected timed_out cancelled)

  @max_approvers_bytes 16 * 1024
  @max_pumble_id 128
  @nonce_bytes 32

  @insert_fields ~w(installation_id execution_id step_execution_id public_action_id
                    token_digest nonce allowed_approvers pumble_channel_id
                    pumble_message_id expires_at)a

  @derive {Inspect, except: [:token_digest, :nonce]}

  @type t :: %__MODULE__{}

  schema "approvals" do
    field :installation_id, :binary_id
    field :execution_id, :binary_id
    field :step_execution_id, :binary_id
    field :status, :string, default: "pending"
    field :public_action_id, :string
    field :token_digest, :binary, redact: true
    field :nonce, :binary, redact: true
    field :allowed_approvers, :map, default: %{}
    field :pumble_channel_id, :string
    field :pumble_message_id, :string
    field :expires_at, :utc_datetime_usec
    field :decided_at, :utc_datetime_usec
    field :decided_by_pumble_user_id, :string
    field :decided_by_member_id, :binary_id
    field :lock_version, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Builds the insertion changeset for a pending approval.

  Raises when given a persisted struct. A stored approval is decided through
  `decide/2`, never through another changeset.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(approval, attrs)

  def changeset(%__MODULE__{id: nil} = approval, attrs) do
    approval
    |> cast(attrs, @insert_fields)
    |> put_change(:status, "pending")
    |> validate_required([
      :installation_id,
      :execution_id,
      :step_execution_id,
      :public_action_id,
      :token_digest,
      :nonce,
      :expires_at
    ])
    |> validate_length(:public_action_id, min: 1, max: 64)
    |> validate_length(:pumble_channel_id, max: @max_pumble_id)
    |> validate_length(:pumble_message_id, max: @max_pumble_id)
    |> validate_digest()
    |> validate_nonce()
    |> validate_bounded_approvers()
    |> unique_constraint(:step_execution_id, name: :approvals_step_execution_id_index)
    |> unique_constraint(:public_action_id, name: :approvals_public_action_id_index)
    |> unique_constraint(:token_digest, name: :approvals_token_digest_index)
    |> check_constraint(:status, name: :approvals_status_check)
    |> check_constraint(:token_digest, name: :approvals_token_digest_check)
    |> foreign_key_constraint(:execution_id)
    |> foreign_key_constraint(:step_execution_id)
    |> foreign_key_constraint(:installation_id)
  end

  def changeset(%__MODULE__{}, _attrs) do
    raise "PumbleAutomation.Executions.Approval cannot be updated through changeset/2. " <>
            "Use decide/2 to record a decision."
  end

  @doc "The statuses an approval may hold."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "The statuses `decide/2` may write."
  @spec decisions() :: [String.t()]
  def decisions, do: @decisions

  @doc "Returns the SHA-256 digest of an approval token."
  @spec digest(binary()) :: binary()
  def digest(token) when is_binary(token), do: :crypto.hash(:sha256, token)

  @doc "The number of bytes `digest/1` returns."
  @spec digest_bytes() :: pos_integer()
  def digest_bytes, do: 32

  @doc "The number of random bytes a nonce holds."
  @spec nonce_bytes() :: pos_integer()
  def nonce_bytes, do: @nonce_bytes

  @doc """
  Keyword set that cancels a pending approval and rotates its token.

  The new nonce and digest cannot verify a previously issued button payload.
  Callers apply this through `update_all` on `status = 'pending'`.
  """
  @spec cancel_set(DateTime.t()) :: keyword()
  def cancel_set(%DateTime{} = now) do
    nonce = :crypto.strong_rand_bytes(@nonce_bytes)

    [
      status: "cancelled",
      decided_at: now,
      token_digest: digest(nonce),
      nonce: nonce,
      updated_at: now
    ]
  end

  @doc """
  Stores the Pumble channel and message ids after a confirmed send.

  The write matches a still-pending row. A cancelled, decided, or stale
  approval is a conflict so a late delivery cannot resurrect a wait.
  """
  @spec record_message(t(), map()) :: {:ok, t()} | {:error, Error.t()}
  def record_message(%__MODULE__{id: id, lock_version: lock_version}, attrs)
      when is_map(attrs) do
    with {:ok, channel_id} <- optional_pumble_id(attrs, :pumble_channel_id),
         {:ok, message_id} <- required_pumble_id(attrs, :pumble_message_id) do
      now = DateTime.utc_now()

      set =
        [pumble_message_id: message_id, lock_version: lock_version + 1, updated_at: now]
        |> put_channel(channel_id)

      query =
        from a in __MODULE__,
          where: a.id == ^id and a.status == "pending" and a.lock_version == ^lock_version,
          select: a

      case Repo.update_all(query, set: set) do
        {1, [row]} -> {:ok, row}
        {0, _rows} -> {:error, not_pending()}
      end
    end
  end

  defp put_channel(set, nil), do: set
  defp put_channel(set, channel_id), do: Keyword.put(set, :pumble_channel_id, channel_id)

  defp optional_pumble_id(attrs, field) do
    case Map.get(attrs, field) || Map.get(attrs, Atom.to_string(field)) do
      nil -> {:ok, nil}
      id -> pumble_id(id, field)
    end
  end

  defp required_pumble_id(attrs, field) do
    case Map.get(attrs, field) || Map.get(attrs, Atom.to_string(field)) do
      id -> pumble_id(id, field)
    end
  end

  defp pumble_id(id, _field)
       when is_binary(id) and id != "" and byte_size(id) <= @max_pumble_id do
    {:ok, id}
  end

  defp pumble_id(_id, _field) do
    {:error,
     Error.new(:validation, :invalid_approval,
       message: "The Pumble message reference is not valid."
     )}
  end

  defp not_pending do
    Error.new(:conflict, :approval_not_pending,
      message: "This approval is no longer waiting for delivery."
    )
  end

  @doc """
  Records a decision on a pending approval, exactly once.

  The write matches `status = 'pending'` and the `:lock_version` the caller
  read. A second caller, or a caller holding a stale version, gets a
  `:conflict` error with code `:approval_already_decided`.

  `attrs` must include `:status` as one of `decisions/0`. `:decided_at`
  defaults to now. `:decided_by_pumble_user_id` and `:decided_by_member_id`
  are optional.
  """
  @spec decide(t(), map()) :: {:ok, t()} | {:error, Error.t()}
  def decide(%__MODULE__{id: id, lock_version: lock_version}, attrs) when is_map(attrs) do
    with {:ok, status} <- decision_status(attrs) do
      now = DateTime.utc_now()

      set = [
        status: status,
        decided_at: Map.get(attrs, :decided_at) || Map.get(attrs, "decided_at") || now,
        decided_by_pumble_user_id:
          Map.get(attrs, :decided_by_pumble_user_id) ||
            Map.get(attrs, "decided_by_pumble_user_id"),
        decided_by_member_id:
          Map.get(attrs, :decided_by_member_id) || Map.get(attrs, "decided_by_member_id"),
        lock_version: lock_version + 1,
        updated_at: now
      ]

      query =
        from a in __MODULE__,
          where: a.id == ^id and a.status == "pending" and a.lock_version == ^lock_version,
          select: a

      case Repo.update_all(query, set: set) do
        {1, [row]} -> {:ok, row}
        {0, _rows} -> {:error, already_decided()}
      end
    end
  end

  defp decision_status(attrs) do
    status = Map.get(attrs, :status) || Map.get(attrs, "status")

    if status in @decisions do
      {:ok, status}
    else
      {:error,
       Error.new(:validation, :invalid_approval_decision,
         message: "The approval decision is not valid."
       )}
    end
  end

  defp already_decided do
    Error.new(:conflict, :approval_already_decided,
      message: "This approval has already been decided."
    )
  end

  defp validate_digest(changeset) do
    case get_field(changeset, :token_digest) do
      nil ->
        changeset

      digest when is_binary(digest) and byte_size(digest) == 32 ->
        changeset

      _other ->
        add_error(changeset, :token_digest, "must be a 32 byte SHA-256 digest")
    end
  end

  defp validate_nonce(changeset) do
    case get_field(changeset, :nonce) do
      nil ->
        changeset

      nonce when is_binary(nonce) and byte_size(nonce) == @nonce_bytes ->
        changeset

      _other ->
        add_error(changeset, :nonce, "must be #{@nonce_bytes} random bytes")
    end
  end

  defp validate_bounded_approvers(changeset) do
    case get_field(changeset, :allowed_approvers) do
      nil ->
        put_change(changeset, :allowed_approvers, %{})

      map when is_map(map) and not is_struct(map) ->
        if Execution.json_within?(map, @max_approvers_bytes) do
          changeset
        else
          add_error(changeset, :allowed_approvers, "is too large")
        end

      _other ->
        add_error(changeset, :allowed_approvers, "must be a map")
    end
  end
end
