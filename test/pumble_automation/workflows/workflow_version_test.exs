defmodule PumbleAutomation.Workflows.WorkflowVersionTest do
  use PumbleAutomation.DataCase, async: true

  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Error
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Workflow
  alias PumbleAutomation.Workflows.WorkflowVersion

  setup do
    %{installation: %{id: installation_id}, member: member} = InstallationsFixtures.install()
    workflow = workflow(installation_id, %{draft_definition: Definition.encode(definition())})

    %{installation_id: installation_id, member: member, workflow: workflow}
  end

  describe "the migration" do
    test "creates the table with its uniqueness and its tenant-composite key" do
      assert %{rows: [[found]]} =
               Repo.query!("SELECT to_regclass('public.workflow_versions')::text")

      assert found == "workflow_versions"

      definitions = index_definitions("workflow_versions")
      assert definitions =~ "UNIQUE"
      assert definitions =~ "(workflow_id, version_number)"
      assert definitions =~ "(workflow_id, identity_hash)"
      assert definitions =~ "workflow_versions_workflow_id_definition_hash_index"
      assert definitions =~ "(workflow_id, source_hash)"

      assert foreign_keys("workflow_versions") =~ "(workflow_id, installation_id)"
    end

    test "gives workflows.active_version_id its deferred foreign key" do
      assert foreign_keys("workflows") =~ "active_version_id"
    end

    test "does not give the table an updated_at column" do
      refute :updated_at in Enum.map(WorkflowVersion.__schema__(:fields), & &1)
    end
  end

  describe "immutability" do
    test "the context exposes no update and no delete" do
      exported = WorkflowVersion.__info__(:functions)

      for name <- [:update, :delete, :update_changeset, :delete_all] do
        refute Keyword.has_key?(exported, name)
      end
    end

    test "changeset/2 raises for a stored version", %{workflow: workflow} do
      {:ok, version} = WorkflowVersion.create(workflow)

      assert_raise RuntimeError, ~r/immutable/, fn ->
        WorkflowVersion.changeset(version, %{compiler_version: "2"})
      end
    end

    test "a stored version still hashes to its stored hash", %{workflow: workflow} do
      {:ok, version} = WorkflowVersion.create(workflow)

      stored = Repo.get!(WorkflowVersion, version.id)

      assert stored.identity_hash =~ ~r/\A[0-9a-f]{64}\z/
      assert WorkflowVersion.intact?(stored)
    end
  end

  describe "definition_hash/1" do
    test "ignores key insertion order" do
      one = %{"a" => 1, "b" => %{"x" => true, "y" => [1, 2]}}
      other = %{"b" => %{"y" => [1, 2], "x" => true}, "a" => 1}

      assert WorkflowVersion.definition_hash(one) == WorkflowVersion.definition_hash(other)
    end

    test "treats an atom key and a string key as the same key" do
      assert WorkflowVersion.definition_hash(%{a: 1, b: 2}) ==
               WorkflowVersion.definition_hash(%{"b" => 2, "a" => 1})
    end

    test "survives a randomized rebuild of the same encoded definition" do
      encoded = Definition.encode(definition([message_node(), delay_node()]))
      expected = WorkflowVersion.definition_hash(encoded)

      for _attempt <- 1..25 do
        assert WorkflowVersion.definition_hash(shuffle_keys(encoded)) == expected
      end
    end

    test "distinguishes different content" do
      refute WorkflowVersion.definition_hash(%{"a" => 1}) ==
               WorkflowVersion.definition_hash(%{"a" => 2})
    end

    test "is a lowercase 64-character hex digest" do
      assert WorkflowVersion.definition_hash(%{}) =~ ~r/\A[0-9a-f]{64}\z/
    end

    test "canonical_json/1 writes sorted string keys" do
      assert WorkflowVersion.canonical_json(%{b: 1, a: %{d: 2, c: 3}}) ==
               ~s({"a":{"c":3,"d":2},"b":1})
    end
  end

  describe "identity_hash/1" do
    test "covers the compiler and resolved dependency snapshot while ignoring set order" do
      secret_one = Ecto.UUID.generate()
      secret_two = Ecto.UUID.generate()
      connection_one = Ecto.UUID.generate()
      connection_two = Ecto.UUID.generate()

      snapshot = %{
        source_definition: %{"schema_version" => 1},
        compiled_definition: %{"entry" => "node-1"},
        compiler_version: "1",
        required_scopes: ["messages:write", "channels:read"],
        referenced_secret_ids: [secret_one, secret_two],
        referenced_connection_ids: [connection_one, connection_two]
      }

      reordered = %{
        "source_definition" => %{"schema_version" => 1},
        "compiled_definition" => %{"entry" => "node-1"},
        "compiler_version" => "1",
        "required_scopes" => ["channels:read", "messages:write"],
        "referenced_secret_ids" => [secret_two, secret_one],
        "referenced_connection_ids" => [connection_two, connection_one]
      }

      assert WorkflowVersion.identity_hash(snapshot) == WorkflowVersion.identity_hash(reordered)

      refute WorkflowVersion.identity_hash(snapshot) ==
               WorkflowVersion.identity_hash(%{snapshot | compiler_version: "2"})
    end

    test "normalizes omitted dependency lists to the stored empty-array defaults" do
      assert WorkflowVersion.identity_hash(%{source_definition: %{}}) ==
               WorkflowVersion.identity_hash(%{
                 source_definition: %{},
                 required_scopes: [],
                 referenced_secret_ids: [],
                 referenced_connection_ids: []
               })
    end
  end

  describe "create/2" do
    test "versions the workflow draft and numbers it from one", %{
      workflow: workflow,
      installation_id: installation_id,
      member: member
    } do
      assert {:ok, version} = WorkflowVersion.create(workflow, %{created_by_member_id: member.id})

      assert version.version_number == 1
      assert version.installation_id == installation_id
      assert version.workflow_id == workflow.id
      assert version.created_by_member_id == member.id
      assert version.definition_hash == WorkflowVersion.definition_hash(workflow.draft_definition)
      assert version.source_hash == WorkflowVersion.definition_hash(workflow.draft_definition)
      assert version.identity_hash == WorkflowVersion.identity_hash(version)
      assert version.required_scopes == []
      assert is_nil(version.compiled_definition)
    end

    test "numbers successive versions monotonically", %{workflow: workflow} do
      assert {:ok, first} = WorkflowVersion.create(workflow)

      assert {:ok, second} =
               WorkflowVersion.create(workflow, %{
                 source_definition: definition([message_node()])
               })

      assert {:ok, third} =
               WorkflowVersion.create(workflow, %{
                 source_definition: definition([message_node(), delay_node()])
               })

      assert [first.version_number, second.version_number, third.version_number] == [1, 2, 3]
    end

    test "refuses a second version of an identical immutable snapshot", %{workflow: workflow} do
      assert {:ok, _first} = WorkflowVersion.create(workflow)

      assert {:error, %Error{class: :conflict, code: :duplicate_version_identity}} =
               WorkflowVersion.create(workflow)
    end

    test "refuses a second snapshot for the same source during rollback compatibility", %{
      workflow: workflow
    } do
      source = workflow.draft_definition
      secret_one = Ecto.UUID.generate()
      secret_two = Ecto.UUID.generate()
      connection_one = Ecto.UUID.generate()
      connection_two = Ecto.UUID.generate()

      snapshots = [
        %{
          source_definition: source,
          compiled_definition: %{"entry" => "node-1"},
          compiler_version: "1",
          required_scopes: ["channels:read"],
          referenced_secret_ids: [secret_one],
          referenced_connection_ids: [connection_one]
        },
        %{
          source_definition: source,
          compiled_definition: %{"entry" => "node-2"},
          compiler_version: "2",
          required_scopes: ["messages:write"],
          referenced_secret_ids: [secret_two],
          referenced_connection_ids: [connection_two]
        }
      ]

      assert {:ok, first} = WorkflowVersion.create(workflow, Enum.at(snapshots, 0))

      assert {:error, %Error{class: :conflict, code: :duplicate_version_identity}} =
               WorkflowVersion.create(workflow, Enum.at(snapshots, 1))

      assert first.definition_hash == first.source_hash
      assert WorkflowVersion.intact?(first)
    end

    test "refuses a workflow with no definition", %{installation_id: installation_id} do
      empty = workflow(installation_id, %{})

      assert {:error, %Error{class: :validation, code: :missing_definition}} =
               WorkflowVersion.create(empty)
    end

    test "refuses a definition the editor could not reopen", %{workflow: workflow} do
      assert {:error, %Error{class: :validation}} =
               WorkflowVersion.create(workflow, %{
                 source_definition: %{"schema_version" => 1, "trigger" => "nonsense"}
               })
    end

    test "answers not_found for a workflow outside its own tenant", %{workflow: workflow} do
      other = InstallationsFixtures.install()
      foreign = %Workflow{} = %{workflow | installation_id: other.installation.id}

      assert {:error, %Error{class: :not_found, code: :workflow_not_found}} =
               WorkflowVersion.create(foreign)
    end

    test "stores the compiler columns when they are given", %{workflow: workflow} do
      assert {:ok, version} =
               WorkflowVersion.create(workflow, %{
                 compiled_definition: %{"entry" => "n1"},
                 compiler_version: "1.0.0",
                 required_scopes: ["channels:write"],
                 referenced_secret_ids: [Ecto.UUID.generate()],
                 referenced_connection_ids: []
               })

      assert version.compiled_definition == %{"entry" => "n1"}
      assert version.compiler_version == "1.0.0"
      assert version.required_scopes == ["channels:write"]
      assert length(version.referenced_secret_ids) == 1
    end
  end

  describe "the cross-tenant foreign key" do
    test "refuses a version whose tenant is not its workflow's tenant", %{workflow: workflow} do
      other = InstallationsFixtures.install()

      assert_raise Postgrex.Error, ~r/foreign key/, fn ->
        Repo.query!(
          """
          INSERT INTO workflow_versions
            (id, installation_id, workflow_id, version_number, source_definition,
             definition_hash, required_scopes, referenced_secret_ids,
             referenced_connection_ids, inserted_at)
          VALUES ($1, $2, $3, 1, '{}'::jsonb, $4, '{}', '{}', '{}', now())
          """,
          [
            Ecto.UUID.dump!(Ecto.UUID.generate()),
            Ecto.UUID.dump!(other.installation.id),
            Ecto.UUID.dump!(workflow.id),
            WorkflowVersion.definition_hash(%{})
          ]
        )
      end
    end

    test "accepts a previous-release insert that omits expansion columns", %{
      workflow: workflow,
      installation_id: installation_id
    } do
      version_id = Ecto.UUID.generate()

      assert %{num_rows: 1} =
               Repo.query!(
                 """
                 INSERT INTO workflow_versions
                   (id, installation_id, workflow_id, version_number, source_definition,
                    definition_hash, required_scopes, referenced_secret_ids,
                    referenced_connection_ids, inserted_at)
                 VALUES ($1, $2, $3, 99, '{}'::jsonb, $4, '{}', '{}', '{}', now())
                 """,
                 [
                   Ecto.UUID.dump!(version_id),
                   Ecto.UUID.dump!(installation_id),
                   Ecto.UUID.dump!(workflow.id),
                   WorkflowVersion.definition_hash(%{})
                 ]
               )

      stored = Repo.get!(WorkflowVersion, version_id)
      assert is_nil(stored.source_hash)
      assert is_nil(stored.identity_hash)
      assert WorkflowVersion.legacy_intact?(stored)
      refute WorkflowVersion.intact?(stored)
    end
  end

  describe "workflows.active_version_id" do
    test "refuses deleting the version a workflow is running", %{workflow: workflow} do
      {:ok, version} = WorkflowVersion.create(workflow)

      Repo.update_all(
        from(w in Workflow, where: w.id == ^workflow.id),
        set: [active_version_id: version.id]
      )

      assert_raise Ecto.ConstraintError, ~r/workflows_active_version_id_fkey/, fn ->
        Repo.delete!(version)
      end
    end

    test "still lets the whole workflow go", %{workflow: workflow} do
      {:ok, version} = WorkflowVersion.create(workflow)

      Repo.update_all(
        from(w in Workflow, where: w.id == ^workflow.id),
        set: [active_version_id: version.id]
      )

      assert {1, _} = Repo.delete_all(from(w in Workflow, where: w.id == ^workflow.id))
      refute Repo.get(WorkflowVersion, version.id)
    end
  end

  defp index_definitions(table) do
    %{rows: rows} =
      Repo.query!("SELECT indexdef FROM pg_indexes WHERE tablename = $1", [table])

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

  defp shuffle_keys(term) when is_map(term) and not is_struct(term) do
    term
    |> Enum.shuffle()
    |> Map.new(fn {key, value} -> {key, shuffle_keys(value)} end)
  end

  defp shuffle_keys(term) when is_list(term), do: Enum.map(term, &shuffle_keys/1)
  defp shuffle_keys(term), do: term
