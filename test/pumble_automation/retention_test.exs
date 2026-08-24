defmodule PumbleAutomation.RetentionTest do
  @moduledoc """
  P13-T04: receipt, execution, audit, OAuth, session, and uninstall purge.
  """

  use PumbleAutomation.DataCase, async: false

  import ExUnit.CaptureLog
  import PumbleAutomation.IngressFixtures

  alias PumbleAutomation.Audit.AuditEvent
  alias PumbleAutomation.Audit.Writer
  alias PumbleAutomation.Connections.Connection
  alias PumbleAutomation.Connections.Secret
  alias PumbleAutomation.ConnectionsFixtures
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.Workers.RetentionWorker
  alias PumbleAutomation.ExecutionsFixtures
  alias PumbleAutomation.Ingress.ReceivedEvent
  alias PumbleAutomation.Ingress.WebhookEndpoint
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Installations.Lifecycle
  alias PumbleAutomation.Installations.OauthState
  alias PumbleAutomation.Installations.OauthStates
  alias PumbleAutomation.Installations.Sessions
  alias PumbleAutomation.Installations.UserAuthorization
  alias PumbleAutomation.Installations.UserSession
  alias PumbleAutomation.Installations.WorkspaceMember
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Retention
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows.Schedule
  alias PumbleAutomation.Workflows.TriggerBinding
  alias PumbleAutomation.Workflows.Workflow
  alias PumbleAutomation.Workflows.WorkflowVersion
  alias PumbleAutomation.WorkflowsFixtures

  @leaked_text "secret-body-must-not-appear-in-logs"

  setup do
    %{installation: installation, member: member, session: session} =
      InstallationsFixtures.install()

    %{
      installation: installation,
      installation_id: installation.id,
      member: member,
      session: session,
      scope: Scope.new(member)
    }
  end

  describe "policy" do
    test "matches the user-facing retention document and sibling constants" do
      policy = Retention.policy()
      doc = File.read!("docs/product/retention.md")

      assert policy.receipts_days == 30
      assert policy.execution_detail_days == 90
      assert policy.audit_days == 365
      assert policy.uninstall_grace_days == 30
      assert policy.receipts_days == ReceivedEvent.retention_days()
      assert policy.uninstall_grace_days == Lifecycle.retention_days()
      assert doc =~ "#{policy.receipts_days} days"
      assert doc =~ "#{policy.execution_detail_days} days"
      assert doc =~ "#{policy.audit_days} days"
      assert doc =~ "#{policy.uninstall_grace_days}-day"
      assert doc =~ "no legal hold"
      refute function_exported?(Retention, :hold, 1)
      refute Map.has_key?(policy, :legal_hold)
    end

    test "status starts with policy and empty last-run fields" do
      status = Retention.status()
      assert status.policy == Retention.policy()
    end
  end

  describe "receipts" do
    test "deletes a receipt whose retain_until is strictly before now and keeps the boundary",
         %{installation_id: installation_id} do
      now = DateTime.utc_now()
      due = due_receipt(installation_id, DateTime.add(now, -1, :microsecond))
      kept = due_receipt(installation_id, now)
      future = received_event(installation_id)

      assert {:ok, counts} = Retention.sweep(now)
      assert counts.receipts == 1
      refute Repo.get(ReceivedEvent, due.id)
      assert Repo.get(ReceivedEvent, kept.id)
      assert Repo.get(ReceivedEvent, future.id)
    end

    test "leaves another tenant's in-window receipt in place", %{installation_id: installation_id} do
      now = DateTime.utc_now()
      %{installation: other} = InstallationsFixtures.install()
      mine = due_receipt(installation_id, DateTime.add(now, -1, :second))
      sentinel = received_event(other.id)

      assert {:ok, _counts} = Retention.sweep(now)

      refute Repo.get(ReceivedEvent, mine.id)
      assert Repo.get(ReceivedEvent, sentinel.id)
    end
  end

  describe "execution detail" do
    test "deletes a terminal execution after 90 days and keeps the boundary", context do
      now = DateTime.utc_now()
      cutoff = DateTime.add(now, -Retention.execution_detail_days(), :day)
      version = ExecutionsFixtures.version(context.installation_id)

      due = terminal_execution(version, DateTime.add(cutoff, -1, :microsecond))
      kept = terminal_execution(version, cutoff)
      waiting = waiting_execution(version, DateTime.add(cutoff, -1, :day))

      assert {:ok, counts} = Retention.sweep(now)
      assert counts.executions == 1
      refute Repo.get(Execution, due.id)
      assert Repo.get(Execution, kept.id)
      assert Repo.get(Execution, waiting.id)
    end

    test "keeps a due root while a descendant still exists", context do
      now = DateTime.utc_now()
      cutoff = DateTime.add(now, -Retention.execution_detail_days(), :day)
      version = ExecutionsFixtures.version(context.installation_id)
      past = DateTime.add(cutoff, -1, :day)

      root = terminal_execution(version, past)

      child =
        version
        |> ExecutionsFixtures.execution(%{
          status: "waiting_delay",
          root_execution_id: root.id,
          lineage_depth: 1
        })
        |> backdate(past)

      assert {:ok, counts} = Retention.sweep(now)
      assert counts.executions == 0
      assert Repo.get(Execution, root.id)
      assert Repo.get(Execution, child.id)
    end

    test "leaves another tenant's in-window terminal execution in place", context do
      now = DateTime.utc_now()
      cutoff = DateTime.add(now, -Retention.execution_detail_days(), :day)
      past = DateTime.add(cutoff, -1, :day)
      %{installation: other} = InstallationsFixtures.install()

      mine = terminal_execution(ExecutionsFixtures.version(context.installation_id), past)

      sentinel =
        ExecutionsFixtures.execution(ExecutionsFixtures.version(other.id), %{status: "completed"})

      assert {:ok, _counts} = Retention.sweep(now)
      refute Repo.get(Execution, mine.id)
      assert Repo.get(Execution, sentinel.id)
    end
  end

  describe "audit" do
    test "deletes audit older than 365 days and keeps the boundary", %{
      installation_id: installation_id
    } do
      now = DateTime.utc_now()
      cutoff = DateTime.add(now, -Retention.audit_days(), :day)
      due = audit_event(installation_id, DateTime.add(cutoff, -1, :microsecond))
      kept = audit_event(installation_id, cutoff)

      assert {:ok, counts} = Retention.sweep(now)
      assert counts.audit_events == 1
      refute Repo.get(AuditEvent, due.id)
      assert Repo.get(AuditEvent, kept.id)
    end
  end

  describe "oauth and sessions" do
    test "deletes consumed and expired oauth states and keeps a live one", %{
      installation_id: installation_id
    } do
      now = DateTime.utc_now()
      {:ok, live_token, live} = OauthStates.create("signin", installation_id: installation_id)
      {:ok, token, _consumed} = OauthStates.create("signin", installation_id: installation_id)
      {:ok, consumed} = OauthStates.consume(token)

      {:ok, _expired_token, expired} =
        OauthStates.create("signin",
          installation_id: installation_id,
          now: DateTime.add(now, -1_000, :second)
        )

      log =
        capture_log(fn ->
          assert {:ok, counts} = Retention.sweep(now)
          assert counts.oauth_states >= 2
        end)

      refute Repo.get(OauthState, consumed.id)
      refute Repo.get(OauthState, expired.id)
      assert Repo.get(OauthState, live.id)
      assert OauthState.digest(live_token) == live.state_digest
      refute log =~ live_token
    end

    test "deletes revoked and expired sessions and keeps a live one", %{
      session: session,
      member: member
    } do
      now = DateTime.utc_now()
      {:ok, revoked} = insert_session(member, now)
      revoke_session(revoked, now)

      {:ok, idle} = insert_session(member, DateTime.add(now, -13 * 60 * 60, :second))

      assert {:ok, counts} = Retention.sweep(now)
      assert counts.sessions >= 2
      refute Repo.get(UserSession, revoked.id)
      refute Repo.get(UserSession, idle.id)
      assert Repo.get(UserSession, session.id)
    end
  end

  describe "resume and observability" do
    test "a bounded first run leaves remaining due rows for the next run", %{
      installation_id: installation_id
    } do
      now = DateTime.utc_now()
      due_until = DateTime.add(now, -1, :second)

      ids =
        for _ <- 1..5 do
          due_receipt(installation_id, due_until).id
        end

      assert {:ok, first} = Retention.sweep(now, batch_size: 2, max_batches: 1)
      assert first.receipts == 2
      assert remaining_receipts(ids) == 3

      assert {:ok, second} = Retention.sweep(now, batch_size: 2)
      assert second.receipts == 3
      assert remaining_receipts(ids) == 0
    end

    test "sweep records last-run metrics and telemetry without deleted content", %{
      installation_id: installation_id
    } do
      now = DateTime.utc_now()

      retain_until = DateTime.add(now, -1, :second)
      received_at = DateTime.add(retain_until, -ReceivedEvent.retention_days(), :day)

      received_event(installation_id, %{
        received_at: received_at,
        occurred_at: received_at,
        retain_until: retain_until,
        data: %{"text" => @leaked_text}
      })

      handler = attach_retention()

      log =
        capture_log(fn ->
          assert {:ok, counts} = Retention.sweep(now, correlation_id: "corr-retention-1")
          assert counts.receipts == 1
        end)

      assert_receive {:retention, measurements, metadata}
      assert measurements.receipts == 1
      refute Map.has_key?(measurements, :data)
      assert metadata.correlation_id == "corr-retention-1"
      assert metadata.source == "sweep"
      refute Map.has_key?(metadata, :text)
      refute log =~ @leaked_text

      status = Retention.status()
      assert status.last_kind == :sweep
      assert status.last_counts.receipts == 1
      assert status.last_correlation_id == "corr-retention-1"
      assert %DateTime{} = status.last_run_at

      :telemetry.detach(handler)
    end

    test "the empty-args worker runs a sweep", %{installation_id: installation_id} do
      now = DateTime.utc_now()
      event = due_receipt(installation_id, DateTime.add(now, -1, :second))

      assert :ok = RetentionWorker.perform(%Oban.Job{args: %{}})
      refute Repo.get(ReceivedEvent, event.id)
    end
  end

  describe "uninstall full purge" do
    test "erases tenant operational rows, keeps the other tenant and audit", context do
      version = ExecutionsFixtures.version(context.installation_id)
      execution = ExecutionsFixtures.execution(version, %{status: "completed"})
      receipt = received_event(context.installation_id)
      endpoint = webhook_endpoint(version)
      binding = WorkflowsFixtures.trigger_binding(version)
      schedule = WorkflowsFixtures.schedule(version)
      ConnectionsFixtures.secret(context.scope)
      ConnectionsFixtures.connection(context.scope)
      audit = audit_event(context.installation_id, DateTime.utc_now())

      %{installation: other, member: other_member} = InstallationsFixtures.install()
      other_scope = Scope.new(other_member)
      other_version = ExecutionsFixtures.version(other.id)
      other_execution = ExecutionsFixtures.execution(other_version)
      other_receipt = due_receipt(other.id, DateTime.add(DateTime.utc_now(), -1, :second))
      ConnectionsFixtures.secret(other_scope)

      {:ok, uninstalled} = Lifecycle.uninstall(context.installation.id)
      assert {:ok, %Installation{status: "deleted"}} = Retention.purge_tenant(uninstalled)

      assert Repo.get!(Installation, context.installation_id).status == "deleted"
      refute Repo.get(Execution, execution.id)
      refute Repo.get(ReceivedEvent, receipt.id)
      refute Repo.get(WebhookEndpoint, endpoint.id)
      refute Repo.get(TriggerBinding, binding.id)
      refute Repo.get(Schedule, schedule.id)
      refute Repo.get(Workflow, version.workflow_id)
      refute Repo.get(WorkflowVersion, version.id)
      assert secrets(context.installation_id) == 0
      assert connections(context.installation_id) == 0
      assert members(context.installation_id) == 0
      assert authorizations(context.installation_id) == 0
      assert Repo.get(AuditEvent, audit.id)

      assert Repo.get!(Installation, other.id).status == "active"
      assert Repo.get(Execution, other_execution.id)
      assert Repo.get(ReceivedEvent, other_receipt.id)
      assert secrets(other.id) == 1
    end

    test "a second purge of an already deleted tenant is a worker no-op", context do
      {:ok, uninstalled} = Lifecycle.uninstall(context.installation.id)
      assert {:ok, deleted} = Retention.purge_tenant(uninstalled)
      assert deleted.status == "deleted"

      assert :ok =
               RetentionWorker.perform(%Oban.Job{
                 args: %{"installation_id" => context.installation_id}
               })

      assert Repo.get!(Installation, context.installation_id).status == "deleted"
    end
  end

  describe "indexes" do
    test "the retention indexes exist" do
      definitions = index_definitions("executions")
      assert definitions =~ "executions_retention_index"
      assert definitions =~ "installation_id"
      assert definitions =~ "updated_at"

      audit = index_definitions("audit_events")
      assert audit =~ "audit_events_preinstall_retention_index"

      oauth = index_definitions("oauth_states")
      assert oauth =~ "oauth_states_consumed_retention_index"

      sessions = index_definitions("user_sessions")
      assert sessions =~ "user_sessions_revoked_retention_index"
    end

    test "serves due execution deletes with the retention index", context do
      now = DateTime.utc_now()
      cutoff = DateTime.add(now, -Retention.execution_detail_days(), :day)

      terminal_execution(
        ExecutionsFixtures.version(context.installation_id),
        DateTime.add(cutoff, -1, :day)
      )

      plan = explain_index_plan(Retention.due_executions_query(now, context.installation_id))

      assert index_backed?(plan)
    end

    test "serves due receipt deletes with the retain_until index", %{
      installation_id: installation_id
    } do
      received_event(installation_id)
      plan = explain_index_plan(Retention.due_receipts_query(DateTime.utc_now()))

      assert index_backed?(plan)
    end
  end

  defp terminal_execution(version, at) do
    version
    |> ExecutionsFixtures.execution(%{status: "completed"})
    |> backdate(at)
  end

  defp waiting_execution(version, at) do
    version
    |> ExecutionsFixtures.execution(%{status: "waiting_delay"})
    |> backdate(at)
  end

  defp backdate(%Execution{} = execution, at) do
    {1, _} =
      Repo.update_all(from(e in Execution, where: e.id == ^execution.id),
        set: [inserted_at: at, updated_at: at]
      )

    Repo.get!(Execution, execution.id)
  end

  defp due_receipt(installation_id, retain_until) do
    received_at = DateTime.add(retain_until, -ReceivedEvent.retention_days(), :day)

    received_event(installation_id, %{
      received_at: received_at,
      occurred_at: received_at,
      retain_until: retain_until
    })
  end

  defp audit_event(installation_id, inserted_at) do
    {:ok, %{audit: event}} =
      Ecto.Multi.new()
      |> Writer.append(:audit, %{
        installation_id: installation_id,
        actor_type: "system",
        action: "security.retention_probe",
        resource_type: "installation",
        resource_id: installation_id,
        correlation_id: Ecto.UUID.generate(),
        metadata: %{result: "ok", source: "test"}
      })
      |> Repo.transaction()

    {1, _} =
      Repo.update_all(from(e in AuditEvent, where: e.id == ^event.id),
        set: [inserted_at: inserted_at]
      )

    Repo.get!(AuditEvent, event.id)
  end

  defp insert_session(member, now) do
    case Sessions.issue(Repo, member, now: now) do
      {:ok, %{session: session}} -> {:ok, session}
    end
  end

  defp revoke_session(session, now) do
    Sessions.revoke(session, now)
  end

  defp remaining_receipts(ids) do
    Repo.aggregate(from(e in ReceivedEvent, where: e.id in ^ids), :count)
  end

  defp secrets(installation_id) do
    Repo.aggregate(from(s in Secret, where: s.installation_id == ^installation_id), :count)
  end

  defp connections(installation_id) do
    Repo.aggregate(from(c in Connection, where: c.installation_id == ^installation_id), :count)
  end

  defp members(installation_id) do
    Repo.aggregate(
      from(m in WorkspaceMember, where: m.installation_id == ^installation_id),
      :count
    )
  end

  defp authorizations(installation_id) do
    Repo.aggregate(
      from(a in UserAuthorization, where: a.installation_id == ^installation_id),
      :count
    )
  end

  defp attach_retention do
    handler = "retention-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        Retention.telemetry_event() ++ [:sweep],
        fn _event, measurements, metadata, pid ->
          send(pid, {:retention, measurements, metadata})
        end,
        self()
      )

    handler
  end

  defp index_definitions(table) do
    %{rows: rows} =
      Repo.query!("SELECT indexdef FROM pg_indexes WHERE tablename = $1", [table])

    Enum.map_join(rows, "\n", fn [definition] -> definition end)
  end
end
