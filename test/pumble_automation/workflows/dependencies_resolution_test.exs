defmodule PumbleAutomation.Workflows.DependenciesResolutionTest do
  @moduledoc """
  Turning the references a workflow holds into this tenant's rows.

  The promise under test is a tenant boundary: a workflow that names another
  workspace's connection or secret must be told the same thing as a workflow
  that names one nobody ever created, because any difference between those two
  answers is a way to learn what another workspace has.
  """

  use PumbleAutomation.DataCase, async: true

  alias PumbleAutomation.ConnectionsFixtures
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows.Compiler
  alias PumbleAutomation.Workflows.Dependencies
  alias PumbleAutomation.Workflows.Node
  alias PumbleAutomation.WorkflowsFixtures

  setup do
    here = InstallationsFixtures.install()
    there = InstallationsFixtures.install()

    %{
      scope: Scope.new(here.member),
      other_scope: Scope.new(there.member),
      installation_id: here.installation.id,
      other_installation_id: there.installation.id
    }
  end

  describe "connections" do
    test "a connection of this tenant resolves to its identifier", context do
      connection = ConnectionsFixtures.connection(context.scope)

      assert {:ok, resolved} = resolve([http_node(connection.id)], context.installation_id)
      assert resolved.connection_ids == [connection.id]
    end

    test "another tenant's connection is refused", context do
      connection = ConnectionsFixtures.connection(context.other_scope)

      assert {:error, [issue]} = resolve([http_node(connection.id)], context.installation_id)
      assert issue.code == :connection_not_found
      assert issue.severity == :error
    end

    test "another tenant's connection is refused in the same words as one that never existed",
         context do
      connection = ConnectionsFixtures.connection(context.other_scope)

      {:error, [theirs]} = resolve([http_node(connection.id)], context.installation_id)
      {:error, [nobodys]} = resolve([http_node(Ecto.UUID.generate())], context.installation_id)

      assert theirs.code == nobodys.code
      assert theirs.message == nobodys.message
    end

    test "a connection that was turned off is refused", context do
      connection = ConnectionsFixtures.connection(context.scope, %{enabled: false})

      assert {:error, [issue]} = resolve([http_node(connection.id)], context.installation_id)
      assert issue.code == :connection_disabled
    end

    test "the secrets a connection injects are part of what the workflow depends on", context do
      secret = ConnectionsFixtures.secret(context.scope)

      connection =
        ConnectionsFixtures.connection(context.scope, %{
          secret_headers: [%{"header" => "authorization", "secret_id" => secret.id}]
        })

      assert {:ok, resolved} = resolve([http_node(connection.id)], context.installation_id)
      assert resolved.secret_ids == [secret.id]
    end

    test "a connection cannot shadow the workflow-managed idempotency header", context do
      connection =
        ConnectionsFixtures.connection(context.scope, %{
          headers: %{"idempotency-key" => "static-value"}
        })

      assert {:error, [issue]} =
               resolve(
                 [http_node(connection.id, idempotency_header: "Idempotency-Key")],
                 context.installation_id
               )

      assert issue.code == :connection_header_conflict
      assert issue.path =~ connection.id
      refute issue.message =~ "static-value"
    end

    test "a distinct idempotency header resolves normally", context do
      connection = ConnectionsFixtures.connection(context.scope, %{headers: %{"x-api" => "v"}})

      assert {:ok, resolved} =
               resolve(
                 [http_node(connection.id, idempotency_header: "Idempotency-Key")],
                 context.installation_id
               )

      assert resolved.connection_ids == [connection.id]
    end
  end

  describe "secrets" do
    test "a secret of this tenant resolves by name to its identifier", context do
      secret = ConnectionsFixtures.secret(context.scope, %{name: "API_TOKEN"})
      connection = ConnectionsFixtures.connection(context.scope)

      assert {:ok, resolved} =
               resolve(
                 [http_node(connection.id, body: "token={{ secret.API_TOKEN }}")],
                 context.installation_id
               )

      assert resolved.secret_ids == [secret.id]
    end

    test "another tenant's secret is refused", context do
      ConnectionsFixtures.secret(context.other_scope, %{name: "API_TOKEN"})
      connection = ConnectionsFixtures.connection(context.scope)

      assert {:error, [issue]} =
               resolve(
                 [http_node(connection.id, body: "token={{ secret.API_TOKEN }}")],
                 context.installation_id
               )

      assert issue.code == :secret_not_found
    end

    test "a secret that exists nowhere is refused", context do
      connection = ConnectionsFixtures.connection(context.scope)

      assert {:error, [issue]} =
               resolve(
                 [http_node(connection.id, body: "{{ secret.NOTHING_HERE }}")],
                 context.installation_id
               )

      assert issue.code == :secret_not_found
      assert issue.path == "/secrets/NOTHING_HERE"
    end

    test "no refusal quotes a value, because no value is ever read", context do
      ConnectionsFixtures.secret(context.other_scope, %{name: "API_TOKEN", value: "top-secret"})
      connection = ConnectionsFixtures.connection(context.scope)

      {:error, [issue]} =
        resolve(
          [http_node(connection.id, body: "{{ secret.API_TOKEN }}")],
          context.installation_id
        )

      refute String.contains?(issue.message, "top-secret")
    end
  end

  describe "answering about everything at once" do
    test "a workflow that references nothing resolves to nothing", context do
      assert {:ok, resolved} =
               resolve([WorkflowsFixtures.message_node()], context.installation_id)

      assert resolved == %{connection_ids: [], secret_ids: []}
    end

    test "every missing reference is named, not just the first", context do
      assert {:error, issues} =
               resolve(
                 [http_node(Ecto.UUID.generate(), body: "{{ secret.NOTHING_HERE }}")],
                 context.installation_id
               )

      assert Enum.map(issues, & &1.code) |> Enum.sort() ==
               [:connection_not_found, :secret_not_found]
    end

    test "one connection used by two steps resolves once", context do
      connection = ConnectionsFixtures.connection(context.scope)

      assert {:ok, resolved} =
               resolve(
                 [http_node(connection.id), http_node(connection.id)],
                 context.installation_id
               )

      assert resolved.connection_ids == [connection.id]
    end
  end

  defp resolve(steps, installation_id) do
    {:ok, compiled} = Compiler.compile(WorkflowsFixtures.definition(steps))

    compiled
    |> Dependencies.calculate()
    |> Dependencies.resolve(installation_id)
  end

  defp http_node(connection_id, config \\ %{}) do
    Node.new(
      :http_action,
      Map.merge(
        %{method: :post, url: "https://api.example.test/v1/hook", connection_id: connection_id},
        Map.new(config)
      )
    )
  end
end
