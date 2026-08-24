defmodule PumbleAutomation.Executions.Nodes.ConditionTest do
  @moduledoc """
  Condition nodes evaluate typed predicates and take exactly one compiled
  edge. Compared values never appear in the reason summary.
  """

  use ExUnit.Case, async: true

  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.NodeRunner
  alias PumbleAutomation.Executions.Nodes.Condition
  alias PumbleAutomation.Workflows.CompiledWorkflow
  alias PumbleAutomation.Workflows.Compiler
  alias PumbleAutomation.Workflows.Expressions
  alias PumbleAutomation.Workflows.Limits

  describe "compiler-produced conditions" do
    test "the default fixture takes the true edge when the text matches" do
      assert {:ok, outcome} = run_compiled("please deploy")
      assert outcome.kind == :success
      assert outcome.edge == "true"
      assert outcome.output["matched"] == true
      assert outcome.output["combinator"] == "all"
      assert outcome.output["reason"] == "predicates.0.contains"
    end

    test "the default fixture takes the false edge when the text does not match" do
      assert {:ok, outcome} = run_compiled("hello")
      assert outcome.kind == :success
      assert outcome.edge == "false"
      assert outcome.output["matched"] == false
    end

    test "NodeRunner uses the condition node without a stub adapter" do
      assert {:ok, outcome} =
               NodeRunner.run(runner_input(compiled_fixture_config(), %{"text" => "deploy now"}))

      assert outcome.edge == "true"
    end
  end

  describe "operator and type matrix" do
    test "equality and inequality compare matching types only" do
      assert matched?(clause("deploy", "eq", "deploy"))
      refute matched?(clause("deploy", "eq", "ship"))
      assert matched?(clause("deploy", "neq", "ship"))
      assert type_error?(clause("true", "eq", flag_path()), %{"flag" => true})
      assert type_error?(clause(count_path(), "eq", "10"), %{"count" => 10})
    end

    test "ordered numeric literals parse the same way activation does" do
      assert matched?(clause("10", "gt", "2.5"))
      assert matched?(clause("10", "gte", "10"))
      assert matched?(clause("2", "lt", "10"))
      assert matched?(clause("2.5", "lte", "2.5"))
      refute matched?(clause("2", "gt", "10"))
    end

    test "ordered comparisons use JSON numbers from the run without coercing strings" do
      assert matched?(clause(count_path(), "gt", "2"), %{"count" => 10})
      assert type_error?(clause(count_path(), "gt", "2"), %{"count" => "10"})
    end

    test "ordered date and datetime strings compare when both sides are the same kind" do
      assert matched?(clause(text_path(), "lt", "2026-02-01"), %{"text" => "2026-01-01"})

      assert matched?(
               clause(text_path(), "gt", "2026-01-01T00:00:00Z"),
               %{"text" => "2026-01-02T00:00:00Z"}
             )

      assert type_error?(
               clause(text_path(), "gt", "2026-01-01T00:00:00Z"),
               %{"text" => "2026-01-02"}
             )
    end

    test "contains, starts_with, and ends_with are string operators" do
      assert matched?(clause("deploy now", "contains", "deploy"))
      refute matched?(clause("hello", "contains", "deploy"))
      assert matched?(clause("deploy", "starts_with", "dep"))
      assert matched?(clause("deploy", "ends_with", "oy"))
      assert matched?(clause("deploy now", "not_contains", "ship"))
      assert type_error?(clause("deploy", "starts_with", count_path()), %{"count" => 1})
    end

    test "contains on a bounded list is membership, and in is the swapped form" do
      tags = %{"tags" => ["alpha", "beta"]}
      assert matched?(clause(tags_path(), "contains", "beta"), tags)
      refute matched?(clause(tags_path(), "contains", "gamma"), tags)

      refute matched?(
               clause(tags_path(), "contains", count_path()),
               %{"tags" => ["alpha", "beta"], "count" => 1}
             )

      assert matched?(clause("beta", "in", tags_path()), tags)
      refute matched?(clause("gamma", "in", tags_path()), tags)
    end

    test "a list longer than the decode bound is refused" do
      oversized = %{"tags" => Enum.map(1..(Limits.max_list_length() + 1), &Integer.to_string/1)}
      assert too_long?(clause(tags_path(), "contains", "x"), oversized)
      assert too_long?(clause("x", "in", tags_path()), oversized)
    end

    test "booleans and zero are not treated as empty or as true" do
      refute matched?(clause(flag_path(), "is_empty", nil), %{"flag" => false})
      refute matched?(clause(count_path(), "is_empty", nil), %{"count" => 0})
      assert type_error?(clause(flag_path(), "eq", "false"), %{"flag" => false})
    end
  end

  describe "nested logical expressions" do
    test "all requires every comparison, any requires one, none requires zero" do
      assert matched?(group("all", [pred("a", "eq", "a"), pred("b", "eq", "b")]))
      refute matched?(group("all", [pred("a", "eq", "a"), pred("b", "eq", "x")]))
      assert matched?(group("any", [pred("a", "eq", "x"), pred("b", "eq", "b")]))
      refute matched?(group("any", [pred("a", "eq", "x"), pred("b", "eq", "y")]))
      assert matched?(group("none", [pred("a", "eq", "x"), pred("b", "eq", "y")]))
      refute matched?(group("none", [pred("a", "eq", "a")]))
    end

    test "a nested any inside all is AND of OR" do
      nested = %{
        "combinator" => "all",
        "predicates" => [
          pred("keep", "eq", "keep"),
          %{"combinator" => "any", "predicates" => [pred("x", "eq", "y"), pred("1", "eq", "1")]}
        ]
      }

      assert matched?(nested)

      failing = %{
        "combinator" => "all",
        "predicates" => [
          pred("keep", "eq", "keep"),
          %{"combinator" => "any", "predicates" => [pred("x", "eq", "y"), pred("1", "eq", "2")]}
        ]
      }

      refute matched?(failing)
    end
  end

  describe "short-circuit" do
    test "all stops at the first false comparison and does not evaluate the rest" do
      config = %{
        "combinator" => "all",
        "predicates" => [pred("nope", "eq", "match"), pred(count_path(), "gt", "2")]
      }

      assert {:ok, result} = Expressions.evaluate(config, tree(%{}))
      assert result.matched == false
      assert result.decided == "predicates.0.eq"
    end

    test "any stops at the first true comparison" do
      config = %{
        "combinator" => "any",
        "predicates" => [pred("match", "eq", "match"), pred(count_path(), "gt", "2")]
      }

      assert {:ok, result} = Expressions.evaluate(config, tree(%{}))
      assert result.matched == true
      assert result.decided == "predicates.0.eq"
    end

    test "none stops at the first true comparison" do
      config = %{
        "combinator" => "none",
        "predicates" => [pred("match", "eq", "match"), pred(count_path(), "gt", "2")]
      }

      assert {:ok, result} = Expressions.evaluate(config, tree(%{}))
      assert result.matched == false
      assert result.decided == "predicates.0.eq"
    end
  end

  describe "missing and null" do
    test "a missing path on a binary comparison is a permanent field and path failure" do
      assert {:ok, outcome} = Condition.run(runner_input(clause(text_path(), "eq", "x"), %{}))
      assert outcome.kind == :permanent_error
      assert outcome.error_class == "validation"
      assert outcome.output["field"] == "predicates.0.left"
      assert outcome.output["path"] == "trigger.data.text"
      refute is_nil(outcome.message)
      refute outcome.message =~ "nil"
    end

    test "null is a value, so two nulls are equal and a missing key is empty" do
      assert matched?(clause(text_path(), "eq", flag_path()), %{"text" => nil, "flag" => nil})
      assert matched?(clause(text_path(), "is_empty", nil), %{})
      assert matched?(clause(text_path(), "is_empty", nil), %{"text" => nil})
      refute matched?(clause(text_path(), "is_not_empty", nil), %{})
      refute matched?(clause(text_path(), "is_present", nil), %{})
      assert matched?(clause(text_path(), "is_present", nil), %{"text" => nil})
      assert matched?(clause(text_path(), "is_not_empty", nil), %{"text" => "hi"})
    end
  end

  describe "branch reason redaction" do
    test "the selected edge and reason do not include compared values" do
      secret = "super-secret-token-value"

      assert {:ok, outcome} =
               Condition.run(runner_input(clause(text_path(), "eq", secret), %{"text" => secret}))

      assert outcome.kind == :success
      assert outcome.edge == "true"
      assert outcome.output["reason"] == "predicates.0.eq"
      refute inspect(outcome) =~ secret
      refute outcome.output["reason"] =~ secret
    end
  end

  describe "refusals" do
    test "an empty predicate list is a validation failure" do
      assert {:error, %Error{code: :no_predicates}} =
               Expressions.evaluate(%{"combinator" => "all", "predicates" => []}, %{})
    end

    test "an unknown comparator is refused" do
      assert {:error, %Error{code: :unknown_value}} =
               Expressions.evaluate(clause("a", "regex", "b"), %{})
    end
  end

  defp run_compiled(text) do
    Condition.run(runner_input(compiled_fixture_config(), %{"text" => text}))
  end

  defp compiled_fixture_config do
    node = condition_node(if_true: [stop_node()])
    assert {:ok, compiled} = Compiler.compile(definition([node]))
    compiled.nodes[node.id].config
  end

  defp runner_input(config, trigger_data) do
    %{
      compiled_node: %{
        type: :condition,
        config: config,
        edges: %{
          "true" => CompiledWorkflow.end_target(),
          "false" => CompiledWorkflow.end_target()
        },
        requires: %{
          "operations" => [],
          "scopes" => [],
          "connection_ids" => [],
          "secret_names" => []
        }
      },
      context: %{},
      trigger_snapshot: %{"data" => trigger_data},
      installation_id: Ecto.UUID.generate(),
      run_mode: "live",
      effect_key: "inst/exec/node",
      attempt: %{id: Ecto.UUID.generate(), number: 1},
      resolver: PumbleAutomation.Connections.Resolver,
      adapters: %{}
    }
  end

  defp matched?(config, data \\ %{}) do
    assert {:ok, %{matched: matched}} = Expressions.evaluate(config, tree(data))
    matched
  end

  defp type_error?(config, data) do
    match?(
      {:error, %Error{code: :comparator_type_mismatch}},
      Expressions.evaluate(config, tree(data))
    )
  end

  defp too_long?(config, data) do
    match?({:error, %Error{code: :too_many_items}}, Expressions.evaluate(config, tree(data)))
  end

  defp clause(left, comparator, right) do
    group("all", [pred(left, comparator, right)])
  end

  defp group(combinator, predicates) do
    %{"combinator" => combinator, "predicates" => predicates}
  end

  defp pred(left, comparator, right) do
    %{"left" => left, "comparator" => comparator, "right" => right}
  end

  defp text_path, do: compiled_path(["data", "text"])
  defp count_path, do: compiled_path(["data", "count"])
  defp tags_path, do: compiled_path(["data", "tags"])
  defp flag_path, do: compiled_path(["data", "flag"])

  defp compiled_path(segments) do
    %{"template" => [%{"path" => %{"root" => "trigger", "path" => segments}}]}
  end

  defp tree(data), do: %{"trigger" => %{"data" => data}}
end
