defmodule PumbleAutomation.Executions.Workers.ScheduleDispatcherTest do
  @moduledoc """
  Due clocks are claimed with SKIP LOCKED, one occurrence key per instant,
  and next_run_at advances from the scheduled instant. Misfires keep only
  the most-recent due slot.
  """

  # One quota test temporarily changes the application-wide limits catalog.
  # Keep the module synchronous so that override cannot affect another test.
  use PumbleAutomation.DataCase, async: false
  use Oban.Testing, repo: PumbleAutomation.Repo

  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Audit.AuditEvent
  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.Workers.AdvanceExecutionWorker
  alias PumbleAutomation.Executions.Workers.ScheduleDispatcherWorker
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Definition.Trigger
  alias PumbleAutomation.Workflows.Schedule
  alias PumbleAutomation.Workflows.ScheduleCalculator

  setup do
    %{installation: installation, member: member} = InstallationsFixtures.install()

    %{
      scope: Scope.new(member),
      installation: installation,
      installation_id: installation.id
    }
  end

  describe "perform/1" do
    test "creates one execution and advances next run for a due clock", context do
      {_activated, schedule} =
        activate_clock!(context, %{
          schedule_type: :every_minutes,
          interval: 15,
          timezone: "Etc/UTC"
        })

      occurrence = minutes_ago(1)
      schedule = stamp!(schedule, occurrence)

      assert :ok = perform_job(ScheduleDispatcherWorker, %{})

      [execution] = executions(context.installation_id)
      assert execution.execution_key == Schedule.occurrence_key(schedule, occurrence)
      assert execution.workflow_version_id == schedule.workflow_version_id
      assert execution.trigger_snapshot["type"] == "schedule"
      assert execution.trigger_snapshot["schedule_id"] == schedule.id

      assert_enqueued(
        worker: AdvanceExecutionWorker,
        args: %{
          installation_id: execution.installation_id,
          execution_id: execution.id,
          expected_node_id: execution.current_node_id,
          generation: 0
        }
      )

      updated = Repo.get!(Schedule, schedule.id)
      assert {:ok, expected_next} = ScheduleCalculator.next(schedule.config, occurrence)
      assert DateTime.compare(updated.next_run_at, expected_next) == :eq
      assert updated.last_dispatch_status == "enqueued"
      assert updated.dispatch_count == 1
      assert DateTime.compare(updated.last_run_at, occurrence) == :eq
    end

    test "a queue-cap refusal skips that clock and still dispatches the next tenant", context do
      previous = Application.get_env(:pumble_automation, :limits, %{})

      Application.put_env(
        :pumble_automation,
        :limits,
        Map.merge(previous, %{queued_executions: 1})
      )

      on_exit(fn -> Application.put_env(:pumble_automation, :limits, previous) end)

      {_activated, blocked} =
        activate_clock!(context, %{
          schedule_type: :every_minutes,
          interval: 15,
          timezone: "Etc/UTC"
        })

      # The quota counts every queued row. One filler fills the cap so the
      # due clock must skip instead of pinning the dispatcher on this tenant.
      {:ok, filler} =
        Engine.create(context.installation_id, %{
          workflow_version_id: blocked.workflow_version_id,
          execution_key: "queue-fill-#{System.unique_integer([:positive])}",
          trigger_snapshot: %{"type" => "manual"},
          run_mode: "live"
        })

      assert filler.status == "queued"

      stamp!(blocked, minutes_ago(2))

      other = InstallationsFixtures.install()

      other_context = %{
        scope: Scope.new(other.member),
        installation_id: other.installation.id
      }

      {_activated, ready} =
        activate_clock!(other_context, %{
          schedule_type: :every_minutes,
          interval: 15,
          timezone: "Etc/UTC"
        })

      stamp!(ready, minutes_ago(1))

      assert {:ok, summary} = ScheduleDispatcherWorker.dispatch_due(DateTime.utc_now())
      assert summary.skipped >= 1
      assert summary.dispatched >= 1
      assert Repo.get!(Schedule, blocked.id).last_dispatch_status == "skipped"
      assert Repo.get!(Schedule, ready.id).last_dispatch_status == "enqueued"
    end
  end

  describe "restart gap and misfires" do
    test "dispatches the most-recent missed instant and skips the older ones", context do
      {_activated, schedule} =
        activate_clock!(context, %{
          schedule_type: :every_hours,
          interval: 1,
          timezone: "Etc/UTC"
        })

      now = utc("2026-06-01T15:00:00Z")
      first_missed = utc("2026-06-01T10:00:00Z")
      most_recent = utc("2026-06-01T15:00:00Z")
      stamp!(schedule, first_missed)

      assert {:ok, summary} = ScheduleDispatcherWorker.dispatch_due(now)
      assert summary.dispatched == 1
      assert summary.skipped == 5

      [execution] = executions(context.installation_id)
      assert execution.execution_key == Schedule.occurrence_key(schedule, most_recent)

      updated = Repo.get!(Schedule, schedule.id)
      assert DateTime.compare(updated.next_run_at, utc("2026-06-01T16:00:00Z")) == :eq
      assert updated.last_dispatch_status == "enqueued"

      audit = Repo.get_by!(AuditEvent, action: "schedule.dispatched", resource_id: schedule.id)
      assert audit.metadata["result"] == "enqueued"
      assert audit.metadata["count"] == 5
      assert audit.actor_type == "job"
    end

    test "a second dispatch of the same occurrence does not insert another execution",
         context do
      {_activated, schedule} =
        activate_clock!(context, %{
          schedule_type: :every_minutes,
          interval: 15,
          timezone: "Etc/UTC"
        })

      now = utc("2026-06-01T12:00:01Z")
      occurrence = utc("2026-06-01T12:00:00Z")
      stamp!(schedule, occurrence)

      assert {:ok, _} = ScheduleDispatcherWorker.dispatch_due(now)
      stamp!(Repo.get!(Schedule, schedule.id), occurrence)
      assert {:ok, _} = ScheduleDispatcherWorker.dispatch_due(now)

      assert Repo.aggregate(
               from(e in Execution, where: e.installation_id == ^context.installation_id),
               :count
             ) == 1
    end

    test "a minute clock stale by years dispatches once and remains scheduled", context do
      {_activated, schedule} =
        activate_clock!(context, %{
          schedule_type: :every_minutes,
          interval: 1,
          timezone: "Etc/UTC"
        })

      first_missed = utc("2020-01-01T00:00:00Z")
      now = utc("2026-08-24T12:34:56Z")
      most_recent = utc("2026-08-24T12:34:00Z")
      stamp!(schedule, first_missed)

      assert {:ok, %{dispatched: 1, failed: 0}} =
               ScheduleDispatcherWorker.dispatch_due(now)

      [execution] = executions(context.installation_id)
      assert execution.execution_key == Schedule.occurrence_key(schedule, most_recent)

      updated = Repo.get!(Schedule, schedule.id)
      assert updated.next_run_at == utc("2026-08-24T12:35:00Z")
      assert updated.last_dispatch_status == "enqueued"
    end

    test "a stale multi-day weekly clock dispatches only its latest selected weekday", context do
      {_activated, schedule} =
        activate_clock!(context, %{
          schedule_type: :weekly,
          time_of_day: "09:00",
          weekdays: ["monday", "wednesday", "friday"],
          timezone: "Europe/Belgrade"
        })

      first_missed = utc("2020-01-06T08:00:00Z")
      now = utc("2026-08-24T12:00:00Z")
      most_recent = utc("2026-08-24T07:00:00Z")
      stamp!(schedule, first_missed)

      assert {:ok, %{dispatched: 1, skipped: 1_038, failed: 0}} =
               ScheduleDispatcherWorker.dispatch_due(now)

      [execution] = executions(context.installation_id)
      assert execution.execution_key == Schedule.occurrence_key(schedule, most_recent)
      assert execution.trigger_snapshot["scheduled_at"] == DateTime.to_iso8601(most_recent)

      updated = Repo.get!(Schedule, schedule.id)
      assert updated.next_run_at == utc("2026-08-26T07:00:00Z")
      assert updated.last_run_at == most_recent
      assert updated.last_dispatch_status == "enqueued"
    end
  end

  describe "DST occurrence" do
    test "America/New_York spring gap uses the first valid instant after 02:30", context do
      {_activated, schedule} =
        activate_clock!(context, %{
          schedule_type: :daily,
          time_of_day: "02:30",
          timezone: "America/New_York"
        })

      occurrence = utc("2026-03-08T07:00:00Z")
      now = utc("2026-03-08T07:00:01Z")
      stamp!(schedule, occurrence)

      assert {:ok, %{dispatched: 1}} = ScheduleDispatcherWorker.dispatch_due(now)

      [execution] = executions(context.installation_id)
      assert execution.execution_key == Schedule.occurrence_key(schedule, occurrence)
      assert execution.trigger_snapshot["scheduled_at"] == DateTime.to_iso8601(occurrence)
      assert execution.trigger_snapshot["timezone"] == "America/New_York"

      updated = Repo.get!(Schedule, schedule.id)
      assert {:ok, expected_next} = ScheduleCalculator.next(schedule.config, occurrence)
      assert DateTime.compare(updated.next_run_at, expected_next) == :eq
    end

    test "America/New_York overlap dispatches the earlier 01:30 occurrence once", context do
      {_activated, schedule} =
        activate_clock!(context, %{
          schedule_type: :daily,
          time_of_day: "01:30",
          timezone: "America/New_York"
        })

      first_missed = utc("2026-10-31T05:30:00Z")
      overlap_occurrence = utc("2026-11-01T05:30:00Z")
      after_both_overlap_instants = utc("2026-11-01T06:31:00Z")
      stamp!(schedule, first_missed)

      assert {:ok, %{dispatched: 1, skipped: 1}} =
               ScheduleDispatcherWorker.dispatch_due(after_both_overlap_instants)

      [execution] = executions(context.installation_id)
      assert execution.execution_key == Schedule.occurrence_key(schedule, overlap_occurrence)
      assert execution.trigger_snapshot["scheduled_at"] == DateTime.to_iso8601(overlap_occurrence)

      updated = Repo.get!(Schedule, schedule.id)
      assert updated.next_run_at == utc("2026-11-02T06:30:00Z")
      assert updated.last_run_at == overlap_occurrence
    end
  end

  describe "one-time completion" do
    test "a due once clock dispatches once and then becomes terminal", context do
      run_at = utc("2026-01-15T12:00:00Z")

      {_activated, schedule} =
        activate_clock!(context, %{
          schedule_type: :once,
          run_at: DateTime.to_iso8601(run_at),
          timezone: "Etc/UTC"
        })

      stamp!(schedule, run_at)
      now = utc("2026-01-15T12:00:01Z")

      assert {:ok, %{dispatched: 1}} = ScheduleDispatcherWorker.dispatch_due(now)

      [execution] = executions(context.installation_id)
      assert execution.execution_key == Schedule.occurrence_key(schedule, run_at)

      updated = Repo.get!(Schedule, schedule.id)
      assert is_nil(updated.next_run_at)
      assert updated.last_dispatch_status == "enqueued"
      assert updated.enabled

      assert {:ok,
              %{
                dispatched: 0,
                skipped: 0,
                failed: 0,
                claimed: 0,
                contended: 0,
                continuation?: false
              }} =
               ScheduleDispatcherWorker.dispatch_due(utc("2026-01-16T00:00:00Z"))

      assert Repo.aggregate(
               from(e in Execution, where: e.installation_id == ^context.installation_id),
               :count
             ) == 1
    end
  end

  describe "disabled and uninstalled" do
    test "a disabled schedule is not dispatched", context do
      {_activated, schedule} =
        activate_clock!(context, %{
          schedule_type: :every_minutes,
          interval: 15,
          timezone: "Etc/UTC"
        })

      stamp!(schedule, minutes_ago(5))
      schedule |> Schedule.changeset(%{enabled: false}) |> Repo.update!()

      assert {:ok, %{dispatched: 0}} = ScheduleDispatcherWorker.dispatch_due(DateTime.utc_now())
      assert executions(context.installation_id) == []
    end

    test "a revoked installation does not create an execution", context do
      {_activated, schedule} =
        activate_clock!(context, %{
          schedule_type: :every_minutes,
          interval: 15,
          timezone: "Etc/UTC"
        })

      occurrence = minutes_ago(1)
      stamp!(schedule, occurrence)

      context.installation
      |> Installation.changeset(%{status: "revoked"})
      |> Repo.update!()

      assert {:ok, summary} = ScheduleDispatcherWorker.dispatch_due(DateTime.utc_now())
      assert summary.dispatched == 0
      assert executions(context.installation_id) == []

      updated = Repo.get!(Schedule, schedule.id)
      assert updated.last_dispatch_status == "skipped"
      assert {:ok, expected_next} = ScheduleCalculator.next(schedule.config, occurrence)
      assert DateTime.compare(updated.next_run_at, expected_next) == :eq
    end

    test "deactivation before dispatch prevents the occurrence", context do
      {activated, schedule} =
        activate_clock!(context, %{
          schedule_type: :every_minutes,
          interval: 15,
          timezone: "Etc/UTC"
        })

      stamp!(schedule, minutes_ago(2))
      {:ok, _} = Workflows.deactivate_workflow(context.scope, activated.workflow.id)

      assert {:ok, %{dispatched: 0}} = ScheduleDispatcherWorker.dispatch_due(DateTime.utc_now())
      assert executions(context.installation_id) == []
    end
  end

  describe "lock_due/2" do
    test "the lock query uses SKIP LOCKED and the due predicate" do
      query = Schedule.lock_due(DateTime.utc_now(), 1)
      {sql, _params} = Repo.to_sql(:all, query)
      assert sql =~ "FOR UPDATE SKIP LOCKED"
      assert sql =~ "enabled"
      assert sql =~ "next_run_at"
    end
  end

  defp activate_clock!(context, config) do
    definition = Definition.new(Trigger.new(:schedule, config), [delay_node(), stop_node()])

    workflow =
      drafted_workflow(context.installation_id, %{
        draft_definition: Definition.encode(definition)
      })

    {:ok, activated} = Workflows.activate_workflow(context.scope, workflow.id, 0)

    schedule =
      Repo.one!(from s in Schedule, where: s.workflow_id == ^workflow.id and s.enabled)

    {activated, schedule}
  end

  defp stamp!(%Schedule{} = schedule, %DateTime{} = next_run_at) do
    schedule
    |> Schedule.changeset(%{next_run_at: next_run_at})
    |> Repo.update!()
  end

  defp executions(installation_id) do
    Repo.all(from e in Execution, where: e.installation_id == ^installation_id)
  end

  defp minutes_ago(minutes), do: DateTime.add(DateTime.utc_now(), -minutes * 60, :second)

  defp utc(iso) when is_binary(iso) do
    {:ok, datetime, 0} = DateTime.from_iso8601(iso)
    DateTime.from_unix!(DateTime.to_unix(datetime, :microsecond), :microsecond)
  end