end

defmodule PumbleAutomation.Workflows.WorkflowVersionConcurrencyTest do
  @moduledoc """
  The version-number race, run against a real database rather than the sandbox.

  This one test cannot use `PumbleAutomation.DataCase`. The sandbox never
  commits, so a task holding its own connection would not see the workflow row
  this test creates, and the `FOR UPDATE` the allocator takes would wait for a
  commit that never comes. Sharing one connection instead would serialize the
  whole transaction inside `DBConnection` and the test would pass without
  exercising the lock at all.

  So the repository is put in `:auto` mode for the duration and the fixture
  rows are really committed. Cleanup is registered with `on_exit/1` rather than
  written as an `after` clause, because a test that fails half way through must
  still leave the database as it found it: committed rows outlive the test that
  wrote them and would break every later test that counts installations.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import PumbleAutomation.WorkflowsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Workflows.WorkflowVersion

  @writers 8

  setup do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  test "concurrent writers allocate consecutive version numbers, never a duplicate" do
    %{installation: installation} = InstallationsFixtures.install()
    on_exit(fn -> InstallationsFixtures.erase!(installation.id) end)

    workflow = drafted_workflow(installation.id)

    results =
      1..@writers
      |> Task.async_stream(
        fn index ->
          WorkflowVersion.create(workflow, %{
            source_definition: definition(Enum.map(1..index, fn _ -> message_node() end))
          })
        end,
        max_concurrency: @writers,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    numbers =
      results
      |> Enum.map(fn {:ok, version} -> version.version_number end)
      |> Enum.sort()

    assert numbers == Enum.to_list(1..@writers)

    stored =
      Repo.all(
        from v in WorkflowVersion,
          where: v.workflow_id == ^workflow.id,
          select: v.version_number
      )

    assert Enum.sort(stored) == Enum.to_list(1..@writers)
  end
end
