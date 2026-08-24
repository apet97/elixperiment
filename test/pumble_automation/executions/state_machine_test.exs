defmodule PumbleAutomation.Executions.StateMachineTest do
  @moduledoc """
  The pure transition table for executions, steps, attempts, and approvals.

  No database is involved. A worker that later applies one of these plans
  still has to lock the row; this file only proves that every command the
  engine will send has one explicit answer, and that terminal states never
  leave.
  """

  use ExUnit.Case, async: true

  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Outcome
  alias PumbleAutomation.Executions.StateMachine
  alias PumbleAutomation.Workflows.CompiledWorkflow

  describe "execution and step transition table" do
    test "every documented Section 19 edge is accepted" do
      table = [
        {"queued", :start, "running"},
        {"queued", :cancel, "cancelled"},
        {"running", :wait_delay, "waiting_delay"},
        {"running", :wait_approval, "waiting_approval"},
        {"running", :pause_uncertain, "paused_uncertain"},
        {"running", :complete, "completed"},
        {"running", :fail, "failed"},
        {"running", :cancel, "cancelled"},
        {"waiting_delay", :resume, "running"},
        {"waiting_delay", :cancel, "cancelled"},
        {"waiting_approval", :resume, "running"},
        {"waiting_approval", :cancel, "cancelled"},
        {"waiting_approval", :fail, "failed"},
        {"waiting_approval", :pause_uncertain, "paused_uncertain"},
        {"paused_uncertain", :cancel, "cancelled"},
        {"paused_uncertain", {:resolve_uncertain, :running}, "running"},
        {"paused_uncertain", {:resolve_uncertain, :failed}, "failed"},
        {"paused_uncertain", {:resolve_uncertain, :completed}, "completed"}
      ]

      for entity <- [:execution, :step], {from, command, to} <- table do
        assert {:ok, plan} = StateMachine.transition(entity, from, command)
        assert plan.to == to
        assert plan.from == from
        assert plan.idempotent? == false
        assert plan.entity == entity
      end
    end

    test "duplicate commands that already arrived are idempotent stays" do
      stays = [
        {"running", :start},
        {"running", :resume},
        {"running", :retry},
        {"waiting_delay", :wait_delay},
        {"waiting_approval", :wait_approval},
        {"paused_uncertain", :pause_uncertain},
        {"completed", :complete},
        {"failed", :fail},
        {"cancelled", :cancel},
        {"cancelled", :request_cancellation},
        {"running", {:resolve_uncertain, "running"}},
        {"failed", {:resolve_uncertain, :failed}},
        {"completed", {:resolve_uncertain, :completed}}
      ]

      for {from, command} <- stays do
        assert {:ok, plan} = StateMachine.transition(:execution, from, command)
        assert plan.to == from
        assert plan.idempotent?
      end
    end

    test "cancellation request is the cancel transition" do
      assert {:ok, %{to: "cancelled", idempotent?: false}} =
               StateMachine.transition(:execution, "queued", :request_cancellation)
    end

    test "illegal moves are conflicts, including backwards from a terminal" do
      illegal = [
        {"queued", :complete},
        {"queued", :fail},
        {"queued", :resume},
        {"queued", :wait_delay},
        {"running", :approve},
        {"completed", :start},
        {"completed", :fail},
        {"completed", :cancel},
        {"completed", {:resolve_uncertain, :failed}},
        {"failed", :complete},
        {"failed", :start},
        {"cancelled", :start},
        {"cancelled", :complete},
        {"paused_uncertain", :complete},
        {"paused_uncertain", :fail},
        {"paused_uncertain", :start},
        {"waiting_delay", :complete},
        {"waiting_delay", :fail}
      ]

      for {from, command} <- illegal do
        assert {:error, %Error{class: :conflict, code: :illegal_transition}} =
                 StateMachine.transition(:execution, from, command)
      end
    end

    test "every status and command is a plan or a typed conflict" do
      commands =
        StateMachine.commands() ++
          Enum.map(StateMachine.states(:execution), &{:resolve_uncertain, &1})

      for entity <- [:execution, :step, :attempt, :approval],
          from <- StateMachine.states(entity) ++ ["not_a_status"],
          command <- commands do
        case StateMachine.transition(entity, from, command) do
          {:ok, plan} ->
            assert plan.entity == entity
            assert plan.from == from
            assert plan.to in StateMachine.states(entity)
            assert is_boolean(plan.idempotent?)

            if StateMachine.terminal?(entity, from) do
              assert plan.to == from
              assert plan.idempotent?
            end

          {:error, %Error{class: :conflict, code: :illegal_transition}} ->
            :ok

          other ->
            flunk("#{entity} #{from} via #{inspect(command)} produced #{inspect(other)}")
        end
      end
    end
  end

  describe "attempt transition table" do
    test "a started attempt may succeed, fail, pause, or cancel" do
      assert {:ok, %{to: "succeeded"}} = StateMachine.transition(:attempt, "started", :succeed)
      assert {:ok, %{to: "failed"}} = StateMachine.transition(:attempt, "started", :fail)

      assert {:ok, %{to: "uncertain"}} =
               StateMachine.transition(:attempt, "started", :pause_uncertain)

      assert {:ok, %{to: "cancelled"}} = StateMachine.transition(:attempt, "started", :cancel)
    end

    test "a finished attempt does not change classification" do
      assert {:ok, %{idempotent?: true, to: "succeeded"}} =
               StateMachine.transition(:attempt, "succeeded", :succeed)

      assert {:error, %Error{code: :illegal_transition}} =
               StateMachine.transition(:attempt, "succeeded", :fail)

      assert {:error, %Error{code: :illegal_transition}} =
               StateMachine.transition(:attempt, "failed", :succeed)
    end
  end

  describe "approval transition table" do
    test "pending may be approved, rejected, timed out, or cancelled" do
      assert {:ok, %{to: "approved"}} = StateMachine.transition(:approval, "pending", :approve)
      assert {:ok, %{to: "rejected"}} = StateMachine.transition(:approval, "pending", :reject)
      assert {:ok, %{to: "timed_out"}} = StateMachine.transition(:approval, "pending", :timeout)
      assert {:ok, %{to: "cancelled"}} = StateMachine.transition(:approval, "pending", :cancel)
    end

    test "a recorded decision cannot be replaced" do
      assert {:ok, %{idempotent?: true}} =
               StateMachine.transition(:approval, "approved", :approve)

      assert {:error, %Error{code: :illegal_transition}} =
               StateMachine.transition(:approval, "approved", :reject)

      assert {:error, %Error{code: :illegal_transition}} =
               StateMachine.transition(:approval, "rejected", :approve)
    end
  end

  describe "terminal closure and no illegal backwards transitions" do
    test "every terminal state × every command either stays put or conflicts" do
      :rand.seed(:exsss, {2026, 8, 17})

      commands =
        StateMachine.commands() ++
          Enum.map(~w(running failed completed), &{:resolve_uncertain, &1})

      for _run <- 1..200,
          entity <- [:execution, :step, :attempt, :approval],
          state <- StateMachine.states(entity),
          command <- commands do
        if StateMachine.terminal?(entity, state) do
          case StateMachine.transition(entity, state, command) do
            {:ok, %{to: ^state, idempotent?: true}} ->
              :ok

            {:error, %Error{class: :conflict, code: :illegal_transition}} ->
              :ok

            other ->
              flunk(
                "terminal #{entity} #{state} via #{inspect(command)} produced #{inspect(other)}"
              )
          end
        end
      end
    end

    test "no command moves a terminal execution back to a runnable state" do
      runnable = ~w(queued running waiting_delay waiting_approval paused_uncertain)
      commands = StateMachine.commands() ++ [{:resolve_uncertain, :running}]

      for from <- ~w(completed failed cancelled), command <- commands do
        case StateMachine.transition(:execution, from, command) do
          {:ok, %{to: to}} -> refute to in runnable
          {:error, %Error{code: :illegal_transition}} -> :ok
        end
      end
    end

    test "a completed step cannot become runnable again" do
      for command <- [:start, :resume, :retry, :wait_delay] do
        assert {:error, %Error{code: :illegal_transition}} =
                 StateMachine.transition(:step, "completed", command)
      end
    end
  end

  describe "deactivation versus uninstall" do
    test "only an active workflow on an active installation admits a new run" do
      assert StateMachine.admit_new_execution?("active", "active")
      refute StateMachine.admit_new_execution?("inactive", "active")
      refute StateMachine.admit_new_execution?("archived", "active")
      refute StateMachine.admit_new_execution?(:draft, "active")
      refute StateMachine.admit_new_execution?("active", "uninstalled")
      refute StateMachine.admit_new_execution?("active", "revoked")
      refute StateMachine.admit_new_execution?("active", "deleted")
      refute StateMachine.admit_new_execution?("active", "degraded")
    end

    test "deactivation leaves in-flight effects allowed; uninstall does not" do
      assert StateMachine.dispatch_effect?("running", "inactive", "active")
      assert StateMachine.dispatch_effect?("waiting_delay", "inactive", "active")
      assert StateMachine.dispatch_effect?("paused_uncertain", "archived", "active")

      refute StateMachine.dispatch_effect?("running", "active", "uninstalled")
      refute StateMachine.dispatch_effect?("running", "active", "revoked")
      refute StateMachine.dispatch_effect?("waiting_approval", "active", "deleted")
      refute StateMachine.dispatch_effect?("completed", "active", "active")
      refute StateMachine.dispatch_effect?("queued", "active", "degraded")
    end
  end

  describe "outcome labels and next-node expectations" do
    test "labels match the compiler's named edges" do
      assert Outcome.labels(:condition) == ["false", "true"]
      assert Outcome.labels(:approval) == ["approved", "rejected", "timed_out"]
      assert Outcome.labels(:pumble_action) == ["next"]
      assert Outcome.labels("delay") == ["next"]
      assert Outcome.labels(:stop) == ["next"]
      assert Outcome.linear() == "next"
      assert Outcome.terminal_target() == CompiledWorkflow.end_target()
    end

    test "follow/2 distinguishes the end sentinel from a continuation" do
      edges = %{"next" => CompiledWorkflow.end_target(), "true" => "node-a"}

      assert {:ok, :end} = Outcome.follow(edges, "next")
      assert {:ok, {:continue, "node-a"}} = Outcome.follow(edges, "true")
      assert {:error, %Error{code: :unknown_outcome_label}} = Outcome.follow(edges, "false")
      refute Outcome.next_node_expected?(CompiledWorkflow.end_target())
      assert Outcome.next_node_expected?("node-a")
    end

    test "new/1 accepts the finite runner kinds and requires an edge on success" do
      assert {:ok, %{kind: :wait_delay}} = Outcome.new(%{kind: :wait_delay})

      assert {:ok, %{kind: :success, edge: "true"}} =
               Outcome.new(%{kind: :success, edge: "true", output: %{"ok" => true}})

      assert {:error, %Error{code: :invalid_outcome}} = Outcome.new(%{kind: :success})
      assert {:error, %Error{code: :invalid_outcome}} = Outcome.new(%{kind: :telepathy})

      assert Outcome.kinds() == [
               :success,
               :wait_delay,
               :wait_approval,
               :retryable_error,
               :permanent_error,
               :uncertain,
               :cancelled
             ]
    end
  end
end