end

defmodule PumbleAutomation.Executions.Workers.ScheduleDispatcherUnsandboxedTest do
  @moduledoc """
  Dispatcher contention, a disable race, and a rejected job insert need a real
  database. The sandbox cannot express `SKIP LOCKED` across connections, and
  a trigger on `oban_jobs` disconnects the sandboxed connection.
  """

  use ExUnit.Case, async: false
  use Oban.Testing, repo: PumbleAutomation.Repo

  import Ecto.Query, only: [from: 2]
  import PumbleAutomation.WorkflowsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.Workers.ScheduleDispatcherWorker
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Definition.Trigger
  alias PumbleAutomation.Workflows.Schedule

  setup do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  test "two dispatchers create one execution for one occurrence" do
    %{installation: installation, member: member} = InstallationsFixtures.install()
    on_exit(fn -> cleanup!(installation.id) end)

    scope = Scope.new(member)
    {_activated, schedule} = activate_clock!(scope, installation.id)
    occurrence = DateTime.add(DateTime.utc_now(), -30, :second)
    stamp!(schedule, occurrence)
    now = DateTime.utc_now()

    results =
      1..2
      |> Task.async_stream(
        fn _index -> ScheduleDispatcherWorker.dispatch_due(now) end,
        max_concurrency: 2,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, _summary}, &1))

    stored =
      Repo.all(from e in Execution, where: e.installation_id == ^installation.id)

    assert length(stored) == 1
    assert hd(stored).execution_key == Schedule.occurrence_key(schedule, occurrence)
  end

  test "a locked installation is skipped so another tenant can dispatch" do
    first = InstallationsFixtures.install()
    second = InstallationsFixtures.install()
    on_exit(fn -> cleanup!(first.installation.id) end)
    on_exit(fn -> cleanup!(second.installation.id) end)

    {_activated, first_schedule} =
      activate_clock!(Scope.new(first.member), first.installation.id)

    {_activated, second_schedule} =
      activate_clock!(Scope.new(second.member), second.installation.id)

    now = DateTime.utc_now()
    stamp!(first_schedule, DateTime.add(now, -120, :second))
    stamp!(second_schedule, DateTime.add(now, -60, :second))

    holder =
      hold_lock!(
        from(installation in Installation,
          where: installation.id == ^first.installation.id,
          lock: "FOR UPDATE"
        )
      )

    on_exit(fn -> release_lock(holder) end)

    assert {:ok, %{dispatched: 1}} = ScheduleDispatcherWorker.dispatch_due(now)

    refute Repo.exists?(
             from execution in Execution,
               where: execution.installation_id == ^first.installation.id
           )

    assert Repo.exists?(
             from execution in Execution,
               where: execution.installation_id == ^second.installation.id
           )

    release_lock!(holder)
  end

  test "a locked schedule is skipped so another due schedule can dispatch" do
    first = InstallationsFixtures.install()
    second = InstallationsFixtures.install()
    on_exit(fn -> cleanup!(first.installation.id) end)
    on_exit(fn -> cleanup!(second.installation.id) end)

    {_activated, first_schedule} =
      activate_clock!(Scope.new(first.member), first.installation.id)

    {_activated, second_schedule} =
      activate_clock!(Scope.new(second.member), second.installation.id)

    now = DateTime.utc_now()
    stamp!(first_schedule, DateTime.add(now, -120, :second))
    stamp!(second_schedule, DateTime.add(now, -60, :second))

    holder =
      hold_lock!(
        from(schedule in Schedule,
          where: schedule.id == ^first_schedule.id,
          lock: "FOR UPDATE"
        )
      )

    on_exit(fn -> release_lock(holder) end)

    assert {:ok, %{dispatched: 1}} = ScheduleDispatcherWorker.dispatch_due(now)

    refute Repo.exists?(
             from execution in Execution,
               where: execution.installation_id == ^first.installation.id
           )

    assert Repo.exists?(
             from execution in Execution,
               where: execution.installation_id == ^second.installation.id
           )

    release_lock!(holder)
  end

  test "a disable race leaves at most one execution and stops further dispatch" do
    %{installation: installation, member: member} = InstallationsFixtures.install()
    on_exit(fn -> cleanup!(installation.id) end)

    scope = Scope.new(member)
    {_activated, schedule} = activate_clock!(scope, installation.id)
    stamp!(schedule, DateTime.add(DateTime.utc_now(), -30, :second))
    now = DateTime.utc_now()

    results =
      Task.async_stream(
        [
          fn -> ScheduleDispatcherWorker.dispatch_due(now) end,
          fn ->
            schedule
            |> Schedule.changeset(%{enabled: false})
            |> Repo.update()
          end
        ],
        fn fun -> fun.() end,
        max_concurrency: 2,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert length(results) == 2

    stored = Repo.get!(Schedule, schedule.id)
    refute stored.enabled

    count =
      Repo.aggregate(
        from(e in Execution, where: e.installation_id == ^installation.id),
        :count
      )

    assert count in [0, 1]

    assert {:ok, %{dispatched: 0}} = ScheduleDispatcherWorker.dispatch_due(DateTime.utc_now())

    assert Repo.aggregate(
             from(e in Execution, where: e.installation_id == ^installation.id),
             :count
           ) == count
  end

  test "a rejected job insert rolls the schedule claim back" do
    %{installation: installation, member: member} = InstallationsFixtures.install()
    on_exit(fn -> cleanup!(installation.id) end)

    scope = Scope.new(member)
    {_activated, schedule} = activate_clock!(scope, installation.id)
    occurrence = DateTime.add(DateTime.utc_now(), -30, :second)
    schedule = stamp!(schedule, occurrence)
    {_name, drop} = reject_job_insert!(installation.id)
    on_exit(drop)

    assert {:error, %Error{}} = ScheduleDispatcherWorker.dispatch_due(DateTime.utc_now())

    stored = Repo.get!(Schedule, schedule.id)
    assert DateTime.compare(stored.next_run_at, occurrence) == :eq
    assert stored.dispatch_count == 0
    assert is_nil(stored.last_dispatch_status)

    refute Repo.exists?(from e in Execution, where: e.installation_id == ^installation.id)
  end

  defp activate_clock!(scope, installation_id) do
    definition =
      Definition.new(
        Trigger.new(:schedule, %{
          schedule_type: :every_minutes,
          interval: 15,
          timezone: "Etc/UTC"
        }),
        [delay_node(), stop_node()]
      )

    workflow =
      drafted_workflow(installation_id, %{draft_definition: Definition.encode(definition)})

    {:ok, activated} = Workflows.activate_workflow(scope, workflow.id, 0)

    schedule =
      Repo.one!(from s in Schedule, where: s.workflow_id == ^workflow.id and s.enabled)

    {activated, schedule}
  end

  defp stamp!(%Schedule{} = schedule, %DateTime{} = next_run_at) do
    schedule
    |> Schedule.changeset(%{next_run_at: next_run_at})
    |> Repo.update!()
  end

  defp reject_job_insert!(installation_id) do
    suffix = System.unique_integer([:positive])
    name = "reject_schedule_oban_jobs_#{suffix}"

    Repo.query!("""
    CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'job insert rejected';
    END;
    $$
    """)

    Repo.query!("""
    CREATE TRIGGER #{name}
    BEFORE INSERT ON oban_jobs
    FOR EACH ROW
    WHEN ((NEW.args ->> 'installation_id') = '#{installation_id}')
    EXECUTE FUNCTION #{name}()
    """)

    drop = fn ->
      Repo.query!("DROP TRIGGER IF EXISTS #{name} ON oban_jobs")
      Repo.query!("DROP FUNCTION IF EXISTS #{name}()")
    end

    {name, drop}
  end

  defp hold_lock!(query) do
    parent = self()

    task =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.one!(query)
          send(parent, {:schedule_lock_held, self()})

          receive do
            :release_schedule_lock -> :ok
          after
            30_000 -> raise "timed out waiting to release scheduler test lock"
          end
        end)
      end)

    assert_receive {:schedule_lock_held, holder}, 5_000
    {task, holder}
  end

  defp release_lock!({task, holder}) do
    release_lock({task, holder})
    assert {:ok, :ok} = Task.await(task, 5_000)
  end

  defp release_lock({_task, holder}), do: send(holder, :release_schedule_lock)

  defp cleanup!(installation_id) do
    Repo.delete_all(
      from j in Oban.Job,
        where: fragment("? ->> 'installation_id' = ?", j.args, ^installation_id)
    )

    InstallationsFixtures.erase!(installation_id)
  end
end
