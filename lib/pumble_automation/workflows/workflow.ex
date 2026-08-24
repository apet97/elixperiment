defmodule PumbleAutomation.Workflows.Workflow do
  @moduledoc """
  One workflow: its identity, its mutable draft, and the version that is live.

  A row here is the aggregate an author works on. It belongs to exactly one
  installation, and every query for it carries that installation, so a workflow
  is never reachable from a tenant that does not own it.

  ## Draft and active version are separate

  `:draft_definition` is what the editor writes. `:active_version_id` names the
  immutable version the engine runs. They are different columns because they
  are different lifetimes: saving a draft a hundred times must not disturb what
  is running, and `save_draft/4` writes neither the active version nor the
  status to make that structural rather than careful.

  ## Optimistic concurrency

  Two people editing one workflow is normal, and a lost update is not. Every
  draft save states the revision it started from, and the write is a
  compare-and-swap:

      UPDATE workflows SET ... WHERE id = $1 AND draft_revision = $2

  When no row matches, nobody's work is overwritten. `save_draft/4` returns a
  `:conflict` error carrying the revision the row actually holds, so the caller
  can show the author what changed underneath them.

  ## Slug

  `:slug` is the manual alias: the name a person types after the slash command
  or picks in a shortcut. It is unique per installation and may be absent,
  because a workflow that no person starts by hand needs no name to type.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias PumbleAutomation.Error
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Limits

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(draft active inactive archived)

  @name_max 120
  @description_max 2000
  @slug_max 64
  @slug_format ~r/\A[a-z0-9][a-z0-9_-]*\z/

  @fields ~w(installation_id name slug description draft_definition draft_revision status
             active_version_id created_by_member_id updated_by_member_id archived_at)a

  @type t :: %__MODULE__{}

  schema "workflows" do
    field :installation_id, :binary_id
    field :name, :string
    field :slug, :string
    field :description, :string
    field :draft_definition, :map
    field :draft_revision, :integer, default: 0
    field :status, :string, default: "draft"
    field :active_version_id, :binary_id
    field :created_by_member_id, :binary_id
    field :updated_by_member_id, :binary_id
    field :archived_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Builds an insert or an update.

  The draft definition is validated as a definition, not as a map: a document
  that `PumbleAutomation.Workflows.Definition` refuses never reaches the
  database, so no row can hold a draft the editor cannot open again.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = workflow, attrs) do
    workflow
    |> cast(attrs, @fields)
    |> validate_required([:installation_id, :name, :status])
    |> validate_length(:name, min: 1, max: @name_max)
    |> validate_length(:description, max: @description_max)
    |> validate_length(:slug, min: 1, max: @slug_max)
    |> validate_format(:slug, @slug_format)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:draft_revision, greater_than_or_equal_to: 0)
    |> validate_draft_definition()
    |> unique_constraint(:slug, name: :workflows_installation_id_slug_index)
    |> check_constraint(:status, name: :workflows_status_check)
    |> check_constraint(:draft_revision, name: :workflows_draft_revision_check)
    |> foreign_key_constraint(:installation_id)
  end

  @doc "The statuses a workflow may hold."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "The greatest length of a workflow name."
  @spec name_max() :: pos_integer()
  def name_max, do: @name_max

  @doc "The greatest length of a workflow description."
  @spec description_max() :: pos_integer()
  def description_max, do: @description_max

  @doc "The greatest length of a workflow slug."
  @spec slug_max() :: pos_integer()
  def slug_max, do: @slug_max

  @doc """
  Saves a draft, but only if the row is still at `expected_revision`.

  `definition` is either a `PumbleAutomation.Workflows.Definition` or the plain
  map one decodes from. Either way it is decoded and re-encoded before the
  write, so what is stored is the canonical shape and a malformed draft is
  refused before it reaches the database.

  Returns the updated workflow with its new revision, or:

    * a `:conflict` error carrying `:current_revision` when somebody else saved
      first;
    * a `:not_found` error when the workflow does not exist inside the given
      installation;
    * a `:validation` error when the draft is not a definition, or is larger
      than the definition size limit.

  Options: `:updated_by_member_id`.
  """
  @spec save_draft(t(), Definition.t() | map(), non_neg_integer(), keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def save_draft(%__MODULE__{} = workflow, definition, expected_revision, opts \\ [])
      when is_integer(expected_revision) and expected_revision >= 0 do
    with {:ok, encoded} <- encode_definition(definition),
         :ok <- Limits.check_size(encoded) do
      compare_and_swap(workflow, encoded, expected_revision, opts)
    end
  end

  @doc """
  Decodes the draft a row holds.

  A row written by `save_draft/4` always decodes. A row whose draft is `nil` —
  a workflow created but never edited — returns a `:not_found` error rather
  than an empty definition, because "no draft yet" is a state a caller should
  handle, not one to paper over.
  """
  @spec draft(t()) :: {:ok, Definition.t()} | {:error, Error.t()}
  def draft(%__MODULE__{draft_definition: nil}) do
    {:error,
     Error.new(:not_found, :draft_not_found, message: "The workflow has no draft definition.")}
  end

  def draft(%__MODULE__{draft_definition: raw}), do: Definition.decode(raw)

  defp compare_and_swap(workflow, encoded, expected_revision, opts) do
    updates =
      [
        draft_definition: encoded,
        draft_revision: expected_revision + 1,
        updated_at: DateTime.utc_now()
      ]
      |> put_updater(Keyword.get(opts, :updated_by_member_id))

    query =
      from w in __MODULE__,
        where:
          w.id == ^workflow.id and w.installation_id == ^workflow.installation_id and
            w.draft_revision == ^expected_revision,
        select: w

    case Repo.update_all(query, set: updates) do
      {1, [updated]} -> {:ok, updated}
      {0, _rows} -> {:error, conflict(workflow, expected_revision)}
    end
  end

  defp put_updater(updates, nil), do: updates
  defp put_updater(updates, member_id), do: Keyword.put(updates, :updated_by_member_id, member_id)

  defp conflict(workflow, expected_revision) do
    query =
      from w in __MODULE__,
        where: w.id == ^workflow.id and w.installation_id == ^workflow.installation_id,
        select: w.draft_revision

    case Repo.one(query) do
      nil ->
        Error.new(:not_found, :workflow_not_found,
          message: "The workflow was not found in this workspace."
        )

      current_revision ->
        Error.new(:conflict, :draft_revision_conflict,
          message: "The workflow draft changed since it was opened.",
          details: %{expected_revision: expected_revision, current_revision: current_revision}
        )
    end
  end

  defp encode_definition(%Definition{} = definition) do
    case Definition.validate_limits(definition) do
      :ok -> {:ok, Definition.encode(definition)}
      {:error, %Error{}} = error -> error
    end
  end

  defp encode_definition(raw) when is_map(raw) do
    case Definition.decode(raw) do
      {:ok, definition} -> {:ok, Definition.encode(definition)}
      {:error, %Error{}} = error -> error
    end
  end

  defp encode_definition(_other) do
    {:error,
     Error.new(:validation, :invalid_definition, message: "The workflow definition is not valid.")}
  end

  defp validate_draft_definition(changeset) do
    case get_change(changeset, :draft_definition) do
      nil ->
        changeset

      raw ->
        case encode_definition(raw) do
          {:ok, encoded} -> put_change(changeset, :draft_definition, encoded)
          {:error, %Error{} = error} -> add_error(changeset, :draft_definition, error.message)
        end
    end
  end
end
