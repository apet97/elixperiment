defmodule PumbleAutomation.Connections.ConnectionTest do
  @moduledoc """
  The HTTP connection: finite, tenant scoped, and impossible to escape from.

  The path suite is the centre of this file. Everything else a connection does
  is ordinary tenant-scoped CRUD; the one thing that would be a vulnerability
  rather than a bug is a node that reaches an origin or a prefix the owner
  never approved, so that rule is tested by enumeration rather than by
  example.
  """

  use PumbleAutomation.DataCase, async: true

  alias PumbleAutomation.Audit.AuditEvent
  alias PumbleAutomation.Connections
  alias PumbleAutomation.Connections.Connection
  alias PumbleAutomation.Connections.ResolvedConnection
  alias PumbleAutomation.Connections.Resolver
  alias PumbleAutomation.Connections.SafeHttp
  alias PumbleAutomation.ConnectionsFixtures
  alias PumbleAutomation.HttpTestServer
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
      member: here.member
    }
  end

  describe "create_connection/2" do
    test "stores a normalized row and audits it", %{scope: scope} do
      assert {:ok, connection} =
               Connections.create_connection(scope, %{
                 name: "Tickets",
                 base_origin: "https://api.example.test:443/",
                 base_path_prefix: "/v1/",
                 headers: %{"Accept" => "application/json"}
               })

      assert connection.type == "http"
      assert connection.base_origin == "https://api.example.test"
      assert connection.base_path_prefix == "/v1"
      assert connection.headers == %{"accept" => "application/json"}
      assert connection.enabled
      assert connection.policy_version == Connection.policy_version()

      assert [event] = audit_events("connection.created")
      assert event.metadata["resource_name"] == "Tickets"
      assert event.metadata["target_kind"] == "http"
    end

    test "keeps a non-default port", %{scope: scope} do
      connection = ConnectionsFixtures.connection(scope, %{base_origin: "https://api.test:8443"})

      assert connection.base_origin == "https://api.test:8443"
    end

    test "refuses a duplicate name inside one workspace", %{scope: scope} do
      ConnectionsFixtures.connection(scope, %{name: "Same"})

      assert {:error, error} =
               Connections.create_connection(scope, %{
                 name: "Same",
                 base_origin: "https://api.test"
               })

      assert error.code == :connection_name_taken
    end
  end

  describe "the base URL rule" do
    test "refuses anything that is not an https origin", %{scope: scope} do
      refusals = [
        {"http://api.test", :origin_not_https},
        {"ftp://api.test", :origin_not_https},
        {"https://user:pass@api.test", :origin_with_userinfo},
        {"https://api.test#fragment", :origin_with_fragment},
        {"https://api.test?a=b", :origin_with_query},
        {"https://api.test/v1", :origin_with_path},
        {"api.test", :origin_not_https},
        {"https://", :origin_without_host}
      ]

      for {origin, code} <- refusals do
        assert {:error, error} =
                 Connections.create_connection(scope, %{name: "N", base_origin: origin}),
               "#{origin} was accepted"

        assert error.code == code, "#{origin} gave #{error.code}"
      end
    end

    test "refuses a path prefix that can climb", %{scope: scope} do
      for prefix <- ["v1", "/v1/../../etc", "/v1/%2e%2e", "/v1//v2", "/v1/."] do
        assert {:error, error} =
                 Connections.create_connection(scope, %{
                   name: "N",
                   base_origin: "https://api.test",
                   base_path_prefix: prefix
                 }),
               "#{prefix} was accepted"

        assert error.class == :validation
      end
    end
  end

  describe "the header rule" do
    test "refuses every framing, routing, and hop-by-hop header", %{scope: scope} do
      for name <- Connection.blocked_headers() ++ ["Proxy-Anything", "HOST"] do
        assert {:error, error} = create_with_headers(scope, %{name => "x"}), "#{name} accepted"
        assert error.code == :header_blocked, "#{name} gave #{error.code}"
      end
    end

    test "refuses a literal authorization header", %{scope: scope} do
      assert {:error, error} = create_with_headers(scope, %{"Authorization" => "Bearer x"})
      assert error.code == :header_secret_only
    end

    test "allows authorization as a secret-backed header", %{scope: scope} do
      secret = ConnectionsFixtures.secret(scope)

      assert {:ok, connection} =
               Connections.create_connection(scope, %{
                 name: "Auth",
                 base_origin: "https://api.test",
                 secret_headers: [%{header: "Authorization", secret_id: secret.id}]
               })

      assert connection.secret_headers == [
               %{"header" => "authorization", "secret_id" => secret.id}
             ]

      assert connection.referenced_secret_ids == [secret.id]
    end

    test "refuses a blocked name even as a secret-backed header", %{scope: scope} do
      secret = ConnectionsFixtures.secret(scope)

      assert {:error, error} =
               Connections.create_connection(scope, %{
                 name: "Auth",
                 base_origin: "https://api.test",
                 secret_headers: [%{header: "Host", secret_id: secret.id}]
               })

      assert error.code == :header_blocked
    end

    test "refuses a malformed header name", %{scope: scope} do
      for name <- ["bad header", "bad\nheader", "", "acc:ept"] do
        assert {:error, error} = create_with_headers(scope, %{name => "x"}), "#{name} accepted"
        assert error.code == :header_name_invalid
      end
    end

    test "refuses a header value carrying a control character", %{scope: scope} do
      assert {:error, error} = create_with_headers(scope, %{"accept" => "a\r\nx-evil: 1"})
      assert error.code == :header_value_invalid
    end

    test "refuses one name set literally and by a secret", %{scope: scope} do
      secret = ConnectionsFixtures.secret(scope)

      assert {:error, error} =
               Connections.create_connection(scope, %{
                 name: "Both",
                 base_origin: "https://api.test",
                 headers: %{"x-api-key" => "literal"},
                 secret_headers: [%{header: "X-API-Key", secret_id: secret.id}]
               })

      assert error.class == :validation
    end

    test "refuses more headers than the limit", %{scope: scope} do
      headers =
        Map.new(1..(Connection.max_headers() + 1), fn n -> {"x-header-#{n}", "value"} end)

      assert {:error, error} = create_with_headers(scope, headers)
      assert error.class == :validation
    end
  end

  describe "secret references" do
    test "another workspace's secret is not found", %{scope: scope, other_scope: other} do
      secret = ConnectionsFixtures.secret(other)

      assert {:error, error} =
               Connections.create_connection(scope, %{
                 name: "Cross",
                 base_origin: "https://api.test",
                 secret_headers: [%{header: "authorization", secret_id: secret.id}]
               })

      assert error == Policy.not_found()
    end

    test "a nonexistent secret answers exactly the same way", %{scope: scope} do
      assert {:error, error} =
               Connections.create_connection(scope, %{
                 name: "Absent",
                 base_origin: "https://api.test",
                 secret_headers: [%{header: "authorization", secret_id: Ecto.UUID.generate()}]
               })

      assert error == Policy.not_found()
    end
  end

  describe "update_connection/3" do
    test "revalidates everything and audits", %{scope: scope} do
      connection = ConnectionsFixtures.connection(scope)

      assert {:ok, updated} =
               Connections.update_connection(scope, connection.id, %{
                 name: connection.name,
                 base_origin: "https://other.test",
                 enabled: false
               })

      assert updated.base_origin == "https://other.test"
      refute updated.enabled
      assert [_event] = audit_events("connection.updated")
    end

    test "cannot be used to smuggle a blocked header in", %{scope: scope} do
      connection = ConnectionsFixtures.connection(scope)

      assert {:error, error} =
               Connections.update_connection(scope, connection.id, %{
                 name: connection.name,
                 base_origin: connection.base_origin,
                 headers: %{"host" => "evil.test"}
               })

      assert error.code == :header_blocked
    end

    test "cannot move the row to another tenant", %{scope: scope, other_scope: other} do
      connection = ConnectionsFixtures.connection(scope)

      {:ok, updated} =
        Connections.update_connection(scope, connection.id, %{
          name: connection.name,
          base_origin: connection.base_origin,
          installation_id: other.installation_id
        })

      assert updated.installation_id == scope.installation_id
    end
  end

  describe "tenancy and roles" do
    test "another workspace sees nothing", %{scope: scope, other_scope: other} do
      connection = ConnectionsFixtures.connection(scope)

      assert {:error, Policy.not_found()} == Connections.get_connection(other, connection.id)
      assert {:error, Policy.not_found()} == Connections.delete_connection(other, connection.id)
      assert {:ok, []} = Connections.list_connections(other)
    end

    test "an editor reads but does not write", %{scope: scope, member: member} do
      ConnectionsFixtures.connection(scope)
      editor = Scope.new(InstallationsFixtures.set_role(member, "editor"))

      assert {:ok, [_one]} = Connections.list_connections(editor)

      assert {:error, error} =
               Connections.create_connection(editor, %{
                 name: "Nope",
                 base_origin: "https://api.test"
               })

      assert error.class == :permission
    end
  end

  describe "delete_connection/2" do
    test "deletes an unreferenced connection and audits it", %{scope: scope} do
      connection = ConnectionsFixtures.connection(scope)

      assert {:ok, _deleted} = Connections.delete_connection(scope, connection.id)
      assert Repo.get(Connection, connection.id) == nil
      assert [_event] = audit_events("connection.deleted")
    end

    test "refuses while an active workflow version references it", %{scope: scope} do
      connection = ConnectionsFixtures.connection(scope)
      activate(scope, referenced_connection_ids: [connection.id])

      assert {:error, error} = Connections.delete_connection(scope, connection.id)
      assert error.code == :connection_in_use
      assert error.details.workflows == ["Deploy announcements"]
      assert Repo.get(Connection, connection.id)
    end
  end

  describe "test_connection/2" do
    test "blocks a loopback origin through UrlPolicy without opening a socket", %{scope: scope} do
      connection =
        ConnectionsFixtures.connection(scope, %{
          name: "Loopback",
          base_origin: "https://127.0.0.1",
          base_path_prefix: nil
        })

      assert {:ok, outcome} = Connections.test_connection(scope, connection.id)
      assert outcome.result == "blocked"
      assert outcome.http_status == nil
      assert outcome.outcome == "That address is not allowed."

      assert [event] = audit_events("connection.tested")
      assert event.metadata["result"] == "blocked"
      assert event.metadata["resource_name"] == "Loopback"
      refute inspect(event) =~ "127.0.0.1"
    end

    test "probes through SafeHttp and records a safe outcome", %{scope: scope} do
      pid = start_supervised!({HttpTestServer, mode: :https})
      info = HttpTestServer.info(pid)
      hostname = HttpTestServer.hostname()
      public = {1, 1, 1, 1}

      connection =
        ConnectionsFixtures.connection(scope, %{
          name: "Probe",
          base_origin: "https://#{hostname}:#{info.port}",
          base_path_prefix: nil
        })

      connect = fn scheme, address, port, host, opts ->
        assert address == public
        SafeHttp.Transport.connect(scheme, info.ip, port, host, opts)
      end

      assert {:ok, outcome} =
               Connections.test_connection(scope, connection.id,
                 resolver: fn ^hostname -> {:ok, [public]} end,
                 connect: connect,
                 transport_opts: [cacerts: info.cacerts]
               )

      assert outcome.result == "ok"
      assert outcome.http_status == 200
      assert outcome.outcome == "HTTP 200"
      refute Map.has_key?(outcome, :body)
      refute inspect(outcome) =~ "GET "

      assert {:ok, outcomes} = Connections.last_test_outcomes(scope)
      assert outcomes[connection.id].result == "ok"
      assert outcomes[connection.id].http_status == 200
    end

    test "an editor may not probe", %{scope: scope, member: member} do
      connection = ConnectionsFixtures.connection(scope)
      editor = %Scope{Scope.new(member) | role: "editor"}

      assert {:error, error} = Connections.test_connection(editor, connection.id)
      assert error.class == :permission
    end

    test "another workspace's connection is still not found", %{
      scope: scope,
      other_scope: other
    } do
      connection = ConnectionsFixtures.connection(scope)

      assert {:error, Policy.not_found()} == Connections.test_connection(other, connection.id)
    end
  end

  describe "the resolver" do
    test "returns handles, never a value", %{scope: scope} do
      secret = ConnectionsFixtures.secret(scope, %{value: "never-here"})

      connection =
        ConnectionsFixtures.connection(scope, %{
          headers: %{"accept" => "application/json"},
          secret_headers: [%{header: "authorization", secret_id: secret.id}]
        })

      assert {:ok, resolved} = Resolver.resolve(scope, connection.id)
      assert %ResolvedConnection{} = resolved
      assert resolved.secret_headers == [%{header: "authorization", secret_id: secret.id}]
      assert ResolvedConnection.secret_ids(resolved) == [secret.id]
      refute inspect(resolved) =~ "never-here"
      refute Map.has_key?(resolved, :value)
    end

    test "a disabled connection is a permanent conflict", %{scope: scope} do
      connection = ConnectionsFixtures.connection(scope, %{enabled: false})

      assert {:error, error} = Resolver.resolve(scope, connection.id)
      assert error.class == :conflict
      assert error.code == :connection_disabled
      refute error.retryable?
    end

    test "another workspace's connection is not found", %{scope: scope, other_scope: other} do
      connection = ConnectionsFixtures.connection(scope)

      assert {:error, Policy.not_found()} == Resolver.resolve(other, connection.id)
      assert {:error, Policy.not_found()} == Resolver.resolve(other, "not-a-uuid")
    end
  end

  describe "narrow_path/2" do
    test "a node narrows the connection's prefix" do
      assert {:ok, "/v1"} = Resolver.narrow_path("/v1", nil)
      assert {:ok, "/v1"} = Resolver.narrow_path("/v1", "")
      assert {:ok, "/v1/tickets"} = Resolver.narrow_path("/v1", "tickets")
      assert {:ok, "/v1/tickets"} = Resolver.narrow_path("/v1", "/tickets")
      assert {:ok, "/v1/tickets/42"} = Resolver.narrow_path("/v1/", "tickets/42")
      assert {:ok, "/"} = Resolver.narrow_path(nil, nil)
      assert {:ok, "/tickets"} = Resolver.narrow_path(nil, "tickets")
    end

    test "the result always stays under the prefix" do
      assert {:ok, path} = Resolver.narrow_path("/v1", "tickets")
      assert String.starts_with?(path, "/v1/")
    end

    test "refuses every way out of the prefix" do
      escapes = [
        "..",
        "../admin",
        "tickets/../../admin",
        "/../admin",
        "%2e%2e/admin",
        "%2E%2E%2Fadmin",
        "tickets/%2e%2e",
        "%2fadmin",
        "//evil.test/admin",
        "https://evil.test/admin",
        "http://evil.test",
        "file:///etc/passwd",
        "\\evil",
        "tickets\\..\\admin",
        "//",
        "tickets//admin",
        "./admin",
        "tickets/./admin"
      ]

      for escape <- escapes do
        assert {:error, error} = Resolver.narrow_path("/v1", escape), "#{escape} was accepted"
        assert error.class == :validation, "#{escape} gave #{error.class}"
      end
    end

    test "refuses the same escapes with no prefix at all" do
      for escape <- ["..", "../admin", "%2e%2e", "//evil.test", "https://evil.test"] do
        assert {:error, _error} = Resolver.narrow_path(nil, escape), "#{escape} was accepted"
      end
    end

    test "a resolved connection carries its own prefix", %{scope: scope} do
      connection = ConnectionsFixtures.connection(scope, %{base_path_prefix: "/v1"})
      {:ok, resolved} = Resolver.resolve(scope, connection.id)

      assert {:ok, "/v1/tickets"} = Resolver.narrow_path(resolved, "tickets")
      assert {:error, _error} = Resolver.narrow_path(resolved, "../admin")
    end

    test "build_url/2 cannot be pointed at another origin", %{scope: scope} do
      connection = ConnectionsFixtures.connection(scope, %{base_path_prefix: "/v1"})
      {:ok, resolved} = Resolver.resolve(scope, connection.id)

      assert {:ok, url} = Resolver.build_url(resolved, "tickets")
      assert url == "https://api.example.test/v1/tickets"

      assert {:error, _error} = Resolver.build_url(resolved, "https://evil.test/x")
    end
  end

  defp create_with_headers(scope, headers) do
    Connections.create_connection(scope, %{
      name: "Headers #{System.unique_integer([:positive])}",
      base_origin: "https://api.test",
      headers: headers
    })
  end

  defp audit_events(action) do
    Repo.all(from event in AuditEvent, where: event.action == ^action)
  end

  defp activate(scope, version_attrs) do
    workflow = WorkflowsFixtures.drafted_workflow(scope.installation_id)
    version = WorkflowsFixtures.version(workflow, Map.new(version_attrs))

    workflow
    |> Workflow.changeset(%{active_version_id: version.id, status: "active"})
    |> Repo.update!()
  end
end
