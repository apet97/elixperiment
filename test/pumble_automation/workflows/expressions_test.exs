defmodule PumbleAutomation.Workflows.ExpressionsTest do
  # Not async: the atom safety test reads the global atom count, and a
  # concurrent test that creates an atom would make it flap.
  use ExUnit.Case, async: false

  alias PumbleAutomation.Workflows.Expressions
  alias PumbleAutomation.Workflows.Limits

  @node_id "6f1b3c1e-1f2a-4c3d-8e4f-5a6b7c8d9e0f"

  describe "roots" do
    test "the five data roots and the secret root parse" do
      assert {:ok, {:trigger, ["message_id"]}} = Expressions.parse("trigger.message_id")
      assert {:ok, {:context, :execution, ["id"]}} = Expressions.parse("execution.id")
      assert {:ok, {:context, :workspace, ["name"]}} = Expressions.parse("workspace.name")
      assert {:ok, {:context, :actor, ["id"]}} = Expressions.parse("actor.id")
      assert {:ok, {:secret, "API_TOKEN"}} = Expressions.parse("secret.API_TOKEN")

      assert {:ok, {:step, @node_id, []}} = Expressions.parse("steps.#{@node_id}.output")
    end

    test "refuses a root that is not one of them" do
      assert Expressions.parse("message.text") == {:error, :unknown_root}
      assert Expressions.parse("secrets.API_TOKEN") == {:error, :unknown_root}
      assert Expressions.parse("Trigger.text") == {:error, :unknown_root}
    end

    test "refuses a root on its own" do
      assert Expressions.parse("trigger") == {:error, :invalid_segment}
      assert Expressions.parse("execution") == {:error, :invalid_segment}
    end

    test "refuses an empty path" do
      assert Expressions.parse("") == {:error, :empty_path}
      assert Expressions.parse(nil) == {:error, :empty_path}
      assert Expressions.parse(42) == {:error, :empty_path}
    end
  end

  describe "segments" do
    test "accepts nested snake_case names" do
      assert {:ok, {:trigger, ["data", "thread_root_id"]}} =
               Expressions.parse("trigger.data.thread_root_id")
    end

    test "refuses a name that could reach into a struct" do
      assert Expressions.parse("trigger.__struct__") == {:error, :invalid_segment}
      assert Expressions.parse("trigger.data.__info__") == {:error, :invalid_segment}
    end

    test "refuses upper case, punctuation, and a leading digit" do
      assert Expressions.parse("trigger.Data") == {:error, :invalid_segment}
      assert Expressions.parse("trigger.data-text") == {:error, :invalid_segment}
      assert Expressions.parse("trigger.data text") == {:error, :invalid_segment}
      assert Expressions.parse("trigger.1data") == {:error, :invalid_segment}
      assert Expressions.parse("trigger.data[0]") == {:error, :invalid_segment}
    end

    test "refuses an empty segment" do
      assert Expressions.parse("trigger..text") == {:error, :invalid_segment}
      assert Expressions.parse("trigger.") == {:error, :invalid_segment}
    end

    test "refuses a path with more segments than the limit" do
      limit = Limits.max_path_segments()
      at_limit = Enum.map_join(["trigger" | Enum.map(2..limit, &"a#{&1}")], ".", & &1)

      assert {:ok, _parsed} = Expressions.parse(at_limit)
      assert Expressions.parse(at_limit <> ".over") == {:error, :path_too_long}
    end
  end

  describe "step references" do
    test "carries the subpath below output" do
      assert {:ok, {:step, @node_id, ["ticket_id"]}} =
               Expressions.parse("steps.#{@node_id}.output.ticket_id")
    end

    test "refuses an identifier that is not a UUID" do
      assert Expressions.parse("steps.not-a-uuid.output") == {:error, :invalid_step_reference}
    end

    test "refuses a reference that does not name output" do
      assert Expressions.parse("steps.#{@node_id}") == {:error, :invalid_step_reference}
      assert Expressions.parse("steps.#{@node_id}.config") == {:error, :invalid_step_reference}
      assert Expressions.parse("steps") == {:error, :invalid_step_reference}
    end
  end

  describe "secret references" do
    test "uses the same grammar a stored secret name obeys" do
      assert {:ok, {:secret, "A"}} = Expressions.parse("secret.A")
      assert {:ok, {:secret, "API_TOKEN_2"}} = Expressions.parse("secret.API_TOKEN_2")
    end

    test "refuses a name that is not one" do
      assert Expressions.parse("secret.api_token") == {:error, :invalid_secret_name}
      assert Expressions.parse("secret.2TOKEN") == {:error, :invalid_secret_name}
      assert Expressions.parse("secret.API.TOKEN") == {:error, :invalid_secret_name}
      assert Expressions.parse("secret") == {:error, :invalid_secret_name}
    end
  end

  describe "determinism and atom safety" do
    test "the same path parses to the same term" do
      assert Expressions.parse("trigger.data.text") == Expressions.parse("trigger.data.text")
    end

    test "paths full of unseen names create no atoms" do
      # Warm the code paths first, so that the atoms loading a module creates
      # are already there when the count is taken.
      Enum.each(paths({11, 13, 17}), &Expressions.parse/1)

      before_count = :erlang.system_info(:atom_count)
      results = Enum.map(paths({23, 29, 31}), &Expressions.parse/1)

      assert :erlang.system_info(:atom_count) == before_count
      assert Enum.all?(results, &match?({:error, _reason}, &1))
    end
  end

  defp paths(seed) do
    :rand.seed(:exsss, seed)

    Enum.map(1..200, fn index ->
      Enum.map_join(1..(rem(index, 4) + 1), ".", fn _part ->
        "Unseen#{:rand.uniform(1_000_000)}"
      end)
    end)
  end
end
