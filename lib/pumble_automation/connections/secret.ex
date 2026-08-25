defmodule PumbleAutomation.Connections.Secret do
  @moduledoc """
  One named, encrypted, write-only tenant credential.

  A secret is created once, rotated when it changes, and read exactly nowhere
  except `PumbleAutomation.Connections.SecretResolver`, immediately before an
  outbound request is built. Everything else in the application handles the
  metadata: the name, the kind, the fingerprint, and the two timestamps.

  ## The value never arrives with a query

  `:value` is declared `load_in_query: false`. Ecto therefore omits the column
  from every `select` it generates, so `Repo.all/1`, `Repo.get/2`, and any
  query a context writes return a struct whose `:value` is `nil` — not because
  a caller remembered to drop it, but because the column was never fetched and
  never decrypted. Reading the plaintext requires naming the field in an
  explicit `select`, which one module does and documents why.

  That also means a tampered ciphertext cannot make a list screen raise. Only
  the resolver touches the cipher, so only the resolver can see it fail.

  ## Inspect

  `@derive {Inspect, except: [:value]}` keeps the plaintext out of a crash
  dump, a `Logger` call, and an `IEx` session, for the window between an insert
  and the struct going out of scope. `secret_test.exs` asserts it.

  ## The fingerprint answers one question

  `fingerprint/2` is `sha256("secrets.value:v1:" <> installation_id <> ":" <> value)`.
  A bare digest of the value would be an offline oracle against any low-entropy
  secret. The tenant salt and domain prefix remove that oracle while preserving
  the only property the application needs: "is this the same value as the one
  already stored".

  ## `key_version` is a copy, not the source of truth

  The authoritative key version is the second byte of the stored envelope.
  This column duplicates it as a plain integer so that a rotation can find and
  count the rows still on a legacy key without decrypting the table.

  It is not yet wired to `PumbleAutomation.Crypto.Rotation`, and cannot be as
  that module stands: it rewrites a row by reloading it with a default select
  and forcing the field back, which for a `load_in_query: false` field would
  force `nil`. Rotating this table needs a variant of that batch that selects
  `:value` explicitly, the same way
  `PumbleAutomation.Connections.SecretResolver` does. That is a rotation-time
  change, not a reason to make the plaintext load by default.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias PumbleAutomation.Crypto.EncryptedBinary
  alias PumbleAutomation.Crypto.Vault

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @derive {Inspect, except: [:value]}

  # What the value is for. It never changes how the value is stored; it tells
  # the UI what kind of credential a workflow is about to send.
  @kinds ~w(api_key bearer_token basic_password signing_key generic)

  @name_format ~r/\A[A-Z][A-Z0-9_]{0,63}\z/
  @max_value_bytes 8_192
  @max_description 500

  @type t :: %__MODULE__{}

  schema "secrets" do
    field :installation_id, :binary_id
    field :name, :string

    field :value, EncryptedBinary,
      aad: "secrets.value",
      load_in_query: false,
      redact: true

    field :kind, :string
    field :key_version, :integer
    field :value_fingerprint, :string
    field :description, :string
    field :last_rotated_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec
    field :created_by_member_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The kinds a secret may declare."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "The grammar a secret name must match, which is also a template identifier."
  @spec name_format() :: Regex.t()
  def name_format, do: @name_format

  @doc "The greatest size of a secret value, in bytes."
  @spec max_value_bytes() :: pos_integer()
  def max_value_bytes, do: @max_value_bytes

  @doc """
  Builds the insertion changeset.

  `installation_id`, `name`, and `value` are required. The key version, the
  fingerprint, and `last_rotated_at` are derived here and are ignored when a
  caller supplies them: a fingerprint the writer did not compute is a claim.
  """
  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) when is_map(attrs) do
    changeset =
      %__MODULE__{}
      |> cast(attrs, [:installation_id, :name, :value, :kind, :description, :created_by_member_id])
      |> update_change(:name, &normalize_name/1)
      |> put_change(:kind, kind_of(attrs))
      |> validate_required([:installation_id, :name, :value])
      |> validate_common()

    seal(changeset, get_change(changeset, :value))
  end

  @doc """
  Builds the changeset that replaces a stored value.

  Only the value moves. The name, the kind, and the description are not
  reachable from here, because a rotation that could also rename the secret
  would let one operation change what a workflow resolves *and* what it
  resolves to.

  Rotating to the value the row already holds is rejected: it looks like a
  rotation in the audit history and is not one.
  """
  @spec rotate_changeset(t(), String.t()) :: Ecto.Changeset.t()
  def rotate_changeset(%__MODULE__{} = secret, value) do
    secret
    |> cast(%{value: value}, [:value])
    |> validate_required([:value])
    |> validate_value_size()
    |> refute_unchanged(secret)
    |> seal(value)
  end

  @doc """
  The stored fingerprint of `value` inside `installation_id`.

  Domain separated and tenant salted. See the module documentation for why it
  is not a bare digest of the value.
  """
  @spec fingerprint(Ecto.UUID.t(), String.t()) :: String.t()
  def fingerprint(installation_id, value) when is_binary(installation_id) and is_binary(value) do
    :sha256
    |> :crypto.hash("secrets.value:v1:" <> installation_id <> ":" <> value)
    |> Base.encode16(case: :lower)
  end

  defp validate_common(changeset) do
    changeset
    |> validate_format(:name, @name_format)
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:description, max: @max_description)
    |> validate_value_size()
    |> unique_constraint([:installation_id, :name],
      name: :secrets_installation_id_name_index
    )
    |> check_constraint(:name, name: :secrets_name_check)
    |> foreign_key_constraint(:installation_id)
  end

  defp validate_value_size(changeset) do
    case get_change(changeset, :value) do
      value when is_binary(value) and byte_size(value) == 0 ->
        add_error(changeset, :value, "cannot be empty")

      value when is_binary(value) and byte_size(value) > @max_value_bytes ->
        add_error(changeset, :value, "is larger than #{@max_value_bytes} bytes")

      _other ->
        changeset
    end
  end

  # The fingerprint and the key version are always written together with the
  # value, so a row can never claim a digest or a key that belongs to an
  # earlier ciphertext.
  defp seal(changeset, value) when is_binary(value) do
    installation_id = get_field(changeset, :installation_id)

    if changeset.valid? and is_binary(installation_id) do
      changeset
      |> put_change(:value_fingerprint, fingerprint(installation_id, value))
      |> put_change(:key_version, Vault.keyring().primary_version)
      |> put_change(:last_rotated_at, DateTime.utc_now())
    else
      changeset
    end
  end

  defp seal(changeset, _value), do: changeset

  defp refute_unchanged(changeset, %__MODULE__{} = secret) do
    value = get_change(changeset, :value)

    if is_binary(value) and
         fingerprint(secret.installation_id, value) == secret.value_fingerprint do
      add_error(changeset, :value, "is the value this secret already holds")
    else
      changeset
    end
  end

  defp kind_of(attrs) do
    case Map.get(attrs, :kind) || Map.get(attrs, "kind") do
      nil -> "generic"
      kind when is_atom(kind) -> Atom.to_string(kind)
      kind -> kind
    end
  end

  defp normalize_name(name) when is_binary(name), do: name |> String.trim() |> String.upcase()
  defp normalize_name(name), do: name
end
