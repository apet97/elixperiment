defmodule PumbleAutomation.Workflows.EditorTest do
  use ExUnit.Case, async: true

  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Error
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Editor
  alias PumbleAutomation.Workflows.Node

  describe "insertion" do
    test "add_before and add_after place a node in the root sequence" do
      first = stop_node()
      second = stop_node()
      definition = definition([first, second])
      inserted = message_node()

      assert {:ok, before} = Editor.add_before(definition, second.id, inserted)
      assert ids(before.steps) == [first.id, inserted.id, second.id]

      assert {:ok, after_} = Editor.add_after(definition, first.id, inserted)
      assert ids(after_.steps) == [first.id, inserted.id, second.id]
    end

    test "add_after places a node inside the branch that holds its target" do
      target = stop_node()
      condition = condition_node(if_true: [target])
      definition = definition([condition])
      inserted = message_node()

      assert {:ok, updated} = Editor.add_after(definition, target.id, inserted)
      assert [%Node{} = updated_condition] = updated.steps
      assert ids(Node.branch(updated_condition, :if_true)) == [target.id, inserted.id]
      assert Node.branch(updated_condition, :if_false) == []
    end

    test "append adds to the end of an addressed sequence" do
      condition = condition_node(if_true: [stop_node()])
      definition = definition([condition])
      inserted = delay_node()

      assert {:ok, updated} = Editor.append(definition, {condition.id, :if_false}, inserted)
      assert ids(Node.branch(hd(updated.steps), :if_false)) == [inserted.id]

      assert {:ok, at_root} = Editor.append(definition, :root, inserted)
      assert ids(at_root.steps) == [condition.id, inserted.id]
    end

    test "append reaches every approval branch" do
      approval = approval_node()
      definition = definition([approval])

      for branch <- [:approved, :rejected, :timed_out] do
        node = stop_node()
        assert {:ok, updated} = Editor.append(definition, {approval.id, branch}, node)
        assert ids(Node.branch(hd(updated.steps), branch)) == [node.id]
      end
    end

    test "insert_at places a node at a position, and refuses one outside the sequence" do
      first = stop_node()
      definition = definition([first])
      inserted = delay_node()

      assert {:ok, updated} = Editor.insert_at(definition, :root, 0, inserted)
      assert ids(updated.steps) == [inserted.id, first.id]

      assert {:ok, appended} = Editor.insert_at(definition, :root, 1, inserted)
      assert ids(appended.steps) == [first.id, inserted.id]

      assert {:error, %Error{code: :invalid_index}} =
               Editor.insert_at(definition, :root, 2, inserted)

      assert {:error, %Error{code: :invalid_index}} =
               Editor.insert_at(definition, :root, -1, inserted)
    end
  end

  describe "addressing failures" do
    setup do
      condition = condition_node()
      %{definition: definition([condition]), condition: condition}
    end

    test "an unknown node identifier is a typed error", %{definition: definition} do
      unknown = Ecto.UUID.generate()

      assert {:error, %Error{class: :not_found, code: :node_not_found}} =
               Editor.add_after(definition, unknown, stop_node())

      assert {:error, %Error{code: :node_not_found}} =
               Editor.update_config(definition, unknown, %{})

      assert {:error, %Error{code: :node_not_found}} = Editor.delete(definition, unknown)
      assert {:error, %Error{code: :node_not_found}} = Editor.address_of(definition, unknown)
    end

    test "a branch the node does not own is a typed error", %{
      definition: definition,
      condition: condition
    } do
      assert {:error, %Error{class: :not_found, code: :branch_not_found}} =
               Editor.append(definition, {condition.id, :approved}, stop_node())
    end

    test "a malformed address is a typed error", %{definition: definition} do
      assert {:error, %Error{code: :invalid_address}} =
               Editor.append(definition, "not-an-address", stop_node())
    end
  end

  describe "update_config/3" do
    test "merges the fields it is given and leaves the rest" do
      node = message_node()
      definition = definition([node])

      assert {:ok, updated} = Editor.update_config(definition, node.id, %{text: "goodbye"})
      assert [%Node{id: id, config: config}] = updated.steps
      assert id == node.id
      assert config.text == "goodbye"
      assert config.channel_id == "channel-1"
      assert config.action == :send_message
    end

    test "accepts a whole configuration struct of the right type" do
      node = delay_node()
      definition = definition([node])
      replacement = %PumbleAutomation.Workflows.Node.DelayConfig{duration_seconds: 900}

      assert {:ok, updated} = Editor.update_config(definition, node.id, replacement)
      assert [%Node{config: ^replacement}] = updated.steps
    end

    test "refuses a field the configuration does not have" do
      node = delay_node()
      definition = definition([node])

      assert {:error, %Error{code: :unknown_config_field}} =
               Editor.update_config(definition, node.id, %{duration_minutes: 5})
    end

    test "refuses a configuration struct of another type" do
      node = delay_node()
      definition = definition([node])
      wrong = %PumbleAutomation.Workflows.Node.StopConfig{reason: "no"}

      assert {:error, %Error{code: :invalid_config}} =
               Editor.update_config(definition, node.id, wrong)
    end

    test "updates a node nested inside a branch" do
      nested = message_node()
      condition = condition_node(if_false: [nested])
      definition = definition([condition])

      assert {:ok, updated} = Editor.update_config(definition, nested.id, %{text: "nested"})
      assert [%Node{config: config}] = Node.branch(hd(updated.steps), :if_false)
      assert config.text == "nested"
    end
  end

  describe "reorder/4" do
    setup do
      nodes = Enum.map(1..3, fn _ -> stop_node() end)
      %{definition: definition(nodes), nodes: nodes}
    end

    test "moves one step inside its sequence", %{definition: definition, nodes: [a, b, c]} do
      assert {:ok, updated} = Editor.reorder(definition, :root, 0, 2)
      assert ids(updated.steps) == [b.id, c.id, a.id]

      assert {:ok, back} = Editor.reorder(updated, :root, 2, 0)
      assert ids(back.steps) == ids(definition.steps)
    end

    test "refuses a position outside the sequence", %{definition: definition} do
      assert {:error, %Error{code: :invalid_index}} = Editor.reorder(definition, :root, 0, 3)
      assert {:error, %Error{code: :invalid_index}} = Editor.reorder(definition, :root, 5, 0)
    end

    test "reorders inside a branch" do
      [a, b] = [stop_node(), delay_node()]
      condition = condition_node(if_true: [a, b])
      definition = definition([condition])

      assert {:ok, updated} = Editor.reorder(definition, {condition.id, :if_true}, 1, 0)
      assert ids(Node.branch(hd(updated.steps), :if_true)) == [b.id, a.id]
    end
  end

  describe "move/4" do
    test "moves a node from the root into a branch, keeping its subtree" do
      leaf = stop_node()
      moved = approval_node(approved: [leaf])
      condition = condition_node()
      definition = definition([moved, condition])

      assert {:ok, updated} = Editor.move(definition, moved.id, {condition.id, :if_true})
      assert ids(updated.steps) == [condition.id]
      assert [%Node{id: moved_id} = landed] = Node.branch(hd(updated.steps), :if_true)
      assert moved_id == moved.id
      assert ids(Node.branch(landed, :approved)) == [leaf.id]
      assert Definition.node_count(updated) == Definition.node_count(definition)
    end

    test "moves a node out of a branch back to the root, at a position" do
      nested = stop_node()
      condition = condition_node(if_true: [nested])
      definition = definition([condition])

      assert {:ok, updated} = Editor.move(definition, nested.id, :root, 0)
      assert ids(updated.steps) == [nested.id, condition.id]
      assert Node.branch(List.last(updated.steps), :if_true) == []
    end

    test "refuses a move into the subtree of the node being moved" do
      inner = condition_node()
      outer = condition_node(if_true: [inner])
      definition = definition([outer])

      assert {:error, %Error{code: :invalid_move}} =
               Editor.move(definition, outer.id, {inner.id, :if_true})
    end

    test "refuses a position outside the target sequence" do
      node = stop_node()
      definition = definition([node, stop_node()])

      assert {:error, %Error{code: :invalid_index}} = Editor.move(definition, node.id, :root, 9)
    end
  end

  describe "delete/2" do
    test "removes a leaf and reports what went" do
      keep = stop_node()
      remove = message_node()
      definition = definition([keep, remove])

      assert {:ok, updated, metadata} = Editor.delete(definition, remove.id)
      assert ids(updated.steps) == [keep.id]

      assert metadata == %{
               deleted_node_ids: [remove.id],
               deleted_count: 1,
               owned_branches?: false
             }
    end

    test "removes a subtree and flags that the node owned branches" do
      grandchild = stop_node()
      child = approval_node(timed_out: [grandchild])
      condition = condition_node(if_true: [child], if_false: [message_node()])
      definition = definition([condition, stop_node()])

      assert {:ok, updated, metadata} = Editor.delete(definition, condition.id)
      assert Definition.node_count(updated) == 1
      assert metadata.owned_branches?
      assert metadata.deleted_count == 4
      assert condition.id in metadata.deleted_node_ids
      assert grandchild.id in metadata.deleted_node_ids
    end

    test "removes a node nested two branches deep" do
      leaf = stop_node()
      inner = approval_node(rejected: [leaf])
      outer = condition_node(if_false: [inner])
      definition = definition([outer])

      assert {:ok, updated, metadata} = Editor.delete(definition, leaf.id)
      assert metadata.deleted_count == 1
      refute metadata.owned_branches?
      assert Definition.node_count(updated) == 2

      assert [%Node{} = kept_inner] = Node.branch(hd(updated.steps), :if_false)
      assert Node.branch(kept_inner, :rejected) == []
    end

    test "deletion_metadata/2 answers without changing anything" do
      child = stop_node()
      condition = condition_node(if_true: [child])
      definition = definition([condition])

      assert {:ok, metadata} = Editor.deletion_metadata(definition, condition.id)
      assert metadata.owned_branches?
      assert metadata.deleted_count == 2
      assert Definition.node_count(definition) == 2
    end
  end

  describe "limits" do
    test "an insertion that would pass the node limit is refused" do
      definition = definition(Enum.map(1..50, fn _ -> stop_node() end))
      assert Definition.node_count(definition) == 50

      assert {:error, %Error{class: :validation, code: :too_many_nodes}} =
               Editor.append(definition, :root, stop_node())

      assert {:error, %Error{code: :too_many_nodes}} =
               Editor.add_before(definition, hd(definition.steps).id, stop_node())
    end

    test "an insertion that would pass the depth limit is refused" do
      {steps, innermost} = deep_chain(8)
      definition = definition(steps)
      assert Definition.depth(definition) == 8

      assert {:error, %Error{class: :validation, code: :branch_too_deep}} =
               Editor.append(definition, {innermost, :if_true}, stop_node())
    end

    test "an insertion one level short of the depth limit is allowed" do
      {steps, innermost} = deep_chain(7)
      definition = definition(steps)

      assert {:ok, updated} = Editor.append(definition, {innermost, :if_true}, stop_node())
      assert Definition.depth(updated) == 8
    end

    test "a move that would pass the depth limit is refused" do
      {steps, innermost} = deep_chain(8)
      moved = stop_node()
      definition = definition(steps ++ [moved])

      assert {:error, %Error{code: :branch_too_deep}} =
               Editor.move(definition, moved.id, {innermost, :if_true})
    end

    test "a refused operation leaves the definition it was given untouched" do
      definition = definition(Enum.map(1..50, fn _ -> stop_node() end))
      encoded = Definition.encode(definition)

      assert {:error, %Error{}} = Editor.append(definition, :root, stop_node())
      assert Definition.encode(definition) == encoded
    end
  end

  describe "determinism" do
    test "the same edit on the same definition gives the same result" do
      definition = definition([condition_node(if_true: [stop_node()]), delay_node()])
      inserted = message_node()

      assert Editor.append(definition, :root, inserted) ==
               Editor.append(definition, :root, inserted)
    end

    test "an edit leaves every other identifier and order alone" do
      untouched = Enum.map(1..3, fn _ -> stop_node() end)
      condition = condition_node(if_true: untouched)
      definition = definition([condition, delay_node()])

      assert {:ok, updated} = Editor.append(definition, {condition.id, :if_false}, message_node())

      assert ids(Node.branch(hd(updated.steps), :if_true)) == ids(untouched)
      assert ids(updated.steps) == ids(definition.steps)
    end
  end

  describe "structural invariants under random editing" do
    test "one hundred random operation sequences preserve every invariant" do
      # A seeded generator loop rather than a property-testing dependency: the
      # seed is fixed, so a failure names an exact sequence to replay.
      :rand.seed(:exsss, {2026, 8, 15})

      Enum.each(1..100, fn _run ->
        Enum.reduce(1..20, definition([stop_node()]), fn _step, definition ->
          before_encoded = Definition.encode(definition)

          case apply_random_operation(definition) do
            {:ok, updated} ->
              assert_invariants(updated)
              updated

            {:ok, updated, metadata} ->
              assert is_list(metadata.deleted_node_ids)
              assert_invariants(updated)
              updated

            {:error, %Error{}} ->
              assert Definition.encode(definition) == before_encoded
              definition
          end
        end)
      end)
    end
  end

  defp apply_random_operation(definition) do
    nodes = Definition.nodes(definition)
    address = random_address(definition, nodes)

    case nodes do
      [] -> Editor.append(definition, address, random_node())
      _ -> definition |> operations(address, Enum.random(nodes)) |> Enum.random() |> apply([])
    end
  end

  defp operations(definition, address, node) do
    [
      fn -> Editor.append(definition, address, random_node()) end,
      fn -> Editor.add_before(definition, node.id, random_node()) end,
      fn -> Editor.add_after(definition, node.id, random_node()) end,
      fn -> Editor.delete(definition, node.id) end,
      fn -> Editor.reorder(definition, address, :rand.uniform(3) - 1, :rand.uniform(3) - 1) end,
      fn -> Editor.move(definition, node.id, address, :last) end,
      fn -> Editor.update_config(definition, node.id, %{}) end
    ]
  end

  defp random_address(_definition, []), do: :root

  defp random_address(_definition, nodes) do
    branching = Enum.filter(nodes, &(Node.branch_keys(&1.type) != []))

    if branching == [] or :rand.uniform(2) == 1 do
      :root
    else
      node = Enum.random(branching)
      {node.id, Enum.random(Node.branch_keys(node.type))}
    end
  end

  defp random_node do
    case :rand.uniform(5) do
      1 -> condition_node()
      2 -> approval_node()
      3 -> delay_node()
      4 -> message_node()
      _ -> stop_node()
    end
  end

  defp assert_invariants(definition) do
    node_ids = Definition.node_ids(definition)

    assert node_ids == Enum.uniq(node_ids)
    assert Definition.node_count(definition) <= 50
    assert Definition.depth(definition) <= 8
    assert {:ok, ^definition} = definition |> Definition.encode() |> Definition.decode()
  end

  defp ids(nodes), do: Enum.map(nodes, & &1.id)

  # A chain of conditions nested `level` deep, with the identifier of the
  # innermost one, so a test can reach the deepest branch by address.
  defp deep_chain(1) do
    node = condition_node()
    {[node], node.id}
  end

  defp deep_chain(level) do
    {inner, innermost} = deep_chain(level - 1)
    {[condition_node(if_true: inner)], innermost}
  end
end
