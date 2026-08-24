defmodule PumbleAutomation.Workflows.ScheduleLifecycleTest do
  @moduledoc """
  Schedule projections are replaced only at activation. The first next_run_at
  comes from the calculator at activation time; draft edits and catch-up do
  not move it. Running executions keep the version they named.
  """

  use PumbleAutomation.DataCase, async: true

  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Audit.AuditEvent
  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.Workers.ScheduleDispatcherWorker
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

  describe "activation first run" do
    test "computes next_run_at from activation time, not the activation instant", context do
      config = %{schedule_type: :daily, time_of_day: "09:00", timezone: "Etc/UTC"}
      {result, schedule} = activate_clock!(context, config)

      assert {:ok, expected} =
               Schedule.first_run_at(schedule.config, result.version.activated_at)

      assert DateTime.compare(schedule.next_run_at, expected) == :eq
      assert DateTime.compare(schedule.next_run_at, result.version.activated_at) == :gt
      refute DateTime.compare(schedule.next_run_at, result.version.activated_at) == :eq
    end

    test "an interval clock's first fire is one interval after activation", context do
      config = %{schedule_type: :every_minutes, interval: 15, timezone: "Etc/UTC"}
      {result, schedule} = activate_clock!(context, config)

      assert {:ok, expected} =
               ScheduleCalculator.next(schedule.config, result.version.activated_at)

      assert DateTime.compare(schedule.next_run_at, expected) == :eq

      assert DateTime.diff(schedule.next_run_at, result.version.activated_at, :minute) ==
               15
    end

    test "a once clock in the future keeps that instant; a past once is terminal", context do
      future = DateTime.add(DateTime.utc_now(), 3_600, :second)

      {_result, upcoming} =
        activate_clock!(context, %{
          schedule_type: :once,
          run_at: DateTime.to_iso8601(future),
          timezone: "Etc/UTC"
        })

      assert DateTime.compare(upcoming.next_run_at, utc_usec(future)) == :eq
      assert upcoming.enabled

      past = utc("2020-01-15T12:00:00Z")

      workflow =
        clock_workflow(context.installation_id, %{
          schedule_type: :once,
          run_at: DateTime.to_iso8601(past),
          timezone: "Etc/UTC"
        })

      {:ok, _result} = Workflows.activate_workflow(context.scope, workflow.id, 0)

      terminal =
        Repo.one!(from s in Schedule, where: s.workflow_id == ^workflow.id and s.enabled)

      assert is_nil(terminal.next_run_at)
      assert terminal.enabled
    end

    test "an unknown IANA timezone blocks activation and writes no projection", context do
      workflow =
        clock_workflow(context.installation_id, %{
          schedule_type: :daily,
          time_of_day: "09:00",
          timezone: "Europe/Atlantis"
        })

      assert {:error, %Error{class: :validation, code: :unknown_timezone}} =
               Workflows.activate_workflow(context.scope, workflow.id, 0)

      refute Repo.exists?(from s in Schedule, where: s.workflow_id == ^workflow.id)
    end
  end

  describe "draft edit" do
    test "editing a draft does not change the enabled projection until activation", context do
      config = %{schedule_type: :daily, time_of_day: "09:00", timezone: "Europe/Belgrade"}
      {first, schedule} = activate_clock!(context, config)

      {:ok, drafted} =
        Workflows.update_draft(
          context.scope,
          first.workflow.id,
          clock_definition(%{
            schedule_type: :daily,
            time_of_day: "17:00",
            timezone: "America/New_York"
          }),
          first.workflow.draft_revision
        )

      stored = Repo.get!(Schedule, schedule.id)

      assert stored.enabled
      assert stored.timezone == "Europe/Belgrade"
      assert stored.config["time_of_day"] == "09:00"
      assert DateTime.compare(stored.next_run_at, schedule.next_run_at) == :eq
      assert drafted.status == "active"
      assert drafted.active_version_id == first.version.id
    end
  end

  describe "timezone and config change" do
    test "a new activation disables the old clock and audits the timezone change", context do
      {first, old} =
        activate_clock!(context, %{
          schedule_type: :daily,
          time_of_day: "09:00",
          timezone: "Europe/Belgrade"
        })

      {:ok, drafted} =
        Workflows.update_draft(
          context.scope,
          first.workflow.id,
          clock_definition(%{
            schedule_type: :daily,
            time_of_day: "09:00",
            timezone: "America/New_York"
          }),
          first.workflow.draft_revision
        )

      {:ok, second} =
        Workflows.activate_workflow(context.scope, drafted.id, drafted.draft_revision)

      schedules = Repo.all(from s in Schedule, where: s.workflow_id == ^first.workflow.id)
      enabled = Enum.filter(schedules, & &1.enabled)
      disabled = Enum.reject(schedules, & &1.enabled)

      assert length(disabled) == 1
      assert hd(disabled).id == old.id
      refute hd(disabled).enabled

      assert [fresh] = enabled
      assert fresh.workflow_version_id == second.version.id
      assert fresh.timezone == "America/New_York"

      assert {:ok, expected} = Schedule.first_run_at(fresh.config, second.version.activated_at)
      assert DateTime.compare(fresh.next_run_at, expected) == :eq
      refute DateTime.compare(fresh.next_run_at, old.next_run_at) == :eq

      event = latest_audit(context.installation_id, "workflow.activated")
      assert event.metadata["previous_timezone"] == "Europe/Belgrade"
      assert event.metadata["timezone"] == "America/New_York"
      assert event.metadata["previous_schedule_type"] == "daily"
      assert event.metadata["schedule_type"] == "daily"
      assert event.metadata["changed_field_count"] >= 1
    end

    test "only one enabled schedule projection exists per workflow", context do
      {first, _old} =
        activate_clock!(context, %{
          schedule_type: :every_minutes,
          interval: 15,
          timezone: "Etc/UTC"
        })

      {:ok, drafted} =
        Workflows.update_draft(
          context.scope,
          first.workflow.id,
          clock_definition(%{
            schedule_type: :every_hours,
            interval: 1,
            timezone: "Etc/UTC"
          }),
          first.workflow.draft_revision
        )

      {:ok, _second} =
        Workflows.activate_workflow(context.scope, drafted.id, drafted.draft_revision)

      enabled =
        Repo.all(
          from s in Schedule,
            where: s.workflow_id == ^first.workflow.id and s.enabled
        )

      assert length(enabled) == 1
      assert hd(enabled).schedule_type == "every_hours"
    end
  end

  describe "deactivate and reactivate" do
    test "deactivation prevents an unclaimed due occurrence from dispatching", context do
      {activated, schedule} =
        activate_clock!(context, %{
          schedule_type: :every_minutes,
          interval: 15,
          timezone: "Etc/UTC"
        })

      stamp!(schedule, minutes_ago(2))
      {:ok, _} = Workflows.deactivate_workflow(context.scope, activated.workflow.id)

      refute Repo.exists?(
               from s in Schedule,
                 where: s.workflow_id == ^activated.workflow.id and s.enabled
             )

      assert {:ok, %{dispatched: 0}} =
               ScheduleDispatcherWorker.dispatch_due(DateTime.utc_now())

      assert executions(context.installation_id) == []
    end

    test "reactivation recalculates from reactivation time and does not catch up", context do
      {first, schedule} =
        activate_clock!(context, %{
          schedule_type: :daily,
          time_of_day: "09:00",
          timezone: "Etc/UTC"
        })

      missed = utc("2026-01-01T09:00:00Z")
      stamp!(schedule, missed)
      {:ok, _} = Workflows.deactivate_workflow(context.scope, first.workflow.id)

      before = DateTime.utc_now()
      {:ok, _result} = Workflows.reactivate_workflow(context.scope, first.workflow.id, 1)
      after_at = DateTime.utc_now()

      fresh =
        Repo.one!(
          from s in Schedule,
            where: s.workflow_id == ^first.workflow.id and s.enabled
        )

      assert fresh.id != schedule.id
      assert {:ok, min_next} = Schedule.first_run_at(fresh.config, before)
      assert {:ok, max_next} = Schedule.first_run_at(fresh.config, after_at)
      assert DateTime.compare(fresh.next_run_at, min_next) in [:eq, :gt]
      assert DateTime.compare(fresh.next_run_at, max_next) in [:eq, :lt]
      refute DateTime.compare(fresh.next_run_at, missed) == :eq
      assert DateTime.compare(fresh.next_run_at, before) == :gt

      assert {:ok, %{dispatched: 0}} =
               ScheduleDispatcherWorker.dispatch_due(DateTime.utc_now())

      assert executions(context.installation_id) == []
    end
  end

  describe "old execution version" do
    test "an already created execution keeps the version it named", context do
      {first, schedule} =
        activate_clock!(context, %{
          schedule_type: :every_minutes,
          interval: 15,
          timezone: "Etc/UTC"
        })

      occurrence = minutes_ago(1)
      stamp!(schedule, occurrence)
      assert {:ok, %{dispatched: 1}} = ScheduleDispatcherWorker.dispatch_due(DateTime.utc_now())

      [execution] = executions(context.installation_id)
      assert execution.workflow_version_id == first.version.id

      {:ok, drafted} =
        Workflows.update_draft(
          context.scope,
          first.workflow.id,
          clock_definition(%{
            schedule_type: :every_minutes,
            interval: 30,
            timezone: "Etc/UTC"
          }),
          first.workflow.draft_revision
        )

      {:ok, second} =
        Workflows.activate_workflow(context.scope, drafted.id, drafted.draft_revision)

      stored = Repo.get!(Execution, execution.id)
      assert stored.workflow_version_id == first.version.id
      assert stored.workflow_version_id != second.version.id

      enabled =
        Repo.one!(
          from s in Schedule,
            where: s.workflow_id == ^first.workflow.id and s.enabled
        )

      assert enabled.workflow_version_id == second.version.id
    end
  end

  defp activate_clock!(context, config) do
    workflow = clock_workflow(context.installation_id, config)
    {:ok, result} = Workflows.activate_workflow(context.scope, workflow.id, 0)

    schedule =
      Repo.one!(from s in Schedule, where: s.workflow_id == ^workflow.id and s.enabled)

    {result, schedule}
  end

  defp clock_workflow(installation_id, config) do
    drafted_workflow(installation_id, %{
      draft_definition: Definition.encode(clock_definition(config))
    })
  end

  defp clock_definition(config) do
    Definition.new(Trigger.new(:schedule, config), [delay_node(), stop_node()])
  end

  defp stamp!(%Schedule{} = schedule, %DateTime{} = next_run_at) do
    schedule
    |> Schedule.changeset(%{next_run_at: next_run_at})
    |> Repo.update!()
  end

  defp executions(installation_id) do
    Repo.all(from e in Execution, where: e.installation_id == ^installation_id)
  end

  defp latest_audit(installation_id, action) do
    Repo.one!(
      from e in AuditEvent,
        where: e.installation_id == ^installation_id and e.action == ^action,
        order_by: [desc: e.inserted_at],
        limit: 1
    )
  end

  defp minutes_ago(minutes), do: DateTime.add(DateTime.utc_now(), -minutes * 60, :second)

  defp utc(iso) when is_binary(iso) do
    {:ok, datetime, 0} = DateTime.from_iso8601(iso)
    utc_usec(datetime)
  end

  defp utc_usec(%DateTime{} = datetime) do
    DateTime.from_unix!(DateTime.to_unix(datetime, :microsecond), :microsecond)
  end
