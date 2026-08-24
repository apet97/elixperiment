defmodule PumbleAutomation.Workflows.Clone do
  @moduledoc """
  Rebuilds a definition through the same constructors, with new identifiers.

  Duplicating a workflow must not share node or trigger identity with the
  source, and it must not share version rows. The only way to promise that
  is to insert new UUIDs the same way an author would: `Trigger.new/2` and
  `Node.new/2`. Configuration is copied; identifiers are not.
  """

  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Definition.Trigger
  alias PumbleAutomation.Workflows.Node

  @doc "A definition equivalent to `definition`, with new trigger and node ids."
  @spec definition(Definition.t()) :: Definition.t()
  def definition(%Definition{} = definition) do
    Definition.new(clone_trigger(definition.trigger), Enum.map(definition.steps, &clone_node/1))
  end

  defp clone_trigger(%Trigger{type: type, config: config}) do
    Trigger.new(type, Map.from_struct(config))
  end

  defp clone_node(%Node{} = node) do
    cloned = Node.new(node.type, Map.from_struct(node.config))

    Enum.reduce(Node.branch_keys(node.type), cloned, fn key, acc ->
      Node.put_branch(acc, key, Enum.map(Map.get(node.branches, key, []), &clone_node/1))
    end)
  end
end
