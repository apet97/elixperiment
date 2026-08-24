defmodule PumbleAutomation.Workflows.Editor do
  @moduledoc """
  Every structural edit a workflow author can make, as pure functions.

  A user interface holds a `PumbleAutomation.Workflows.Definition`, calls one
  function here, and gets back either a new definition or a typed error. It
  never reaches into the structure itself. Centralising the edits is what makes
  the structural promises testable: identifier stability, ordering, and the
  limits are properties of these functions, not of a template.

  ## Addresses

  A node is addressed by its identifier, wherever it is nested. A *sequence* is
  addressed either as `:root`, meaning the top-level `steps` list, or as
  `{node_id, branch_key}`, meaning one branch of one node. Those two forms
  cover the whole document, because a branch is the only other place a step can
  live.

  ## Guarantees

    * **Determinism.** The same definition and the same operation give the same
      result, byte for byte, every time.
    * **Stability.** An identifier is never rewritten. Nodes that the operation
      does not name keep their identifiers and their order.
    * **No partial mutation.** Each operation builds a candidate and validates
      it whole. On failure the caller gets an error and the definition it
      already had; there is no half-applied state to discard, because nothing
      is applied in place.
    * **Limits.** `Definition.validate_limits/1` runs on the result of every
      operation. One operation cannot step over a limit, and a sequence of
      operations cannot walk over one.

  ## Deletion

  Deleting a node deletes the subtree under it. `delete/2` returns metadata
  saying how many nodes went and whether the node owned a branch that was not
  empty, so a caller can ask for confirmation with the true cost in front of
  it. `deletion_metadata/2` answers the same question without changing
  anything, for a confirmation dialog shown before the decision.
  """

  alias PumbleAutomation.Error
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Definition.Trigger
  alias PumbleAutomation.Workflows.Node

  @type address :: :root | {String.t(), Node.branch_key()}
  @type deletion :: %{
          deleted_node_ids: [String.t()],
          deleted_count: non_neg_integer(),
          owned_branches?: boolean()
        }

  @doc """
  Inserts `node` immediately before the node identified by `target_id`.
  """
  @spec add_before(Definition.t(), String.t(), Node.t()) ::
          {:ok, Definition.t()} | {:error, Error.t()}
  def add_before(definition, target_id, node), do: insert_relative(definition, target_id, node, 0)

  @doc """
  Inserts `node` immediately after the node identified by `target_id`.
  """
  @spec add_after(Definition.t(), String.t(), Node.t()) ::
          {:ok, Definition.t()} | {:error, Error.t()}
  def add_after(definition, target_id, node), do: insert_relative(definition, target_id, node, 1)

  @doc """
  Appends `node` to the end of the sequence at `address`.
  """
  @spec append(Definition.t(), address(), Node.t()) :: {:ok, Definition.t()} | {:error, Error.t()}
  def append(%Definition{} = definition, address, %Node{} = node) do
    with {:ok, steps} <- sequence_at(definition, address) do
      definition
      |> put_sequence(address, steps ++ [node])
      |> finish()
    end
  end

  @doc """
  Inserts `node` into the sequence at `address` at `index`.

  `index` counts from zero and may equal the length of the sequence, which
  appends.
  """
  @spec insert_at(Definition.t(), address(), non_neg_integer(), Node.t()) ::
          {:ok, Definition.t()} | {:error, Error.t()}
  def insert_at(%Definition{} = definition, address, index, %Node{} = node)
      when is_integer(index) do
    with {:ok, steps} <- sequence_at(definition, address),
         :ok <- check_index(index, length(steps)) do
      definition
      |> put_sequence(address, List.insert_at(steps, index, node))
      |> finish()
    end
  end

  @doc """
  Replaces the configuration of one node.

  `attrs` is a map with atom keys, merged into the configuration the node
  already has, so a caller can change one field without restating the rest.
  The node type cannot be changed this way: a different type is a different
  node, with a different identifier.
  """
  @spec update_config(Definition.t(), String.t(), map() | struct()) ::
          {:ok, Definition.t()} | {:error, Error.t()}
  def update_config(%Definition{} = definition, node_id, attrs) do
    with {:ok, node} <- fetch_node(definition, node_id),
         {:ok, config} <- merged_config(node, attrs) do
      definition |> replace_config(node_id, config) |> finish()
    end
  end

  defp replace_config(definition, node_id, config) do
    map_nodes(definition, fn candidate ->
      if candidate.id == node_id, do: %{candidate | config: config}, else: candidate
    end)
  end

  @doc """
  Replaces the trigger configuration.

  `attrs` is a map with atom keys, merged into the configuration the trigger
  already has, or a configuration struct of the matching type. The trigger
  type cannot be changed this way: a different type is a different trigger.
  """
  @spec update_trigger_config(Definition.t(), map() | struct()) ::
          {:ok, Definition.t()} | {:error, Error.t()}
  def update_trigger_config(%Definition{} = definition, attrs) do
    with {:ok, config} <- merged_trigger_config(definition.trigger, attrs) do
      trigger = %{definition.trigger | config: config}
      %{definition | trigger: trigger} |> finish()
    end
  end

  @doc """
  Replaces the trigger, keeping the rest of the definition.

  A draft may reuse the existing trigger identifier so the entry point stays
  stable across a type change. Bindings are not rewritten here; they are
  projections of an activated version.
  """
  @spec replace_trigger(Definition.t(), Trigger.t()) ::
          {:ok, Definition.t()} | {:error, Error.t()}
  def replace_trigger(%Definition{} = definition, %Trigger{} = trigger) do
    %{definition | trigger: trigger} |> finish()
  end

  @doc """
  Moves the node at `from` in the sequence at `address` to `to`.

  Both positions count from zero, and both must already exist: reordering
  never changes how many steps a sequence has.
  """
  @spec reorder(Definition.t(), address(), non_neg_integer(), non_neg_integer()) ::
          {:ok, Definition.t()} | {:error, Error.t()}
  def reorder(%Definition{} = definition, address, from, to)
      when is_integer(from) and is_integer(to) do
    with {:ok, steps} <- sequence_at(definition, address),
         :ok <- check_index(from, length(steps) - 1),
         :ok <- check_index(to, length(steps) - 1) do
      definition
      |> put_sequence(
        address,
        steps |> List.delete_at(from) |> List.insert_at(to, Enum.at(steps, from))
      )
      |> finish()
    end
  end

  @doc """
  Moves a node, and the subtree under it, into the sequence at `address`.

  `index` is where it lands, counting from zero, and `:last` appends. A node
  cannot be moved into its own subtree: the result would not be a tree, so the
  operation is refused rather than repaired.
  """
  @spec move(Definition.t(), String.t(), address(), non_neg_integer() | :last) ::
          {:ok, Definition.t()} | {:error, Error.t()}
  def move(%Definition{} = definition, node_id, address, index \\ :last) do
    with {:ok, node} <- fetch_node(definition, node_id),
         :ok <- check_move_target(node, address),
         detached = detach(definition, node_id),
         {:ok, steps} <- sequence_at(detached, address),
         position = position(index, steps),
         :ok <- check_index(position, length(steps)) do
      detached
      |> put_sequence(address, List.insert_at(steps, position, node))
      |> finish()
    end
  end

  defp detach(definition, node_id) do
    map_sequences(definition, fn steps -> Enum.reject(steps, &(&1.id == node_id)) end)
  end

  defp position(:last, steps), do: length(steps)
  defp position(index, _steps), do: index

  @doc """
  Deletes a node and the subtree under it.

  Returns the new definition and the metadata describing what went, so the
  caller can report it or, having asked first, record that the author
  confirmed it.
  """
  @spec delete(Definition.t(), String.t()) ::
          {:ok, Definition.t(), deletion()} | {:error, Error.t()}
  def delete(%Definition{} = definition, node_id) do
    with {:ok, metadata} <- deletion_metadata(definition, node_id) do
      result =
        definition |> detach(node_id) |> finish()

      case result do
        {:ok, updated} -> {:ok, updated, metadata}
        {:error, %Error{}} = error -> error
      end
    end
  end

  @doc """
  Describes what deleting `node_id` would remove, without removing it.
  """
  @spec deletion_metadata(Definition.t(), String.t()) :: {:ok, deletion()} | {:error, Error.t()}
  def deletion_metadata(%Definition{} = definition, node_id) do
    with {:ok, node} <- fetch_node(definition, node_id) do
      removed = Node.flatten(node)

      {:ok,
       %{
         deleted_node_ids: Enum.map(removed, & &1.id),
         deleted_count: length(removed),
         owned_branches?: Node.owns_branches?(node)
       }}
    end
  end

  @doc """
  The address of the sequence that directly contains `node_id`.
  """
  @spec address_of(Definition.t(), String.t()) :: {:ok, address()} | {:error, Error.t()}
  def address_of(%Definition{} = definition, node_id) do
    cond do
      Enum.any?(definition.steps, &(&1.id == node_id)) -> {:ok, :root}
      found = branch_address(definition.steps, node_id) -> {:ok, found}
      true -> {:error, node_not_found(node_id)}
    end
  end

  defp branch_address(steps, node_id) do
    Enum.find_value(steps, &node_branch_address(&1, node_id))
  end

  defp node_branch_address(node, node_id) do
    Enum.find_value(Node.branch_keys(node.type), &branch_key_address(node, &1, node_id))
  end

  defp branch_key_address(node, key, node_id) do
    branch = Map.get(node.branches, key, [])

    cond do
      Enum.any?(branch, &(&1.id == node_id)) -> {node.id, key}
      found = branch_address(branch, node_id) -> found
      true -> nil
    end
  end

  defp insert_relative(%Definition{} = definition, target_id, %Node{} = node, offset) do
    with {:ok, address} <- address_of(definition, target_id),
         {:ok, steps} <- sequence_at(definition, address) do
      index = Enum.find_index(steps, &(&1.id == target_id)) + offset

      definition
      |> put_sequence(address, List.insert_at(steps, index, node))
      |> finish()
    end
  end

  defp fetch_node(definition, node_id) when is_binary(node_id) do
    case Definition.fetch_node(definition, node_id) do
      {:ok, node} -> {:ok, node}
      :error -> {:error, node_not_found(node_id)}
    end
  end

  defp fetch_node(_definition, node_id), do: {:error, node_not_found(node_id)}

  defp merged_config(%Node{config: %module{}}, %module{} = replacement), do: {:ok, replacement}

  defp merged_config(%Node{}, %_other{}) do
    {:error,
     Error.new(:validation, :invalid_config,
       message: "The step configuration is not valid for this step type."
     )}
  end

  defp merged_config(%Node{config: %module{} = config}, attrs) when is_map(attrs) do
    unknown = Map.keys(attrs) -- Map.keys(Map.from_struct(config))

    if unknown == [] do
      {:ok, struct!(module, Map.merge(Map.from_struct(config), attrs))}
    else
      {:error,
       Error.new(:validation, :unknown_config_field,
         message: "The step configuration has a field that does not exist.",
         details: %{count: length(unknown)}
       )}
    end
  end

  defp merged_config(_node, _attrs) do
    {:error,
     Error.new(:validation, :invalid_config,
       message: "The step configuration is not valid for this step type."
     )}
  end

  defp merged_trigger_config(%Trigger{config: %module{}}, %module{} = replacement) do
    {:ok, replacement}
  end

  defp merged_trigger_config(%Trigger{}, %_other{}) do
    {:error,
     Error.new(:validation, :invalid_config,
       message: "The trigger configuration is not valid for this trigger type."
     )}
  end

  defp merged_trigger_config(%Trigger{config: %module{} = config}, attrs) when is_map(attrs) do
    unknown = Map.keys(attrs) -- Map.keys(Map.from_struct(config))

    if unknown == [] do
      {:ok, struct!(module, Map.merge(Map.from_struct(config), attrs))}
    else
      {:error,
       Error.new(:validation, :unknown_config_field,
         message: "The trigger configuration has a field that does not exist.",
         details: %{count: length(unknown)}
       )}
    end
  end

  defp merged_trigger_config(_trigger, _attrs) do
    {:error,
     Error.new(:validation, :invalid_config,
       message: "The trigger configuration is not valid for this trigger type."
     )}
  end

  defp sequence_at(%Definition{} = definition, :root), do: {:ok, definition.steps}

  defp sequence_at(%Definition{} = definition, {node_id, branch_key}) do
    with {:ok, node} <- fetch_node(definition, node_id) do
      case Node.branch(node, branch_key) do
        nil -> {:error, branch_not_found(node_id, branch_key)}
        steps -> {:ok, steps}
      end
    end
  end

  defp sequence_at(_definition, address) do
    {:error,
     Error.new(:validation, :invalid_address,
       message: "The step address is not valid.",
       details: %{address: inspect(address)}
     )}
  end

  defp put_sequence(%Definition{} = definition, :root, steps), do: %{definition | steps: steps}

  defp put_sequence(%Definition{} = definition, {node_id, branch_key}, steps) do
    map_nodes(definition, fn node ->
      if node.id == node_id, do: Node.put_branch(node, branch_key, steps), else: node
    end)
  end

  defp map_nodes(%Definition{} = definition, fun) do
    map_sequences(definition, fn steps -> Enum.map(steps, fun) end)
  end

  defp map_sequences(%Definition{} = definition, fun) do
    %{definition | steps: rewrite(definition.steps, fun)}
  end

  defp rewrite(steps, fun) do
    steps
    |> Enum.map(fn node ->
      branches =
        Enum.reduce(Node.branch_keys(node.type), node.branches, fn key, branches ->
          Map.put(branches, key, rewrite(Map.get(branches, key, []), fun))
        end)

      %{node | branches: branches}
    end)
    |> fun.()
  end

  defp check_move_target(_node, :root), do: :ok

  defp check_move_target(%Node{} = node, {target_id, _branch_key}) do
    if Enum.any?(Node.flatten(node), &(&1.id == target_id)) do
      {:error,
       Error.new(:validation, :invalid_move,
         message: "A step cannot be moved inside itself.",
         details: %{node_id: node.id}
       )}
    else
      :ok
    end
  end

  defp check_move_target(_node, _address), do: :ok

  defp check_index(index, highest) when is_integer(index) and index >= 0 and index <= highest,
    do: :ok

  defp check_index(index, highest) do
    {:error,
     Error.new(:validation, :invalid_index,
       message: "The position is outside the sequence.",
       details: %{index: index, highest: highest}
     )}
  end

  defp finish(%Definition{} = definition) do
    case Definition.validate_limits(definition) do
      :ok -> {:ok, definition}
      {:error, %Error{}} = error -> error
    end
  end

  defp node_not_found(node_id) do
    Error.new(:not_found, :node_not_found,
      message: "The step was not found in this workflow.",
      details: %{node_id: inspect(node_id)}
    )
  end

  defp branch_not_found(node_id, branch_key) do
    Error.new(:not_found, :branch_not_found,
      message: "The step has no such branch.",
      details: %{node_id: node_id, branch: inspect(branch_key)}
    )
  end
end
