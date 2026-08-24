defmodule PumbleAutomation.Executions.Workers.ScheduleDispatcherWorker do
  @moduledoc """
  Claims due clocks, creates one execution per occurrence, and advances next run.

  A static Oban cron entry runs this worker every minute. User-defined clocks
  stay in `schedules`; cron is only this system tick. Each due row is locked
  with `FOR UPDATE SKIP LOCKED` in its own transaction so two dispatchers
  cannot create the same occurrence, and a failure rolls back only that
  schedule. The worker snoozes for one second when a bounded batch leaves due
  rows, so supported load drains without waiting for another cron minute.

  ## Misfire policy

  The product contract does not support catch-up. After a restart gap this
  worker dispatches the **single most-recent** due instant for that clock and
  skips older missed instants. Skipped count is audited. Next run is computed
  from that most-recent scheduled instant through `ScheduleCalculator.next/2`,
  never from worker completion. A completed `once` clock is terminal
  (`next_run_at` becomes nil).

  ## Occupancy and lifecycle

  Executions are created through `Engine.create/2`, so inactive installations,
  deactivated workflows, version mismatch, and the five-slot occupancy limit
  apply unchanged. Disabled rows are not selected.
  """

  use Oban.Worker,
    queue: :schedules,
    max_attempts: 20,
    unique: [period: 45, states: :incomplete]

  import Ecto.Query, only: [from: 2, where: 3]

  alias Ecto.Multi
  alias PumbleAutomation.Audit.Writer
  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.FailureInjection
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Installations.Policy
  alias PumbleAutomation.Installations.Service
  alias PumbleAutomation.Limits
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows.Schedule
  alias PumbleAutomation.Workflows.ScheduleCalculator
  alias PumbleAutomation.Workflows.TriggerBinding
  alias PumbleAutomation.Workflows.Workflow

  @batch_size 50
  @candidate_scan_limit @batch_size * 2
  @continuation_delay_seconds 1
  @lock_timeout "3s"
  @telemetry_event [:pumble_automation, :schedule, :dispatch]

  @doc "How many due schedules one dispatcher run will try to claim."
  @spec batch_size() :: pos_integer()
  def batch_size, do: @batch_size

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case dispatch_due(DateTime.utc_now()) do
      {:ok, %{continuation?: true}} -> {:snooze, @continuation_delay_seconds}
      {:ok, _summary} -> :ok
      {:error, %Error{retryable?: true} = error} -> {:error, error.code}
      {:error, %Error{}} -> :ok
    end
  end

  @doc """
  Dispatches a bounded batch of due schedules as of `now`.

  `now` is injected so DST and misfire tests can pin the reference without
  reading the server clock. Production passes `DateTime.utc_now/0`.
  """
  @spec dispatch_due(DateTime.t()) :: {:ok, map()} | {:error, Error.t()}
  def dispatch_due(%DateTime{} = now) do
    now = utc(now)

    drain(
      now,
      @batch_size,
      @candidate_scan_limit,
      %{
        dispatched: 0,
        skipped: 0,
        failed: 0,
        claimed: 0,
        contended: 0,
        continuation?: false
      },
      []
    )
  end

  defp drain(now, remaining, _scans, acc, _excluded) when remaining <= 0 do
    {:ok, finalize(now, acc)}
  end

  defp drain(now, _remaining, scans, acc, _excluded) when scans <= 0 do
    {:ok, finalize(now, acc)}
  end

  defp drain(now, remaining, scans, acc, excluded) do
    case dispatch_next(now, excluded) do
      {:ok, :empty} ->
        {:ok, finalize(now, acc)}

      {:ok, :enqueued, skipped} ->
        drain(
          now,
          remaining - 1,
          scans - 1,
          %{
            acc
            | dispatched: acc.dispatched + 1,
              skipped: acc.skipped + skipped,
              claimed: acc.claimed + 1
          },
          excluded
        )

      {:ok, :skipped, skipped} ->
        drain(
          now,
          remaining - 1,
          scans - 1,
          %{acc | skipped: acc.skipped + skipped, claimed: acc.claimed + 1},
          excluded
        )

      {:ok, :failed} ->
        drain(
          now,
          remaining - 1,
          scans - 1,
          %{acc | failed: acc.failed + 1, claimed: acc.claimed + 1},
          excluded
        )

      {:ok, :contended, schedule_id} ->
        drain(
          now,
          remaining,
          scans - 1,
          %{acc | contended: acc.contended + 1},
          [schedule_id | excluded]
        )

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp dispatch_next(now, excluded_schedule_ids) do
    FailureInjection.crash(:schedule_dispatch)

    Multi.new()
    |> Service.as_multi()
    |> Multi.run(:candidate, fn repo, _changes ->
      lock_candidate_installation(repo, now, excluded_schedule_ids)
    end)
    |> Multi.run(:workflow, fn repo, %{candidate: candidate} ->
      lock_candidate_workflow(repo, candidate)
    end)
    |> Multi.run(:schedule, fn repo, %{candidate: candidate} ->
      lock_candidate_schedule(repo, candidate, now)
    end)
    |> Multi.run(:plan, fn _repo, %{schedule: schedule} -> plan(schedule, now) end)
    |> Multi.run(:execution, fn repo, changes -> create_or_skip(repo, changes) end)
    |> Multi.run(:advance, fn repo, changes -> persist(repo, changes, now) end)
    |> Writer.append(:audit, &audit_attrs/1)
    |> Repo.transaction()
    |> finish_dispatch(now)
  end

  # Lock order matches activation: installation -> workflow -> schedule. The
  # candidate query locks only the installation. Its join makes PostgreSQL skip
  # every due row for a tenant whose installation is already locked.
  defp lock_candidate_installation(repo, now, excluded_schedule_ids) do
    repo.query!("SELECT set_config('lock_timeout', $1, true)", [@lock_timeout])

    query =
      from schedule in Schedule,
        join: installation in Installation,
        on: installation.id == schedule.installation_id,
        where:
          schedule.enabled and not is_nil(schedule.next_run_at) and
            schedule.next_run_at <= ^now and schedule.id not in ^excluded_schedule_ids,
        order_by: [asc: schedule.next_run_at, asc: schedule.id],
        limit: 1,
        lock: fragment("FOR UPDATE OF ? SKIP LOCKED", installation),
        select: %{
          schedule_id: schedule.id,
          workflow_id: schedule.workflow_id,
          installation_id: schedule.installation_id
        }

    case repo.one(query) do
      nil -> {:error, :empty}
      candidate -> {:ok, candidate}
    end
  end

  defp lock_candidate_workflow(repo, candidate) do
    query =
      from workflow in Workflow,
        where:
          workflow.id == ^candidate.workflow_id and
            workflow.installation_id == ^candidate.installation_id,
        lock: "FOR UPDATE SKIP LOCKED"

    case repo.one(query) do
      %Workflow{} = workflow -> {:ok, workflow}
      nil -> {:error, {:contended, candidate.schedule_id}}
    end
  end

  defp lock_candidate_schedule(repo, candidate, now) do
    query =
      now
      |> Schedule.lock_due(1)
      |> where(
        [schedule],
        schedule.id == ^candidate.schedule_id and
          schedule.installation_id == ^candidate.installation_id and
          schedule.workflow_id == ^candidate.workflow_id
      )

    case repo.one(query) do
      %Schedule{} = schedule -> {:ok, schedule}
      nil -> {:error, {:contended, candidate.schedule_id}}
    end
  end

  defp plan(%Schedule{} = schedule, now) do
    occurrence = utc(schedule.next_run_at)

    case ScheduleCalculator.latest_due(schedule.config, occurrence, now) do
      {:ok, latest} ->
        {:ok, Map.put(latest, :kind, :dispatch)}

      {:error, %Error{retryable?: true} = error} ->
        {:error, error}

      {:error, %Error{} = error} ->
        {:ok,
         %{
           kind: :failed,
           occurrence: occurrence,
           next_run_at: nil,
           skipped: 0,
           error: error
         }}
    end
  end

  defp create_or_skip(repo, %{plan: %{kind: :dispatch} = plan, schedule: schedule}) do
    key = Schedule.occurrence_key(schedule, plan.occurrence)

    with :ok <- admit_installation(repo, schedule),
         :ok <- admit_workflow(repo, schedule),
         :ok <- admit_binding(repo, schedule),
         :absent <- existing_execution(repo, schedule.installation_id, key),
         :ok <- admit_queued_quota(repo, schedule.installation_id) do
      enqueue_occurrence(schedule, plan, key)
    else
      {:existing, execution} -> {:ok, {:enqueued, execution}}
      {:skip, %Error{} = error} -> {:ok, {:skipped, error}}
    end
  end

  defp create_or_skip(_repo, %{plan: %{kind: :failed, error: error}}) do
    {:ok, {:failed, error}}
  end

  defp create_or_skip(_repo, %{plan: %{kind: :not_due}}) do
    {:ok, {:skipped, :not_due}}
  end

  defp enqueue_occurrence(schedule, plan, key) do
    attrs = %{
      workflow_version_id: schedule.workflow_version_id,
      execution_key: key,
      trigger_snapshot: trigger_snapshot(schedule, plan),
      run_mode: "live"
    }

    case Engine.create(schedule.installation_id, attrs) do
      {:ok, execution} -> {:ok, {:enqueued, execution}}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  # Check the cap before `Engine.create/2`. A failed nested create rolls this
  # claim transaction back, which would pin the clock at the head of the due
  # set and starve later tenants.
  defp admit_queued_quota(repo, installation_id) do
    limit = Limits.get(:queued_executions)

    count =
      repo.aggregate(
        from(row in Execution,
          where: row.installation_id == ^installation_id and row.status == "queued"
        ),
        :count
      )

    if count >= limit do
      Limits.record_hit(:queued_executions, installation_id)

      {:skip,
       Error.new(:validation, :queued_executions_limit,
         retryable?: true,
         message: "This workspace has too many queued executions."
       )}
    else
      :ok
    end
  end

  defp admit_installation(repo, %Schedule{} = schedule) do
    case repo.get(Installation, schedule.installation_id) do
      %Installation{status: "active"} ->
        :ok

      %Installation{} ->
        {:skip,
         Error.new(:permission, :installation_revoked,
           message: "This workspace's authorization is no longer valid."
         )}

      nil ->
        {:skip, Policy.not_found()}
    end
  end

  defp admit_workflow(repo, %Schedule{} = schedule) do
    query =
      from workflow in Workflow,
        where:
          workflow.id == ^schedule.workflow_id and
            workflow.installation_id == ^schedule.installation_id

    case repo.one(query) do
      %Workflow{status: "active", active_version_id: version_id}
      when version_id == schedule.workflow_version_id ->
        :ok

      %Workflow{status: "active"} ->
        {:skip,
         Error.new(:conflict, :version_mismatch,
           message: "That workflow version is not the live program."
         )}

      %Workflow{} ->
        {:skip, Error.new(:conflict, :not_active, message: "That workflow is not running.")}

      nil ->
        Scope.record_if_foreign(
          Workflow,
          schedule.workflow_id,
          schedule.installation_id,
          :schedules
        )

        {:skip, Policy.not_found()}
    end
  end

  defp admit_binding(repo, %Schedule{} = schedule) do
    query =
      from binding in TriggerBinding,
        where:
          binding.installation_id == ^schedule.installation_id and
            binding.workflow_version_id == ^schedule.workflow_version_id and
            binding.enabled,
        limit: 1

    case repo.one(query) do
      %TriggerBinding{} ->
        :ok

      nil ->
        {:skip, Error.new(:conflict, :not_active, message: "That workflow is not running.")}
    end
  end

  defp existing_execution(repo, installation_id, key) do
    query =
      from execution in Execution,
        where: execution.installation_id == ^installation_id and execution.execution_key == ^key

    case repo.one(query) do
      %Execution{} = execution -> {:existing, execution}
      nil -> :absent
    end
  end

  defp persist(repo, %{schedule: schedule, plan: plan, execution: result}, now) do
    {status, next_run_at, last_run_at} = persist_fields(plan, result)

    schedule
    |> Schedule.changeset(%{
      next_run_at: next_run_at,
      last_run_at: last_run_at,
      last_dispatched_at: now,
      last_dispatch_status: status,
      dispatch_count: schedule.dispatch_count + 1,
      lock_version: schedule.lock_version + 1
    })
    |> repo.update()
  end

  defp persist_fields(plan, {:enqueued, _execution}) do
    {"enqueued", plan.next_run_at, plan.occurrence}
  end

  defp persist_fields(plan, {:skipped, _reason}) do
    {"skipped", plan.next_run_at, plan.occurrence}
  end

  defp persist_fields(plan, {:failed, _error}) do
    {"failed", nil, plan.occurrence}
  end

  defp trigger_snapshot(%Schedule{} = schedule, plan) do
    %{
      "type" => "schedule",
      "schedule_id" => schedule.id,
      "schedule_type" => schedule.schedule_type,
      "timezone" => schedule.timezone,
      "scheduled_at" => DateTime.to_iso8601(plan.occurrence)
    }
  end

  defp audit_attrs(%{schedule: schedule, plan: plan, execution: result}) do
    %{
      installation_id: schedule.installation_id,
      actor_type: "job",
      action: "schedule.dispatched",
      resource_type: "schedule",
      resource_id: schedule.id,
      metadata: audit_metadata(plan, result)
    }
  end

  defp audit_metadata(plan, {:enqueued, _execution}) do
    %{result: "enqueued", source: "dispatcher", count: plan.skipped}
  end

  defp audit_metadata(plan, {:skipped, %Error{} = error}) do
    %{
      result: "skipped",
      source: "dispatcher",
      count: plan.skipped,
      reason: Atom.to_string(error.code)
    }
  end

  defp audit_metadata(plan, {:skipped, :not_due}) do
    %{result: "skipped", source: "dispatcher", count: plan.skipped, reason: "not_due"}
  end

  defp audit_metadata(plan, {:failed, %Error{} = error}) do
    %{
      result: "failed",
      source: "dispatcher",
      count: plan.skipped,
      reason: Atom.to_string(error.code)
    }
  end

  defp finish_dispatch({:ok, changes}, now) do
    emit_lag(changes, now)

    case outcome(changes) do
      {:enqueued, skipped} -> {:ok, :enqueued, skipped}
      {:skipped, skipped} -> {:ok, :skipped, skipped}
      :failed -> {:ok, :failed}
    end
  end

  defp finish_dispatch({:error, :candidate, :empty, _changes}, _now), do: {:ok, :empty}

  defp finish_dispatch({:error, step, {:contended, schedule_id}, _changes}, _now)
       when step in [:workflow, :schedule] do
    {:ok, :contended, schedule_id}
  end

  defp finish_dispatch({:error, _step, %Error{} = error, _changes}, _now) do
    {:error, error}
  end

  defp finish_dispatch({:error, _step, reason, _changes}, _now) do
    {:error,
     Error.new(:internal, :schedule_dispatch_failed,
       message: "The due schedule could not be dispatched.",
       details: %{reason: inspect(reason)}
     )}
  end

  defp outcome(%{execution: {:enqueued, _execution}, plan: plan}), do: {:enqueued, plan.skipped}
  defp outcome(%{execution: {:skipped, _reason}, plan: plan}), do: {:skipped, plan.skipped + 1}
  defp outcome(%{execution: {:failed, _error}}), do: :failed

  defp emit_lag(
         %{plan: %{kind: :dispatch, occurrence: occurrence}, execution: {:enqueued, _}},
         now
       ) do
    lag_ms = max(DateTime.diff(now, occurrence, :millisecond), 0)

    :telemetry.execute(
      @telemetry_event,
      %{count: 1, lag_ms: lag_ms},
      %{outcome: "enqueued"}
    )
  end

  defp emit_lag(_changes, _now), do: :ok

  defp finalize(now, summary) do
    %{summary | continuation?: Repo.exists?(Schedule.due(now))}
  end

  defp utc(%DateTime{} = datetime) do
    DateTime.from_unix!(DateTime.to_unix(datetime, :microsecond), :microsecond)
  end
end
