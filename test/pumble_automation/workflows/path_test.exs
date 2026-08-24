defmodule PumbleAutomation.Workflows.PathTest do
  @moduledoc """
  Compiler-produced paths resolve against a JSON tree, or fail with a typed
  error that names the path and never the value.
  """

  # Not async: the atom-safety test reads the global atom count.
  use ExUnit.Case, async: false

  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Context
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Workflows.Limits
  alias PumbleAutomation.Workflows.Path

  @node_id "6f1b3c1e-1f2a-4c3d-8e4f-5a6b7c8d9e0f"

  describe "from_compiled/1" do
    test "a trigger path is the root plus its segments" do
      assert {:ok, ["trigger", "data", "text"]} =
               Path.from_compiled(%{"root" => "trigger", "path" => ["data", "text"]})
    end

    test "a step path inserts the output segment the compiler omitted" do
      assert {:ok, ["steps", @node_id, "output", "ticket_id"]} =
               Path.from_compiled(%{
                 "root" => "steps",
                 "node_id" => @node_id,
                 "path" => ["ticket_id"]
               })
    end

    test "a whole step output is the path that stops at output" do
      assert {:ok, ["steps", @node_id, "output"]} =
               Path.from_compiled(%{"root" => "steps", "node_id" => @node_id, "path" => []})
    end

    test "execution, workspace, and actor are documented metadata roots" do
      assert {:ok, ["execution", "id"]} =
               Path.from_compiled(%{"root" => "execution", "path" => ["id"]})

      assert {:ok, ["workspace", "id"]} =
               Path.from_compiled(%{"root" => "workspace", "path" => ["id"]})

      assert {:ok, ["actor", "id"]} =
               Path.from_compiled(%{"root" => "actor", "path" => ["id"]})
    end

    test "a secret is not a general context path" do
      assert {:error, %Error{class: :validation, code: :secret_not_in_context}} =
               Path.from_compiled(%{"root" => "secret", "name" => "API_TOKEN"})
    end

    test "an unknown root is refused" do
      assert {:error, %Error{code: :unknown_root}} =
               Path.from_compiled(%{"root" => "message", "path" => ["text"]})
    end

    test "a list index in the compiled path is kept as an integer" do
      assert {:ok, ["trigger", "items", 0, "name"]} =
               Path.from_compiled(%{"root" => "trigger", "path" => ["items", 0, "name"]})
    end
  end

  describe "roots" do
    test "every documented data root resolves" do
      tree = %{
        "trigger" => %{"text" => "hello"},
        "steps" => %{@node_id => %{"output" => %{"ticket_id" => "T-1"}}},
        "execution" => %{"id" => "run-1", "run_mode" => "live"},
        "workspace" => %{"id" => "W-1"},
        "actor" => %{"id" => "U-1"}
      }

      assert Path.resolve(%{"root" => "trigger", "path" => ["text"]}, tree) == {:ok, "hello"}

      assert Path.resolve(
               %{"root" => "steps", "node_id" => @node_id, "path" => ["ticket_id"]},
               tree
             ) == {:ok, "T-1"}

      assert Path.resolve(%{"root" => "execution", "path" => ["id"]}, tree) == {:ok, "run-1"}
      assert Path.resolve(%{"root" => "execution", "path" => ["run_mode"]}, tree) == {:ok, "live"}
      assert Path.resolve(%{"root" => "workspace", "path" => ["id"]}, tree) == {:ok, "W-1"}
      assert Path.resolve(%{"root" => "actor", "path" => ["id"]}, tree) == {:ok, "U-1"}
    end

    test "a whole step output is the map under output" do
      tree = %{"steps" => %{@node_id => %{"output" => %{"ticket_id" => "T-1"}}}}

      assert Path.resolve(["steps", @node_id, "output"], tree) ==
               {:ok, %{"ticket_id" => "T-1"}}
    end

    test "a root on its own is not a value" do
      tree = %{"trigger" => %{"text" => "hello"}}

      assert {:error, %Error{code: :invalid_segment, details: %{path: "trigger"}}} =
               Path.resolve(["trigger"], tree)
    end
  end

  describe "missing versus null" do
    test "a present null is a value" do
      tree = %{"trigger" => %{"text" => nil}}

      assert Path.resolve(["trigger", "text"], tree) == {:ok, nil}
    end

    test "an absent key is missing, not null" do
      tree = %{"trigger" => %{}}

      assert {:error, %Error{code: :path_missing, details: %{path: "trigger.text"}}} =
               Path.resolve(["trigger", "text"], tree)
    end

    test "descending into null is a type error, not missing" do
      tree = %{"trigger" => %{"data" => nil}}

      assert {:error, %Error{code: :path_type_mismatch, details: %{path: "trigger.data.text"}}} =
               Path.resolve(["trigger", "data", "text"], tree)
    end

    test "a missing parent is missing at the parent, not the child" do
      tree = %{"trigger" => %{}}

      assert {:error, %Error{code: :path_missing, details: %{path: "trigger.data"}}} =
               Path.resolve(["trigger", "data", "text"], tree)
    end
  end

  describe "list indices" do
    test "a bounded index reads that element" do
      tree = %{"trigger" => %{"items" => [%{"name" => "a"}, %{"name" => "b"}]}}

      assert Path.resolve(["trigger", "items", 1, "name"], tree) == {:ok, "b"}
    end

    test "index zero is the first element" do
      tree = %{"trigger" => %{"items" => ["only"]}}

      assert Path.resolve(["trigger", "items", 0], tree) == {:ok, "only"}
    end

    test "a nil list element is null, not missing" do
      tree = %{"trigger" => %{"items" => [nil]}}

      assert Path.resolve(["trigger", "items", 0], tree) == {:ok, nil}
    end

    test "an index past the end is missing" do
      tree = %{"trigger" => %{"items" => ["a"]}}

      assert {:error, %Error{code: :path_missing, details: %{path: "trigger.items.1"}}} =
               Path.resolve(["trigger", "items", 1], tree)
    end

    test "a negative index is not a segment" do
      tree = %{"trigger" => %{"items" => ["a"]}}

      assert {:error, %Error{code: :invalid_segment, details: %{path: "trigger.items.-1"}}} =
               Path.resolve(["trigger", "items", -1], tree)
    end

    test "an integer on a map is a type error" do
      tree = %{"trigger" => %{"data" => %{"0" => "no"}}}

      assert {:error, %Error{code: :path_type_mismatch, details: %{path: "trigger.data.0"}}} =
               Path.resolve(["trigger", "data", 0], tree)
    end

    test "a string on a list is a type error" do
      tree = %{"trigger" => %{"items" => [%{"name" => "a"}]}}

      assert {:error, %Error{code: :path_type_mismatch, details: %{path: "trigger.items.name"}}} =
               Path.resolve(["trigger", "items", "name"], tree)
    end
  end

  describe "refusals of internal state" do
    test "a struct is not traversed" do
      tree = %{"trigger" => DateTime.utc_now()}

      assert {:error, %Error{code: :path_type_mismatch, details: %{path: "trigger.year"}}} =
               Path.resolve(["trigger", "year"], tree)
    end

    test "a PID is not a value" do
      tree = %{"trigger" => %{"pid" => self()}}

      assert {:error, %Error{code: :path_type_mismatch, details: %{path: "trigger.pid"}}} =
               Path.resolve(["trigger", "pid"], tree)
    end

    test "a function is not a value" do
      tree = %{"trigger" => %{"fun" => fn -> :secret end}}

      assert {:error, %Error{code: :path_type_mismatch, details: %{path: "trigger.fun"}}} =
               Path.resolve(["trigger", "fun"], tree)
    end

    test "an atom other than a JSON scalar is not a value" do
      tree = %{"trigger" => %{"status" => :running}}

      assert {:error, %Error{code: :path_type_mismatch, details: %{path: "trigger.status"}}} =
               Path.resolve(["trigger", "status"], tree)
    end

    test "booleans and numbers are values" do
      tree = %{"trigger" => %{"ok" => true, "count" => 3, "ratio" => 1.5, "off" => false}}

      assert Path.resolve(["trigger", "ok"], tree) == {:ok, true}
      assert Path.resolve(["trigger", "off"], tree) == {:ok, false}
      assert Path.resolve(["trigger", "count"], tree) == {:ok, 3}
      assert Path.resolve(["trigger", "ratio"], tree) == {:ok, 1.5}
    end

    test "an atom-keyed map is not read through a user segment" do
      tree = %{"trigger" => %{text: "hidden"}}

      assert {:error, %Error{code: :path_missing, details: %{path: "trigger.text"}}} =
               Path.resolve(["trigger", "text"], tree)
    end

    test "a struct-field segment is refused before lookup" do
      tree = %{"trigger" => %{"__struct__" => "Elixir.Nope"}}

      assert {:error, %Error{code: :invalid_segment, details: %{path: "trigger.__struct__"}}} =
               Path.resolve(["trigger", "__struct__"], tree)
    end

    test "an atom as a segment creates no lookup" do
      tree = %{"trigger" => %{"text" => "hello"}}

      assert {:error, %Error{code: :invalid_segment}} =
               Path.resolve(["trigger", :text], tree)
    end
  end

  describe "maximum path length" do
    test "a path at the limit still resolves" do
      limit = Limits.max_path_segments()
      rest = Enum.map(2..limit, &"a#{&1}")

      nested =
        rest
        |> Enum.reverse()
        |> Enum.reduce("leaf", fn key, inner -> %{key => inner} end)

      segments = ["trigger" | rest]

      assert length(segments) == limit
      assert Path.resolve(segments, %{"trigger" => nested}) == {:ok, "leaf"}
    end

    test "one segment past the limit is refused without walking" do
      limit = Limits.max_path_segments()
      segments = ["trigger" | Enum.map(2..(limit + 1), &"a#{&1}")]

      assert {:error, %Error{code: :path_too_long}} = Path.resolve(segments, %{})
    end
  end

  describe "atom table safety" do
    test "unseen segment names create no atoms" do
      tree = %{"trigger" => %{}}
      Enum.each(paths({11, 13, 17}), &Path.resolve(&1, tree))

      before_count = :erlang.system_info(:atom_count)
      results = Enum.map(paths({23, 29, 31}), &Path.resolve(&1, tree))

      assert :erlang.system_info(:atom_count) == before_count
      assert Enum.all?(results, &match?({:error, %Error{}}, &1))
    end
  end

  describe "determinism and safety" do
    test "the same path and tree produce the same answer" do
      tree = %{"trigger" => %{"text" => "hello"}}

      assert Path.resolve(["trigger", "text"], tree) ==
               Path.resolve(["trigger", "text"], tree)
    end

    test "errors name the path and never interpolate a value" do
      tree = %{"trigger" => %{"text" => "classified"}}

      assert {:error, %Error{message: message, details: details}} =
               Path.resolve(["trigger", "missing"], tree)

      refute String.contains?(message, "classified")
      refute details |> inspect() |> String.contains?("classified")
      assert details.path == "trigger.missing"
    end

    test "resolution does not raise on garbage" do
      assert {:error, %Error{}} = Path.resolve(nil, %{})
      assert {:error, %Error{}} = Path.resolve(%{}, %{})
      assert {:error, %Error{}} = Path.resolve(["trigger", "x"], nil)
      assert {:error, %Error{}} = Path.resolve(["trigger", make_ref()], %{"trigger" => %{}})
    end
  end

  describe "Executions.Context" do
    test "the tree exposes only documented roots" do
      tree =
        Context.tree(%{
          context: %{
            "execution" => %{"id" => "run-1", "run_mode" => "dry_run", "lock_version" => 9},
            "workspace" => %{"id" => "W-1", "token" => "nope"},
            "actor" => %{"id" => "U-1"},
            "credentials" => %{"bot" => "secret"},
            "steps" => %{@node_id => %{"output" => %{"ok" => true}, "attempt" => 3}}
          },
          trigger_snapshot: %{"text" => "hi", "actor_id" => "U-1"}
        })

      assert Map.keys(tree) |> Enum.sort() ==
               ["actor", "execution", "steps", "trigger", "workspace"]

      assert tree["execution"] == %{"id" => "run-1", "run_mode" => "dry_run"}
      assert tree["workspace"] == %{"id" => "W-1"}
      assert tree["actor"] == %{"id" => "U-1"}
      assert tree["trigger"] == %{"text" => "hi", "actor_id" => "U-1"}
      assert tree["steps"] == %{@node_id => %{"output" => %{"ok" => true}}}
      refute Map.has_key?(tree, "credentials")
    end

    test "an execution row is read through the same allowlist" do
      execution = %Execution{
        context: %{"execution" => %{"id" => "run-2", "run_mode" => "live"}},
        trigger_snapshot: %{"channel_id" => "C-1"}
      }

      tree = Context.tree(execution)

      assert Path.resolve(["execution", "id"], tree) == {:ok, "run-2"}
      assert Path.resolve(["trigger", "channel_id"], tree) == {:ok, "C-1"}
    end

    test "structs, PIDs, and functions are stripped from the tree" do
      tree =
        Context.tree(%{
          context: %{"execution" => %{"id" => "run-3", "run_mode" => "live", "pid" => self()}},
          trigger_snapshot: %{
            "when" => DateTime.utc_now(),
            "fun" => fn -> :no end,
            "text" => "ok"
          }
        })

      assert tree["trigger"] == %{"text" => "ok"}
      assert tree["execution"] == %{"id" => "run-3", "run_mode" => "live"}
    end

    test "a path through the context tree does not see a secret root" do
      tree =
        Context.tree(%{
          context: %{"secret" => %{"API_TOKEN" => "leak"}},
          trigger_snapshot: %{}
        })

      assert {:error, %Error{code: :secret_not_in_context}} =
               Path.resolve(["secret", "API_TOKEN"], tree)

      refute Map.has_key?(tree, "secret")
    end
  end

  defp paths(seed) do
    :rand.seed(:exsss, seed)

    Enum.map(1..200, fn index ->
      [
        "trigger"
        | Enum.map(1..(rem(index, 4) + 1), fn _part -> "Unseen#{:rand.uniform(1_000_000)}" end)
      ]
    end)
  end
end
