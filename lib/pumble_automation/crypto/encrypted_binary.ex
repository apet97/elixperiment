defmodule PumbleAutomation.Crypto.EncryptedBinary do
  @moduledoc """
  An Ecto field that is ciphertext in the database and plaintext in the struct.

  Declare it with the associated data the column is bound to:

      field :encrypted_bot_token, PumbleAutomation.Crypto.EncryptedBinary,
        aad: "installations.encrypted_bot_token"

  Dumping encrypts with the primary key; loading decrypts with whichever key
  version the stored envelope names. Neither direction is something a caller
  asks for, which is the point: no module needs to call a decrypt function to
  read a credential it already owns, and no module gets a decrypt function it
  could point at a row it does not own.

  ## Why the associated data names a column and not a tenant

  GCM associated data should bind a ciphertext as narrowly as the format allows.
  Binding to record type plus tenant would be better still, but `dump/3` sees
  one value and the field's compile-time parameters — never the row it belongs
  to, and never a sibling field. There is no hook in `Ecto.ParameterizedType`
  that carries the rest of the struct.

  So the binding is `"table.column"`. That already defeats moving a ciphertext
  between columns or tables. It does not defeat moving a ciphertext between two
  rows of the same column, which is a distinct control: row identity is enforced
  by the tenant-scoped queries and foreign keys described in
  `docs/operations/migrations.md`, not by the cipher.

  ## Redaction

  This type stores plaintext in the struct after a load, so every schema that
  uses it must exclude the field from `Inspect`. The schemas in
  `PumbleAutomation.Installations` do that with `@derive {Inspect, except: [...]}`.
  """

  use Ecto.ParameterizedType

  alias PumbleAutomation.Crypto.Vault
  alias PumbleAutomation.Crypto.VaultError

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :aad) do
      {:ok, aad} when is_binary(aad) and byte_size(aad) > 0 ->
        %{aad: aad}

      _other ->
        raise ArgumentError,
              "#{inspect(__MODULE__)} requires a non-empty :aad option, such as " <>
                ~s(aad: "installations.encrypted_bot_token")
    end
  end

  @impl true
  def type(_params), do: :binary

  @impl true
  def cast(nil, _params), do: {:ok, nil}
  def cast(value, _params) when is_binary(value), do: {:ok, value}
  def cast(_value, _params), do: :error

  @impl true
  def dump(nil, _dumper, _params), do: {:ok, nil}

  def dump(value, _dumper, %{aad: aad}) when is_binary(value) do
    case Vault.encrypt(value, aad) do
      {:ok, envelope} -> {:ok, envelope}
      {:error, error} -> raise VaultError, error: error
    end
  end

  def dump(_value, _dumper, _params), do: :error

  @impl true
  def load(nil, _loader, _params), do: {:ok, nil}

  def load(value, _loader, %{aad: aad}) when is_binary(value) do
    case Vault.decrypt(value, aad) do
      {:ok, plaintext} -> {:ok, plaintext}
      {:error, error} -> raise VaultError, error: error
    end
  end

  def load(_value, _loader, _params), do: :error

  @impl true
  def equal?(left, right, _params), do: left == right

  @impl true
  def embed_as(_format, _params), do: :self
end
