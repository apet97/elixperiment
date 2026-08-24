defmodule PumbleAutomation.MaintenanceTest do
  @moduledoc """
  P14-T04: singleton maintenance scheduling, bounded continuation, pause/run-once,
  safe repair vs unsafe alert, and tenant sentinels.
  """

  use PumbleAutomation.DataCase, async: false
  use Oban.Testing, repo: PumbleAutomation.Repo

  import Ecto.Query, only: [from: 2]

  alias PumbleAutomation.Audit.AuditEvent
  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Workers.AdvanceExecutionWorker
  alias PumbleAutomation.Executions.Workers.ReconciliationWorker
  alias PumbleAutomation.Executions.Workers.RetentionWorker
  alias PumbleAutomation.ExecutionsFixtures
  alias PumbleAutomation.Installations.CleanupWorker
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Installations.OauthState
  alias PumbleAutomation.Installations.OauthStates
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Maintenance
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Telemetry
  alias PumbleAutomation.Workflows.TriggerBinding
  alias PumbleAutomation.Workflows.Workflow
  alias PumbleAutomation.WorkflowsFixtures

  setup do
    on_exit(fn ->
      Enum.each(Maintenance.kinds(), &Maintenance.resume/1)
    end)

    %{installation: installation, member: member} = InstallationsFixtures.install()

    %{
      installation: installation,
      installation_id: installation.id,
      member: member,
      scope: Scope.new(member)
    }
  end

  describe "duplicate scheduler" do
    test "one incomplete reconcile job exists, and a discarded job does not block the next" do
      assert {:ok, first} = Oban.insert(ReconciliationWorker.new(%{}))
      refute first.conflict?

      assert {:ok, second} = Oban.insert(ReconciliationWorker.new(%{}))
      assert second.conflict?

      Repo.update_all(from(job in Oban.Job, where: job.id == ^first.id),
        set: [state: "discarded", discarded_at: DateTime.utc_now()]
      )

      assert {:ok, third} = Oban.insert(ReconciliationWorker.new(%{}))
      refute third.conflict?
      refute third.id == first.id
    end

    test "cleanup and integrity are distinct singletons" do
      assert {:ok, cleanup} = Oban.insert(CleanupWorker.new(%{kind: "cleanup"}))
      refute cleanup.conflict?

      assert {:ok, again} = Oban.insert(CleanupWorker.new(%{kind: "cleanup"}))
      assert again.conflict?

      assert {:ok, integrity} = Oban.insert(CleanupWorker.new(%{kind: "integrity"}))
      refute integrity.conflict?
    end
  end

  describe "pause/resume" do
    test "paused cleanup skips deletes; run-once still runs", context do
      now = DateTime.utc_now()
      {:ok, _token, expired} = expired_oauth(now)

      assert :ok = Maintenance.pause(:cleanup)

      assert :ok =
               CleanupWorker.perform(%Oban.Job{
                 args: %{"kind" => "cleanup", "batch_size" => 10}
               })

      assert Repo.get(OauthState, expired.id)

      assert :ok = Maintenance.run_once(:cleanup, %{"batch_size" => 10})
      refute Repo.get(OauthState, expired.id)

      {:ok, _token, later} = expired_oauth(now)
      assert :ok = Maintenance.resume(:cleanup)

      assert :ok =
               CleanupWorker.perform(%Oban.Job{
                 args: %{"kind" => "cleanup", "batch_size" => 10}
               })

      refute Repo.get(OauthState, later.id)
      assert context.installation.id
    end
  end

  describe "restart midway and batch continuation" do
    test "a bounded cleanup tick snoozes and the next tick finishes remaining rows" do
      now = DateTime.utc_now()

      ids =
        for _index <- 1..3 do
          {:ok, _token, state} = expired_oauth(now)
          state.id
        end

      assert {:snooze, 1} =
               CleanupWorker.perform(%Oban.Job{
                 args: %{"kind" => "cleanup", "batch_size" => 1}
               })

      remaining = Enum.count(ids, &Repo.get(OauthState, &1))
      assert remaining == 2

      assert {:snooze, 1} =
               CleanupWorker.perform(%Oban.Job{
                 args: %{"kind" => "cleanup", "batch_size" => 1}
               })

      assert :ok =
               CleanupWorker.perform(%Oban.Job{
                 args: %{"kind" => "cleanup", "batch_size" => 1}
               })

      assert Enum.all?(ids, fn id -> is_nil(Repo.get(OauthState, id)) end)
    end

    test "a retention sweep that hits max_batches snoozes and continues" do
      now = DateTime.utc_now()

      ids =
        for _index <- 1..3 do
          {:ok, _token, state} = expired_oauth(now)
          state.id
        end

      assert {:snooze, 1} =
               RetentionWorker.perform(%Oban.Job{
                 args: %{"batch_size" => 1, "max_batches" => 1}
               })

      remaining = Enum.count(ids, &Repo.get(OauthState, &1))
      assert remaining in 1..2

      assert :ok = RetentionWorker.perform(%Oban.Job{args: %{"batch_size" => 1}})
      assert Enum.all?(ids, fn id -> is_nil(Repo.get(OauthState, id)) end)
    end
  end

  describe "safe repair and unsafe alert" do
    test "integrity disables a stale binding, restores a missing wait job, and alerts orphan secrets",
         context do
      handler = attach_alerts()
      stale = stale_binding!(context.installation_id)
      waiting = waiting_without_job!(context.installation_id)
      {workflow, version} = live_orphan_secret!(context.installation_id)

      assert :ok =
               CleanupWorker.perform(%Oban.Job{
                 args: %{
                   "kind" => "integrity",
                   "installation_id" => context.installation_id,
                   "batch_size" => 20
                 }
               })

      assert Repo.get!(TriggerBinding, stale.id).enabled == false

      assert_enqueued(
        worker: AdvanceExecutionWorker,
        args: %{execution_id: waiting.id}
      )

      assert Repo.get!(version.__struct__, version.id).referenced_secret_ids ==
               version.referenced_secret_ids

      assert Repo.get!(Workflow, workflow.id).status == "active"

      assert_receive {:telemetry, [:pumble_automation, :maintenance, :alert], %{count: 1},
                      %{kind: "orphan_secret", status: "alert"}}

      assert Repo.exists?(
               from event in AuditEvent,
                 where: event.installation_id == ^context.installation_id,
                 where: event.action == "admin.maintenance_alert",
                 where: event.resource_id == ^workflow.id
             )

      :telemetry.detach(handler)
    end

    test "an owner run-once is audited and an editor is refused", context do
      assert {:ok, summary} = Maintenance.run_once(context.scope, :cleanup)
      assert summary.kind == :cleanup

      assert Repo.exists?(
               from event in AuditEvent,
                 where: event.installation_id == ^context.installation_id,
                 where: event.action == "admin.maintenance_run",
                 where: event.actor_id == ^context.member.id
             )

      %{member: editor} = InstallationsFixtures.install(role: "editor")

      assert {:error, %Error{class: :permission}} =
               Maintenance.run_once(Scope.new(editor), :cleanup)
    end
  end

  describe "tenant sentinel" do
    test "integrity scoped to one tenant leaves the other tenant's anomaly in place", context do
      %{installation: other} = InstallationsFixtures.install()
      ours = stale_binding!(context.installation_id)
      theirs = stale_binding!(other.id)

      assert :ok =
               CleanupWorker.perform(%Oban.Job{
                 args: %{
                   "kind" => "integrity",
                   "installation_id" => context.installation_id,
                   "batch_size" => 20
                 }
               })

      assert Repo.get!(TriggerBinding, ours.id).enabled == false
      assert Repo.get!(TriggerBinding, theirs.id).enabled == true
    end

    test "due uninstalled cleanup enqueues a tenant purge without touching another workspace",
         context do
      %{installation: other} = InstallationsFixtures.install()
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      context.installation
      |> Installation.changeset(%{
        status: "uninstalled",
        uninstalled_at: past,
        deletion_scheduled_at: past
      })
      |> Repo.update!()

      assert :ok =
               CleanupWorker.perform(%Oban.Job{
                 args: %{
                   "kind" => "integrity",
                   "installation_id" => context.installation_id,
                   "batch_size" => 20
                 }
               })

      assert_enqueued(
        worker: RetentionWorker,
        args: %{installation_id: context.installation_id}
      )

      refute_enqueued(worker: RetentionWorker, args: %{installation_id: other.id})
    end
  end

  describe "schedule documentation" do
    test "every kind has a scheduler and a documented duration" do
      docs = File.read!("docs/operations/maintenance.md")

      for kind <- Maintenance.kinds() do
        duration = Maintenance.expected_duration(kind)
        assert docs =~ duration.cron
        assert is_integer(duration.budget_ms)
        assert duration.typical != ""
      end
    end
  end

  defp expired_oauth(now) do
    OauthStates.create("install", now: DateTime.add(now, -3_600, :second))
  end

  defp stale_binding!(installation_id) do
    workflow = WorkflowsFixtures.drafted_workflow(installation_id)
    version = WorkflowsFixtures.version(workflow)
    WorkflowsFixtures.trigger_binding(version, %{enabled: true})
  end

  defp waiting_without_job!(installation_id) do
    version = ExecutionsFixtures.version(installation_id)

    execution =
      ExecutionsFixtures.execution(version, %{
        status: "waiting_delay",
        current_node_id: Ecto.UUID.generate()
      })

    ExecutionsFixtures.step_execution(execution, %{
      status: "waiting_delay",
      node_type: "delay",
      node_id: execution.current_node_id
    })

    execution
  end

  defp live_orphan_secret!(installation_id) do
    workflow = WorkflowsFixtures.drafted_workflow(installation_id)
    missing = Ecto.UUID.generate()
    version = WorkflowsFixtures.version(workflow, %{referenced_secret_ids: [missing]})

    workflow =
      workflow
      |> Workflow.changeset(%{status: "active", active_version_id: version.id})
      |> Repo.update!()

    {workflow, version}
  end

  defp attach_alerts do
    handler = "maintenance-alert-#{System.unique_integer([:positive])}"
    test = self()

    :ok =
      :telemetry.attach(
        handler,
        Telemetry.events().maintenance_alert,
        fn event, measurements, metadata, _config ->
          send(test, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    handler
  end
end
