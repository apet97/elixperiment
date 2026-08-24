defmodule PumbleAutomation.Workflows.TemplatesTest do
  use ExUnit.Case, async: true

  alias PumbleAutomation.Workflows.Limits
  alias PumbleAutomation.Workflows.Templates

  @node_id "6f1b3c1e-1f2a-4c3d-8e4f-5a6b7c8d9e0f"

  describe "parse/1" do
    test "text with no reference is one literal" do
      assert Templates.parse("Deploy finished") == {[{:literal, "Deploy finished"}], []}
    end

    test "empty text has no segments" do
      assert Templates.parse("") == {[], []}
    end

    test "a reference on its own is one reference" do
      assert {[{:reference, {:trigger, ["data", "text"]}}], []} =
               Templates.parse("{{ trigger.data.text }}")
    end

    test "literals and references keep their order" do
      assert {segments, []} = Templates.parse("A {{ trigger.data.text }} B {{ actor.id }} C")

      assert [
               {:literal, "A "},
               {:reference, {:trigger, ["data", "text"]}},
               {:literal, " B "},
               {:reference, {:context, :actor, ["id"]}},
               {:literal, " C"}
             ] = segments
    end

    test "surrounding whitespace inside a reference is ignored" do
      assert Templates.parse("{{trigger.data.text}}") ==
               Templates.parse("{{   trigger.data.text   }}")
    end

    test "a step reference parses through to its subpath" do
      assert {[{:reference, {:step, @node_id, ["ticket_id"]}}], []} =
               Templates.parse("{{ steps.#{@node_id}.output.ticket_id }}")
    end

    test "anything that is not text parses to nothing, and says so" do
      assert Templates.parse(nil) == {[], [:invalid_type]}
      assert Templates.parse(42) == {[], [:invalid_type]}
    end
  end

  describe "text that only looks like a reference" do
    test "a lone brace is a literal" do
      assert Templates.parse("{ trigger }") == {[{:literal, "{ trigger }"}], []}
    end

    test "a closing pair with no opening pair is a literal" do
      assert Templates.parse("value }} here") == {[{:literal, "value }} here"}], []}
    end
  end

  describe "refusals" do
    test "an opened reference that never closes" do
      assert {_segments, [:unterminated_reference]} =
               Templates.parse("hello {{ trigger.data.text")
    end

    test "an empty reference" do
      assert {[], [:empty_reference]} = Templates.parse("{{}}")
      assert {_segments, [:empty_reference]} = Templates.parse("a {{   }} b")
    end

    test "a reference whose path is not a path" do
      assert {[], [:unknown_root]} = Templates.parse("{{ message.text }}")
      assert {[], [:invalid_segment]} = Templates.parse("{{ trigger.Data }}")
    end

    test "every reason is reported once, in the order it was met" do
      assert {_segments, [:unknown_root, :invalid_segment]} =
               Templates.parse("{{ message.text }} {{ trigger.Data }} {{ other.thing }}")
    end

    test "the scanner keeps going after a bad reference" do
      assert {_segments, [:unknown_root, :empty_reference]} =
               Templates.parse("{{ bad.root }} {{ }}")
    end

    # The reason a template must report both halves: an author fixing the
    # syntax should not then be told about a reference that was wrong all
    # along, and the validator cannot see the reference unless it is returned.
    test "a reference that parses is kept even when another one does not" do
      assert {segments, [:unterminated_reference]} =
               Templates.parse("{{ actor.id }} then {{ never closed")

      assert Templates.references(segments) == [{:context, :actor, ["id"]}]
    end
  end

  describe "bounds" do
    test "a template may interpolate up to the reference limit" do
      assert {segments, []} = Templates.parse(repeat(Limits.max_template_references()))
      assert length(Templates.references(segments)) == Limits.max_template_references()
    end

    test "one reference over the limit is refused, and expands nothing" do
      assert Templates.parse(repeat(Limits.max_template_references() + 1)) ==
               {[], [:too_many_references]}
    end
  end

  describe "references/1" do
    test "returns the parsed references, in order" do
      assert {segments, []} = Templates.parse("{{ actor.id }} and {{ workspace.name }}")

      assert Templates.references(segments) == [
               {:context, :actor, ["id"]},
               {:context, :workspace, ["name"]}
             ]
    end

    test "returns nothing for text with no reference" do
      assert {segments, []} = Templates.parse("plain")
      assert Templates.references(segments) == []
    end
  end

  defp repeat(count), do: String.duplicate("{{ trigger.data.text }}", count)
end
