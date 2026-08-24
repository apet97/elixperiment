defmodule PumbleAutomation.Workflows.DefinitionTest do
  # Not async: the fuzz test reads the global atom count, and a concurrent test
  # that creates an atom would make it flap.
  use ExUnit.Case, async: false

  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Error
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Definition.Trigger
  alias PumbleAutomation.Workflows.ManualAlias
  alias PumbleAutomation.Workflows.Node

  describe "encode/1 and decode/1" do
    test "round-trip every node type through JSON" do
      definition =
        definition([
          message_node(),
          delay_node(),
          http_node(),
          condition_node(if_true: [message_node()], if_false: [stop_node()]),
          approval_node(
            approved: [message_node()],
            rejected: [stop_node()],
            timed_out: [delay_node()]
          ),
          stop_node()
        ])

      assert {:ok, decoded} = round_trip(definition)
      assert decoded == definition
    end

    test "round-trip every trigger type" do
      for trigger <- [
            Trigger.new(:pumble_event, %{event: :reaction_added}),
            Trigger.new(:manual, %{manual_alias: "deploy", global_shortcut: true}),
            Trigger.new(:schedule, %{
              schedule_type: :weekly,
              time_of_day: "09:00",
              weekdays: ["monday"],
              timezone: "Europe/Belgrade"
            }),
            Trigger.new(:webhook, %{require_signature: true}),
            Trigger.new(:manual_test)
          ] do
        definition = Definition.new(trigger, [message_node()])
        assert {:ok, decoded} = round_trip(definition)
        assert decoded.trigger == trigger
      end
    end

    test "manual aliases use the workflow slug syntax", do: assert_manual_alias_syntax()

    test "encodes to the shape of Section 15.1" do
      encoded = definition([message_node()]) |> Definition.encode()

      assert %{"schema_version" => 1, "trigger" => trigger, "steps" => [step]} = encoded

      assert %{"id" => _, "type" => "pumble_event", "config" => %{"event" => "NEW_MESSAGE"}} =
               trigger

      assert %{"id" => _, "type" => "pumble_action", "config" => config} = step
      assert config["action"] == "send_message"
    end

    test "condition and approval carry their plan branch keys" do
      encoded =
        definition([
          condition_node(if_true: [stop_node()]),
          approval_node(rejected: [stop_node()])
        ])
        |> Definition.encode()

      [condition, approval] = encoded["steps"]

      assert Map.keys(condition) |> Enum.sort() == ~w(config id if_false if_true type)
      assert Map.keys(approval) |> Enum.sort() == ~w(approved config id rejected timed_out type)
    end

    test "keeps default configuration values across a round trip" do
      node = Node.new(:condition, %{})
      definition = definition([node])

      assert {:ok, decoded} = round_trip(definition)
      assert [%Node{config: %{combinator: :all, predicates: []}}] = decoded.steps
    end

    test "round-trips an authored HTTP idempotency header" do
      node =
        Node.new(:http_action, %{
          method: :post,
          url: "https://example.test/hook",
          idempotency_header: "Idempotency-Key"
        })

      assert {:ok, decoded} = round_trip(definition([node]))
      assert [%Node{config: %{idempotency_header: "Idempotency-Key"}}] = decoded.steps
    end
  end

  defp assert_manual_alias_syntax do
    for alias_name <- ["Deploy", "-deploy", "deploy now", String.duplicate("a", 65)] do
      raw =
        Definition.new(Trigger.new(:manual, %{manual_alias: alias_name}), [])
        |> Definition.encode()

      assert {:error, %Error{code: :invalid_definition} = error} = Definition.decode(raw)

      assert [%{path: "/trigger/config/manual_alias"} = issue] = error.details.issues
      assert issue.reason in [:invalid_format, :too_long]
      assert issue.message == ManualAlias.message()
    end
  end

  describe "decode/1 refusals" do
    test "refuses an unsupported schema version" do
      raw = definition([]) |> Definition.encode() |> Map.put("schema_version", 2)

      assert {:error, %Error{class: :validation, code: :unsupported_schema_version} = error} =
               Definition.decode(raw)

      assert error.details == %{supported: 1, received: 2}
    end

    test "refuses unknown fields at every closed wire-schema boundary" do
      encoded = Definition.encode(definition([http_node()]))

      cases = [
        {Map.put(encoded, "runtime", %{}), "/runtime"},
        {update_in(encoded, ["trigger"], &Map.put(&1, "callback", "surprise")),
         "/trigger/callback"},
        {update_in(encoded, ["steps", Access.at(0)], &Map.put(&1, "next", "somewhere")),
         "/steps/0/next"},
        {update_in(
           encoded,
           ["steps", Access.at(0), "config"],
           &Map.put(&1, "idempotent", true)
         ), "/steps/0/config/idempotent"}
      ]

      for {raw, path} <- cases do
        assert {:error, %Error{code: :invalid_definition} = error} = Definition.decode(raw)
        assert [%{path: ^path, reason: :unknown_field}] = error.details.issues
      end
    end

    test "a non-text root key is refused without inspecting it" do
      raw = Definition.encode(definition([])) |> Map.put({:not, :json}, "ignored")

      assert {:error, %Error{code: :invalid_definition} = error} = Definition.decode(raw)
      assert [%{path: "", reason: :unknown_field}] = error.details.issues
    end

    test "refuses oversized trigger and node maps before enumerating unknown fields" do
      encoded = Definition.encode(definition([http_node()]))

      trigger =
        Enum.reduce(1..1_000, encoded["trigger"], fn index, raw ->
          Map.put(raw, "unknown-#{index}", %{"nested" => String.duplicate("x", 100)})
        end)

      node =
        Enum.reduce(1..1_000, hd(encoded["steps"]), fn index, raw ->
          Map.put(raw, "unknown-#{index}", %{"nested" => String.duplicate("x", 100)})
        end)

      for {raw, path} <- [
            {put_in(encoded["trigger"], trigger), "/trigger"},
            {put_in(encoded["steps"], [node]), "/steps/0"}
          ] do
        assert {:error, %Error{code: :invalid_definition} = error} = Definition.decode(raw)
        assert [%{path: ^path, reason: :too_many_keys}] = error.details.issues
      end
    end

    test "bounds unknown-field issues before building the error" do
      raw =
        Enum.reduce(1..60, Definition.encode(definition([])), fn index, acc ->
          Map.put(acc, "unknown-#{String.pad_leading(Integer.to_string(index), 2, "0")}", true)
        end)

      assert {:error, %Error{code: :invalid_definition} = error} = Definition.decode(raw)
      assert length(error.details.issues) == 50
      assert Enum.all?(error.details.issues, &(&1.reason == :unknown_field))
      assert error.details.issues == Enum.sort_by(error.details.issues, & &1.path)
    end

    test "refuses a missing schema version" do
      raw = definition([]) |> Definition.encode() |> Map.delete("schema_version")

      assert {:error, %Error{code: :unsupported_schema_version} = error} = Definition.decode(raw)
      assert error.details.received == :not_an_integer
    end

    test "refuses an unknown node type" do
      raw = put_in(encoded_with_step()["steps"], [%{"id" => uuid(), "type" => "launch_missile"}])

      assert {:error, %Error{code: :invalid_definition} = error} = Definition.decode(raw)
      assert [%{path: "/steps/0/type", reason: :unknown_node_type}] = error.details.issues
    end

    test "refuses an unknown trigger type" do
      raw = put_in(encoded_with_step()["trigger"]["type"], "telepathy")

      assert {:error, %Error{code: :invalid_definition} = error} = Definition.decode(raw)
      assert [%{path: "/trigger/type", reason: :unknown_trigger_type}] = error.details.issues
    end

    test "refuses a missing trigger" do
      raw = definition([]) |> Definition.encode() |> Map.delete("trigger")

      assert {:error, %Error{code: :invalid_definition} = error} = Definition.decode(raw)
      assert [%{path: "/trigger", reason: :missing}] = error.details.issues
    end

    test "refuses duplicate node identifiers" do
      id = uuid()
      definition = definition([message_node(id: id), delay_node(id: id)])

      assert {:error, %Error{code: :duplicate_node_ids}} =
               definition |> Definition.encode() |> Definition.decode()
    end

    test "refuses duplicate identifiers across a branch boundary" do
      id = uuid()
      definition = definition([condition_node(if_true: [message_node(id: id)], id: id)])

      assert {:error, %Error{code: :duplicate_node_ids}} =
               definition |> Definition.encode() |> Definition.decode()
    end

    test "refuses a node identifier that is not a UUID" do
      raw = put_in(encoded_with_step()["steps"], [%{"id" => "step-1", "type" => "stop"}])

      assert {:error, %Error{code: :invalid_definition} = error} = Definition.decode(raw)
      assert [%{path: "/steps/0/id", reason: :invalid_node_id}] = error.details.issues
    end

    test "refuses a missing required configuration field, naming its path" do
      raw =
        put_in(encoded_with_step()["steps"], [
          %{"id" => uuid(), "type" => "http_action", "config" => %{"method" => "post"}}
        ])

      assert {:error, %Error{code: :invalid_definition} = error} = Definition.decode(raw)
      assert [%{path: "/steps/0/config/url", reason: :missing}] = error.details.issues
    end

    test "reports every bad field rather than only the first" do
      raw =
        put_in(encoded_with_step()["steps"], [
          %{"id" => uuid(), "type" => "http_action", "config" => %{}}
        ])

      assert {:error, %Error{} = error} = Definition.decode(raw)
      assert length(error.details.issues) == 2
    end

    test "refuses a value that is the wrong type" do
      raw =
        put_in(encoded_with_step()["steps"], [
          %{"id" => uuid(), "type" => "delay", "config" => %{"duration_seconds" => "soon"}}
        ])

      assert {:error, %Error{} = error} = Definition.decode(raw)

      assert [%{path: "/steps/0/config/duration_seconds", reason: :invalid_type}] =
               error.details.issues
    end

    test "refuses a string longer than the decode bound" do
      raw =
        put_in(encoded_with_step()["steps"], [
          %{
            "id" => uuid(),
            "type" => "stop",
            "config" => %{"reason" => String.duplicate("x", 2048)}
          }
        ])

      assert {:error, %Error{} = error} = Definition.decode(raw)
      assert [%{path: "/steps/0/config/reason", reason: :too_long}] = error.details.issues
    end

    test "refuses a list longer than the decode bound" do
      raw =
        put_in(encoded_with_step()["steps"], [
          %{
            "id" => uuid(),
            "type" => "approval",
            "config" => %{
              "timeout_seconds" => 60,
              "approver_member_ids" => Enum.map(1..100, &"member-#{&1}")
            }
          }
        ])

      assert {:error, %Error{} = error} = Definition.decode(raw)
      assert [%{reason: :too_many_items}] = error.details.issues
    end

    test "refuses input that is not an object" do
      for raw <- ["definition", 1, [], nil] do
        assert {:error, %Error{code: :invalid_definition}} = Definition.decode(raw)
      end
    end

    test "refuses a branch that is not a list" do
      raw =
        put_in(encoded_with_step()["steps"], [
          %{"id" => uuid(), "type" => "condition", "config" => %{}, "if_true" => "nope"}
        ])

      assert {:error, %Error{} = error} = Definition.decode(raw)
      assert [%{path: "/steps/0/if_true", reason: :invalid_type}] = error.details.issues
    end
  end

  describe "structural limits" do
    test "accepts a definition at the depth limit and refuses one past it" do
      assert Definition.depth(definition(nest(8))) == 8
      assert {:ok, _decoded} = round_trip(definition(nest(8)))

      assert Definition.depth(definition(nest(9))) == 9
      assert {:error, %Error{code: :branch_too_deep}} = round_trip(definition(nest(9)))
    end

    test "accepts a definition at the node limit and refuses one past it" do
      at_limit = definition(Enum.map(1..50, fn _ -> stop_node() end))
      assert Definition.node_count(at_limit) == 50
      assert {:ok, _decoded} = round_trip(at_limit)

      # A root list past the limit is refused while it is still a document,
      # by the sequence bound, before any structure is built from it.
      past_limit = definition(Enum.map(1..51, fn _ -> stop_node() end))
      assert {:error, %Error{code: :invalid_definition} = error} = round_trip(past_limit)
      assert [%{path: "/steps", reason: :too_many_items}] = error.details.issues
    end

    test "refuses a node count past the limit that no single sequence reaches" do
      # Twenty-six conditions, each holding one step: fifty-two nodes, and no
      # sequence longer than twenty-six.
      steps = Enum.map(1..26, fn _ -> condition_node(if_true: [stop_node()]) end)
      definition = definition(steps)

      assert Definition.node_count(definition) == 52
      assert {:error, %Error{code: :too_many_nodes}} = round_trip(definition)
    end

    test "counts nodes inside branches" do
      definition = definition([condition_node(if_true: [message_node(), stop_node()])])

      assert Definition.node_count(definition) == 3
      assert length(Definition.node_ids(definition)) == 3
    end

    test "an empty definition has depth zero and a flat one has depth one" do
      assert Definition.depth(definition([])) == 0
      assert Definition.depth(definition([stop_node(), stop_node()])) == 1
    end
  end

  describe "fetch_node/2" do
    test "finds a node nested inside a branch" do
      id = uuid()

      definition =
        definition([condition_node(if_false: [approval_node(rejected: [stop_node(id: id)])])])

      assert {:ok, %Node{id: ^id, type: :stop}} = Definition.fetch_node(definition, id)
      assert :error = Definition.fetch_node(definition, uuid())
    end
  end

  describe "atom safety" do
    test "malformed documents never grow the atom table" do
      # Warm every code path first, so that the atoms a module creates when it
      # is loaded are already there when the count is taken. The measured set
      # is generated from a different seed, so every string in it is one this
      # process has never seen.
      Enum.each(fuzz_payloads(200, {17, 23, 42}), &Definition.decode/1)

      before_count = :erlang.system_info(:atom_count)

      results = Enum.map(fuzz_payloads(200, {99, 7, 5}), &Definition.decode/1)

      assert :erlang.system_info(:atom_count) == before_count
      assert Enum.all?(results, &match?({:error, %Error{}}, &1))
    end

    test "a document full of unseen strings creates no atoms" do
      raw = %{
        "schema_version" => 1,
        "trigger" => %{
          "id" => uuid(),
          "type" => "definitely_not_a_trigger_type_#{System.unique_integer([:positive])}",
          "config" => %{"unseen_key_#{System.unique_integer([:positive])}" => "value"}
        },
        "steps" => [
          %{
            "id" => uuid(),
            "type" => "unseen_node_type_#{System.unique_integer([:positive])}",
            "config" => %{}
          }
        ]
      }

      before_count = :erlang.system_info(:atom_count)
      assert {:error, %Error{}} = Definition.decode(raw)
      assert :erlang.system_info(:atom_count) == before_count
    end
  end

  defp round_trip(definition) do
    definition
    |> Definition.encode()
    |> Jason.encode!()
    |> Jason.decode!()
    |> Definition.decode()
  end

  defp encoded_with_step, do: definition([message_node()]) |> Definition.encode()

  defp uuid, do: Ecto.UUID.generate()

  defp nest(1), do: [stop_node()]
  defp nest(level), do: [condition_node(if_true: nest(level - 1))]

  # A deterministic generator: the same seed gives the same 200 documents, so a
  # failure here is reproducible rather than a story about a bad afternoon.
  defp fuzz_payloads(count, seed) do
    :rand.seed(:exsss, seed)

    Enum.map(1..count, fn index -> fuzz_value(index, 0) end)
  end

  defp fuzz_value(index, depth) when depth > 3, do: "leaf-#{index}"

  defp fuzz_value(index, depth) do
    case rem(:rand.uniform(1000) + index, 8) do
      0 -> "string-#{:rand.uniform(1_000_000)}"
      1 -> :rand.uniform(1_000_000)
      2 -> [fuzz_value(index, depth + 1), fuzz_value(index + 1, depth + 1)]
      3 -> %{"schema_version" => :rand.uniform(9), "steps" => fuzz_value(index, depth + 1)}
      4 -> %{"type" => "type-#{:rand.uniform(1_000_000)}", "id" => "id-#{:rand.uniform(999)}"}
      5 -> %{"trigger" => fuzz_value(index, depth + 1), "schema_version" => 1}
      6 -> %{"steps" => [fuzz_value(index, depth + 1)], "schema_version" => 1, "trigger" => nil}
      _ -> %{"key-#{:rand.uniform(1_000_000)}" => fuzz_value(index, depth + 1)}
    end
  end
end
