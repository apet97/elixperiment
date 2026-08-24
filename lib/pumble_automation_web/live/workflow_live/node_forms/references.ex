defmodule PumbleAutomationWeb.WorkflowLive.NodeForms.References do
  @moduledoc """
  Path suggestions a configuration field may insert, matching the validator.

  A step may read the trigger, earlier output on its own path, and the run
  context. It may not read a later step or a sibling branch that does not
  always run. Secrets are listed only for fields that may carry them, and
  only as names.
  """

  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Node
  alias PumbleAutomation.Workflows.Templates

  @output_types [:pumble_action, :http_action, :approval]

  @trigger_fields ~w(
    type actor_id channel_id resource_id thread_root_id
    occurred_at occurred_at_source correlation_id bot_origin data
  )

  @context_paths [
    %{path: "execution.id", label: "This run", kind: :context},
    %{path: "execution.run_mode", label: "Run mode", kind: :context},
    %{path: "workspace.id", label: "Workspace", kind: :context},
    %{path: "actor.id", label: "Actor", kind: :context}
  ]

  @type suggestion :: %{path: String.t(), label: String.t(), kind: atom()}

  @doc "Suggestions available when configuring `node_id` inside `definition`."
  @spec available(Definition.t(), String.t()) :: [suggestion()]
  def available(%Definition{} = definition, node_id) when is_binary(node_id) do
    trigger_paths() ++ @context_paths ++ step_paths(definition, node_id)
  end

  @doc "Suggestions available on the trigger itself (run context only)."
  @spec available_for_trigger() :: [suggestion()]
  def available_for_trigger, do: @context_paths

  @doc "Write-only secret name suggestions. Values never appear."
  @spec secret_paths([map()]) :: [suggestion()]
  def secret_paths(secrets) when is_list(secrets) do
    Enum.map(secrets, fn secret ->
      %{path: "secret.#{secret.name}", label: secret.name, kind: :secret}
    end)
  end

  @doc "Secret names referenced from template text, never values."
  @spec secret_names_in(term()) :: [String.t()]
  def secret_names_in(value) when is_binary(value) do
    {segments, _reasons} = Templates.parse(value)

    for {:reference, {:secret, name}} <- segments, do: name
  end

  def secret_names_in(value) when is_map(value) do
    value |> Map.values() |> Enum.flat_map(&secret_names_in/1)
  end

  def secret_names_in(value) when is_list(value) do
    Enum.flat_map(value, &secret_names_in/1)
  end

  def secret_names_in(_value), do: []

  @doc "The template snippet an insert button writes."
  @spec snippet(String.t()) :: String.t()
  def snippet(path) when is_binary(path), do: "{{ #{path} }}"

  defp trigger_paths do
    Enum.map(@trigger_fields, fn field ->
      %{
        path: "trigger.#{field}",
        label: "Trigger #{String.replace(field, "_", " ")}",
        kind: :trigger
      }
    end)
  end

  defp step_paths(%Definition{} = definition, node_id) do
    types = Map.new(Definition.nodes(definition), &{&1.id, &1.type})

    case find_available(definition.steps, node_id, []) do
      {:hit, ids} ->
        ids
        |> Enum.reverse()
        |> Enum.filter(&(Map.get(types, &1) in @output_types))
        |> Enum.map(&step_suggestion/1)

      :miss ->
        []
    end
  end

  defp step_suggestion(id) do
    %{
      path: "steps.#{id}.output",
      label: "Output of #{String.slice(id, 0, 8)}",
      kind: :step,
      node_id: id
    }
  end

  defp find_available(nodes, target, available) do
    nodes
    |> Enum.reduce_while({:miss, available}, &search_node(&1, target, &2))
    |> finish_search()
  end

  defp search_node(%Node{id: target}, target, {:miss, available}) do
    {:halt, {:hit, available}}
  end

  defp search_node(%Node{} = node, target, {:miss, available}) do
    case find_in_branches(node, target, [node.id | available]) do
      {:hit, found} -> {:halt, {:hit, found}}
      :miss -> {:cont, {:miss, [node.id | available]}}
    end
  end

  defp find_in_branches(%Node{} = node, target, available) do
    Enum.reduce_while(Node.branch_keys(node.type), :miss, fn key, :miss ->
      case find_available(Map.get(node.branches, key, []), target, available) do
        {:hit, found} -> {:halt, {:hit, found}}
        :miss -> {:cont, :miss}
      end
    end)
  end

  defp finish_search({:hit, ids}), do: {:hit, ids}
  defp finish_search({:miss, _ids}), do: :miss
end