end

defmodule PumbleAutomation.Workflows.ScheduleLifecycleConcurrencyTest do
  @moduledoc """
  Activation versus the dispatcher on a real database. Row locks decide the
  race: an occurrence whose create committed may still run on the old version.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import PumbleAutomation.WorkflowsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.Workers.ScheduleDispatcherWorker
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Definition.Trigger
  alias PumbleAutomation.Workflows.Schedule
  alias PumbleAutomation.Workflows.Workflow

  setup do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  test "activation/dispatch race leaves at most one old execution and one enabled clock" do
    %{installation: installation, member: member} = InstallationsFixtures.install()
    on_exit(fn -> cleanup!(installation.id) end)

    scope = Scope.new(member)
    workflow = clock_workflow(installation.id, %{schedule_type: :every_minutes, interval: 15})
    {:ok, first} = Workflows.activate_workflow(scope, workflow.id, 0)

    schedule =
      Repo.one!(from s in Schedule, where: s.workflow_id == ^workflow.id and s.enabled)

    stamp!(schedule, DateTime.add(DateTime.utc_now(), -30, :second))

    {:ok, drafted} =
      Workflows.update_draft(
        scope,
        workflow.id,
        clock_definition(%{schedule_type: :every_minutes, interval: 30, timezone: "Etc/UTC"}),
        first.workflow.draft_revision
      )

    now = DateTime.utc_now()

    _results =
      Task.async_stream(
        [
          fn -> ScheduleDispatcherWorker.dispatch_due(now) end,
          fn -> Workflows.activate_workflow(scope, drafted.id, drafted.draft_revision) end
        ],
        fn fun -> fun.() end,
        max_concurrency: 2,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    stored = Repo.get!(Workflow, drafted.id)

    if stored.active_version_id == first.version.id do
      assert {:ok, _} = Workflows.activate_workflow(scope, drafted.id, drafted.draft_revision)
    end

    stored = Repo.get!(Workflow, drafted.id)
    assert stored.active_version_id != first.version.id

    enabled =
      Repo.all(from s in Schedule, where: s.workflow_id == ^workflow.id and s.enabled)

    assert length(enabled) == 1
    assert hd(enabled).workflow_version_id == stored.active_version_id
    assert hd(enabled).schedule_type == "every_minutes"
    assert hd(enabled).config["interval"] == 30

    executions =
      Repo.all(from e in Execution, where: e.installation_id == ^installation.id)

    assert length(executions) in [0, 1]

    if executions != [] do
      assert hd(executions).workflow_version_id == first.version.id
    end

    assert {:ok, %{dispatched: 0}} = ScheduleDispatcherWorker.dispatch_due(DateTime.utc_now())

    assert Repo.aggregate(
             from(e in Execution, where: e.installation_id == ^installation.id),
             :count
           ) == length(executions)
  end

  defp clock_workflow(installation_id, config) do
    drafted_workflow(installation_id, %{
      draft_definition: Definition.encode(clock_definition(config))
    })
  end

  defp clock_definition(config) do
    Definition.new(
      Trigger.new(:schedule, Map.put_new(config, :timezone, "Etc/UTC")),
      [delay_node(), stop_node()]
    )
  end

  defp stamp!(%Schedule{} = schedule, %DateTime{} = next_run_at) do
    schedule
    |> Schedule.changeset(%{next_run_at: next_run_at})
    |> Repo.update!()
  end

  defp cleanup!(installation_id) do
    Repo.delete_all(
      from j in Oban.Job,
        where: fragment("? ->> 'installation_id' = ?", j.args, ^installation_id)
    )

    InstallationsFixtures.erase!(installation_id)
  end
end
