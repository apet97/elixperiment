defmodule PumbleAutomation.Crypto.RotationTest do
  # Not async: a rotation is defined by which key the application is currently
  # configured with, so these tests change that configuration and restore it.
  use PumbleAutomation.DataCase, async: false

  alias PumbleAutomation.Crypto.Rotation
  alias PumbleAutomation.Installations.Installation

  @token "xoxb-rotation-sentinel"
  @old_key :binary.copy(<<4>>, 32)
  @new_key :binary.copy(<<9>>, 32)

  setup do
    original = Application.get_env(:pumble_automation, :encryption)
    on_exit(fn -> Application.put_env(:pumble_automation, :encryption, original) end)
    :ok
  end

  describe "rotate/3" do
    test "re-encrypts a row written under a legacy key" do
      use_old_key()
      installation = insert_installation(@token, 1)

      assert stored_key_version(installation.id) == 1

      use_new_key()

      assert Rotation.rotate(Installation, :encrypted_bot_token,
               version_field: :token_key_version
             ) == {:ok, %{scanned: 1, rotated: 1}}

      assert stored_key_version(installation.id) == 2

      reloaded = Repo.get!(Installation, installation.id)
      assert reloaded.encrypted_bot_token == @token
      assert reloaded.token_key_version == 2
    end

    test "is finished when it reports nothing rotated" do
      use_old_key()
      insert_installation(@token, 1)
      use_new_key()

      assert {:ok, %{rotated: 1}} =
               Rotation.rotate(Installation, :encrypted_bot_token,
                 version_field: :token_key_version
               )

      assert Rotation.rotate(Installation, :encrypted_bot_token) ==
               {:ok, %{scanned: 0, rotated: 0}}
    end

    test "leaves rows that already use the primary key alone" do
      use_new_key()
      installation = insert_installation(@token, 2)
      before = Repo.get!(Installation, installation.id).updated_at

      assert Rotation.rotate(Installation, :encrypted_bot_token) ==
               {:ok, %{scanned: 0, rotated: 0}}

      assert Repo.get!(Installation, installation.id).updated_at == before
    end

    test "skips rows with no stored credential" do
      use_new_key()
      insert_installation(nil, nil)

      assert Rotation.rotate(Installation, :encrypted_bot_token) ==
               {:ok, %{scanned: 0, rotated: 0}}
    end

    test "honours the batch limit" do
      use_old_key()
      for _row <- 1..3, do: insert_installation(@token, 1)
      use_new_key()

      assert {:ok, %{scanned: 2, rotated: 2}} =
               Rotation.rotate(Installation, :encrypted_bot_token, limit: 2)

      assert {:ok, %{scanned: 1, rotated: 1}} =
               Rotation.rotate(Installation, :encrypted_bot_token, limit: 2)
    end
  end

  defp use_old_key do
    Application.put_env(:pumble_automation, :encryption,
      key: @old_key,
      key_version: 1,
      legacy_keys: %{}
    )
  end

  defp use_new_key do
    Application.put_env(:pumble_automation, :encryption,
      key: @new_key,
      key_version: 2,
      legacy_keys: %{1 => @old_key}
    )
  end

  defp insert_installation(token, key_version) do
    attrs = %{
      pumble_workspace_id: "ws-" <> Ecto.UUID.generate(),
      encrypted_bot_token: token,
      token_key_version: key_version
    }

    %Installation{}
    |> Installation.changeset(attrs)
    |> Repo.insert!()
  end

  # Reads the key-version byte straight out of the stored envelope, which is
  # what the rotation scan itself does.
  defp stored_key_version(id) do
    %{rows: [[version]]} =
      Repo.query!(
        "SELECT get_byte(encrypted_bot_token, 1) FROM installations WHERE id = $1",
        [Ecto.UUID.dump!(id)]
      )

    version
  end
end
