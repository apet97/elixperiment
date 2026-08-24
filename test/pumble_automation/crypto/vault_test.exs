defmodule PumbleAutomation.Crypto.VaultTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias PumbleAutomation.Crypto.EncryptedBinary
  alias PumbleAutomation.Crypto.Vault
  alias PumbleAutomation.Crypto.VaultError
  alias PumbleAutomation.Error

  require Logger

  # A value that must never appear in a ciphertext, an inspect, or a log line.
  @plaintext "xoxb-sup3r-sekrit-sentinel-token"
  @aad "installations.encrypted_bot_token"

  @primary :binary.copy(<<9>>, 32)
  @legacy :binary.copy(<<4>>, 32)

  defp keyring(primary_version \\ 2) do
    %{primary_version: primary_version, keys: %{1 => @legacy, 2 => @primary}}
  end

  describe "encrypt/3 and decrypt/3" do
    test "round-trips a value" do
      assert {:ok, envelope} = Vault.encrypt(@plaintext, @aad, keyring())
      assert {:ok, @plaintext} = Vault.decrypt(envelope, @aad, keyring())
    end

    test "round-trips an empty value" do
      assert {:ok, envelope} = Vault.encrypt("", @aad, keyring())
      assert {:ok, ""} = Vault.decrypt(envelope, @aad, keyring())
    end

    test "never writes the plaintext into the envelope" do
      assert {:ok, envelope} = Vault.encrypt(@plaintext, @aad, keyring())

      refute envelope =~ @plaintext
      assert byte_size(envelope) == 2 + 12 + 16 + byte_size(@plaintext)
    end

    test "produces a different envelope every time for the same input" do
      envelopes =
        for _attempt <- 1..25 do
          assert {:ok, envelope} = Vault.encrypt(@plaintext, @aad, keyring())
          envelope
        end

      assert envelopes |> Enum.uniq() |> length() == 25
    end

    test "stamps the format version and the primary key version" do
      assert {:ok, envelope} = Vault.encrypt(@plaintext, @aad, keyring())
      assert <<1, 2, _rest::binary>> = envelope
      assert Vault.key_version(envelope) == {:ok, 2}
    end

    test "reads a value written under a legacy key" do
      assert {:ok, envelope} = Vault.encrypt(@plaintext, @aad, keyring(1))
      assert Vault.key_version(envelope) == {:ok, 1}

      # The keyring that now writes version 2 still reads version 1.
      assert {:ok, @plaintext} = Vault.decrypt(envelope, @aad, keyring())
    end
  end

  describe "decrypt/3 failure" do
    test "refuses a tampered ciphertext" do
      assert {:ok, envelope} = Vault.encrypt(@plaintext, @aad, keyring())

      assert {:error, error} = Vault.decrypt(flip_last_byte(envelope), @aad, keyring())
      assert error.code == :credential_auth_failed
    end

    test "refuses a tampered nonce or tag" do
      assert {:ok, envelope} = Vault.encrypt(@plaintext, @aad, keyring())

      for offset <- [2, 14] do
        assert {:error, error} = Vault.decrypt(flip_byte(envelope, offset), @aad, keyring())
        assert error.code == :credential_auth_failed
      end
    end

    test "refuses a renumbered key version, because the header is authenticated" do
      assert {:ok, envelope} = Vault.encrypt(@plaintext, @aad, keyring())
      <<format, _version, rest::binary>> = envelope

      assert {:error, error} = Vault.decrypt(<<format, 1, rest::binary>>, @aad, keyring())
      assert error.code == :credential_auth_failed
    end

    test "refuses the wrong associated data" do
      assert {:ok, envelope} = Vault.encrypt(@plaintext, @aad, keyring())

      assert {:error, error} =
               Vault.decrypt(envelope, "user_authorizations.encrypted_access_token", keyring())

      assert error.code == :credential_auth_failed
    end

    test "refuses an unknown key version" do
      assert {:ok, envelope} = Vault.encrypt(@plaintext, @aad, keyring())
      <<format, _version, rest::binary>> = envelope
      unknown = <<format, 7, rest::binary>>

      assert {:error, error} = Vault.decrypt(unknown, @aad, keyring())
      assert error.code == :credential_key_unknown
      assert error.details == %{key_version: 7}
    end

    test "refuses a truncated envelope" do
      assert {:error, error} = Vault.decrypt(<<1, 2, 3>>, @aad, keyring())
      assert error.code == :credential_envelope_malformed
    end

    test "refuses to write under a primary version that has no key" do
      assert {:error, error} =
               Vault.encrypt(@plaintext, @aad, %{primary_version: 5, keys: %{1 => @legacy}})

      assert error.code == :credential_key_unknown
    end

    test "reports every failure as a non-retryable internal error" do
      assert {:error, error} = Vault.decrypt(<<1, 2, 3>>, @aad, keyring())

      assert %Error{class: :internal, retryable?: false} = error
      refute Error.retryable?(error)
      assert error.message == "A stored credential cannot be read."
    end
  end

  describe "keyring/0" do
    test "reads the configured key and version" do
      keyring = Vault.keyring()

      assert keyring.primary_version == 1
      assert byte_size(Map.fetch!(keyring.keys, 1)) == Vault.key_bytes()
    end
  end

  describe "the encrypted field type" do
    test "requires the associated data to be declared" do
      assert_raise ArgumentError, ~r/:aad option/, fn -> EncryptedBinary.init([]) end
    end

    test "encrypts on dump and decrypts on load" do
      params = EncryptedBinary.init(aad: @aad)

      assert {:ok, envelope} = EncryptedBinary.dump(@plaintext, nil, params)
      refute envelope == @plaintext
      assert {:ok, @plaintext} = EncryptedBinary.load(envelope, nil, params)
    end

    test "passes nil through untouched" do
      params = EncryptedBinary.init(aad: @aad)

      assert EncryptedBinary.dump(nil, nil, params) == {:ok, nil}
      assert EncryptedBinary.load(nil, nil, params) == {:ok, nil}
    end

    test "refuses a value that is not a binary" do
      params = EncryptedBinary.init(aad: @aad)

      assert EncryptedBinary.cast(123, params) == :error
      assert EncryptedBinary.dump(123, nil, params) == :error
    end

    test "raises a typed error when a stored value cannot be read" do
      params = EncryptedBinary.init(aad: @aad)
      assert {:ok, envelope} = EncryptedBinary.dump(@plaintext, nil, params)

      exception =
        assert_raise VaultError, fn ->
          EncryptedBinary.load(flip_last_byte(envelope), nil, params)
        end

      assert %Error{class: :internal, code: :credential_auth_failed, retryable?: false} =
               exception.error

      refute Exception.message(exception) =~ @plaintext
    end

    test "binds the ciphertext to the column it was written for" do
      written = EncryptedBinary.init(aad: @aad)
      other = EncryptedBinary.init(aad: "user_authorizations.encrypted_access_token")

      assert {:ok, envelope} = EncryptedBinary.dump(@plaintext, nil, written)

      assert_raise VaultError, fn -> EncryptedBinary.load(envelope, nil, other) end
    end
  end

  describe "redaction" do
    test "no plaintext reaches inspect or the log" do
      assert {:ok, envelope} = Vault.encrypt(@plaintext, @aad, keyring())
      assert {:error, error} = Vault.decrypt(flip_last_byte(envelope), @aad, keyring())

      log =
        capture_log(fn ->
          Logger.warning("vault: #{inspect(error)} for #{inspect(envelope)}")
        end)

      refute log =~ @plaintext
      refute inspect(envelope) =~ @plaintext
      refute inspect(error) =~ @plaintext
      refute Exception.message(%VaultError{error: error}) =~ @plaintext
    end
  end

  defp flip_last_byte(binary), do: flip_byte(binary, byte_size(binary) - 1)

  defp flip_byte(binary, offset) do
    <<head::binary-size(^offset), byte, tail::binary>> = binary
    <<head::binary, Bitwise.bxor(byte, 1), tail::binary>>
  end
end
