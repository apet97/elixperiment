defmodule PumbleAutomation.Ingress.WebhookEndpointTest do
  @moduledoc """
  Durable webhook-endpoint constraints: token digests, binding, and lookup.
  """

  use PumbleAutomation.DataCase, async: true

  import PumbleAutomation.IngressFixtures

  alias PumbleAutomation.Ingress.WebhookEndpoint
  alias PumbleAutomation.InstallationsFixtures

  setup do
    %{installation: %{id: installation_id}} = InstallationsFixtures.install()
    version = version(installation_id)
    %{installation_id: installation_id, version: version}
  end

  describe "the migration" do
    test "creates the table with public-id uniqueness and tenant-composite keys" do
      assert %{rows: [["webhook_endpoints"]]} =
               Repo.query!("SELECT to_regclass('public.webhook_endpoints')::text")

      definitions = index_definitions("webhook_endpoints")
      assert definitions =~ "UNIQUE"
      assert definitions =~ "(public_id)"
      assert definitions =~ "(token_digest)"
      assert definitions =~ "(installation_id, enabled)"

      assert foreign_keys("webhook_endpoints") =~ "(workflow_id, installation_id)"
      assert foreign_keys("webhook_endpoints") =~ "(workflow_version_id, installation_id)"
      assert foreign_keys("webhook_endpoints") =~ "ON DELETE CASCADE"

      assert "webhook_endpoints_token_digest_check" in check_constraints("webhook_endpoints")

      assert "webhook_endpoints_previous_token_pair_check" in check_constraints(
               "webhook_endpoints"
             )

      assert "webhook_endpoints_signing_secret_pair_check" in check_constraints(
               "webhook_endpoints"
             )

      assert "webhook_endpoints_signature_compatibility_check" in check_constraints(
               "webhook_endpoints"
             )

      assert "webhook_endpoints_previous_signing_secret_pair_check" in check_constraints(
               "webhook_endpoints"
             )

      assert "webhook_endpoints_rate_limit_per_minute_check" in check_constraints(
               "webhook_endpoints"
             )
    end

    test "does not create a plaintext bearer-token column" do
      fields = WebhookEndpoint.__schema__(:fields)
      refute :token in fields
      refute :secret in fields
      refute :bearer in fields
    end
  end

  describe "changeset and token digest" do
    test "stores a keyed digest, never the plaintext token", %{version: version} do
      token = WebhookEndpoint.generate_token()
      endpoint = webhook_endpoint(version, %{token: token})
      loaded = Repo.get!(WebhookEndpoint, endpoint.id)

      assert loaded.token_digest == WebhookEndpoint.digest(token)
      refute loaded.token_digest == token
      assert byte_size(loaded.token_digest) == WebhookEndpoint.digest_bytes()
      assert WebhookEndpoint.authenticates?(loaded, token)
      refute WebhookEndpoint.authenticates?(loaded, WebhookEndpoint.generate_token())
    end

    test "the digest is not a bare SHA-256 of the token", %{version: version} do
      token = WebhookEndpoint.generate_token()
      endpoint = webhook_endpoint(version, %{token: token})

      refute endpoint.token_digest == :crypto.hash(:sha256, token)
    end

    test "accepts the previous token only until its expiry", %{version: version} do
      current = WebhookEndpoint.generate_token()
      previous = WebhookEndpoint.generate_token()
      now = DateTime.utc_now()

      endpoint =
        webhook_endpoint(version, %{
          token: current,
          previous_token_digest: WebhookEndpoint.digest(previous),
          previous_token_expires_at: DateTime.add(now, 60, :second)
        })

      assert WebhookEndpoint.authenticates?(endpoint, current, now)
      assert WebhookEndpoint.authenticates?(endpoint, previous, now)
      refute WebhookEndpoint.authenticates?(endpoint, previous, DateTime.add(now, 61, :second))
    end

    test "refuses a digest that is not 32 bytes", %{version: version} do
      changeset =
        WebhookEndpoint.changeset(%WebhookEndpoint{}, %{
          installation_id: version.installation_id,
          workflow_id: version.workflow_id,
          workflow_version_id: version.id,
          public_id: WebhookEndpoint.generate_public_id(),
          token_digest: "not-a-digest"
        })

      assert %{token_digest: [_]} = errors_on(changeset)
    end

    test "refuses a previous digest without an expiry", %{version: version} do
      changeset =
        WebhookEndpoint.changeset(%WebhookEndpoint{}, %{
          installation_id: version.installation_id,
          workflow_id: version.workflow_id,
          workflow_version_id: version.id,
          public_id: WebhookEndpoint.generate_public_id(),
          token_digest: WebhookEndpoint.digest(WebhookEndpoint.generate_token()),
          previous_token_digest: WebhookEndpoint.digest(WebhookEndpoint.generate_token())
        })

      assert %{previous_token_expires_at: [_]} = errors_on(changeset)
    end

    test "refuses rate settings outside 1..10000", %{version: version} do
      attrs = %{
        installation_id: version.installation_id,
        workflow_id: version.workflow_id,
        workflow_version_id: version.id,
        public_id: WebhookEndpoint.generate_public_id(),
        token_digest: WebhookEndpoint.digest(WebhookEndpoint.generate_token())
      }

      assert %{rate_limit_per_minute: [_]} =
               errors_on(
                 WebhookEndpoint.changeset(
                   %WebhookEndpoint{},
                   Map.put(attrs, :rate_limit_per_minute, 0)
                 )
               )

      assert %{rate_limit_per_ip_per_minute: [_]} =
               errors_on(
                 WebhookEndpoint.changeset(
                   %WebhookEndpoint{},
                   Map.put(attrs, :rate_limit_per_ip_per_minute, 10_001)
                 )
               )
    end

    test "inspect does not print token digests", %{version: version} do
      endpoint = webhook_endpoint(version)
      inspected = inspect(endpoint)

      refute inspected =~ Base.encode16(endpoint.token_digest, case: :lower)
    end

    test "encrypts a required signing secret and loads it only for authentication", %{
      version: version
    } do
      secret = WebhookEndpoint.generate_signing_secret()

      endpoint =
        webhook_endpoint(version, %{
          require_signature: true,
          signing_secret: secret,
          signing_secret_key_version: WebhookEndpoint.signing_secret_key_version()
        })

      loaded = Repo.get!(WebhookEndpoint, endpoint.id)
      refute loaded.enabled
      assert loaded.signature_enabled
      assert WebhookEndpoint.enabled?(loaded)
      assert is_nil(loaded.signing_secret)
      refute inspect(endpoint) =~ secret
      refute inspect(loaded) =~ secret

      for_auth = Repo.one!(WebhookEndpoint.by_public_id_for_auth(endpoint.public_id))
      assert for_auth.signing_secret == secret
      refute inspect(for_auth) =~ secret

      assert %{rows: [[ciphertext]]} =
               Repo.query!("SELECT signing_secret FROM webhook_endpoints WHERE id = $1", [
                 Ecto.UUID.dump!(endpoint.id)
               ])

      refute ciphertext == secret
      assert :nomatch == :binary.match(ciphertext, secret)
    end

    test "requires an encrypted signing-secret pair when signatures are enabled", %{
      version: version
    } do
      changeset =
        WebhookEndpoint.changeset(%WebhookEndpoint{}, %{
          installation_id: version.installation_id,
          workflow_id: version.workflow_id,
          workflow_version_id: version.id,
          public_id: WebhookEndpoint.generate_public_id(),
          token_digest: WebhookEndpoint.digest(WebhookEndpoint.generate_token()),
          require_signature: true
        })

      assert %{signing_secret: [_], signing_secret_key_version: [_]} = errors_on(changeset)
    end

    test "signatures bind to exact raw bytes and use the previous secret only before expiry", %{
      version: version
    } do
      current = WebhookEndpoint.generate_signing_secret()
      previous = WebhookEndpoint.generate_signing_secret()
      now = DateTime.utc_now()

      endpoint =
        webhook_endpoint(version, %{
          require_signature: true,
          signing_secret: current,
          signing_secret_key_version: WebhookEndpoint.signing_secret_key_version(),
          previous_signing_secret: previous,
          previous_signing_secret_key_version: WebhookEndpoint.signing_secret_key_version(),
          previous_signing_secret_expires_at: DateTime.add(now, 60, :second)
        })

      body = ~s({"a":1})
      current_signature = WebhookEndpoint.sign_body(current, body)
      previous_signature = WebhookEndpoint.sign_body(previous, body)

      assert WebhookEndpoint.signature_valid?(endpoint, current_signature, body, now)
      assert WebhookEndpoint.signature_valid?(endpoint, previous_signature, body, now)

      refute WebhookEndpoint.signature_valid?(
               endpoint,
               previous_signature,
               body,
               DateTime.add(now, 61, :second)
             )

      refute WebhookEndpoint.signature_valid?(endpoint, current_signature, body <> "\n", now)
      refute WebhookEndpoint.signature_valid?(endpoint, nil, body, now)
      refute WebhookEndpoint.signature_valid?(endpoint, "sha256=malformed", body, now)
    end

    test "an unsigned endpoint accepts a missing signature", %{version: version} do
      endpoint = webhook_endpoint(version)
      assert WebhookEndpoint.signature_valid?(endpoint, nil, ~s({"ok":true}))
    end
  end

  describe "cross-tenant endpoint lookup" do
    test "by_public_id/1 finds the endpoint by its opaque id", %{
      version: version
    } do
      endpoint = webhook_endpoint(version)

      assert [found] = Repo.all(WebhookEndpoint.by_public_id(endpoint.public_id))
      assert found.id == endpoint.id
    end

    test "by_public_id/2 never returns another tenant's endpoint", %{version: version} do
      endpoint = webhook_endpoint(version)
      %{installation: other} = InstallationsFixtures.install()

      assert [] == Repo.all(WebhookEndpoint.by_public_id(other.id, endpoint.public_id))

      assert [found] =
               Repo.all(WebhookEndpoint.by_public_id(version.installation_id, endpoint.public_id))

      assert found.id == endpoint.id
    end

    test "refuses a workflow that belongs to another installation", %{version: version} do
      %{installation: other} = InstallationsFixtures.install()

      assert {:error, changeset} =
               %WebhookEndpoint{}
               |> WebhookEndpoint.changeset(%{
                 installation_id: other.id,
                 workflow_id: version.workflow_id,
                 workflow_version_id: version.id,
                 public_id: WebhookEndpoint.generate_public_id(),
                 token_digest: WebhookEndpoint.digest(WebhookEndpoint.generate_token())
               })
               |> Repo.insert()

      errors = errors_on(changeset)
      assert Map.has_key?(errors, :workflow_id) or Map.has_key?(errors, :workflow_version_id)
    end
  end

  defp index_definitions(table) do
    %{rows: rows} = Repo.query!("SELECT indexdef FROM pg_indexes WHERE tablename = $1", [table])
    Enum.map_join(rows, "\n", &hd/1)
  end

  defp foreign_keys(table) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT pg_get_constraintdef(c.oid)
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        WHERE t.relname = $1 AND c.contype = 'f'
        """,
        [table]
      )

    Enum.map_join(rows, "\n", &hd/1)
  end

  defp check_constraints(table) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT con.conname FROM pg_constraint con
        JOIN pg_class rel ON rel.oid = con.conrelid
        WHERE rel.relname = $1 AND con.contype = 'c'
        """,
        [table]
      )

    rows |> Enum.map(fn [name] -> name end) |> Enum.sort()
  end
end
