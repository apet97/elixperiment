defmodule PumbleAutomation.Connections.SecretTest do
  @moduledoc """
  The secret store: write-only, tenant scoped, and safe to delete.

  The tests are grouped by the promise they hold, not by the function they
  call, because the promises are the contract: a value that goes in and does
  not come back out, a rotation that is visible, a tampered ciphertext that
  stops an action instead of degrading it, and a delete that cannot orphan a
  running workflow.
  """

  use PumbleAutomation.DataCase, async: true

  alias PumbleAutomation.Audit.AuditEvent
  alias PumbleAutomation.Connections
  alias PumbleAutomation.Connections.Connection
  alias PumbleAutomation.Connections.Secret
  alias PumbleAutomation.Connections.SecretResolver
  alias PumbleAutomation.ConnectionsFixtures
  alias PumbleAutomation.Executions.Workers.RetentionWorker
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Installations.Lifecycle
  alias PumbleAutomation.Installations.Policy
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows.Workflow
  alias PumbleAutomation.WorkflowsFixtures

  setup do
    here = InstallationsFixtures.install()
    there = InstallationsFixtures.install()

    %{
      scope: Scope.new(here.member),
      other_scope: Scope.new(there.member),
      member: here.member,
      installation: here.installation,
      installation_id: here.installation.id
    }
  end

  describe "the write-only API" do
    test "no read returns the value", %{scope: scope} do
      created = ConnectionsFixtures.secret(scope, %{value: "top-secret"})

      assert created.value == nil

      assert {:ok, fetched} = Connections.get_secret(scope, created.id)
      assert fetched.value == nil

      assert {:ok, [listed]} = Connections.list_secrets(scope)
      refute Map.has_key?(listed, :value)
      assert listed.name == created.name
    end

    test "the column is not even fetched by an ordinary read", %{scope: scope} do
      secret = ConnectionsFixtures.secret(scope, %{value: "top-secret"})

      assert %Secret{value: nil} = Repo.get!(Secret, secret.id)
    end

    test "the context exposes no function that resolves a plaintext" do
      names = Connections.__info__(:functions) |> Keyword.keys() |> Enum.map(&to_string/1)

      refute Enum.any?(names, &String.contains?(&1, "plaintext"))
      refute Enum.any?(names, &String.contains?(&1, "reveal"))
      refute Enum.any?(names, &String.contains?(&1, "resolve"))
    end

    test "every public function refuses a first argument that is not a scope" do
      for {name, arity} <- Connections.__info__(:functions) do
        args = [:not_a_scope | List.duplicate(%{}, arity - 1)]

        assert_raise FunctionClauseError, fn -> apply(Connections, name, args) end
      end
    end
  end

  describe "create_secret/2" do
    test "stores metadata and audits without the value", %{scope: scope} do
      assert {:ok, secret} =
               Connections.create_secret(scope, %{
                 name: "api_token",
                 value: "abc-123",
                 kind: "api_key",
                 description: "Ticket system"
               })

      assert secret.name == "API_TOKEN"
      assert secret.kind == "api_key"
      assert secret.key_version >= 1
      assert secret.value_fingerprint =~ ~r/\A[0-9a-f]{64}\z/
      assert secret.last_rotated_at

      assert [event] = audit_events("secret.created")
      assert event.metadata["resource_name"] == "API_TOKEN"
      assert event.metadata["target_kind"] == "api_key"
      refute Enum.any?(Map.values(event.metadata), &(&1 == "abc-123"))
    end

    test "the fingerprint is not a bare digest of the value", %{scope: scope} do
      secret = ConnectionsFixtures.secret(scope, %{value: "abc-123"})
      bare = :sha256 |> :crypto.hash("abc-123") |> Base.encode16(case: :lower)

      refute secret.value_fingerprint == bare
    end

    test "the same value in two workspaces fingerprints differently", %{
      scope: scope,
      other_scope: other_scope
    } do
      here = ConnectionsFixtures.secret(scope, %{name: "SHARED", value: "same"})
      there = ConnectionsFixtures.secret(other_scope, %{name: "SHARED", value: "same"})

      refute here.value_fingerprint == there.value_fingerprint
    end

    test "refuses a name that is not a template identifier", %{scope: scope} do
      assert {:error, error} =
               Connections.create_secret(scope, %{name: "my token", value: "x"})

      assert error.class == :validation
    end

    test "refuses an empty value", %{scope: scope} do
      assert {:error, error} = Connections.create_secret(scope, %{name: "EMPTY", value: ""})
      assert error.class == :validation
    end

    test "refuses a duplicate name inside one workspace", %{scope: scope} do
      ConnectionsFixtures.secret(scope, %{name: "DUP"})

      assert {:error, error} = Connections.create_secret(scope, %{name: "DUP", value: "y"})
      assert error.class == :conflict
      assert error.code == :secret_name_taken
    end

    test "the same name in another workspace is fine", %{scope: scope, other_scope: other} do
      ConnectionsFixtures.secret(scope, %{name: "DUP"})

      assert {:ok, _secret} = Connections.create_secret(other, %{name: "DUP", value: "y"})
    end
  end

  describe "rotate_secret/3" do
    test "replaces the value and moves the fingerprint", %{scope: scope, installation_id: id} do
      secret = ConnectionsFixtures.secret(scope, %{value: "old"})

      assert {:ok, rotated} = Connections.rotate_secret(scope, secret.id, "new")
      assert rotated.value == nil
      refute rotated.value_fingerprint == secret.value_fingerprint

      assert {:ok, "new"} = SecretResolver.resolve_for_action(id, secret.id)
      assert [_event] = audit_events("secret.rotated")
    end

    test "refuses rotating to the value already stored", %{scope: scope} do
      secret = ConnectionsFixtures.secret(scope, %{value: "same"})

      assert {:error, error} = Connections.rotate_secret(scope, secret.id, "same")
      assert error.class == :validation
      assert audit_events("secret.rotated") == []
    end

    test "does not rename or re-kind the secret", %{scope: scope} do
      secret = ConnectionsFixtures.secret(scope, %{name: "STABLE", kind: "api_key"})

      assert {:ok, rotated} = Connections.rotate_secret(scope, secret.id, "next")
      assert rotated.name == "STABLE"
      assert rotated.kind == "api_key"
    end
  end

  describe "the resolver" do
    test "returns the plaintext and touches last_used_at", %{scope: scope, installation_id: id} do
      secret = ConnectionsFixtures.secret(scope, %{value: "resolved-value"})
      refute Repo.get!(Secret, secret.id).last_used_at

      assert {:ok, "resolved-value"} = SecretResolver.resolve_for_action(id, secret.id)
      assert Repo.get!(Secret, secret.id).last_used_at

      assert [event] = audit_events("secret.used")
      assert event.metadata["resource_name"] == secret.name
      refute Enum.any?(Map.values(event.metadata), &(&1 == "resolved-value"))
    end

    test "another tenant's secret answers exactly as a nonexistent one", %{
      scope: scope,
      other_scope: other
    } do
      secret = ConnectionsFixtures.secret(scope)
      cross = SecretResolver.resolve_for_action(other.installation_id, secret.id)
      absent = SecretResolver.resolve_for_action(other.installation_id, Ecto.UUID.generate())

      assert {:error, %{} = cross_error} = cross
      assert {:error, %{} = absent_error} = absent
      assert cross_error == absent_error
      assert cross_error == Policy.not_found()
    end

    test "a malformed identifier is not found rather than a crash", %{installation_id: id} do
      assert {:error, error} = SecretResolver.resolve_for_action(id, "not-a-uuid")
      assert error == Policy.not_found()
    end

    test "a tampered ciphertext is a permanent security failure", %{
      scope: scope,
      installation_id: id
    } do
      secret = ConnectionsFixtures.secret(scope, %{value: "intact"})
      corrupt!(secret.id)

      assert {:error, error} = SecretResolver.resolve_for_action(id, secret.id)
      assert error.class == :internal
      refute error.retryable?
    end

    test "a tampered ciphertext does not break metadata reads", %{scope: scope} do
      secret = ConnectionsFixtures.secret(scope)
      corrupt!(secret.id)

      assert {:ok, [_listed]} = Connections.list_secrets(scope)
      assert {:ok, _fetched} = Connections.get_secret(scope, secret.id)
    end
  end

  describe "tenancy" do
    test "another workspace cannot read, rotate, or delete", %{
      scope: scope,
      other_scope: other
    } do
      secret = ConnectionsFixtures.secret(scope)

      assert {:error, Policy.not_found()} == Connections.get_secret(other, secret.id)
      assert {:error, Policy.not_found()} == Connections.rotate_secret(other, secret.id, "x")
      assert {:error, Policy.not_found()} == Connections.delete_secret(other, secret.id)
    end

    test "listing only shows this workspace's secrets", %{scope: scope, other_scope: other} do
      ConnectionsFixtures.secret(scope)
      ConnectionsFixtures.secret(other)

      assert {:ok, [_one]} = Connections.list_secrets(scope)
    end
  end

  describe "roles" do
    test "an editor may see metadata but may not write", %{member: member} do
      editor = member_scope(member, "editor")
      assert {:ok, []} = Connections.list_secrets(editor)

      assert {:error, error} = Connections.create_secret(editor, %{name: "NOPE", value: "x"})
      assert error.class == :permission
    end

    test "a viewer may not even list", %{member: member} do
      viewer = member_scope(member, "viewer")

      assert {:error, error} = Connections.list_secrets(viewer)
      assert error.class == :permission
    end
  end

  describe "delete_secret/2" do
    test "deletes an unreferenced secret and audits it", %{scope: scope} do
      secret = ConnectionsFixtures.secret(scope)

      assert {:ok, deleted} = Connections.delete_secret(scope, secret.id)
      assert deleted.value == nil
      assert Repo.get(Secret, secret.id) == nil
      assert [_event] = audit_events("secret.deleted")
    end

    test "refuses while an active workflow version references it", %{scope: scope} do
      secret = ConnectionsFixtures.secret(scope)
      activate(scope, referenced_secret_ids: [secret.id])

      assert {:error, error} = Connections.delete_secret(scope, secret.id)
      assert error.class == :conflict
      assert error.code == :secret_in_use
      assert error.details.workflows == ["Deploy announcements"]
      assert error.message =~ "Deploy announcements"
      assert Repo.get(Secret, secret.id)
    end

    test "a superseded version does not pin a secret forever", %{scope: scope} do
      secret = ConnectionsFixtures.secret(scope)
      workflow = WorkflowsFixtures.drafted_workflow(scope.installation_id)
      WorkflowsFixtures.version(workflow, %{referenced_secret_ids: [secret.id]})

      # The workflow runs nothing: `active_version_id` is still nil.
      assert {:ok, _deleted} = Connections.delete_secret(scope, secret.id)
    end

    test "refuses while a connection references it", %{scope: scope} do
      secret = ConnectionsFixtures.secret(scope)

      connection =
        ConnectionsFixtures.connection(scope, %{
          secret_headers: [%{header: "authorization", secret_id: secret.id}]
        })

      assert {:error, error} = Connections.delete_secret(scope, secret.id)
      assert error.code == :secret_in_use
      assert error.details.connections == [connection.name]
    end
  end

  describe "redaction" do
    test "inspect never shows the value", %{scope: scope} do
      {:ok, secret} = Connections.create_secret(scope, %{name: "SHOWN", value: "hidden-value"})

      refute inspect(secret) =~ "hidden-value"
      refute inspect(%{secret | value: "hidden-value"}) =~ "hidden-value"
    end

    test "a changeset does not show the value" do
      changeset =
        Secret.create_changeset(%{
          installation_id: Ecto.UUID.generate(),
          name: "SHOWN",
          value: "hidden-value"
        })

      refute inspect(changeset) =~ "hidden-value"
    end

    test "the schema declares the value redacted" do
      assert :value in Secret.__schema__(:redact_fields)
    end
  end

  describe "uninstall purge" do
    test "erasing a tenant erases its secrets and leaves other tenants alone", %{
      scope: scope,
      other_scope: other,
      installation: installation
    } do
      ConnectionsFixtures.secret(scope)
      ConnectionsFixtures.connection(scope)
      ConnectionsFixtures.secret(other)
      ConnectionsFixtures.connection(other)

      {:ok, uninstalled} = Lifecycle.uninstall(installation.id)

      assert {:ok, %Installation{status: "deleted"}} = RetentionWorker.purge(uninstalled)

      assert rows_of(Secret, scope.installation_id) == 0
      assert rows_of(Connection, scope.installation_id) == 0

      assert rows_of(Secret, other.installation_id) == 1
      assert rows_of(Connection, other.installation_id) == 1
    end
  end

  defp rows_of(schema, installation_id) do
    Repo.aggregate(from(row in schema, where: row.installation_id == ^installation_id), :count)
  end

  defp audit_events(action) do
    Repo.all(from event in AuditEvent, where: event.action == ^action)
  end

  defp member_scope(member, role) do
    Scope.new(InstallationsFixtures.set_role(member, role))
  end

  # Replaces the stored envelope with one the key cannot authenticate. Written
  # with raw SQL on purpose: an `update_all` would go through
  # `PumbleAutomation.Crypto.EncryptedBinary`, which would encrypt the
  # replacement and store a perfectly valid ciphertext of it.
  defp corrupt!(secret_id) do
    envelope = <<1, 1>> <> :crypto.strong_rand_bytes(48)

    {:ok, _result} =
      Repo.query(
        "UPDATE secrets SET value = $1 WHERE id = $2",
        [envelope, Ecto.UUID.dump!(secret_id)]
      )

    :ok
  end

  defp activate(scope, version_attrs) do
    workflow = WorkflowsFixtures.drafted_workflow(scope.installation_id)
    version = WorkflowsFixtures.version(workflow, Map.new(version_attrs))

    workflow
    |> Workflow.changeset(%{active_version_id: version.id, status: "active"})
    |> Repo.update!()
  end
end
