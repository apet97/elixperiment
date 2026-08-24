defmodule PumbleAutomation.Workflows.Node do
  @moduledoc """
  One step in an editable workflow definition.

  A node is a stable identifier, a type from a closed set, a typed
  configuration for that type, and — for the two types that branch — ordered
  branch sequences of further nodes. That is the whole shape. There is no free
  edge list and no cross-node reference, so the editable representation cannot
  express a cycle: nesting is the only way one node reaches another, and
  nesting is a tree.

  ## Types and branches

  The six node types of Section 15.1 of the plan are `condition`, `delay`,
  `approval`, `pumble_action`, `http_action`, and `stop`. Two of them own
  branches, and the branch keys are fixed by the plan:

    * `condition` owns `if_true` and `if_false`;
    * `approval` owns `approved`, `rejected`, and `timed_out`.

  Every branch is an ordered list, and a node of any other type has no
  branches at all.

  ## Identifiers

  A node identifier is a UUID generated once, when the node is created, and
  never rewritten. The editor's operations move nodes without touching them,
  so a compiled version, an execution record, and a screen can all name the
  same step across an edit. `decode/2` rejects a definition in which an
  identifier is absent, malformed, or repeated.

  ## Atoms

  Node types, branch keys, and every configuration enumeration are read
  through literal maps written out in source. No function in this module or in
  `PumbleAutomation.Workflows.Node.Config` turns a string from user input into
  an atom, so a hostile document cannot grow the atom table.
  """

  alias PumbleAutomation.Workflows.Limits
  alias PumbleAutomation.Workflows.Node.ApprovalConfig
  alias PumbleAutomation.Workflows.Node.ConditionConfig
  alias PumbleAutomation.Workflows.Node.Config
  alias PumbleAutomation.Workflows.Node.DelayConfig
  alias PumbleAutomation.Workflows.Node.HttpActionConfig
  alias PumbleAutomation.Workflows.Node.PumbleActionConfig
  alias PumbleAutomation.Workflows.Node.StopConfig

  # A hard stop on decode recursion, far above the branch depth limit. It
  # guards the stack while a document is still untrusted; the depth limit that
  # a workflow must respect is checked once the structure exists.
  @max_decode_depth Limits.max_json_depth()

  @types %{
    "condition" => :condition,
    "delay" => :delay,
    "approval" => :approval,
    "pumble_action" => :pumble_action,
    "http_action" => :http_action,
    "stop" => :stop
  }

  @config_modules %{
    condition: ConditionConfig,
    delay: DelayConfig,
    approval: ApprovalConfig,
    pumble_action: PumbleActionConfig,
    http_action: HttpActionConfig,
    stop: StopConfig
  }

  @branch_keys %{
    condition: [:if_true, :if_false],
    approval: [:approved, :rejected, :timed_out],
    delay: [],
    pumble_action: [],
    http_action: [],
    stop: []
  }

  @branch_names %{
    "if_true" => :if_true,
    "if_false" => :if_false,
    "approved" => :approved,
    "rejected" => :rejected,
    "timed_out" => :timed_out
  }

  @type type :: :condition | :delay | :approval | :pumble_action | :http_action | :stop
  @type branch_key :: :if_true | :if_false | :approved | :rejected | :timed_out

  @type config ::
          ConditionConfig.t()
          | DelayConfig.t()
          | ApprovalConfig.t()
          | PumbleActionConfig.t()
          | HttpActionConfig.t()
          | StopConfig.t()

  @type t :: %__MODULE__{
          id: String.t(),
          type: type(),
          config: config(),
          branches: %{branch_key() => [t()]}
        }

  @enforce_keys [:id, :type, :config]
  defstruct [:id, :type, :config, branches: %{}]

  @doc """
  Builds a node of `type` with `attrs` as its configuration.

  The identifier is generated here, which is what makes insertion the only
  place an identifier is chosen. Pass `:id` in `opts` only to reproduce a
  known node, such as in a test.

  Attributes are given with atom keys and already-typed values: this function
  is the internal constructor, and `decode/2` is the door untrusted documents
  come through.
  """
  @spec new(type(), map() | keyword(), keyword()) :: t()
  def new(type, attrs \\ %{}, opts \\ []) when is_map_key(@config_modules, type) do
    %__MODULE__{
      id: Keyword.get_lazy(opts, :id, &Ecto.UUID.generate/0),
      type: type,
      config: struct!(Map.fetch!(@config_modules, type), attrs),
      branches: Map.new(branch_keys(type), &{&1, []})
    }
  end

  @doc "The node types a definition may contain, as a literal wire-to-atom map."
  @spec types() :: %{String.t() => type()}
  def types, do: @types

  @doc "The configuration module a node of `type` carries, or `nil` for an unknown type."
  @spec config_module(term()) :: module() | nil
  def config_module(type), do: Map.get(@config_modules, type)

  @doc "The ordered branch keys a node of `type` owns."
  @spec branch_keys(type()) :: [branch_key()]
  def branch_keys(type), do: Map.get(@branch_keys, type, [])

  @doc "The branch sequence stored under `key`, or `nil` when the node has no such branch."
  @spec branch(t(), branch_key()) :: [t()] | nil
  def branch(%__MODULE__{} = node, key) do
    if key in branch_keys(node.type), do: Map.get(node.branches, key, []), else: nil
  end

  @doc "Replaces the branch sequence stored under `key`."
  @spec put_branch(t(), branch_key(), [t()]) :: t()
  def put_branch(%__MODULE__{} = node, key, steps) when is_list(steps) do
    %{node | branches: Map.put(node.branches, key, steps)}
  end

  @doc "Whether the node owns at least one branch that is not empty."
  @spec owns_branches?(t()) :: boolean()
  def owns_branches?(%__MODULE__{} = node) do
    Enum.any?(branch_keys(node.type), fn key -> Map.get(node.branches, key, []) != [] end)
  end

  @doc "The node and every node nested under it, in document order."
  @spec flatten(t()) :: [t()]
  def flatten(%__MODULE__{} = node) do
    [
      node
      | Enum.flat_map(
          branch_keys(node.type),
          &Enum.flat_map(Map.get(node.branches, &1, []), fn child -> flatten(child) end)
        )
    ]
  end

  @doc """
  Decodes one raw node at `path` into a `t:t/0`.

  Returns every issue found rather than the first, and never partially builds
  a node: a node either decodes whole or contributes issues.
  """
  @spec decode(term(), String.t(), non_neg_integer()) :: {:ok, t()} | {:error, [Config.issue()]}
  def decode(raw, path, depth \\ 0)

  def decode(_raw, path, depth) when depth > @max_decode_depth do
    {:error, [Config.issue(path, :too_deep, "is nested too deeply")]}
  end

  def decode(raw, path, depth) when is_map(raw) and not is_struct(raw) do
    with {:ok, type} <- decode_type(raw, path),
         :ok <- Config.ensure_known_keys(raw, node_fields(type), path),
         {:ok, id} <- decode_id(raw, path),
         {:ok, config} <-
           Config.decode(
             Map.fetch!(@config_modules, type),
             Map.get(raw, "config", %{}),
             Config.join(path, "config")
           ),
         {:ok, branches} <- decode_branches(type, raw, path, depth) do
      {:ok, %__MODULE__{id: id, type: type, config: config, branches: branches}}
    end
  end

  def decode(_raw, path, _depth) do
    {:error, [Config.issue(path, :invalid_type, "must be an object")]}
  end

  @doc "Encodes a node into a plain, string-keyed map."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = node) do
    base = %{
      "id" => node.id,
      "type" => wire_type(node.type),
      "config" => Config.encode(node.config)
    }

    Enum.reduce(branch_keys(node.type), base, fn key, acc ->
      Map.put(acc, Atom.to_string(key), Enum.map(Map.get(node.branches, key, []), &encode/1))
    end)
  end

  defp wire_type(type) do
    @types |> Enum.find(fn {_string, atom} -> atom == type end) |> elem(0)
  end

  defp node_fields(type) do
    ["id", "type", "config" | Enum.map(branch_keys(type), &Atom.to_string/1)]
  end

  defp decode_type(raw, path) do
    case Map.get(raw, "type") do
      value when is_binary(value) ->
        case Map.fetch(@types, value) do
          {:ok, type} ->
            {:ok, type}

          :error ->
            {:error,
             [
               Config.issue(
                 Config.join(path, "type"),
                 :unknown_node_type,
                 "is not a supported step type"
               )
             ]}
        end

      _other ->
        {:error, [Config.issue(Config.join(path, "type"), :missing, "is required")]}
    end
  end

  defp decode_id(raw, path) do
    id_path = Config.join(path, "id")

    with value when is_binary(value) <- Map.get(raw, "id"),
         true <- byte_size(value) <= Limits.max_string_length(),
         {:ok, id} <- Ecto.UUID.cast(value) do
      {:ok, id}
    else
      _other -> {:error, [Config.issue(id_path, :invalid_node_id, "must be a UUID")]}
    end
  end

  defp decode_branches(type, raw, path, depth) do
    {branches, issues} =
      Enum.reduce(branch_keys(type), {%{}, []}, fn key, {branches, issues} ->
        case decode_branch(raw, key, path, depth) do
          {:ok, steps} -> {Map.put(branches, key, steps), issues}
          {:error, new_issues} -> {branches, issues ++ new_issues}
        end
      end)

    case issues do
      [] -> {:ok, branches}
      _ -> {:error, issues}
    end
  end

  defp decode_branch(raw, key, path, depth) do
    name = Atom.to_string(key)
    branch_path = Config.join(path, name)

    case Map.get(raw, name, []) do
      steps when is_list(steps) -> decode_sequence(steps, branch_path, depth + 1)
      _other -> {:error, [Config.issue(branch_path, :invalid_type, "must be a list of steps")]}
    end
  end

  @doc """
  Decodes an ordered sequence of raw nodes at `path`.

  Used for the root `steps` list and for every branch, so both are bounded and
  reported the same way.
  """
  @spec decode_sequence(term(), String.t(), non_neg_integer()) ::
          {:ok, [t()]} | {:error, [Config.issue()]}
  def decode_sequence(raw, path, depth \\ 0)

  def decode_sequence(raw, path, depth) when is_list(raw) do
    if length(raw) > Limits.max_nodes() do
      {:error, [Config.issue(path, :too_many_items, "has too many steps")]}
    else
      collect(raw, path, depth)
    end
  end

  def decode_sequence(_raw, path, _depth) do
    {:error, [Config.issue(path, :invalid_type, "must be a list of steps")]}
  end

  defp collect(raw, path, depth) do
    {nodes, issues} =
      raw
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {element, index}, acc ->
        collect_one(acc, element, Config.join(path, index), depth)
      end)

    case issues do
      [] -> {:ok, Enum.reverse(nodes)}
      _ -> {:error, issues}
    end
  end

  defp collect_one({nodes, issues}, element, path, depth) do
    case decode(element, path, depth) do
      {:ok, node} -> {[node | nodes], issues}
      {:error, new_issues} -> {nodes, issues ++ new_issues}
    end
  end

  @doc "The branch names a document may use, as a literal wire-to-atom map."
  @spec branch_names() :: %{String.t() => branch_key()}
  def branch_names, do: @branch_names
end
