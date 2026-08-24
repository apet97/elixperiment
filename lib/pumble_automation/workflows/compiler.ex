defmodule PumbleAutomation.Workflows.Compiler do
  @moduledoc """
  Turns an edited definition into the graph a worker runs: Section 15.2.

  `compile/1` refuses anything `PumbleAutomation.Workflows.Validator` calls an
  error, so a compiled graph is by construction a graph that passed validation.
  Warnings do not stop it. A step after a stop is unreachable, so it is left
  out of the graph rather than carried as a step no run can enter.

  ## Flattening

  The tree becomes a flat map by giving every step the identifier of the step
  that follows it. Within a sequence that is the next sibling. For the last
  step of a sequence it is the *continuation*: whatever follows the branching
  step the sequence belongs to, worked out the same way, all the way up to the
  end of the workflow.

  A branching step sends each outcome to the first step of that branch, or
  straight to its own continuation when the branch is empty. Identifiers are
  the author's own, so a compiled step and an edited step are the same step and
  an execution can be read against the outline it came from.

  ## Precompiling

  Text that interpolates is stored as the segments
  `PumbleAutomation.Workflows.Templates` produced, and a path is stored as its
  parsed parts rather than as the text that was typed. Nothing re-parses a
  template while a workflow is running, and nothing at run time can be handed a
  path that was never checked.

  Text that interpolates nothing stays text. Validation refuses a reference in
  a field that takes plain text, so a plain string here means a field with
  nothing to render, not a field whose template was missed.
  """

  alias PumbleAutomation.Workflows.CompiledWorkflow
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Definition.Trigger
  alias PumbleAutomation.Workflows.Dependencies
  alias PumbleAutomation.Workflows.Node
  alias PumbleAutomation.Workflows.Node.Config
  alias PumbleAutomation.Workflows.Templates
  alias PumbleAutomation.Workflows.TriggerBinding
  alias PumbleAutomation.Workflows.ValidationIssue
  alias PumbleAutomation.Workflows.Validator
  alias PumbleAutomation.Workflows.WorkflowVersion

  # The outcome names of Section 15.2, which are shorter than the branch keys
  # an author sees. Nothing derives one from the other by rewriting text.
  @outcomes %{
    if_true: "true",
    if_false: "false",
    approved: "approved",
    rejected: "rejected",
    timed_out: "timed_out"
  }

  @next "next"

  @doc """
  Compiles `definition`, or returns the issues that stop it.

  The error is the validator's own list, so a caller shows the same findings
  the editor shows rather than a second description of them.
  """
  @spec compile(Definition.t()) :: {:ok, CompiledWorkflow.t()} | {:error, [ValidationIssue.t()]}
  def compile(%Definition{} = definition) do
    issues = Validator.validate(definition)

    if ValidationIssue.errors?(issues) do
      {:error, ValidationIssue.errors(issues)}
    else
      {:ok, build(definition)}
    end
  end

  @doc "The outcome name each branch key is written as in a compiled graph."
  @spec outcomes() :: %{Node.branch_key() => String.t()}
  def outcomes, do: @outcomes

  defp build(%Definition{} = definition) do
    written = graph(definition.steps, CompiledWorkflow.end_target(), %{})
    entry = definition.steps |> List.first() |> Map.fetch!(:id)
    nodes = Map.take(written, reachable(written, entry))

    order =
      definition
      |> Definition.nodes()
      |> Enum.map(& &1.id)
      |> Enum.filter(&Map.has_key?(nodes, &1))

    %CompiledWorkflow{
      entry_node_id: entry,
      nodes: nodes,
      node_order: order,
      max_path_length: longest_path(nodes, entry),
      required_scopes: Dependencies.required_scopes(nodes),
      trigger_binding: trigger_binding(definition.trigger),
      definition_hash: WorkflowVersion.definition_hash(Definition.encode(definition))
    }
  end

  # A step written after a stop can never be arrived at. The validator says so
  # as a warning, which is right for an author, but a graph is a program: what
  # it holds is what can run, so what cannot run is left out of it rather than
  # carried along as steps no execution will ever mention.
  defp reachable(nodes, entry), do: nodes |> follow([entry], %{}) |> Map.keys()

  defp follow(_nodes, [], seen), do: seen

  defp follow(nodes, [id | rest], seen) do
    cond do
      id == CompiledWorkflow.end_target() ->
        follow(nodes, rest, seen)

      Map.has_key?(seen, id) ->
        follow(nodes, rest, seen)

      true ->
        targets = nodes |> Map.fetch!(id) |> Map.fetch!(:edges) |> Map.values()
        follow(nodes, targets ++ rest, Map.put(seen, id, true))
    end
  end

  # `continuation` is where this whole sequence leads once it finishes, so the
  # last step of a branch needs no knowledge of the branch it sits in.
  defp graph([], _continuation, nodes), do: nodes

  defp graph([node | rest], continuation, nodes) do
    following = first_id(rest, continuation)

    nodes
    |> Map.put(node.id, compile_node(node, following))
    |> then(&branch_graphs(node, following, &1))
    |> then(&graph(rest, continuation, &1))
  end

  defp branch_graphs(%Node{} = node, continuation, nodes) do
    Enum.reduce(Node.branch_keys(node.type), nodes, fn key, acc ->
      graph(branch(node, key), continuation, acc)
    end)
  end

  defp compile_node(%Node{} = node, following) do
    config = compile_config(node.config)

    %{
      type: node.type,
      config: config,
      edges: edges(node, following),
      requires: Dependencies.requirements(node.type, config)
    }
  end

  defp edges(%Node{type: :stop}, _following), do: %{@next => CompiledWorkflow.end_target()}

  defp edges(%Node{} = node, following) do
    case Node.branch_keys(node.type) do
      [] ->
        %{@next => following}

      keys ->
        Map.new(keys, fn key ->
          {Map.fetch!(@outcomes, key), first_id(branch(node, key), following)}
        end)
    end
  end

  defp branch(%Node{} = node, key), do: Map.get(node.branches, key, [])

  defp first_id([], continuation), do: continuation
  defp first_id([node | _rest], _continuation), do: node.id

  ## Configuration

  # `Config.encode/1` already knows how a configuration is written down: string
  # keys, enums as their wire strings, nested configurations encoded the same
  # way. All this adds is the one thing storage does not do, which is turning
  # text that interpolates into the segments it was parsed into.
  defp compile_config(config), do: config |> Config.encode() |> compile_data()

  defp compile_data(text) when is_binary(text), do: compile_text(text)
  defp compile_data(values) when is_list(values), do: Enum.map(values, &compile_data/1)

  defp compile_data(%{} = value) do
    Map.new(value, fn {key, inner} -> {key, compile_data(inner)} end)
  end

  defp compile_data(value), do: value

  defp compile_text(text) when is_binary(text) do
    {segments, []} = Templates.parse(text)

    case Templates.references(segments) do
      [] -> text
      _references -> %{"template" => Enum.map(segments, &segment/1)}
    end
  end

  defp segment({:literal, text}), do: %{"literal" => text}
  defp segment({:reference, reference}), do: %{"path" => path(reference)}

  defp path({:trigger, subpath}), do: %{"root" => "trigger", "path" => subpath}
  defp path({:secret, name}), do: %{"root" => "secret", "name" => name}
  defp path({:context, root, subpath}), do: %{"root" => Atom.to_string(root), "path" => subpath}

  defp path({:step, node_id, subpath}) do
    %{"root" => "steps", "node_id" => node_id, "path" => subpath}
  end

  ## Derived facts

  defp trigger_binding(%Trigger{type: :schedule, config: config} = trigger) do
    # A schedule needs more than a discriminator: activation writes a row that
    # says when to run, and that is the trigger's own configuration.
    Map.put(%{"bindings" => bindings(trigger)}, "schedule", Config.encode(config))
  end

  defp trigger_binding(%Trigger{} = trigger), do: %{"bindings" => bindings(trigger)}

  defp bindings(%Trigger{} = trigger) do
    trigger
    |> TriggerBinding.discriminators()
    |> Enum.map(fn binding ->
      Map.new(binding, fn {key, value} -> {Atom.to_string(key), value} end)
    end)
  end

  # The graph converges but never loops, so the longest run is found by taking
  # the longest way out of each step once and remembering it.
  defp longest_path(nodes, entry) do
    {length, _measured} = depth(nodes, entry, %{})
    length
  end

  defp depth(nodes, target, measured) do
    cond do
      target == CompiledWorkflow.end_target() -> {0, measured}
      Map.has_key?(measured, target) -> {Map.fetch!(measured, target), measured}
      true -> measure(nodes, target, measured)
    end
  end

  defp measure(nodes, target, measured) do
    node = Map.fetch!(nodes, target)

    {longest, measured} =
      Enum.reduce(Map.values(node.edges), {0, measured}, fn next, {longest, measured} ->
        {length, measured} = depth(nodes, next, measured)
        {max(longest, length), measured}
      end)

    {longest + 1, Map.put(measured, target, longest + 1)}
  end
end
