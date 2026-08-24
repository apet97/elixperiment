defmodule PumbleAutomation.Executions.Workers.AdvanceExecutionWorker do
  @moduledoc """
  Advances one execution by claiming, evaluating, and finalizing a step.

  Job args are identifiers and the expected generation only: installation,
  execution, node, and lock version. The worker claims in a short transaction,
  evaluates the compiled node without holding row locks, then finalizes the
  outcome in a second transaction that also inserts the next durable job.

  Duplicate and stale jobs exit as a successful no-op so Oban does not retry
  them forever. An early delay wake snoozes until `resume_at`. A due delay
  wait is claimed as a resume and finalized along the linear edge without
  resolving the duration again. A lock timeout before claim is retryable at
  the Oban layer because no attempt exists yet. After a claim, exceptions
  and classified errors are recorded through finalize; Oban must not retry
  the same generation. Node retries are engine-owned (`RetryPolicy`, five
  attempts, jittered backoff).
  """

  use Oban.Worker,
    queue: :executions,
    max_attempts: 20,
    unique: [keys: [:execution_id, :expected_node_id, :generation], states: :incomplete]

  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.NodeRunner
  alias PumbleAutomation.Executions.Nodes.Delay
  alias PumbleAutomation.Executions.Outcome
  alias PumbleAutomation.Executions.RetryPolicy
  alias PumbleAutomation.FailureInjection
  alias PumbleAutomation.Limits
  alias PumbleAutomation.Logging

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    Logging.attach_context(%{job_id: job_id(job)})

    try do
      case claim_job(job) do
        {:ok, :noop} -> :ok
        {:ok, {:snooze, seconds}} -> {:snooze, seconds}
        {:ok, snapshot} -> run_claimed(snapshot)
        {:error, :worker_exception} -> {:error, :worker_exception}
        {:error, %Error{retryable?: true} = error} -> {:error, error.code}
        {:error, %Error{} = error} -> {:cancel, error.code}
      end
    after
      Logging.clear_context()
    end
  end

  defp claim_job(job) do
    Engine.claim(job)
  rescue
    _exception -> {:error, :worker_exception}
  end

  defp run_claimed(%{delay_resume?: true} = snapshot) do
    attach_snapshot(snapshot)
    run_or_expire(snapshot, fn -> resume_delay(snapshot) end)
  end

  defp run_claimed(snapshot) do
    attach_snapshot(snapshot)
    run_or_expire(snapshot, fn -> evaluate_claimed(snapshot) end)
  end

  defp attach_snapshot(snapshot) do
    Logging.attach_context(%{
      installation_id: snapshot.installation_id,
      workflow_id: snapshot.workflow_id,
      version_id: snapshot.workflow_version_id,
      execution_id: snapshot.execution_id,
      step_id: snapshot.step_execution_id,
      attempt_id: snapshot.attempt_id,
      operation: snapshot.node_type
    })
  end

  defp job_id(%Oban.Job{id: id}) when is_integer(id), do: Integer.to_string(id)
  defp job_id(_job), do: nil

  defp run_or_expire(snapshot, fun) do
    if Limits.execution_expired?(snapshot) do
      Limits.record_hit(:execution_lifetime, snapshot.installation_id)
      finalize_claimed(snapshot, lifetime_outcome())
    else
      finalize_claimed(snapshot, fun.())
    end
  end

  defp lifetime_outcome do
    {:ok, outcome} =
      Outcome.new(%{
        kind: :permanent_error,
        error_class: "resource_limit",
        message: "The execution exceeded its maximum lifetime."
      })

    outcome
  end

  defp resume_delay(snapshot) do
    case Delay.resume(snapshot) do
      {:ok, outcome} -> outcome
      {:error, %Error{} = error} -> RetryPolicy.outcome_for_error(error)
    end
  rescue
    exception -> RetryPolicy.wrap_exception(exception)
  catch
    kind, reason -> RetryPolicy.wrap_throw(kind, reason)
  end

  defp evaluate_claimed(snapshot) do
    case NodeRunner.run(NodeRunner.input(snapshot)) do
      {:ok, outcome} -> outcome
      {:error, %Error{} = error} -> RetryPolicy.outcome_for_error(error)
    end
  rescue
    exception -> RetryPolicy.wrap_exception(exception)
  catch
    kind, reason -> RetryPolicy.wrap_throw(kind, reason)
  end

  defp finalize_claimed(snapshot, outcome) do
    result =
      case Engine.finalize(snapshot, outcome) do
        {:ok, :noop} -> :ok
        {:ok, execution} -> {:ok, execution}
        {:error, %Error{}} -> :ok
      end

    FailureInjection.crash(:after_finalize_before_job_return)
    result
  rescue
    _exception -> :ok
  end
end
