defmodule PumbleAutomation.Workflows.CompiledWorkflowTest do
  @moduledoc """
  The read side of a stored compiled workflow.

  A document is read back long after it was written, by a release that may not
  be the one that wrote it. Every test here is about refusing a document rather
  than half-loading one, because a graph that is nearly understood is a graph
  that runs somebody's workflow the wrong way.
  """

  use ExUnit.Case, async: true

  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Error
  alias PumbleAutomation.Workflows.CompiledWorkflow
  alias PumbleAutomation.Workflows.Compiler

  setup do
    {:ok, compiled} = Compiler.compile(definition([condition_node(if_true: [message_node()])]))

    %{compiled: compiled, document: CompiledWorkflow.encode(compiled)}
  end

  describe "reading a stored document" do
    test "a document this compiler wrote is understood", %{document: document} do
      assert {:ok, decoded} = CompiledWorkflow.decode(document)
      assert decoded.compiler_version == CompiledWorkflow.compiler_version()
      assert Enum.all?(Map.values(decoded.nodes), &is_atom(&1.type))
    end

    test "a document from a compiler this release does not have is refused", %{
      document: document
    } do
      document = Map.put(document, "compiler_version", "0")

      assert {:error, %Error{} = error} = CompiledWorkflow.decode(document)
      assert error.class == :conflict
      assert error.code == :unsupported_compiler_version
    end

    test "a document of an unknown shape is refused", %{document: document} do
      document = Map.put(document, "schema_version", 99)

      assert {:error, %Error{code: :unsupported_schema_version}} =
               CompiledWorkflow.decode(document)
    end

    test "a document whose entry names no step is refused", %{document: document} do
      document = Map.put(document, "entry_node_id", Ecto.UUID.generate())

      assert {:error, %Error{code: :invalid_compiled_workflow}} =
               CompiledWorkflow.decode(document)
    end

    test "a document naming a step type that does not exist is refused", %{document: document} do
      {id, node} = document |> Map.fetch!("nodes") |> Enum.at(0)
      nodes = Map.put(document["nodes"], id, Map.put(node, "type", "mine_bitcoin"))

      assert {:error, %Error{code: :invalid_compiled_workflow}} =
               CompiledWorkflow.decode(Map.put(document, "nodes", nodes))
    end

    test "a document with no steps is refused", %{document: document} do
      assert {:error, %Error{code: :invalid_compiled_workflow}} =
               CompiledWorkflow.decode(Map.put(document, "nodes", %{}))
    end

    test "a step missing its edges is refused", %{document: document} do
      {id, node} = document |> Map.fetch!("nodes") |> Enum.at(0)
      nodes = Map.put(document["nodes"], id, Map.delete(node, "edges"))

      assert {:error, %Error{code: :invalid_compiled_workflow}} =
               CompiledWorkflow.decode(Map.put(document, "nodes", nodes))
    end

    test "an edge that names no step is refused", %{document: document} do
      {id, node} =
        Enum.find(document["nodes"], fn {_id, node} -> node["type"] == "pumble_action" end)

      nodes =
        Map.put(document["nodes"], id, put_in(node, ["edges", "next"], Ecto.UUID.generate()))

      assert {:error, %Error{code: :invalid_compiled_workflow}} =
               CompiledWorkflow.decode(Map.put(document, "nodes", nodes))
    end

    test "a declaration that is not a list of names is refused", %{document: document} do
      {id, node} = document |> Map.fetch!("nodes") |> Enum.at(0)
      requires = Map.put(node["requires"], "operations", 7)
      nodes = Map.put(document["nodes"], id, Map.put(node, "requires", requires))

      assert {:error, %Error{code: :invalid_compiled_workflow}} =
               CompiledWorkflow.decode(Map.put(document, "nodes", nodes))
    end

    test "a step nothing can reach is refused", %{document: document} do
      extra = Ecto.UUID.generate()

      nodes =
        Map.put(document["nodes"], extra, %{
          "type" => "delay",
          "config" => %{"duration_seconds" => 1},
          "edges" => %{"next" => "end"},
          "requires" => %{
            "operations" => [],
            "scopes" => [],
            "connection_ids" => [],
            "secret_names" => []
          }
        })

      assert {:error, %Error{code: :invalid_compiled_workflow}} =
               CompiledWorkflow.decode(Map.put(document, "nodes", nodes))
    end

    test "a two-step cycle is refused" do
      {:ok, compiled} = Compiler.compile(definition([delay_node(), delay_node()]))
      document = CompiledWorkflow.encode(compiled)
      [first, second] = compiled.node_order
      document = put_in(document, ["nodes", second, "edges", "next"], first)

      assert {:error, %Error{code: :invalid_compiled_workflow} = error} =
               CompiledWorkflow.decode(document)

      assert error.message =~ "cycle"
    end

    test "a self-loop is refused" do
      {:ok, compiled} = Compiler.compile(definition([delay_node()]))
      document = CompiledWorkflow.encode(compiled)
      id = compiled.entry_node_id
      document = put_in(document, ["nodes", id, "edges", "next"], id)

      assert {:error, %Error{code: :invalid_compiled_workflow} = error} =
               CompiledWorkflow.decode(document)

      assert error.message =~ "cycle"
    end

    test "something that is not a document at all is refused" do
      assert {:error, %Error{code: :invalid_compiled_workflow}} = CompiledWorkflow.decode("{}")
    end

    test "no refusal repeats what the document held", %{document: document} do
      marker = "sentinel-#{System.unique_integer([:positive])}"

      assert {:error, %Error{} = error} =
               CompiledWorkflow.decode(Map.put(document, "compiler_version", marker))

      refute String.contains?(error.message, marker)
    end
  end
end
