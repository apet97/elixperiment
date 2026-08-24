defmodule PumbleAutomation.Ingress.EndpointsRotationConcurrencyTest do
  @moduledoc """
  Credential rotation derives overlap state from one locked endpoint row.

  This module uses real concurrent database connections. Sharing one sandbox
  transaction would serialize through the owning test process before the row
  lock could be exercised.
  """

  use ExUnit.Case, async: false

  import PumbleAutomation.IngressFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias PumbleAutomation.Barrier
  alias PumbleAutomation.Crypto.Vault
  alias PumbleAutomation.Ingress.Endpoints
  alias PumbleAutomation.Ingress.WebhookEndpoint
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope

  setup do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  test "two racing rotations leave both returned credential pairs valid" do
    %{installation: installation, member: member} = InstallationsFixtures.install()
    on_exit(fn -> InstallationsFixtures.erase!(installation.id) end)

    scope = Scope.new(member)
    original_secret = WebhookEndpoint.generate_signing_secret()

    endpoint =
      webhook_endpoint(version(installation.id), %{
        require_signature: true,
        signing_secret: original_secret,
        signing_secret_key_version: WebhookEndpoint.signing_secret_key_version()
      })

    results =
      Barrier.race([
        fn -> Endpoints.rotate(scope, endpoint.id) end,
        fn -> Endpoints.rotate(scope, endpoint.id) end
      ])

    assert [{:ok, first}, {:ok, second}] = results
    refute first.token == second.token
    refute first.signing_secret == second.signing_secret

    stored = Repo.one!(WebhookEndpoint.by_id_for_rotation(installation.id, endpoint.id))

    returned_token_digests =
      results
      |> Enum.map(fn {:ok, result} ->
        {:ok, token} = Base.url_decode64(result.token, padding: false)
        WebhookEndpoint.digest(token)
      end)
      |> MapSet.new()

    assert returned_token_digests ==
             MapSet.new([stored.token_digest, stored.previous_token_digest])

    returned_signing_secrets =
      results
      |> Enum.map(fn {:ok, result} -> result.signing_secret end)
      |> MapSet.new()

    assert returned_signing_secrets ==
             MapSet.new([stored.signing_secret, stored.previous_signing_secret])

    raw_body = ~s({"race":true})

    assert Enum.all?(returned_signing_secrets, fn secret ->
             signature = WebhookEndpoint.sign_body(secret, raw_body)
             WebhookEndpoint.signature_valid?(stored, signature, raw_body)
           end)
  end

  test "rotation re-encrypts current and overlap secrets under the new primary key" do
    %{installation: installation, member: member} = InstallationsFixtures.install()
    on_exit(fn -> InstallationsFixtures.erase!(installation.id) end)

    scope = Scope.new(member)
    original_secret = WebhookEndpoint.generate_signing_secret()

    endpoint =
      webhook_endpoint(version(installation.id), %{
        require_signature: true,
        signing_secret: original_secret,
        signing_secret_key_version: WebhookEndpoint.signing_secret_key_version()
      })

    previous_encryption = Application.fetch_env!(:pumble_automation, :encryption)
    old_version = Keyword.fetch!(previous_encryption, :key_version)
    old_key = Keyword.fetch!(previous_encryption, :key)
    legacy_keys = Keyword.get(previous_encryption, :legacy_keys, %{})

    new_version =
      Enum.find(1..Vault.max_key_version(), fn version ->
        version != old_version and not Map.has_key?(legacy_keys, version)
      end)

    rotated_encryption =
      previous_encryption
      |> Keyword.put(:key_version, new_version)
      |> Keyword.put(:key, :crypto.strong_rand_bytes(Vault.key_bytes()))
      |> Keyword.put(:legacy_keys, Map.put(legacy_keys, old_version, old_key))

    Application.put_env(:pumble_automation, :encryption, rotated_encryption)
    on_exit(fn -> Application.put_env(:pumble_automation, :encryption, previous_encryption) end)

    assert {:ok, rotated} = Endpoints.rotate(scope, endpoint.id)

    assert %{rows: [[^new_version, ^new_version, ^new_version, ^new_version]]} =
             Repo.query!(
               """
               SELECT
                 get_byte(signing_secret, $2),
                 signing_secret_key_version,
                 get_byte(previous_signing_secret, $2),
                 previous_signing_secret_key_version
               FROM webhook_endpoints
               WHERE id = $1
               """,
               [Ecto.UUID.dump!(endpoint.id), Vault.key_version_offset()]
             )

    stored = Repo.one!(WebhookEndpoint.by_id_for_rotation(installation.id, endpoint.id))
    assert stored.signing_secret == rotated.signing_secret
    assert stored.previous_signing_secret == original_secret
  end
end
