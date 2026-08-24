defmodule PumbleAutomation.Performance.SchedulerCapacityTest do
  @moduledoc """
  Bounded scheduler batch and tenant-fairness proof.

  The fixture spans three tenants. Each tenant reaches the configured active-
  workflow limit and remains below the queue limit while the global due set
  crosses one worker batch. Durations are observations; counts, query shape,
  and fairness are the deterministic gates.
  """

  use PumbleAutomation.DataCase, async: false
  use Oban.Testing, repo: PumbleAutomation.Repo

  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Executions.Concurrency
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.Workers.AdvanceExecutionWorker
  alias PumbleAutomation.Executions.Workers.ScheduleDispatcherWorker
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Limits
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Definition.Trigger
  alias PumbleAutomation.Workflows.Schedule

  @tenant_count 3
  @max_queries_per_claim 30

  test "the production worker snoozes at the cap and its next run drains all due clocks" do
    batch_size = ScheduleDispatcherWorker.batch_size()
    workflows_per_tenant = Limits.get(:active_workflows)
    due_count = @tenant_count * workflows_per_tenant
    remainder = due_count - batch_size
    admitted_jobs = @tenant_count * Concurrency.max_running()
    now = DateTime.utc_now()

    contexts =
      for _index <- 1..@tenant_count do
        %{installation: installation, member: member} = InstallationsFixtures.install()
        %{installation_id: installation.id, scope: Scope.new(member)}
      end

    schedules =
      for index <- 0..(due_count - 1) do
        context = Enum.at(contexts, rem(index, @tenant_count))
        schedule = activate_clock!(context, index)
        occurrence = DateTime.add(now, -(due_count + 5 - index), :second)
        stamp!(schedule, occurrence)
      end

    assert length(schedules) == due_count

    lock_query = Schedule.lock_due(now, batch_size)
    {lock_sql, _params} = Repo.to_sql(:all, lock_query)
    assert lock_sql =~ "LIMIT"
    assert lock_sql =~ "FOR UPDATE SKIP LOCKED"
    assert lock_sql =~ "next_run_at"

    plan = explain_index_plan(Schedule.due(now), analyze: true)
    assert index_backed?(plan)
    refute plan =~ "Seq Scan on schedules"
    emit_plan("scheduler_due", plan, true)

    {first_result, first_queries, first_us} =
      trace_timed_queries(fn -> ScheduleDispatcherWorker.perform(%Oban.Job{args: %{}}) end)

    assert first_result == {:snooze, 1}
    assert length(first_queries) <= batch_size * @max_queries_per_claim + 5
    assert execution_count() == batch_size
    assert due_schedule_count(now) == remainder
    assert length(all_enqueued(worker: AdvanceExecutionWorker)) == admitted_jobs

    first_counts = tenant_execution_counts(contexts)
    assert Enum.sort(first_counts) == [16, 17, 17]

    {second_result, second_queries, second_us} =
      trace_timed_queries(fn -> ScheduleDispatcherWorker.perform(%Oban.Job{args: %{}}) end)

    assert second_result == :ok
    assert length(second_queries) <= remainder * @max_queries_per_claim + 5
    assert execution_count() == due_count
    assert due_schedule_count(now) == 0
    assert length(all_enqueued(worker: AdvanceExecutionWorker)) == admitted_jobs
    final_counts = List.duplicate(workflows_per_tenant, @tenant_count)
    assert tenant_execution_counts(contexts) == final_counts

    emit_metric("scheduler_batch", due_count, first_us + second_us,
      batch_size: batch_size,
      first_batch_queries: length(first_queries),
      second_batch_queries: length(second_queries),
      admitted_jobs: admitted_jobs,
      continuation_count: remainder,
      parked_executions: due_count - admitted_jobs,
      first_tenant_counts: Enum.join(first_counts, ","),
      final_tenant_counts: Enum.join(final_counts, ",")
    )
  end

  defp activate_clock!(context, index) do
    definition =
      Definition.new(
        Trigger.new(:schedule, %{
          schedule_type: :every_minutes,
          interval: 15,
          timezone: "Etc/UTC"
        }),
        [delay_node()]
      )

    workflow =
      drafted_workflow(context.installation_id, %{
        name: "Capacity clock #{index}",
        draft_definition: Definition.encode(definition)
      })

    assert {:ok, _activated} = Workflows.activate_workflow(context.scope, workflow.id, 0)
    Repo.one!(from schedule in Schedule, where: schedule.workflow_id == ^workflow.id)
  end

  defp stamp!(schedule, occurrence) do
    schedule
    |> Schedule.changeset(%{next_run_at: occurrence})
    |> Repo.update!()
  end

  defp due_schedule_count(now) do
    Repo.aggregate(
      from(schedule in Schedule,
        where:
          schedule.enabled and not is_nil(schedule.next_run_at) and
            schedule.next_run_at <= ^now
      ),
      :count
    )
  end

  defp execution_count, do: Repo.aggregate(Execution, :count)

  defp tenant_execution_counts(contexts) do
    Enum.map(contexts, fn context ->
      Repo.aggregate(
        from(execution in Execution,
          where: execution.installation_id == ^context.installation_id
        ),
        :count
      )
    end)
  end

  defp trace_timed_queries(fun) do
    handler = "capacity-scheduler-trace-#{System.unique_integer([:positive])}"
    counter = :counters.new(1, [])
    mine = self()

    :ok =
      :telemetry.attach(
        handler,
        [:pumble_automation, :repo, :query],
        fn _event, _measurements, _metadata, _config ->
          if self() == mine, do: :counters.add(counter, 1, 1)
        end,
        nil
      )

    try do
      {elapsed_us, result} = :timer.tc(fun)
      {result, List.duplicate(:query, :counters.get(counter, 1)), elapsed_us}
    after
      :telemetry.detach(handler)
    end
  end

  defp emit_metric(name, count, elapsed_us, metadata) do
    details = Enum.map_join(metadata, " ", fn {key, value} -> "#{key}=#{value}" end)

    IO.puts(
      "CAPACITY_METRIC name=#{name} count=#{count} total_us=#{elapsed_us} " <>
        "avg_us=#{div(elapsed_us, count)} #{details} gate=semantic"
    )
  end

  defp emit_plan(name, plan, index_backed) do
    digest = :sha256 |> :crypto.hash(plan) |> Base.encode16(case: :lower) |> binary_part(0, 16)

    IO.puts(
      "CAPACITY_PLAN name=#{name} index_backed=#{index_backed} " <>
        "seq_schedules=#{plan =~ "Seq Scan on schedules"} digest=#{digest}"
    )
  end
end
