defmodule PumbleAutomation.Integration.IngressScheduleWindowsTest do
  @moduledoc """
  Duplicate callbacks and schedule dispatch crash windows. Two deliveries
  collapse; a killed dispatcher does not advance the clock.
  """

  use PumbleAutomation.FailureWindowsCase

  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.Workers.ScheduleDispatcherWorker
  alias PumbleAutomation.FailureInjector
  alias PumbleAutomation.FailureWindowsCase
  alias PumbleAutomation.Ingress.ReceivedEvent
  alias PumbleAutomation.Ingress.Service
  alias PumbleAutomation.Pumble.Payload
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Definition.Trigger
  alias PumbleAutomation.Workflows.Schedule

  test "duplicate callbacks produce one receipt, one execution, and one job" do
    %{installation: installation, member: member} = install!()
    scope = Scope.new(member)
    {:ok, _activated} = activate!(scope, installation.id, [delay_node()])

    payload = %Payload.Event{
      message_type: "PUMBLE_EVENT",
      event_type: "NEW_MESSAGE",
      workspace_id: installation.pumble_workspace_id,
      body: %{
        "cId" => "channel-1",
        "aId" => "user-1",
        "tx" => "hello",
        "rid" => "RID-fw-#{System.unique_integer([:positive])}",
        "mId" => "M-fw",
        "tsm" => 1_767_225_600_000
      }
    }

    ctx = %{raw_body: "fw-bytes", signature: "sig"}
    assert :accepted = Service.enqueue_event(payload, ctx)
    assert :accepted = Service.enqueue_event(payload, ctx)

    receipts =
      Repo.all(from r in ReceivedEvent, where: r.installation_id == ^installation.id)

    assert length(receipts) == 1

    executions =
      Repo.all(from e in Execution, where: e.installation_id == ^installation.id)

    assert length(executions) == 1

    jobs =
      Repo.all(
        from j in Oban.Job,
          where: j.worker == "PumbleAutomation.Executions.Workers.AdvanceExecutionWorker",
          where: fragment("? ->> 'execution_id' = ?", j.args, ^hd(executions).id)
      )

    assert length(jobs) == 1
  end

  test "a crash during schedule dispatch rolls back and a later tick dispatches once" do
    %{installation: installation, member: member} = install!()
    scope = Scope.new(member)
    {_activated, schedule} = activate_clock!(scope, installation.id)
    occurrence = DateTime.add(DateTime.utc_now(), -30, :second)

    schedule
    |> Schedule.changeset(%{next_run_at: occurrence})
    |> Repo.update!()

    now = DateTime.utc_now()
    FailureInjector.arm(:schedule_dispatch, :kill)
    FailureWindowsCase.crash_through(fn -> ScheduleDispatcherWorker.dispatch_due(now) end)

    stored = Repo.get!(Schedule, schedule.id)
    assert DateTime.compare(stored.next_run_at, occurrence) == :eq
    assert [] == Repo.all(from e in Execution, where: e.installation_id == ^installation.id)

    assert {:ok, %{dispatched: 1}} = ScheduleDispatcherWorker.dispatch_due(now)

    executions = Repo.all(from e in Execution, where: e.installation_id == ^installation.id)
    assert length(executions) == 1
    assert hd(executions).execution_key == Schedule.occurrence_key(schedule, occurrence)
  end

  test "two dispatchers still create one execution for one occurrence" do
    %{installation: installation, member: member} = install!()
    scope = Scope.new(member)
    {_activated, schedule} = activate_clock!(scope, installation.id)
    occurrence = DateTime.add(DateTime.utc_now(), -30, :second)

    schedule
    |> Schedule.changeset(%{next_run_at: occurrence})
    |> Repo.update!()

    now = DateTime.utc_now()

    results =
      Barrier.race([
        fn -> ScheduleDispatcherWorker.dispatch_due(now) end,
        fn -> ScheduleDispatcherWorker.dispatch_due(now) end
      ])

    assert Enum.all?(results, &match?({:ok, _summary}, &1))

    stored = Repo.all(from e in Execution, where: e.installation_id == ^installation.id)
    assert length(stored) == 1
  end

  defp install! do
    installed = InstallationsFixtures.install()
    on_exit(fn -> DatabaseRaceCase.cleanup!(installed.installation.id) end)
    installed
  end

  defp activate!(scope, installation_id, nodes) do
    workflow =
      drafted_workflow(installation_id, %{
        draft_definition: Definition.encode(definition(nodes))
      })

    Workflows.activate_workflow(scope, workflow.id, 0)
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
end
