defmodule PumbleAutomation.Crypto.Rotation do
  @moduledoc """
  Re-encrypts stored credentials under the current primary key.

  A key rotation is a deploy: the new key becomes primary, the old one stays in
  the keyring as a legacy read key, and every existing row is still readable.
  This module is what finally removes the legacy key's remaining readers, so
  that the old key can be retired.

  ## Not automatic

  Nothing calls this on a schedule and nothing calls it during a request. A
  rotation rewrites rows and holds plaintext in memory while it does; when that
  happens is an operator's decision, taken with the old key still configured.
  Run it from a release console or a deliberate maintenance job, one bounded
  batch at a time, until `rotated` comes back zero.

  ## How a stale row is found

  Without decrypting anything: the envelope's second byte is the key version,
  so the scan is `get_byte(column, 1) != primary_version` in SQL. Rows already
  on the primary key are never read.

  A row is rewritten by loading it, which decrypts with the legacy key, and
  writing the same value back with `force_change/3`, which encrypts with the
  primary key. Plaintext therefore lives in one struct for the length of one
  update and is never copied elsewhere.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias PumbleAutomation.Crypto.Vault
  alias PumbleAutomation.Error
  alias PumbleAutomation.Repo

  @default_limit 100

  @typedoc "What one batch did."
  @type report :: %{scanned: non_neg_integer(), rotated: non_neg_integer()}

  @doc """
  Rotates up to `:limit` rows of `schema` whose `field` still uses a legacy key.

  Options:

    * `:limit` — how many rows this batch may rewrite. Defaults to
      `#{@default_limit}`. Keep it small enough that one batch is a short
      transaction-free burst rather than a table rewrite.
    * `:version_field` — a column holding the key version as a plain integer,
      such as `:token_key_version`. It is updated with the row.

  The target is always the configured keyring, because the write goes through
  the field type, which has no way to be handed a different one. Taking a
  keyring here would let a caller scan for one key and write another, and the
  batch would then rotate the same rows forever.

  Returns `{:ok, report}` when the batch finished, or `{:error, t:PumbleAutomation.Error.t/0}`
  when a row could not be written. A failed batch has still committed the rows
  it wrote before the failure, because each row is its own update; running the
  batch again resumes from what is left.
  """
  @spec rotate(module(), atom(), keyword()) :: {:ok, report()} | {:error, Error.t()}
  def rotate(schema, field, opts \\ []) when is_atom(schema) and is_atom(field) do
    limit = Keyword.get(opts, :limit, @default_limit)
    version_field = Keyword.get(opts, :version_field)
    primary = Vault.keyring().primary_version

    rows = Repo.all(stale_query(schema, field, primary, limit))

    case rotate_rows(rows, field, version_field, primary) do
      {:ok, rotated} -> {:ok, %{scanned: length(rows), rotated: rotated}}
      {:error, error} -> {:error, error}
    end
  end

  defp stale_query(schema, field, primary, limit) do
    offset = Vault.key_version_offset()

    from(row in schema,
      where: not is_nil(field(row, ^field)),
      where: fragment("get_byte(?, ?)", field(row, ^field), ^offset) != ^primary,
      limit: ^limit
    )
  end

  defp rotate_rows(rows, field, version_field, primary) do
    Enum.reduce_while(rows, {:ok, 0}, fn row, {:ok, rotated} ->
      case rotate_row(row, field, version_field, primary) do
        {:ok, _row} -> {:cont, {:ok, rotated + 1}}
        {:error, changeset} -> {:halt, {:error, write_error(changeset)}}
      end
    end)
  end

  defp rotate_row(row, field, version_field, primary) do
    row
    |> Changeset.change(version_changes(version_field, primary))
    |> Changeset.force_change(field, Map.fetch!(row, field))
    |> Repo.update()
  end

  defp version_changes(nil, _primary), do: %{}
  defp version_changes(version_field, primary), do: %{version_field => primary}

  defp write_error(%Changeset{} = changeset) do
    fields = changeset.errors |> Enum.map(fn {field, _error} -> field end) |> Enum.sort()

    Error.new(:conflict, :credential_rotation_failed,
      message: "A stored credential could not be rewritten.",
      retryable?: false,
      details: %{invalid_fields: Enum.map(fields, &Atom.to_string/1)}
    )
  end
end
