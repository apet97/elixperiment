defmodule PumbleAutomation.Operations.Health do
  @moduledoc """
  Bounded queue, schedule, and readiness diagnostics.

  Public `/health/ready` stays the three cheap probes in
  `PumbleAutomation.Health`: database ping, migrations, and Oban
  supervision. Those fail only when this node cannot accept durable work.

  This module adds the rest of the picture — latency, queue age, discarded
  jobs, due-schedule lag, stale attempts, missing jobs, and cleanup lag —
  for an owner (or a deployment-internal caller). Query failures become
  `:unknown`, are logged, and never hang the public ready endpoint.

  Identifiers in samples are tenant-scoped. Job arguments are never read
  into the report.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Migrator
  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Concurrency
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.StepAttempt
  alias PumbleAutomation.Executions.StepExecution
  alias PumbleAutomation.Health
  alias PumbleAutomation.Installations.Policy
  alias PumbleAutomation.Logging
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Retention
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows.Schedule

  @query_timeout_ms 2_000
  @sample_limit 10
  @advance_worker Concurrency.advance_worker()
  @incomplete_job_states Concurrency.incomplete_job_states()

  @alert_thresholds %{
    database_latency_ms: 200,
    oldest_available_job_ms: :timer.minutes(15),
    discarded_jobs: 1,
    schedule_lag_ms: :timer.minutes(5),
    stale_attempts: 1,
    missing_jobs: 1,
    cleanup_lag_ms: :timer.hours(26)
  }

  @readiness_thresholds %{
    database_latency_ms: @query_timeout_ms,
    oldest_available_job_ms: :timer.hours(6),
    discarded_jobs: 10_000,
    schedule_lag_ms: :timer.hours(6),
    stale_attempts: 1_000,
    missing_jobs: 1_000,
    cleanup_lag_ms: :timer.hours(72)
  }

  @typedoc "One diagnostic outcome."
  @type check_status :: :ok | :degraded | :unhealthy | :unknown

  @typedoc "A named check with optional tenant-scoped samples."
  @type check :: %{
          name: atom(),
          status: check_status(),
          value: number() | String.t() | nil,
          unit: String.t() | nil,
          samples: [map()]
        }

  @typedoc "Owner or deployment diagnostic report."
  @type report :: %{
          status: check_status(),
          generated_at: DateTime.t(),
          installation_id: Ecto.UUID.t() | nil,
          ready?: boolean(),
          checks: [check()],
          alert_thresholds: map(),
          readiness_thresholds: map()
        }

  @doc "Alert recommendations: look, but the node can still accept work."
  @spec alert_thresholds() :: map()
  def alert_thresholds, do: @alert_thresholds

  @doc "Thresholds that mean durable work cannot be accepted or is stuck."
  @spec readiness_thresholds() :: map()
  def readiness_thresholds, do: @readiness_thresholds

  @doc """
  Tenant-scoped diagnostics for an owner.

  Editors and viewers receive the same permission error as other support
  operations. A query failure is `:unknown` inside the report, not an
  error return.
  """
  @spec diagnostics(Scope.t(), keyword()) :: {:ok, report()} | {:error, Error.t()}
  def diagnostics(%Scope{} = scope, opts \\ []) do
    with :ok <- Policy.authorize(scope, :destructive_lifecycle) do
      {:ok, snapshot(Keyword.put(opts, :installation_id, scope.installation_id))}
    end
  end

  @doc """
  Deployment-internal snapshot.

  Pass `:installation_id` to restrict samples and queue/schedule/execution
  counts to one tenant. Omit it for node-level counts with no identifiers.
  """
  @spec snapshot(keyword()) :: report()
  def snapshot(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    probe = Keyword.get_lazy(opts, :probe, &Health.configured_probe/0)
    timeout = Keyword.get(opts, :timeout, @query_timeout_ms)
    installation_id = Keyword.get(opts, :installation_id)

    ready = Health.readiness(probe: probe, timeout: timeout)
    db = database_check(probe, timeout)
    db_ok? = db.status == :ok

    checks =
      [
        db,
        migrations_check(probe, db_ok?),
        oban_check(probe)
      ] ++
        if db_ok? do
          [
            oldest_job_check(installation_id, now),
            discarded_jobs_check(installation_id),
            schedule_lag_check(installation_id, now),
            stale_attempts_check(installation_id, now),
            missing_jobs_check(installation_id),
            cleanup_lag_check(now)
          ]
        else
          skipped_db_checks()
        end

    %{
      status: overall(checks),
      generated_at: now,
      installation_id: installation_id,
      ready?: ready.status == :ok,
      checks: checks,
      alert_thresholds: @alert_thresholds,
      readiness_thresholds: @readiness_thresholds
    }
  end

  defp database_check(probe, timeout) do
    started = System.monotonic_time()
    outcome = run_probe(fn -> probe.ping(timeout) end)
    latency_ms = elapsed_ms(started)

    case outcome do
      :ok ->
        check(:database_latency, classify_age(latency_ms, :database_latency_ms), latency_ms, "ms")

      {:error, _error} ->
        check(:database_latency, :unhealthy, latency_ms, "ms")

      :unknown ->
        check(:database_latency, :unknown, nil, "ms")
    end
  end

  defp migrations_check(probe, true) do
    case run_probe(fn -> probe.migration_status() end) do
      :ok ->
        check(:migrations, :ok, latest_migration_version(), "version")

      {:error, _error} ->
        check(:migrations, :unhealthy, pending_migration_count(), "pending")

      :unknown ->
        check(:migrations, :unknown, nil, "pending")
    end
  end

  defp migrations_check(_probe, false), do: check(:migrations, :unknown, nil, "pending")

  defp oban_check(probe) do
    case run_probe(fn -> probe.queue_status() end) do
      :ok -> check(:oban, :ok, 1, "available")
      {:error, _error} -> check(:oban, :unhealthy, 0, "available")
      :unknown -> check(:oban, :unknown, nil, "available")
    end
  end

  defp oldest_job_check(installation_id, now) do
    query =
      from job in Oban.Job,
        where: job.state == "available",
        select: {count(job.id), min(job.scheduled_at)}

    query = scope_jobs(query, installation_id)

    case bounded(fn -> Repo.one(query, timeout: @query_timeout_ms) end) do
      {:ok, {count, oldest}} ->
        age_ms = age_ms(oldest, now)
        samples = tenant_samples(installation_id, oldest_job_samples(installation_id, count))

        :oldest_available_job
        |> check(classify_age(age_ms, :oldest_available_job_ms), age_ms, "ms")
        |> Map.put(:samples, samples)

      :unknown ->
        check(:oldest_available_job, :unknown, nil, "ms")
    end
  end

  defp discarded_jobs_check(installation_id) do
    query =
      from job in Oban.Job,
        where: job.state == "discarded",
        select: count(job.id)

    query = scope_jobs(query, installation_id)

    case bounded(fn -> Repo.one(query, timeout: @query_timeout_ms) end) do
      {:ok, count} ->
        samples = tenant_samples(installation_id, discarded_job_samples(installation_id, count))

        :discarded_jobs
        |> check(classify_count(count, :discarded_jobs), count, "jobs")
        |> Map.put(:samples, samples)

      :unknown ->
        check(:discarded_jobs, :unknown, nil, "jobs")
    end
  end

  defp schedule_lag_check(installation_id, now) do
    lag_query =
      from schedule in Schedule,
        where:
          schedule.enabled and not is_nil(schedule.next_run_at) and schedule.next_run_at <= ^now,
        select: {count(schedule.id), min(schedule.next_run_at)}

    lag_query = scope_schedules(lag_query, installation_id)

    case bounded(fn -> Repo.one(lag_query, timeout: @query_timeout_ms) end) do
      {:ok, {count, oldest}} ->
        lag_ms = age_ms(oldest, now)

        samples =
          tenant_samples(installation_id, due_schedule_samples(installation_id, now, count))

        :schedule_lag
        |> check(classify_age(lag_ms, :schedule_lag_ms), lag_ms, "ms")
        |> Map.put(:samples, samples)

      :unknown ->
        check(:schedule_lag, :unknown, nil, "ms")
    end
  end

  defp stale_attempts_check(installation_id, now) do
    cutoff = DateTime.add(now, -Concurrency.stale_after_seconds(), :second)

    query =
      from attempt in StepAttempt,
        join: step in StepExecution,
        on: step.id == attempt.step_execution_id,
        join: execution in Execution,
        on: execution.id == step.execution_id,
        where: attempt.status == "started",
        where: attempt.started_at < ^cutoff,
        where: execution.status == "running",
        select: {count(attempt.id), min(attempt.started_at)}

    query = scope_attempts(query, installation_id)

    case bounded(fn -> Repo.one(query, timeout: @query_timeout_ms) end) do
      {:ok, {count, _oldest}} ->
        samples =
          tenant_samples(installation_id, stale_attempt_samples(installation_id, cutoff, count))

        :stale_attempts
        |> check(classify_count(count, :stale_attempts), count, "attempts")
        |> Map.put(:samples, samples)

      :unknown ->
        check(:stale_attempts, :unknown, nil, "attempts")
    end
  end

  defp missing_jobs_check(installation_id) do
    case bounded(fn ->
           {missing_job_count(installation_id), missing_job_ids(installation_id)}
         end) do
      {:ok, {count, ids}} ->
        samples = tenant_samples(installation_id, Enum.map(ids, &%{kind: :execution, id: &1}))

        :missing_jobs
        |> check(classify_count(count, :missing_jobs), count, "executions")
        |> Map.put(:samples, samples)

      :unknown ->
        check(:missing_jobs, :unknown, nil, "executions")
    end
  end

  defp cleanup_lag_check(now) do
    status = Retention.status()

    case status.last_run_at do
      nil ->
        check(:cleanup_lag, :ok, nil, "ms")

      %DateTime{} = last_run_at ->
        lag_ms = age_ms(last_run_at, now)
        check(:cleanup_lag, classify_age(lag_ms, :cleanup_lag_ms), lag_ms, "ms")
    end
  rescue
    _exception ->
      log_unknown(:cleanup_lag)
      check(:cleanup_lag, :unknown, nil, "ms")
  end

  defp skipped_db_checks do
    Enum.map(
      [
        :oldest_available_job,
        :discarded_jobs,
        :schedule_lag,
        :stale_attempts,
        :missing_jobs,
        :cleanup_lag
      ],
      &check(&1, :unknown, nil, nil)
    )
  end

  defp missing_job_ids(installation_id) do
    running = missing_running(installation_id)
    waiting = missing_waiting(installation_id)
    queued = missing_queued(installation_id)
    Enum.take(Enum.uniq(running ++ waiting ++ queued), @sample_limit)
  end

  defp missing_job_count(installation_id) do
    length(missing_running(installation_id)) +
      length(missing_waiting(installation_id)) +
      length(missing_queued(installation_id))
  end

  defp missing_running(installation_id) do
    from(execution in Execution,
      as: :exec,
      where: execution.status == "running",
      where: is_nil(execution.cancelled_at),
      where: not exists(incomplete_advance_subquery()),
      where:
        not exists(
          from attempt in StepAttempt,
            join: step in StepExecution,
            on: step.id == attempt.step_execution_id,
            where: step.execution_id == parent_as(:exec).id,
            where: attempt.status == "started"
        ),
      select: execution.id,
      limit: ^@sample_limit
    )
    |> scope_executions(installation_id)
    |> Repo.all(timeout: @query_timeout_ms)
  end

  defp missing_waiting(installation_id) do
    from(execution in Execution,
      as: :exec,
      where: execution.status == "waiting_delay",
      where: is_nil(execution.cancelled_at),
      where: not exists(incomplete_advance_subquery()),
      select: execution.id,
      limit: ^@sample_limit
    )
    |> scope_executions(installation_id)
    |> Repo.all(timeout: @query_timeout_ms)
  end

  defp missing_queued(nil) do
    []
  end

  defp missing_queued(installation_id) do
    if Concurrency.open_slots(Repo, installation_id) > 0 do
      Repo
      |> Concurrency.admissions(installation_id)
      |> Enum.map(& &1.id)
      |> Enum.take(@sample_limit)
    else
      []
    end
  end

  defp incomplete_advance_subquery do
    from job in Oban.Job,
      where: job.worker == ^@advance_worker,
      where: job.state in ^@incomplete_job_states,
      where: fragment("? ->> 'execution_id' = ?::text", job.args, parent_as(:exec).id)
  end

  defp oldest_job_samples(_installation_id, 0), do: []

  defp oldest_job_samples(installation_id, _count) do
    query =
      from job in Oban.Job,
        where: job.state == "available",
        order_by: [asc: job.scheduled_at],
        limit: ^@sample_limit,
        select: %{
          kind: :job,
          id: job.id,
          queue: job.queue,
          execution_id: fragment("? ->> 'execution_id'", job.args)
        }

    query
    |> scope_jobs(installation_id)
    |> Repo.all(timeout: @query_timeout_ms)
    |> Enum.map(&sanitize_sample/1)
  end

  defp discarded_job_samples(_installation_id, 0), do: []

  defp discarded_job_samples(installation_id, _count) do
    query =
      from job in Oban.Job,
        where: job.state == "discarded",
        order_by: [desc: job.discarded_at],
        limit: ^@sample_limit,
        select: %{
          kind: :job,
          id: job.id,
          queue: job.queue,
          execution_id: fragment("? ->> 'execution_id'", job.args)
        }

    query
    |> scope_jobs(installation_id)
    |> Repo.all(timeout: @query_timeout_ms)
    |> Enum.map(&sanitize_sample/1)
  end

  defp due_schedule_samples(_installation_id, _now, 0), do: []

  defp due_schedule_samples(installation_id, now, _count) do
    query =
      from schedule in Schedule.due(now),
        order_by: [asc: schedule.next_run_at],
        limit: ^@sample_limit,
        select: %{
          kind: :schedule,
          id: schedule.id,
          workflow_id: schedule.workflow_id,
          next_run_at: schedule.next_run_at
        }

    query
    |> scope_schedules(installation_id)
    |> Repo.all(timeout: @query_timeout_ms)
  end

  defp stale_attempt_samples(_installation_id, _cutoff, 0), do: []

  defp stale_attempt_samples(installation_id, cutoff, _count) do
    query =
      from attempt in StepAttempt,
        join: step in StepExecution,
        on: step.id == attempt.step_execution_id,
        join: execution in Execution,
        on: execution.id == step.execution_id,
        where: attempt.status == "started",
        where: attempt.started_at < ^cutoff,
        where: execution.status == "running",
        order_by: [asc: attempt.started_at],
        limit: ^@sample_limit,
        select: %{kind: :execution, id: execution.id}

    query
    |> scope_attempts(installation_id)
    |> Repo.all(timeout: @query_timeout_ms)
  end

  defp sanitize_sample(sample) when is_map(sample) do
    Map.drop(sample, [:args, :errors, :unsaved_error, "args", "errors"])
  end

  defp tenant_samples(nil, _samples), do: []
  defp tenant_samples(_installation_id, samples), do: samples

  defp scope_jobs(query, nil), do: query

  defp scope_jobs(query, installation_id) do
    from job in query,
      where: fragment("? ->> 'installation_id' = ?", job.args, ^installation_id)
  end

  defp scope_schedules(query, nil), do: query

  defp scope_schedules(query, installation_id) do
    from schedule in query, where: schedule.installation_id == ^installation_id
  end

  defp scope_executions(query, nil), do: query

  defp scope_executions(query, installation_id) do
    from execution in query, where: execution.installation_id == ^installation_id
  end

  defp scope_attempts(query, nil), do: query

  defp scope_attempts(query, installation_id) do
    from [attempt, step, execution] in query,
      where: execution.installation_id == ^installation_id
  end

  defp latest_migration_version do
    Migrator.migrations(Repo)
    |> Enum.filter(fn {status, _version, _name} -> status == :up end)
    |> Enum.map(fn {_status, version, _name} -> version end)
    |> Enum.max(fn -> nil end)
  rescue
    _exception -> nil
  end

  defp pending_migration_count do
    Migrator.migrations(Repo)
    |> Enum.count(fn {status, _version, _name} -> status == :down end)
  rescue
    _exception -> nil
  end

  defp run_probe(fun) do
    fun.()
  rescue
    _exception ->
      log_unknown(:probe)
      :unknown
  catch
    _kind, _reason ->
      log_unknown(:probe)
      :unknown
  end

  defp bounded(fun) do
    {:ok, fun.()}
  rescue
    _exception -> unknown_query()
  catch
    _kind, _reason -> unknown_query()
  end

  defp unknown_query do
    log_unknown(:query)
    :unknown
  end

  defp log_unknown(operation) do
    Logging.event(:warning, "health.check", %{
      operation: "health.diagnostics",
      status: "unknown",
      error_code: "query_failed",
      error_class: "dependency",
      event_type: Atom.to_string(operation)
    })
  end

  defp classify_age(0, _key), do: :ok

  defp classify_age(value, key) when is_integer(value) do
    classify_number(
      value,
      Map.fetch!(@alert_thresholds, key),
      Map.fetch!(@readiness_thresholds, key)
    )
  end

  defp classify_count(count, key) when is_integer(count) do
    classify_number(
      count,
      Map.fetch!(@alert_thresholds, key),
      Map.fetch!(@readiness_thresholds, key)
    )
  end

  defp classify_number(value, _alert, ready) when value >= ready, do: :unhealthy
  defp classify_number(value, alert, _ready) when value >= alert, do: :degraded
  defp classify_number(_value, _alert, _ready), do: :ok

  defp overall(checks) do
    statuses = Enum.map(checks, & &1.status)

    cond do
      :unhealthy in statuses -> :unhealthy
      :unknown in statuses -> :unknown
      :degraded in statuses -> :degraded
      true -> :ok
    end
  end

  defp check(name, status, value, unit) do
    %{name: name, status: status, value: value, unit: unit, samples: []}
  end

  defp age_ms(nil, _now), do: 0

  defp age_ms(%DateTime{} = instant, now) do
    max(0, DateTime.diff(now, instant, :millisecond))
  end

  defp elapsed_ms(started) do
    System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)
  end
end
