defmodule PumbleAutomation.Crypto.Vault do
  @moduledoc """
  Authenticated encryption for stored credentials.

  Every credential this application persists is sealed here with AES-256-GCM
  from OTP `:crypto`. There is no encryption dependency: the whole primitive is
  one call in each direction, and a package would add a supply-chain surface
  without adding a guarantee. See `docs/contract/dependency_policy.md`, which
  allows exactly this choice.

  ## The envelope

      <<envelope_version::8, key_version::8, nonce::binary-12, tag::binary-16, ciphertext::binary>>

  The two leading bytes are also fed to GCM as associated data, together with
  the caller's `aad`. That binds the ciphertext to the key version it claims,
  so an attacker cannot renumber an envelope to a weaker key and cannot move a
  ciphertext from one column to another: both changes fail authentication
  rather than decrypting into something plausible.

  `envelope_version` exists so a future format change is readable, not
  guessable. `key_version` is a single byte, which is why a key version is
  limited to 1..255; it lets a rotation find stale rows with `get_byte(col, 1)`
  instead of decrypting the table.

  ## Keys and rotation

  A keyring holds one primary version, used for every write, and any number of
  legacy versions, used for reads only. Rotation is therefore a normal deploy:
  add the new key as primary, keep the old one as legacy, then re-encrypt rows
  in the background with `PumbleAutomation.Crypto.Rotation`. Keys come from
  configuration, which in production comes only from injected secrets.

  Every function takes the keyring as an optional last argument. A test can
  then build its own keyring instead of mutating global application state, and
  production code keeps using the configured one.

  ## Failure

  An unknown key version, a malformed envelope, and a failed authentication tag
  all return a non-retryable `PumbleAutomation.Error` of class `:internal`.
  Retrying cannot help, and the caller must not fall back to an unencrypted or
  stale value: a credential that cannot be read is a credential that cannot be
  used.

  ## Plaintext lifetime

  The BEAM offers no way to wipe a binary, so this module cannot promise
  zeroization. What it can do is keep plaintext out of long-lived structures:
  nothing here caches a decrypted value, and callers should resolve a
  credential at the moment of use.
  """

  alias PumbleAutomation.Error

  @cipher :aes_256_gcm
  @envelope_version 1
  @nonce_bytes 12
  @tag_bytes 16
  @key_bytes 32
  @max_key_version 255

  @typedoc "A key version, small enough to fit the envelope's version byte."
  @type key_version :: 1..255

  @typedoc "The primary write version and every version that can still be read."
  @type keyring :: %{primary_version: key_version(), keys: %{key_version() => binary()}}

  @doc """
  Builds the configured keyring.

  Raises `ArgumentError` when the application has no encryption key, because a
  release that can write unreadable credentials is worse than one that stops.
  """
  @spec keyring() :: keyring()
  def keyring do
    settings = Application.get_env(:pumble_automation, :encryption, [])
    version = fetch_setting!(settings, :key_version)
    key = fetch_setting!(settings, :key)
    legacy = Keyword.get(settings, :legacy_keys, %{})

    validate_key!(:key, key)
    validate_version!(version)

    Enum.each(legacy, fn {legacy_version, legacy_key} ->
      validate_key!(legacy_version, legacy_key)
    end)

    %{primary_version: version, keys: Map.put(legacy, version, key)}
  end

  @doc """
  Seals `plaintext` under the keyring's primary key.

  `aad` names what the ciphertext belongs to, usually `"table.column"`. The same
  value must be given to `decrypt/3`; anything else fails authentication.

  Two calls with the same arguments return different envelopes, because the
  nonce is random. That is required, not incidental: equal ciphertexts would
  tell a reader of the table which rows hold the same secret.
  """
  @spec encrypt(binary(), binary(), keyring()) :: {:ok, binary()} | {:error, Error.t()}
  def encrypt(plaintext, aad, keyring \\ keyring())

  def encrypt(plaintext, aad, keyring) when is_binary(plaintext) and is_binary(aad) do
    version = keyring.primary_version

    case fetch_key(keyring, version) do
      {:ok, key} ->
        nonce = :crypto.strong_rand_bytes(@nonce_bytes)
        header = <<@envelope_version, version>>

        {ciphertext, tag} =
          :crypto.crypto_one_time_aead(@cipher, key, nonce, plaintext, header <> aad, true)

        {:ok, header <> nonce <> tag <> ciphertext}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Opens an envelope produced by `encrypt/3`.

  Any modification of any byte of the envelope, and any `aad` other than the one
  used to seal it, returns an error instead of a value.
  """
  @spec decrypt(binary(), binary(), keyring()) :: {:ok, binary()} | {:error, Error.t()}
  def decrypt(envelope, aad, keyring \\ keyring())

  def decrypt(
        <<@envelope_version, version, nonce::binary-size(@nonce_bytes),
          tag::binary-size(@tag_bytes), ciphertext::binary>>,
        aad,
        keyring
      )
      when is_binary(aad) do
    case fetch_key(keyring, version) do
      {:ok, key} -> open(key, version, nonce, tag, ciphertext, aad)
      {:error, error} -> {:error, error}
    end
  end

  def decrypt(envelope, aad, _keyring) when is_binary(envelope) and is_binary(aad) do
    {:error, malformed_error()}
  end

  @doc """
  Returns the key version an envelope was sealed with, without decrypting it.

  Rotation uses this to report what it found; the scan itself happens in SQL.
  """
  @spec key_version(binary()) :: {:ok, key_version()} | {:error, Error.t()}
  def key_version(<<@envelope_version, version, _rest::binary>>)
      when version in 1..@max_key_version do
    {:ok, version}
  end

  def key_version(envelope) when is_binary(envelope), do: {:error, malformed_error()}

  @doc "The offset of the key-version byte inside an envelope."
  @spec key_version_offset() :: non_neg_integer()
  def key_version_offset, do: 1

  @doc "The highest key version the envelope format can carry."
  @spec max_key_version() :: pos_integer()
  def max_key_version, do: @max_key_version

  @doc "The required length of a key, in bytes."
  @spec key_bytes() :: pos_integer()
  def key_bytes, do: @key_bytes

  defp open(key, version, nonce, tag, ciphertext, aad) do
    header = <<@envelope_version, version>>

    case :crypto.crypto_one_time_aead(
           @cipher,
           key,
           nonce,
           ciphertext,
           header <> aad,
           tag,
           false
         ) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> {:error, auth_error()}
    end
  end

  defp fetch_key(keyring, version) do
    case Map.fetch(keyring.keys, version) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, unknown_key_error(version)}
    end
  end

  defp fetch_setting!(settings, key) do
    case Keyword.fetch(settings, key) do
      {:ok, value} ->
        value

      :error ->
        raise ArgumentError,
              "encryption #{key} is not configured. Set ENCRYPTION_KEY and " <>
                "ENCRYPTION_KEY_VERSION. See .env.example."
    end
  end

  defp validate_key!(name, key) when is_binary(key) and byte_size(key) == @key_bytes, do: name

  defp validate_key!(name, _key) do
    raise ArgumentError, "encryption key #{inspect(name)} must be exactly #{@key_bytes} bytes"
  end

  defp validate_version!(version) when version in 1..@max_key_version, do: version

  defp validate_version!(_version) do
    raise ArgumentError,
          "encryption key version must be an integer between 1 and #{@max_key_version}"
  end

  defp unknown_key_error(version) do
    Error.new(:internal, :credential_key_unknown,
      message: "A stored credential cannot be read.",
      retryable?: false,
      details: %{key_version: version}
    )
  end

  defp auth_error do
    Error.new(:internal, :credential_auth_failed,
      message: "A stored credential cannot be read.",
      retryable?: false
    )
  end

  defp malformed_error do
    Error.new(:internal, :credential_envelope_malformed,
      message: "A stored credential cannot be read.",
      retryable?: false
    )
  end
end
