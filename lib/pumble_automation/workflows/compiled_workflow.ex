defmodule PumbleAutomation.Workflows.CompiledWorkflow do
  @moduledoc """
  The immutable executable form of a workflow.

  A definition is a tree, because that is what an author edits. This is the
  same workflow as a flat map of steps joined by named edges, because that is
  what a worker runs. Choosing what happens after a step becomes reading one
  edge by name, with no branch to descend and no parent to remember.

  ## Edges

  Every step names, for each way it can finish, the step that runs next. A
  step that ends the run names `end/0` instead. A linear step has one outcome,
  `"next"`; a condition has `"true"` and `"false"`; an approval has
  `"approved"`, `"rejected"`, and `"timed_out"`. Nothing else is an outcome,
  and no outcome is ever absent, so a worker that cannot find its edge has met
  a defect rather than the end of the workflow.

  Where a branch finishes, its last step points at whatever follows the step
  that owns the branch. Two branches of one condition therefore lead to the
  same place, which is convergence, not a join: no step waits for a second
  path to arrive, and no step is entered twice in one run. The graph stays
  acyclic and every step is reachable from the entry.

  ## What a configuration holds

  A configuration here is plain data, already checked. Text that interpolates
  nothing stays text. Text that interpolates is a `%{"template" => segments}`
  map whose segments are the literals and parsed paths of
  `PumbleAutomation.Workflows.Templates`, so nothing parses a template while a
  workflow is running.

  No secret value appears. A secret is a name in a path, and it is resolved
  against the tenant's rows at the moment of the request.

  ## Versions

  `schema_version/0` describes the document and `compiler_version/0` describes
  the program that wrote it. A stored document from a compiler this release
  does not have is refused by `decode/1`, because running a graph on
  assumptions that have since changed is worse than not running it.
  """

  alias PumbleAutomation.Error
  alias PumbleAutomation.Workflows.Node

  @schema_version 1
  @compiler_version "1"
  @end_target "end"

  @typedoc """
  One step: what it does, how it was configured, what it needs, and where each
  outcome leads.

  `requires` is the step's own declaration rather than something a reader works
  out from the configuration: which Pumble operations it performs, which scopes
  those are known to need, and which connections and secrets it uses.
  """
  @type compiled_node :: %{
          type: Node.type(),
          config: %{String.t() => term()},
          edges: %{String.t() => String.t()},
          requires: %{String.t() => [String.t()]}
        }

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          compiler_version: String.t(),
          entry_node_id: String.t(),
          nodes: %{String.t() => compiled_node()},
          node_order: [String.t()],
          max_path_length: non_neg_integer(),
          required_scopes: [String.t()],
          trigger_binding: %{String.t() => term()},
          definition_hash: String.t()
        }

  @enforce_keys [:entry_node_id, :nodes, :node_order, :definition_hash]
  defstruct schema_version: @schema_version,
            compiler_version: @compiler_version,
            entry_node_id: nil,
            nodes: %{},
            node_order: [],
            max_path_length: 0,
            required_scopes: [],
            trigger_binding: %{},
            definition_hash: nil

  @doc "The version of the compiled document shape."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "The version of the compiler that writes this shape."
  @spec compiler_version() :: String.t()
  def compiler_version, do: @compiler_version

  @doc "The edge target that means the run finishes."
  @spec end_target() :: String.t()
  def end_target, do: @end_target

  @doc """
  Encodes into the plain, string-keyed executable document.

  Keys are strings and values are JSON types, so the result is what is stored
  and what is hashed.
  """
  @spec encode(t()) :: %{String.t() => term()}
  def encode(%__MODULE__{} = compiled) do
    %{
      "schema_version" => compiled.schema_version,
      "compiler_version" => compiled.compiler_version,
      "entry_node_id" => compiled.entry_node_id,
      "nodes" => Map.new(compiled.nodes, fn {id, node} -> {id, encode_node(node)} end),
      "node_order" => compiled.node_order,
      "max_path_length" => compiled.max_path_length,
      "required_scopes" => compiled.required_scopes,
      "trigger_binding" => compiled.trigger_binding,
      "definition_hash" => compiled.definition_hash
    }
  end

  @doc """
  Reads a stored document back.

  This is the read side and it trusts nothing: a document from an unknown
  compiler, a document of an unknown shape, or a document whose entry names no
  step is refused rather than half-loaded.
  """
  @spec decode(term()) :: {:ok, t()} | {:error, Error.t()}
  def decode(%{} = document) do
    with :ok <-
           check_version(document, "schema_version", @schema_version, :unsupported_schema_version),
         :ok <-
           check_version(
             document,
             "compiler_version",
             @compiler_version,
             :unsupported_compiler_version
           ),
         {:ok, nodes} <- decode_nodes(Map.get(document, "nodes")),
         {:ok, entry} <- decode_entry(Map.get(document, "entry_node_id"), nodes),
         :ok <- check_graph(nodes, entry) do
      {:ok,
       %__MODULE__{
         entry_node_id: entry,
         nodes: nodes,
         node_order: list(Map.get(document, "node_order")),
         max_path_length: Map.get(document, "max_path_length", 0),
         required_scopes: list(Map.get(document, "required_scopes")),
         trigger_binding: Map.get(document, "trigger_binding") || %{},
         definition_hash: Map.get(document, "definition_hash")
       }}
    end
  end

  def decode(_document), do: {:error, invalid("must be an object")}

  defp encode_node(node) do
    %{
      "type" => Atom.to_string(node.type),
      "config" => node.config,
      "edges" => node.edges,
      "requires" => node.requires
    }
  end

  # Both versions are operational gates: a graph written by a shape or a
  # program this release does not have may mean something other than it
  # appears to, and guessing which is worse than refusing to run it.
  defp check_version(document, key, expected, code) do
    case Map.get(document, key) do
      ^expected ->
        :ok

      other ->
        {:error,
         Error.new(:conflict, code,
           message: "This workflow was compiled by a version that is no longer supported.",
           details: %{key => other, "expected" => expected}
         )}
    end
  end

  defp decode_nodes(nodes) when is_map(nodes) and map_size(nodes) > 0 do
    Enum.reduce_while(nodes, {:ok, %{}}, fn {id, raw}, {:ok, acc} ->
      case decode_node(raw) do
        {:ok, node} -> {:cont, {:ok, Map.put(acc, id, node)}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp decode_nodes(_nodes), do: {:error, invalid("must name at least one step")}

  defp decode_node(%{
         "type" => type,
         "config" => config,
         "edges" => edges,
         "requires" => requires
       })
       when is_map(config) and is_map(edges) and is_map(requires) do
    with {:ok, known} <- known_type(type),
         :ok <- check_edges(known, edges),
         :ok <- check_requires(requires) do
      {:ok, %{type: known, config: config, edges: edges, requires: requires}}
    end
  end

  defp decode_node(_raw) do
    {:error, invalid("must name a type, a configuration, its edges, and what it needs")}
  end

  defp known_type(type) do
    case Map.fetch(Node.types(), type) do
      {:ok, known} -> {:ok, known}
      :error -> {:error, invalid("names a step type that does not exist")}
    end
  end

  # Every outcome a worker can take must be present, named, and point at a
  # string. Whether that string names a real step is checked once every step
  # has been read, because a target may be a sibling that has not been decoded
  # yet.
  defp check_edges(type, edges) do
    expected = expected_outcomes(type)
    names = edges |> Map.keys() |> Enum.sort()
    values = Map.values(edges)

    cond do
      names != expected ->
        {:error, invalid("must name every outcome of its step type")}

      not Enum.all?(values, &is_binary/1) ->
        {:error, invalid("must send every outcome to a step")}

      true ->
        :ok
    end
  end

  defp expected_outcomes(:condition), do: ["false", "true"]
  defp expected_outcomes(:approval), do: ["approved", "rejected", "timed_out"]
  defp expected_outcomes(_type), do: ["next"]

  defp check_requires(requires) do
    expected = ["connection_ids", "operations", "scopes", "secret_names"]

    if Enum.sort(Map.keys(requires)) == expected and
         Enum.all?(expected, &string_list?(Map.get(requires, &1))) do
      :ok
    else
      {:error, invalid("must declare what each step needs as lists of names")}
    end
  end

  defp string_list?(values) when is_list(values), do: Enum.all?(values, &is_binary/1)
  defp string_list?(_values), do: false

  defp decode_entry(entry, nodes) when is_binary(entry) do
    if Map.has_key?(nodes, entry) do
      {:ok, entry}
    else
      {:error, invalid("names an entry step that is not in the graph")}
    end
  end

  defp decode_entry(_entry, _nodes), do: {:error, invalid("must name an entry step")}

  # A stored graph is what a worker runs, so a dangling edge or an unreachable
  # step is a defect, not a document we can half-load.
  defp check_graph(nodes, entry) do
    targets = nodes |> Enum.flat_map(fn {_id, node} -> Map.values(node.edges) end) |> Enum.uniq()
    missing = Enum.reject(targets, &(&1 == @end_target or Map.has_key?(nodes, &1)))
    reached = reachable(nodes, entry)

    cond do
      missing != [] ->
        {:error, invalid("names a next step that is not in the graph")}

      MapSet.size(reached) != map_size(nodes) ->
        {:error, invalid("contains a step nothing can reach")}

      cycling?(nodes, entry, %{}) ->
        {:error, invalid("contains a cycle")}

      true ->
        :ok
    end
  end

  defp cycling?(_nodes, @end_target, _path), do: false
  defp cycling?(_nodes, id, path) when is_map_key(path, id), do: true

  defp cycling?(nodes, id, path) do
    case Map.fetch(nodes, id) do
      {:ok, node} ->
        Enum.any?(Map.values(node.edges), &cycling?(nodes, &1, Map.put(path, id, true)))

      :error ->
        false
    end
  end

  defp reachable(nodes, entry), do: nodes |> follow([entry], %{}) |> Map.keys() |> MapSet.new()

  defp follow(_nodes, [], seen), do: seen

  defp follow(nodes, [id | rest], seen) do
    cond do
      id == @end_target ->
        follow(nodes, rest, seen)

      Map.has_key?(seen, id) ->
        follow(nodes, rest, seen)

      true ->
        case Map.fetch(nodes, id) do
          {:ok, node} ->
            follow(nodes, Map.values(node.edges) ++ rest, Map.put(seen, id, true))

          :error ->
            follow(nodes, rest, seen)
        end
    end
  end

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []

  defp invalid(message) do
    Error.new(:validation, :invalid_compiled_workflow,
      message: "This compiled workflow #{message}."
    )
  end
end
