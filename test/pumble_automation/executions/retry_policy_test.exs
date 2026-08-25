defmodule PumbleAutomation.Executions.RetryPolicyTest do
  @moduledoc """
  Error classes map onto one retry disposition, backoff is bounded, and the
  worker records engine-owned retries instead of looping in Oban.
  """

  use PumbleAutomation.DataCase, async: true
  use Oban.Testing, repo: PumbleAutomation.Repo

  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.Outcome
  alias PumbleAutomation.Executions.RetryPolicy
  alias PumbleAutomation.Executions.StepAttempt
  alias PumbleAutomation.Executions.Workers.AdvanceExecutionWorker
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Pumble.Client
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition

  setup do
    %{installation: installation, member: member} = InstallationsFixtures.install()
    scope = Scope.new(member)

    %{
      scope: scope,
      installation: installation,
      installation_id: installation.id
    }
  end

  describe "status and error matrix" do
    test "every named class has exactly one disposition" do
      for class <- RetryPolicy.classes() do
        disposition =
          RetryPolicy.decide(%{
            error_class: class,
            retry_safety: :not_idempotent,
            attempt_number: 1
          })

        assert disposition in [:retry, :fail, :pause_uncertain, :cancel], class
      end
    end

    test "permanent provider rejection never retries" do
      for class <-
            ~w(validation authentication authorization missing_scope installation_revoked
               not_found conflict remote_permanent resource_limit internal_invariant) do
        assert RetryPolicy.decide(%{
                 error_class: class,
                 retry_safety: :read_only,
                 attempt_number: 1
               }) == :fail
      end
    end

    test "infrastructure failure before an effect retries until exhaustion" do
      for class <- ~w(rate_limited transient_transport remote_transient internal) do
        assert RetryPolicy.decide(%{
                 error_class: class,
                 retry_safety: :not_idempotent,
                 attempt_number: 1
               }) == :retry
      end
    end

    test "unknown non-idempotent write outcomes pause rather than auto-retry" do
      for class <- ~w(ambiguous_transport side_effect_uncertain) do
        assert RetryPolicy.decide(%{
                 error_class: class,
                 retry_safety: :not_idempotent,
                 attempt_number: 1
               }) == :pause_uncertain
      end
    end

    test "unknown outcomes on read-only or idempotent effects retry" do
      for safety <- [:read_only, :idempotent_effect],
          class <- ~w(ambiguous_transport side_effect_uncertain) do
        assert RetryPolicy.decide(%{
                 error_class: class,
                 retry_safety: safety,
                 attempt_number: 1
               }) == :retry
      end
    end

    test "cancelled never retries" do
      assert RetryPolicy.decide(%{
               error_class: "cancelled",
               retry_safety: :read_only,
               attempt_number: 1
             }) == :cancel
    end

    test "an unknown class fails closed" do
      assert RetryPolicy.decide(%{
               error_class: "made_up",
               retry_safety: :read_only,
               attempt_number: 1
             }) == :fail
    end

    test "Pumble retry-safety decides whether a write may repeat" do
      send_message = %{
        type: :pumble_action,
        config: %{"action" => "send_message"},
        requires: %{"operations" => ["post_message"]}
      }

      add_reaction = %{
        type: :pumble_action,
        config: %{"action" => "add_reaction"},
        requires: %{"operations" => ["add_reaction"]}
      }

      assert RetryPolicy.retry_safety(send_message) == :not_idempotent
      assert RetryPolicy.retry_safety(add_reaction) == :idempotent_effect
      assert Client.retry_safety(:post_message) == :not_idempotent
      assert Client.retry_safety(:add_reaction) == :idempotent_effect

      {:ok, retryable} =
        Outcome.new(%{kind: :retryable_error, error_class: "side_effect_uncertain"})

      {:ok, paused} =
        RetryPolicy.apply(retryable, %{attempt_number: 1, compiled_node: send_message})

      {:ok, retried} =
        RetryPolicy.apply(retryable, %{attempt_number: 1, compiled_node: add_reaction})

      assert paused.kind == :uncertain
      assert retried.kind == :retryable_error
      assert retried.resume_at
    end
  end

  describe "Retry-After parsing and cap" do
    test "honours a valid delay and clamps it to the resource policy" do
      assert RetryPolicy.parse_retry_after("12") == 12
      assert RetryPolicy.parse_retry_after(["30"]) == 30
      assert RetryPolicy.parse_retry_after(0) == 1
      assert RetryPolicy.parse_retry_after(86_400) == 900
      assert RetryPolicy.parse_retry_after("soon") == nil
      assert RetryPolicy.max_retry_after() == 900
    end

    test "a Retry-After hint replaces the schedule within the cap" do
      assert RetryPolicy.backoff_seconds(1, retry_after: 30) == 30
      assert RetryPolicy.backoff_seconds(1, retry_after: 86_400) == 900
      assert RetryPolicy.backoff_seconds(1, jitter: fn ceiling -> ceiling end) == 1
    end
  end

  describe "dispatch evidence" do
    test "records confirmed, possibly-sent, not-sent, and unknown evidence honestly" do
      {:ok, responded} =
        Outcome.new(%{
          kind: :permanent_error,
          error_class: "remote_permanent",
          output: %{"status" => 422}
        })

      confirmed = RetryPolicy.diagnostics(responded, %{})
      assert confirmed["dispatch_state"] == "confirmed"
      assert confirmed["dispatched"]
      assert confirmed["bytes_may_have_left"]

      {:ok, response_after_write} =
        Outcome.new(%{
          kind: :permanent_error,
          error_class: "remote_permanent",
          output: %{"status" => 422, "request_written" => false}
        })

      response_evidence = RetryPolicy.diagnostics(response_after_write, %{})
      assert response_evidence["dispatch_state"] == "confirmed"
      assert response_evidence["dispatched"]

      {:ok, write_may_have_left} =
        Outcome.new(%{
          kind: :uncertain,
          error_class: "ambiguous_transport",
          output: %{"request_written" => true}
        })

      possibly_sent = RetryPolicy.diagnostics(write_may_have_left, %{})
      assert possibly_sent["dispatch_state"] == "possibly_sent"
      assert possibly_sent["bytes_may_have_left"]
      assert possibly_sent["duplicate_risk"]
      refute Map.has_key?(possibly_sent, "dispatched")

      {:ok, connect_failure} =
        Outcome.new(%{
          kind: :retryable_error,
          error_class: "transient_transport",
          output: %{"request_written" => false}
        })

      not_sent = RetryPolicy.diagnostics(connect_failure, %{})
      assert not_sent["dispatch_state"] == "not_sent"
      refute not_sent["dispatched"]
      refute not_sent["bytes_may_have_left"]

      {:ok, unknown} =
        Outcome.new(%{
          kind: :uncertain,
          error_class: "ambiguous_transport"
        })

      uncertain = RetryPolicy.diagnostics(unknown, %{})
      assert uncertain["dispatch_state"] == "unknown"
      assert uncertain["duplicate_risk"]
      refute Map.has_key?(uncertain, "dispatched")
      refute Map.has_key?(uncertain, "bytes_may_have_left")
    end
  end

  describe "jitter range" do
    test "full jitter stays inside the schedule ceiling and is not constant" do
      :rand.seed(:exsss, {7, 11, 13})
      ceiling = RetryPolicy.backoff_ceiling(4)
      samples = for _index <- 1..40, do: RetryPolicy.backoff_seconds(4)

      assert ceiling == 120
      assert Enum.all?(samples, &(&1 in 0..ceiling))
      assert samples |> Enum.uniq() |> length() > 1
    end

    test "the schedule matches the documented retry policy" do
      assert RetryPolicy.schedule() == [1, 5, 30, 120, 600]
      assert RetryPolicy.max_attempts() == 5
    end
  end

  describe "attempt exhaustion" do
    test "the fifth retryable failure finalizes the execution as failed", context do
      %{snapshot: first} = claimed!(context, [stop_node()])
      execution_id = first.execution_id

      finalized =
        Enum.reduce(1..5, first, fn index, snapshot ->
          {:ok, outcome} =
            Outcome.new(%{
              kind: :retryable_error,
              error_class: "transient_transport",
              message: "upstream timeout"
            })

          assert {:ok, execution} = Engine.finalize(snapshot, outcome)

          if index < 5 do
            assert execution.status == "running"
            attempt = Repo.get!(StepAttempt, snapshot.attempt_id)
            assert attempt.status == "failed"
            assert attempt.retry_at
            assert attempt.diagnostics["kind"] == "retryable_error"
            assert {:ok, next} = Engine.claim(job_args(execution))
            next
          else
            assert execution.status == "failed"
            attempt = Repo.get!(StepAttempt, snapshot.attempt_id)
            assert attempt.status == "failed"
            refute attempt.retry_at

            assert attempt.diagnostics["message"] ==
                     "The step was retried the maximum number of times."

            execution
          end
        end)

      assert Repo.get!(Execution, execution_id).status == "failed"
      assert finalized.status == "failed"
      assert Repo.aggregate(StepAttempt, :count) == 5
    end
  end

  describe "worker-level exception before and after claim" do
    test "an exception after claim is recorded and schedules engine retry, not Oban retry",
         context do
      %{snapshot: snapshot, execution: execution} = claimed!(context, [stop_node()])
      original_args = job_args(%{execution | lock_version: snapshot.generation - 1})
      outcome = RetryPolicy.wrap_exception(%RuntimeError{message: "token=super-secret"})

      assert {:ok, finalized} = Engine.finalize(snapshot, outcome)
      assert finalized.status == "running"

      attempt = Repo.get!(StepAttempt, snapshot.attempt_id)
      assert attempt.status == "failed"
      assert attempt.retry_at
      refute inspect(attempt.diagnostics) =~ "super-secret"
      assert attempt.diagnostics["exception"] == "RuntimeError"

      assert_enqueued(
        worker: AdvanceExecutionWorker,
        args: %{
          execution_id: execution.id,
          expected_node_id: snapshot.node_id,
          generation: finalized.lock_version
        }
      )

      assert :ok = AdvanceExecutionWorker.perform(%Oban.Job{args: original_args})
      assert Repo.get!(Execution, execution.id).status == "running"
      assert Repo.aggregate(StepAttempt, :count) == 1
    end

    test "a failure before claim does not open an attempt and is a success no-op", context do
      %{execution: execution, job_args: args} = queued!(context, [stop_node()])

      context.installation
      |> Installation.changeset(%{status: "uninstalled"})
      |> Repo.update!()

      assert :ok = AdvanceExecutionWorker.perform(%Oban.Job{args: args})
      assert Repo.get!(Execution, execution.id).status == "queued"
      assert Repo.aggregate(StepAttempt, :count) == 0
    end

    test "Oban retries only pre-claim failures; the engine owns the five node attempts" do
      changeset =
        AdvanceExecutionWorker.new(%{
          "installation_id" => Ecto.UUID.generate(),
          "execution_id" => Ecto.UUID.generate(),
          "expected_node_id" => Ecto.UUID.generate(),
          "generation" => 0
        })

      assert changeset.changes[:max_attempts] == 20 or changeset.data.max_attempts == 20
      assert RetryPolicy.max_attempts() == 5
    end
  end

  describe "recorded retry time" do
    test "a retryable finalize writes retry_at and a scheduled job", context do
      %{snapshot: snapshot, execution: execution} = claimed!(context, [stop_node()])

      {:ok, outcome} =
        Outcome.new(%{
          kind: :retryable_error,
          error_class: "rate_limited",
          output: %{"retry_after" => 30}
        })

      before = DateTime.utc_now()
      assert {:ok, finalized} = Engine.finalize(snapshot, outcome)
      assert finalized.status == "running"

      attempt = Repo.get!(StepAttempt, snapshot.attempt_id)
      assert attempt.retry_at
      assert DateTime.diff(attempt.retry_at, before, :second) in 29..31
      assert attempt.diagnostics["guidance"] == "The step will retry automatically."
      assert attempt.diagnostics["effect_key"] == snapshot.effect_key

      assert_enqueued(
        worker: AdvanceExecutionWorker,
        args: %{
          execution_id: execution.id,
          expected_node_id: snapshot.node_id,
          generation: finalized.lock_version
        }
      )
    end

    test "a permanent error inserts no retry job", context do
      %{snapshot: snapshot, execution: execution} = claimed!(context, [stop_node()])

      {:ok, outcome} =
        Outcome.new(%{kind: :permanent_error, error_class: "validation", message: "bad payload"})

      assert {:ok, finalized} = Engine.finalize(snapshot, outcome)
      assert finalized.status == "failed"
      refute Repo.get!(StepAttempt, snapshot.attempt_id).retry_at

      refute_enqueued(
        worker: AdvanceExecutionWorker,
        args: %{execution_id: execution.id, generation: finalized.lock_version}
      )
    end
  end

  defp claimed!(context, nodes) do
    started = queued!(context, nodes)
    {:ok, snapshot} = Engine.claim(job_args(started.execution))
    Map.put(started, :snapshot, snapshot)
  end

  defp queued!(context, nodes) do
    %{version: version} = activate!(context.scope, context.installation_id, definition(nodes))

    {:ok, execution} =
      Engine.create(context.scope, %{
        workflow_version_id: version.id,
        execution_key: "retry-#{System.unique_integer([:positive])}"
      })

    %{
      execution: Repo.get!(Execution, execution.id),
      version: version,
      job_args: job_args(Repo.get!(Execution, execution.id))
    }
  end

  defp activate!(scope, installation_id, definition) do
    workflow =
      drafted_workflow(installation_id, %{draft_definition: Definition.encode(definition)})

    {:ok, result} = Workflows.activate_workflow(scope, workflow.id, 0)
    %{version: result.version, workflow: result.workflow}
  end

  defp job_args(%Execution{} = execution) do
    %{
      "installation_id" => execution.installation_id,
      "execution_id" => execution.id,
      "expected_node_id" => execution.current_node_id,
      "generation" => execution.lock_version
    }
  end
end
