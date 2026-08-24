defmodule PumbleAutomation.Workflows.WorkflowVersion do
  @moduledoc """
  One immutable version of a workflow: the program an execution binds to.

  A draft is a document somebody is editing. A version is a document nobody can
  edit any more. That difference is the whole reason this table exists: a run
  that started an hour ago must finish under the definition it started with,
  and the only way to promise that is for the definition to be unreachable by
  any writer once it is stored.

  ## Create only

  There is `create/2`. There is no `update/2` and no `delete/1`, and neither
  will be added. `changeset/2` accepts a fresh struct and raises a
  `RuntimeError` for a struct that already has an id, so composing an update
  into an `Ecto.Multi` fails loudly at the call site rather than quietly
  succeeding. A correction is a new version, which is also what makes the
  history readable: the row an execution names still says what that execution
  ran.

  The database has no trigger enforcing this. See the migration for why, and
  for what would change that decision.

  ## The hashes are computed here, never supplied

  `definition_hash/1` canonicalizes before it hashes: every key becomes a
  string, every map is written in sorted key order, and the result is encoded
  once, deterministically. That digest is stored as `source_hash`.
  `identity_hash/1` applies the same digest to the source plus its compiled and
  dependency snapshot. An activation reuses a row only when that whole
  immutable snapshot matches.

  `definition_hash` remains the previous release's source digest and unique
  discriminator during this expand release. A same-source snapshot change is
  refused instead of stored as a second row. This keeps the previous release's
  lookup and integrity behavior valid throughout the rollback window. A later
  contract release may remove that compatibility constraint before it enables
  multiple snapshot identities for one source.

  `create/2` computes all hashes from the fields it is about to store.
  Caller-supplied hashes are ignored, because a hash the writer did not compute
  is a claim, not a checksum.

  ## Version numbers are allocated under the workflow's row lock

  `create/2` takes `SELECT ... FOR UPDATE` on the parent workflow, reads
  `max(version_number) + 1`, and inserts. Two concurrent activations of one
  workflow therefore serialize on that lock and receive consecutive numbers.
  The unique index on `(workflow_id, version_number)` is the backstop: if the
  lock is ever bypassed, the second writer gets an error instead of a
  duplicate.

  The tenant is read from the locked workflow row rather than from the caller,
  so a mismatched `installation_id` cannot be constructed. The composite
  foreign key refuses one anyway.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias PumbleAutomation.Error
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Limits
  alias PumbleAutomation.Workflows.Workflow

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @compiler_version_max 64
  @scope_max 128

  @insert_fields ~w(installation_id workflow_id version_number source_definition
                    compiled_definition compiler_version definition_hash source_hash identity_hash required_scopes
                    referenced_secret_ids referenced_connection_ids created_by_member_id
                    activated_at)a

  @type t :: %__MODULE__{}

  schema "workflow_versions" do
    field :installation_id, :binary_id
    field :workflow_id, :binary_id
    field :version_number, :integer
    field :source_definition, :map
    field :compiled_definition, :map
    field :compiler_version, :string
    field :definition_hash, :string
    field :source_hash, :string
    field :identity_hash, :string
    field :required_scopes, {:array, :string}, default: []
    field :referenced_secret_ids, {:array, Ecto.UUID}, default: []
    field :referenced_connection_ids, {:array, Ecto.UUID}, default: []
    field :created_by_member_id, :binary_id
    field :activated_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc """
  Builds the one and only changeset: an insertion.

  Raises when given a persisted struct. A version that is already stored has no
  valid change, and returning an invalid changeset here would let a caller
  treat "immutable" as a validation error to be worked around.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(version, attrs)

  def changeset(%__MODULE__{id: nil} = version, attrs) do
    version
    |> cast(attrs, @insert_fields)
    |> validate_required([
      :installation_id,
      :workflow_id,
      :version_number,
      :source_definition,
      :definition_hash,
      :source_hash,
      :identity_hash
    ])
    |> validate_number(:version_number, greater_than_or_equal_to: 1)
    |> validate_format(:definition_hash, ~r/\A[0-9a-f]{64}\z/)
    |> validate_format(:source_hash, ~r/\A[0-9a-f]{64}\z/)
    |> validate_format(:identity_hash, ~r/\A[0-9a-f]{64}\z/)
    |> validate_length(:compiler_version, max: @compiler_version_max)
    |> validate_scopes()
    |> unique_constraint([:workflow_id, :version_number],
      name: :workflow_versions_workflow_id_version_number_index
    )
    |> unique_constraint([:workflow_id, :identity_hash],
      name: :workflow_versions_workflow_id_identity_hash_index
    )
    |> unique_constraint([:workflow_id, :definition_hash],
      name: :workflow_versions_workflow_id_definition_hash_index
    )
    |> check_constraint(:version_number, name: :workflow_versions_version_number_check)
    |> check_constraint(:definition_hash, name: :workflow_versions_definition_hash_check)
    |> check_constraint(:source_hash, name: :workflow_versions_source_hash_check)
    |> check_constraint(:identity_hash, name: :workflow_versions_identity_hash_check)
    |> check_constraint(:identity_hash, name: :workflow_versions_snapshot_hash_pair_check)
    |> foreign_key_constraint(:workflow_id)
    |> foreign_key_constraint(:installation_id)
  end

  def changeset(%__MODULE__{}, _attrs) do
    raise "PumbleAutomation.Workflows.WorkflowVersion is immutable: a stored version " <>
            "cannot be changed. Create a new version instead."
  end

  @doc "The greatest length of a compiler version string."
  @spec compiler_version_max() :: pos_integer()
  def compiler_version_max, do: @compiler_version_max

  @doc """
  Creates the next version of `workflow`.

  Takes the workflow's row lock, allocates `max(version_number) + 1`, hashes
  the canonical source definition, and inserts. Runs in a transaction; nesting
  inside a caller's transaction is safe and is how activation will use it.

  `attrs` may carry `:source_definition` (a `PumbleAutomation.Workflows.Definition`
  or the map it encodes to), `:compiled_definition`, `:compiler_version`,
  `:required_scopes`, `:referenced_secret_ids`, `:referenced_connection_ids`,
  `:created_by_member_id`, and `:activated_at`. When `:source_definition` is
  absent the workflow's stored draft is versioned.

  Any `:definition_hash`, `:source_hash`, `:identity_hash`, `:version_number`,
  `:workflow_id`, or `:installation_id` in `attrs` is ignored: all six are
  derived here.

  Returns a `:conflict` error when the same immutable snapshot already has a
  version, and a `:not_found` error when the workflow does not exist inside its
  own tenant.
  """
  @spec create(Workflow.t(), map()) :: {:ok, t()} | {:error, Error.t()}
  def create(%Workflow{} = workflow, attrs \\ %{}) when is_map(attrs) do
    result =
      Repo.transaction(fn ->
        with {:ok, locked} <- lock_workflow(workflow),
             {:ok, encoded} <- source_definition(locked, attrs),
             {:ok, version} <- insert(locked, encoded, attrs) do
          version
        else
          {:error, %Error{} = error} -> Repo.rollback(error)
        end
      end)

    case result do
      {:ok, version} -> {:ok, version}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @doc """
  The lowercase hex SHA-256 of `term`'s canonical encoding.

  Key order is irrelevant, and atom and string keys hash alike, so the same
  program always produces the same digest.
  """
  @spec definition_hash(term()) :: String.t()
  def definition_hash(term) do
    :sha256
    |> :crypto.hash(canonical_json(term))
    |> Base.encode16(case: :lower)
  end

  @doc "The lowercase SHA-256 identity of a source, compiler, and dependency snapshot."
  @spec identity_hash(t() | map()) :: String.t()
  def identity_hash(snapshot) when is_map(snapshot) do
    snapshot
    |> identity_document()
    |> definition_hash()
  end

  @doc """
  The canonical JSON encoding of `term`: string keys, sorted, no whitespace.

  Exposed because a caller that wants to prove a stored row still hashes to its
  source or identity digest needs the same encoding this module used.
  """
  @spec canonical_json(term()) :: binary()
  def canonical_json(term), do: term |> canonicalize() |> Jason.encode!()

  @doc """
  Whether both authoritative hashes still match `version`'s immutable fields.

  A `false` here is an integrity failure, not a validation error: the row was
  changed by something that is not this module.
  """
  @spec intact?(t()) :: boolean()
  def intact?(
        %__MODULE__{
          source_definition: source,
          source_hash: source_hash,
          identity_hash: identity_hash
        } = version
      ) do
    is_binary(source_hash) and definition_hash(source) == source_hash and
      version.definition_hash == source_hash and
      is_binary(identity_hash) and identity_hash(version) == identity_hash
  end

  @doc "Whether a row written by the previous release still matches its source hash."
  @spec legacy_intact?(t()) :: boolean()
  def legacy_intact?(%__MODULE__{
        source_definition: source,
        definition_hash: definition_hash,
        source_hash: nil,
        identity_hash: nil
      }) do
    is_binary(definition_hash) and definition_hash(source) == definition_hash
  end

  def legacy_intact?(%__MODULE__{}), do: false

  defp lock_workflow(%Workflow{id: id, installation_id: installation_id}) do
    query =
      from w in Workflow,
        where: w.id == ^id and w.installation_id == ^installation_id,
        lock: "FOR UPDATE"

    case Repo.one(query) do
      nil ->
        {:error,
         Error.new(:not_found, :workflow_not_found,
           message: "The workflow was not found in this workspace."
         )}

      workflow ->
        {:ok, workflow}
    end
  end

  defp source_definition(workflow, attrs) do
    case Map.get(attrs, :source_definition) do
      nil -> encode_definition(workflow.draft_definition)
      given -> encode_definition(given)
    end
  end

  defp encode_definition(nil) do
    {:error,
     Error.new(:validation, :missing_definition,
       message: "The workflow has no definition to version."
     )}
  end

  defp encode_definition(%Definition{} = definition) do
    case Definition.validate_limits(definition) do
      :ok -> {:ok, Definition.encode(definition)}
      {:error, %Error{}} = error -> error
    end
  end

  defp encode_definition(raw) when is_map(raw) do
    with {:ok, definition} <- Definition.decode(raw),
         encoded = Definition.encode(definition),
         :ok <- Limits.check_size(encoded) do
      {:ok, encoded}
    end
  end

  defp encode_definition(_other) do
    {:error,
     Error.new(:validation, :invalid_definition, message: "The workflow definition is not valid.")}
  end

  defp insert(workflow, encoded, attrs) do
    source_hash = definition_hash(encoded)

    row =
      attrs
      |> Map.take(~w(compiled_definition compiler_version required_scopes
                     referenced_secret_ids referenced_connection_ids
                     created_by_member_id activated_at)a)
      |> Map.merge(%{
        installation_id: workflow.installation_id,
        workflow_id: workflow.id,
        version_number: next_version_number(workflow.id),
        source_definition: encoded,
        source_hash: source_hash
      })
      |> then(&Map.put(&1, :identity_hash, identity_hash(&1)))
      |> Map.put(:definition_hash, source_hash)

    %__MODULE__{}
    |> changeset(row)
    |> Repo.insert()
    |> case do
      {:ok, version} -> {:ok, version}
      {:error, changeset} -> {:error, insert_error(changeset)}
    end
  end

  defp next_version_number(workflow_id) do
    query =
      from v in __MODULE__,
        where: v.workflow_id == ^workflow_id,
        select: max(v.version_number)

    case Repo.one(query) do
      nil -> 1
      highest -> highest + 1
    end
  end

  defp insert_error(%Ecto.Changeset{} = changeset) do
    cond do
      violated?(changeset, "workflow_versions_workflow_id_identity_hash_index") ->
        Error.new(:conflict, :duplicate_version_identity,
          message: "That workflow snapshot already has a version."
        )

      violated?(changeset, "workflow_versions_workflow_id_definition_hash_index") ->
        Error.new(:conflict, :duplicate_version_identity,
          message: "That workflow snapshot already has a version."
        )

      violated?(changeset, "workflow_versions_workflow_id_version_number_index") ->
        Error.new(:conflict, :version_number_taken,
          message: "Another version was created at the same time. Try again."
        )

      true ->
        Error.new(:validation, :invalid_version,
          message: "The workflow version is not valid.",
          details: %{fields: Enum.map(changeset.errors, fn {field, _} -> field end)}
        )
    end
  end

  # A composite unique constraint reports its error on the first field it
  # names, so the field is not what tells the two apart. The constraint name is.
  defp violated?(%Ecto.Changeset{errors: errors}, name) do
    Enum.any?(errors, fn {_field, {_message, opts}} ->
      Keyword.get(opts, :constraint_name) == name
    end)
  end

  defp validate_scopes(changeset) do
    scopes = get_field(changeset, :required_scopes) || []

    if Enum.all?(scopes, &(is_binary(&1) and byte_size(&1) in 1..@scope_max)) do
      changeset
    else
      add_error(changeset, :required_scopes, "must be non-empty strings")
    end
  end

  defp identity_document(snapshot) do
    %{
      "source_definition" => snapshot_value(snapshot, :source_definition),
      "compiled_definition" => snapshot_value(snapshot, :compiled_definition),
      "compiler_version" => snapshot_value(snapshot, :compiler_version),
      "required_scopes" => sorted_values(snapshot_value(snapshot, :required_scopes)),
      "referenced_secret_ids" => sorted_values(snapshot_value(snapshot, :referenced_secret_ids)),
      "referenced_connection_ids" =>
        sorted_values(snapshot_value(snapshot, :referenced_connection_ids))
    }
  end

  defp snapshot_value(snapshot, key) do
    case Map.fetch(snapshot, key) do
      {:ok, value} -> value
      :error -> Map.get(snapshot, Atom.to_string(key))
    end
  end

  defp sorted_values(nil), do: []
  defp sorted_values(values) when is_list(values), do: Enum.sort(values)
  defp sorted_values(value), do: value

  # Sorted string keys at every depth. `Jason.OrderedObject` is what keeps the
  # encoder from re-ordering a map back into term order. Structs are left to
  # Jason's own encoders, so a `DateTime` hashes as its ISO 8601 string rather
  # than as its fields.
  defp canonicalize(term) when is_struct(term), do: term

  defp canonicalize(term) when is_map(term) do
    %Jason.OrderedObject{
      values:
        term
        |> Enum.map(fn {key, value} -> {to_string(key), canonicalize(value)} end)
        |> Enum.sort_by(&elem(&1, 0))
    }
  end

  defp canonicalize(term) when is_list(term), do: Enum.map(term, &canonicalize/1)

  defp canonicalize(term) when is_atom(term) and not is_boolean(term) and not is_nil(term) do
    Atom.to_string(term)
  end

  defp canonicalize(term), do: term
end
