defmodule PumbleAutomation.Executions.NodeRunnerTest do
  @moduledoc """
  The runtime catalog matches the compiler, outcomes are bounded, and a
  raised runner is classified internal without writing rows.
  """

  use ExUnit.Case, async: true

  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.NodeRegistry
  alias PumbleAutomation.Executions.NodeRunner
  alias PumbleAutomation.Executions.Outcome
  alias PumbleAutomation.Executions.StateMachine
  alias PumbleAutomation.Executions.StepExecution
  alias PumbleAutomation.Workflows.CompiledWorkflow
  alias PumbleAutomation.Workflows.Node

  describe "registry completeness" do
    test "runtime types are exactly the compiler node catalog" do
      assert NodeRegistry.types() == NodeRegistry.compiler_types()
      assert NodeRegistry.types() == Node.types() |> Map.values() |> Enum.sort()
    end

    test "every catalog entry declares effect class, retry safety, schema, and size" do
      for type <- NodeRegistry.types() do
        assert {:ok, spec} = NodeRegistry.spec(type)
        assert spec.type == type
        assert spec.effect_class in [:pure, :pumble, :http, :wait]
        assert spec.retry_safety in [:read_only, :idempotent_effect, :not_idempotent]
        assert spec.output_schema == %{type: :map}
        assert spec.max_output_bytes > 0
        assert spec.max_output_bytes <= StepExecution.max_payload_bytes()
      end
    end

    test "unknown types are a permanent compiler/runtime mismatch" do
      assert {:error, %Error{class: :internal, code: :unknown_node_type}} =
               NodeRegistry.spec(:telepathy)

      assert {:error, %Error{code: :unknown_node_type}} = NodeRegistry.spec("telepathy")
    end

    test "a wire type is resolved through the compiler map, not String.to_atom" do
      assert {:ok, %{type: :delay}} = NodeRegistry.spec("delay")
    end
  end

  describe "outcome validation and size" do
    test "every kind maps to a legal running-state command" do
      for kind <- Outcome.kinds() do
        command = Outcome.state_command(kind)
        assert {:ok, plan} = StateMachine.transition(:execution, "running", command)
        assert is_binary(plan.to)

        attempt_command = Outcome.attempt_command(kind)
        assert {:ok, _} = StateMachine.transition(:attempt, "started", attempt_command)
      end
    end

    test "a delay outcome without resume_at is refused" do
      {:ok, outcome} = Outcome.new(%{kind: :wait_delay, output: %{}})

      assert {:error, %Error{code: :invalid_outcome}} = Outcome.bound(outcome, 1024)
    end

    test "an oversized output is a resource-limit error" do
      {:ok, outcome} =
        Outcome.new(%{
          kind: :success,
          edge: "next",
          output: %{"blob" => String.duplicate("a", 2048)}
        })

      assert {:error, %Error{code: :output_too_large}} = Outcome.bound(outcome, 64)
    end

    test "secret-looking keys are dropped before the outcome is persistable" do
      {:ok, outcome} =
        Outcome.new(%{
          kind: :success,
          edge: "next",
          output: %{"ok" => true, "access_token" => "secret-value"}
        })

      assert {:ok, bounded} = Outcome.bound(outcome, 1024)
      assert bounded.output["ok"] == true
      refute Map.has_key?(bounded.output, "access_token")
    end

    test "bounded diagnostic text keeps only complete UTF-8 codepoints" do
      message_prefix = String.duplicate("m", 499)
      reference_prefix = String.duplicate("r", 255)

      {:ok, outcome} =
        Outcome.new(%{
          kind: :permanent_error,
          message: message_prefix <> "😀",
          remote_reference: reference_prefix <> "😀"
        })

      assert {:ok, bounded} = Outcome.bound(outcome, 1024)
      assert bounded.message == message_prefix
      assert bounded.remote_reference == reference_prefix
      assert String.valid?(bounded.message)
      assert String.valid?(bounded.remote_reference)
    end
  end

  describe "evaluation" do
    test "a delay node waits until its configured timestamp" do
      assert {:ok, outcome} = NodeRunner.run(input(:delay, %{"duration_seconds" => 60}))
      assert outcome.kind == :wait_delay
      assert outcome.edge == "next"
      assert %DateTime{} = outcome.resume_at
      assert DateTime.diff(outcome.resume_at, DateTime.utc_now(), :second) in 58..61
      assert outcome.output["wait_seconds"] == 60
    end

    test "a stop node succeeds along the linear edge" do
      assert {:ok, outcome} = NodeRunner.run(input(:stop, %{"reason" => "done"}))
      assert outcome.kind == :success
      assert outcome.edge == Outcome.linear()
      assert outcome.output["reason"] == "done"
    end

    test "a stop reason remains successful when its byte cap crosses a codepoint" do
      prefix = String.duplicate("r", 1023)

      assert {:ok, outcome} = NodeRunner.run(input(:stop, %{"reason" => prefix <> "😀"}))
      assert outcome.kind == :success
      assert outcome.output["reason"] == prefix
      assert String.valid?(outcome.output["reason"])
    end

    test "pumble and http adapters are substitution points" do
      adapter = fn _input ->
        Outcome.new(%{kind: :success, edge: "next", output: %{"via" => "stub"}})
      end

      assert {:ok, outcome} =
               NodeRunner.run(input(:pumble_action, %{}, adapters: %{pumble: adapter}))

      assert outcome.kind == :success
      assert outcome.output["via"] == "stub"

      assert {:ok, %Outcome{kind: :permanent_error}} = NodeRunner.run(input(:pumble_action, %{}))
    end

    test "an oversized adapter output becomes a permanent resource-limit failure" do
      adapter = fn _input ->
        Outcome.new(%{
          kind: :success,
          edge: "next",
          output: %{"blob" => String.duplicate("a", StepExecution.max_payload_bytes() + 32)}
        })
      end

      assert {:ok, outcome} =
               NodeRunner.run(input(:pumble_action, %{}, adapters: %{pumble: adapter}))

      assert outcome.kind == :permanent_error
      assert outcome.error_class == "resource_limit"
    end
  end

  describe "exception wrapping" do
    test "a raised adapter is an internal retryable outcome" do
      adapter = fn _input -> raise "token=super-secret" end

      assert {:ok, outcome} =
               NodeRunner.run(input(:http_action, %{}, adapters: %{http: adapter}))

      assert outcome.kind == :retryable_error
      assert outcome.error_class == "internal"
      assert outcome.message == "The step failed internally."
      refute inspect(outcome) =~ "super-secret"
      assert outcome.output["exception"] == "RuntimeError"
    end

    test "a thrown adapter is classified the same way" do
      adapter = fn _input -> throw(:nope) end

      assert {:ok, %Outcome{kind: :retryable_error, error_class: "internal"}} =
               NodeRunner.run(input(:http_action, %{}, adapters: %{http: adapter}))
    end
  end

  defp input(type, config, opts \\ []) do
    %{
      compiled_node: %{
        type: type,
        config: config,
        edges: %{"next" => CompiledWorkflow.end_target()},
        requires: %{
          "operations" => [],
          "scopes" => [],
          "connection_ids" => [],
          "secret_names" => []
        }
      },
      context: %{},
      trigger_snapshot: %{},
      installation_id: Ecto.UUID.generate(),
      run_mode: "live",
      effect_key: "inst/exec/node",
      attempt: %{id: Ecto.UUID.generate(), number: 1},
      resolver: PumbleAutomation.Connections.Resolver,
      adapters: Keyword.get(opts, :adapters, %{})
    }
  end
end
