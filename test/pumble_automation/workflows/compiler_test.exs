defmodule PumbleAutomation.Workflows.CompilerTest do
  @moduledoc """
  What the compiler must guarantee about a graph before anything runs it.

  The claims are the ones a worker relies on: every outcome leads somewhere, a
  run always reaches the end, no run visits a step twice, and the identifiers
  are the author's own. Each is asserted by walking the compiled graph alone,
  never by consulting the definition it came from, because a worker will not
  have the definition either.
  """

  use ExUnit.Case, async: true

  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Workflows.CompiledWorkflow
  alias PumbleAutomation.Workflows.Compiler
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Definition.Trigger
  alias PumbleAutomation.Workflows.Node
  alias PumbleAutomation.Workflows.WorkflowVersion

  @ending CompiledWorkflow.end_target()

  describe "the shape of a compiled workflow" do
    test "steps become a flat map keyed by the identifiers the author owns" do
      first = message_node()
      second = delay_node()

      compiled = compile!(definition([first, second]))

      assert Map.keys(compiled.nodes) |> Enum.sort() == Enum.sort([first.id, second.id])
      assert compiled.entry_node_id == first.id
      assert compiled.node_order == [first.id, second.id]
    end

    test "a nested step is in the same flat map as the step that owns it" do
      inner = message_node()
      branch = condition_node(if_true: [inner])

      compiled = compile!(definition([branch]))

      assert Map.has_key?(compiled.nodes, inner.id)
      assert compiled.nodes[inner.id].type == :pumble_action
    end

    test "the document carries the versions of both the shape and the compiler" do
      compiled = compile!(definition([message_node()]))

      assert compiled.schema_version == CompiledWorkflow.schema_version()
      assert compiled.compiler_version == CompiledWorkflow.compiler_version()
    end
  end

  describe "edges" do
    test "a linear step points at the step after it" do
      first = message_node()
      second = delay_node()

      compiled = compile!(definition([first, second]))

      assert compiled.nodes[first.id].edges == %{"next" => second.id}
      assert compiled.nodes[second.id].edges == %{"next" => @ending}
    end

    test "a condition names one target for each outcome" do
      yes = message_node()
      no = delay_node()
      branch = condition_node(if_true: [yes], if_false: [no])

      compiled = compile!(definition([branch]))

      assert compiled.nodes[branch.id].edges == %{"true" => yes.id, "false" => no.id}
    end

    test "an approval names all three of its outcomes" do
      branch = approval_node(approved: [message_node()])

      compiled = compile!(definition([branch]))

      assert compiled.nodes[branch.id].edges |> Map.keys() |> Enum.sort() ==
               ["approved", "rejected", "timed_out"]
    end

    test "an empty branch leads to whatever follows the step that owns it" do
      branch = condition_node(if_true: [message_node()])
      after_branch = delay_node()

      compiled = compile!(definition([branch, after_branch]))

      assert compiled.nodes[branch.id].edges["false"] == after_branch.id
    end

    test "the last step of a branch continues after the step that owns the branch" do
      inner = message_node()
      branch = condition_node(if_true: [inner])
      after_branch = delay_node()

      compiled = compile!(definition([branch, after_branch]))

      assert compiled.nodes[inner.id].edges == %{"next" => after_branch.id}
    end

    test "a branch that ends the workflow continues to the end" do
      inner = message_node()
      branch = condition_node(if_true: [inner])

      compiled = compile!(definition([branch]))

      assert compiled.nodes[inner.id].edges == %{"next" => @ending}
    end

    test "a branch nested two deep still continues past both of its owners" do
      inner = message_node()
      middle = condition_node(if_true: [inner])
      outer = approval_node(approved: [middle])
      after_all = delay_node()

      compiled = compile!(definition([outer, after_all]))

      assert compiled.nodes[middle.id].edges["true"] == inner.id
      assert compiled.nodes[inner.id].edges == %{"next" => after_all.id}
      assert compiled.nodes[outer.id].edges["rejected"] == after_all.id
    end

    test "a stop ends the run whatever follows it" do
      stop = stop_node()

      compiled = compile!(definition([stop, message_node()]))

      assert compiled.nodes[stop.id].edges == %{"next" => @ending}
    end

    test "a step nothing can reach is not part of the program" do
      # The validator warns the author that a step after a stop will never run.
      # A graph is what runs, so it does not carry the step at all.
      stop = stop_node()
      never = message_node()

      compiled = compile!(definition([stop, never]))

      refute Map.has_key?(compiled.nodes, never.id)
      refute never.id in compiled.node_order
    end

    test "a permission only an unreachable step would need is not demanded" do
      compiled = compile!(definition([stop_node(), message_node()]))

      assert compiled.required_scopes == []
    end
  end

  describe "the invariants a worker relies on" do
    setup do
      %{compiled: compile!(definition(mixed_steps()))}
    end

    test "every outcome of every step names exactly one target", %{compiled: compiled} do
      for {id, node} <- compiled.nodes do
        expected = outcome_names(node.type)

        assert Enum.sort(Map.keys(node.edges)) == Enum.sort(expected),
               "step #{id} of type #{node.type} does not name its outcomes"

        assert Enum.all?(Map.values(node.edges), &target?(compiled, &1))
      end
    end

    test "every step is reachable from the entry", %{compiled: compiled} do
      assert reachable(compiled) == compiled.nodes |> Map.keys() |> MapSet.new()
    end

    test "no path revisits a step", %{compiled: compiled} do
      assert acyclic?(compiled)
    end

    test "a run picks its next step by reading one edge, and always ends", %{compiled: compiled} do
      # This is the worker's whole algorithm: hold an identifier, read an edge,
      # hold the next identifier. Nothing here consults the definition, keeps a
      # stack of enclosing branches, or knows what a branch is.
      run = fn run, id, visited ->
        if id == @ending do
          visited
        else
          run.(run, compiled.nodes[id].edges |> Map.values() |> hd(), [id | visited])
        end
      end

      visited = run.(run, compiled.entry_node_id, [])

      assert visited != []
      assert Enum.uniq(visited) == visited
    end

    test "the longest run is as long as the deepest path", %{compiled: compiled} do
      assert compiled.max_path_length == longest(compiled, compiled.entry_node_id)
    end
  end

  describe "precompiled configuration" do
    test "text that interpolates becomes parsed segments" do
      node =
        Node.new(:pumble_action, %{
          action: :send_message,
          channel_id: "channel-1",
          text: "hi {{ trigger.data.text }}"
        })

      compiled = compile!(definition([node]))

      assert compiled.nodes[node.id].config["text"] == %{
               "template" => [
                 %{"literal" => "hi "},
                 %{"path" => %{"root" => "trigger", "path" => ["data", "text"]}}
               ]
             }
    end

    test "text that interpolates nothing stays text" do
      node = message_node()

      compiled = compile!(definition([node]))

      assert compiled.nodes[node.id].config["text"] == "hello"
    end

    test "a step reference keeps the step it names" do
      first = message_node()

      second =
        Node.new(:pumble_action, %{
          action: :send_message,
          channel_id: "channel-1",
          text: "{{ steps.#{first.id}.output.id }}"
        })

      compiled = compile!(definition([first, second]))

      assert [%{"path" => path}] = compiled.nodes[second.id].config["text"]["template"]
      assert path == %{"root" => "steps", "node_id" => first.id, "path" => ["id"]}
    end

    test "a secret stays a name and never becomes a value" do
      node =
        Node.new(:http_action, %{
          method: :post,
          url: "https://example.test/hook",
          connection_id: Ecto.UUID.generate(),
          body: "token={{ secret.API_TOKEN }}"
        })

      compiled = compile!(definition([node]))

      assert [_literal, %{"path" => path}] = compiled.nodes[node.id].config["body"]["template"]
      assert path == %{"root" => "secret", "name" => "API_TOKEN"}
    end

    test "an HTTP idempotency header is part of the compiled contract" do
      node =
        Node.new(:http_action, %{
          method: :post,
          url: "https://example.test/hook",
          idempotency_header: "Idempotency-Key"
        })

      compiled = compile!(definition([node]))

      assert compiled.nodes[node.id].config["idempotency_header"] == "Idempotency-Key"
    end

    test "a condition keeps its comparator and both sides" do
      branch = condition_node(if_true: [message_node()])

      compiled = compile!(definition([branch]))

      assert %{"predicates" => [predicate], "combinator" => "all"} =
               compiled.nodes[branch.id].config

      assert predicate["comparator"] == "contains"
      assert predicate["right"] == "deploy"
      assert %{"template" => _segments} = predicate["left"]
    end

    test "an enumerated value is stored as the string it is stored as everywhere else" do
      node = message_node()

      compiled = compile!(definition([node]))

      assert compiled.nodes[node.id].config["action"] == "send_message"
    end
  end

  describe "what each step declares it needs" do
    test "a step that reaches Pumble names the operations it performs" do
      node = message_node()

      compiled = compile!(definition([node]))

      assert compiled.nodes[node.id].requires["operations"] == ["post_message"]
      assert compiled.nodes[node.id].requires["scopes"] == ["messages:write"]
    end

    test "a step that reaches nothing declares nothing" do
      node = delay_node()

      compiled = compile!(definition([node]))

      assert compiled.nodes[node.id].requires == %{
               "operations" => [],
               "scopes" => [],
               "connection_ids" => [],
               "secret_names" => []
             }
    end

    test "an HTTP step names the connection and secrets it uses" do
      connection_id = Ecto.UUID.generate()

      node =
        Node.new(:http_action, %{
          method: :post,
          url: "https://example.test/hook",
          connection_id: connection_id,
          body: "token={{ secret.API_TOKEN }}"
        })

      compiled = compile!(definition([node]))

      assert compiled.nodes[node.id].requires["connection_ids"] == [connection_id]
      assert compiled.nodes[node.id].requires["secret_names"] == ["API_TOKEN"]
    end

    test "every step declares all four, so nothing has to be worked out later" do
      compiled = compile!(definition(mixed_steps()))

      for {id, node} <- compiled.nodes do
        assert Enum.sort(Map.keys(node.requires)) ==
                 ["connection_ids", "operations", "scopes", "secret_names"],
               "step #{id} does not declare what it needs"
      end
    end
  end

  describe "the trigger" do
    test "a schedule carries the metadata activation needs to plan runs" do
      trigger =
        Trigger.new(:schedule, %{schedule_type: :daily, time_of_day: "09:00", timezone: "Etc/UTC"})

      compiled = compile!(Definition.new(trigger, [message_node()]))

      assert compiled.trigger_binding["schedule"]["schedule_type"] == "daily"
      assert compiled.trigger_binding["schedule"]["time_of_day"] == "09:00"
      assert compiled.trigger_binding["schedule"]["timezone"] == "Etc/UTC"
      assert [%{"kind" => "schedule", "type" => "daily"}] = compiled.trigger_binding["bindings"]
    end

    test "a trigger that is not a schedule carries no schedule" do
      compiled = compile!(definition([message_node()]))

      refute Map.has_key?(compiled.trigger_binding, "schedule")
    end

    test "an event trigger carries one binding per channel it listens to" do
      trigger = Trigger.new(:pumble_event, %{event: :new_message, channel_ids: ["a", "b"]})

      compiled = compile!(Definition.new(trigger, [message_node()]))

      assert Enum.map(compiled.trigger_binding["bindings"], & &1["channel_id"]) == ["a", "b"]
    end
  end

  describe "the document that is stored" do
    test "encoding produces string keys and JSON values" do
      compiled = compile!(definition(mixed_steps()))

      encoded = CompiledWorkflow.encode(compiled)

      assert Enum.all?(Map.keys(encoded), &is_binary/1)
      assert is_binary(Jason.encode!(encoded))
    end

    test "a document round trips through encoding" do
      compiled = compile!(definition(mixed_steps()))

      assert {:ok, decoded} = compiled |> CompiledWorkflow.encode() |> CompiledWorkflow.decode()
      assert decoded.nodes == compiled.nodes
      assert decoded.entry_node_id == compiled.entry_node_id
      assert decoded.node_order == compiled.node_order
    end

    test "a document survives the trip through JSON, which is how it is stored" do
      compiled = compile!(definition(mixed_steps()))

      restored =
        compiled
        |> CompiledWorkflow.encode()
        |> Jason.encode!()
        |> Jason.decode!()

      assert {:ok, decoded} = CompiledWorkflow.decode(restored)
      assert decoded.nodes == compiled.nodes
    end
  end

  describe "hashing" do
    test "the hash is of the source definition, so it names what was compiled" do
      definition = definition(mixed_steps())

      compiled = compile!(definition)

      assert compiled.definition_hash ==
               WorkflowVersion.definition_hash(Definition.encode(definition))
    end

    test "compiling the same definition twice gives the same hash and the same document" do
      definition = definition(mixed_steps())

      first = compile!(definition)
      second = compile!(definition)

      assert first.definition_hash == second.definition_hash
      assert CompiledWorkflow.encode(first) == CompiledWorkflow.encode(second)
    end

    test "a changed definition gives a different hash" do
      steps = [message_node()]

      changed = [
        Node.new(:pumble_action, %{action: :send_message, channel_id: "channel-1", text: "other"})
      ]

      refute compile!(definition(steps)).definition_hash ==
               compile!(definition(changed)).definition_hash
    end
  end

  describe "refusing to compile" do
    test "a definition with errors returns them instead of a partial graph" do
      assert {:error, issues} = Compiler.compile(definition([]))
      refute issues == []
      assert Enum.all?(issues, &(&1.severity == :error))
    end

    test "a definition whose only findings are warnings still compiles" do
      # A step after a stop is unreachable, which is worth saying and not worth
      # refusing.
      definition = definition([stop_node(), message_node()])

      assert {:ok, %CompiledWorkflow{}} = Compiler.compile(definition)
    end
  end

  describe "purity" do
    test "no I/O occurs" do
      assert query_count(fn -> Compiler.compile(definition(mixed_steps())) end) == 0
    end

    test "compiling does not change the definition it was given" do
      definition = definition(mixed_steps())
      encoded = Definition.encode(definition)

      Compiler.compile(definition)

      assert Definition.encode(definition) == encoded
    end
  end

  describe "whatever it is given" do
    # The hand-written cases above each cover one shape. This covers the claim
    # they are instances of: for any definition, compiling either answers with
    # a graph that keeps every invariant or answers with the validator's
    # issues, and never raises. Only what an author can reach is generated;
    # a branch holding something that is not a step is a programmer-invariant
    # violation, not an input, and is left alone for the same reason the
    # validator's own generator leaves it alone.
    test "two hundred random definitions compile into sound graphs or are refused" do
      :rand.seed(:exsss, {2026, 8, 16})

      for _run <- 1..200 do
        definition = random_definition()

        case Compiler.compile(definition) do
          {:ok, compiled} -> assert_sound(compiled)
          {:error, issues} -> assert Enum.all?(issues, &(&1.severity == :error))
        end
      end
    end

    test "a definition an author has broken is refused rather than half compiled" do
      :rand.seed(:exsss, {2026, 8, 17})

      for _run <- 1..200 do
        definition = corrupt(random_definition())

        case Compiler.compile(definition) do
          {:ok, compiled} -> assert_sound(compiled)
          {:error, issues} -> refute issues == []
        end
      end
    end
  end

  defp assert_sound(compiled) do
    assert reachable(compiled) == compiled.nodes |> Map.keys() |> MapSet.new()
    assert acyclic?(compiled)
    assert is_binary(Jason.encode!(CompiledWorkflow.encode(compiled)))

    for {_id, node} <- compiled.nodes do
      assert Enum.sort(Map.keys(node.edges)) == Enum.sort(outcome_names(node.type))
      assert Enum.all?(Map.values(node.edges), &target?(compiled, &1))
    end
  end

  defp random_definition do
    definition(Enum.map(1..6, fn _index -> random_node(2) end))
  end

  defp random_node(0), do: Enum.random([message_node(), delay_node(), stop_node(), text_node()])

  defp random_node(depth) do
    case :rand.uniform(7) do
      1 -> condition_node(if_true: [random_node(depth - 1)], if_false: [random_node(depth - 1)])
      2 -> approval_node(approved: [random_node(depth - 1)])
      3 -> approval_node(rejected: [random_node(depth - 1)], timed_out: [random_node(depth - 1)])
      4 -> text_node()
      5 -> delay_node()
      6 -> connected_node()
      _ -> stop_node()
    end
  end

  defp text_node do
    Node.new(:pumble_action, %{
      action: :send_message,
      channel_id: "channel-1",
      text: random_text()
    })
  end

  defp connected_node do
    Node.new(:http_action, %{
      method: :post,
      url: "https://example.test/hook",
      connection_id: Ecto.UUID.generate(),
      headers: %{"x-trace" => random_text()},
      body: "payload=#{random_text()}"
    })
  end

  defp random_text do
    Enum.random([
      "plain text",
      "{{ trigger.data.text }}",
      "before {{ trigger.data.text }} between {{ execution.id }} after",
      "{{ secret.API_TOKEN }}",
      "{{ workspace.id }}/{{ actor.id }}"
    ])
  end

  defp corrupt(definition) do
    %{definition | steps: Enum.map(definition.steps, &corrupt_node/1)}
  end

  defp corrupt_node(node) do
    case :rand.uniform(6) do
      1 -> %{node | type: :teleport}
      2 -> %{node | id: "not-a-uuid"}
      3 -> put_config(node, "{{ unclosed and {{ trigger.Nope }}")
      4 -> put_config(node, :bogus_atom)
      5 -> put_config(node, 42)
      _ -> node
    end
  end

  defp put_config(node, value) do
    case node.config.__struct__.fields() do
      [] ->
        node

      fields ->
        {name, _kind, _opts} = Enum.random(fields)
        %{node | config: Map.put(node.config, name, value)}
    end
  end

  defp compile!(definition) do
    assert {:ok, compiled} = Compiler.compile(definition)
    compiled
  end

  defp mixed_steps do
    [
      condition_node(
        if_true: [message_node(), delay_node()],
        if_false: [approval_node(approved: [message_node()], rejected: [stop_node()])]
      ),
      message_node()
    ]
  end

  defp outcome_names(type) do
    case Node.branch_keys(type) do
      [] -> ["next"]
      keys -> Enum.map(keys, &Map.fetch!(Compiler.outcomes(), &1))
    end
  end

  defp target?(_compiled, @ending), do: true
  defp target?(compiled, id), do: Map.has_key?(compiled.nodes, id)

  defp reachable(compiled) do
    walk = fn walk, id, seen ->
      cond do
        id == @ending ->
          seen

        MapSet.member?(seen, id) ->
          seen

        true ->
          compiled.nodes[id].edges
          |> Map.values()
          |> Enum.reduce(MapSet.put(seen, id), &walk.(walk, &1, &2))
      end
    end

    walk.(walk, compiled.entry_node_id, MapSet.new())
  end

  defp acyclic?(compiled) do
    descend = fn descend, id, path ->
      cond do
        id == @ending ->
          true

        MapSet.member?(path, id) ->
          false

        true ->
          compiled.nodes[id].edges
          |> Map.values()
          |> Enum.all?(&descend.(descend, &1, MapSet.put(path, id)))
      end
    end

    descend.(descend, compiled.entry_node_id, MapSet.new())
  end

  defp longest(_compiled, @ending), do: 0

  defp longest(compiled, id) do
    1 +
      (compiled.nodes[id].edges
       |> Map.values()
       |> Enum.map(&longest(compiled, &1))
       |> Enum.max())
  end

  defp query_count(fun) do
    handler = "compiler-query-count-#{System.unique_integer([:positive])}"
    counter = :counters.new(1, [])
    mine = self()

    :telemetry.attach(
      handler,
      [:pumble_automation, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        if self() == mine, do: :counters.add(counter, 1, 1)
      end,
      nil
    )

    try do
      fun.()
      :counters.get(counter, 1)
    after
      :telemetry.detach(handler)
    end
  end
end
