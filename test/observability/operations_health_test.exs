defmodule PumbleAutomation.Observability.OperationsHealthTest do
  @moduledoc """
  Queue, schedule, and readiness diagnostics: public ready stays minimal,
  detailed checks are owner-only and tenant-scoped, and a probe failure
  does not hang liveness.
  """

  use PumbleAutomationWeb.ConnCase, async: false
  use Oban.Testing, repo: PumbleAutomation.Repo

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Executions.Concurrency
  alias PumbleAutomation.Executions.StepAttempt
  alias PumbleAutomation.Executions.Workers.AdvanceExecutionWorker
  alias PumbleAutomation.ExecutionsFixtures
  alias PumbleAutomation.Health
  alias PumbleAutomation.HealthProbes
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Operations.Health, as: OperationsHealth
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomationWeb.BrowserSession

  defp put_probe(module) do
    previous = Application.fetch_env(:pumble_automation, :health_probe)
    Application.put_env(:pumble_automation, :health_probe, module)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:pumble_automation, :health_probe, value)
        :error -> Application.delete_env(:pumble_automation, :health_probe)
      end
    end)
  end

  defp log_in(conn, token) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Test.put_req_cookie(BrowserSession.cookie(), token)
  end

  defp check(report, name), do: Enum.find(report.checks, &(&1.name == name))

  defp minutes_ago(minutes) do
    DateTime.add(DateTime.utc_now(), -minutes * 60, :second)
  end

  defp insert_available_job!(installation_id, scheduled_at, execution_id) do
    args = %{
      "installation_id" => installation_id,
      "execution_id" => execution_id,
      "expected_node_id" => Ecto.UUID.generate(),
      "generation" => 1
    }

    {:ok, job} = args |> AdvanceExecutionWorker.new(scheduled_at: scheduled_at) |> Oban.insert()

    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
      set: [state: "available", scheduled_at: scheduled_at]
    )

    Repo.get!(Oban.Job, job.id)
  end

  describe "healthy baseline" do
    test "owner diagnostics are ok and public ready stays 200", %{conn: conn} do
      %{session_token: token, member: member, installation: installation} =
        InstallationsFixtures.install()

      assert {:ok, report} = OperationsHealth.diagnostics(Scope.new(member))
      assert report.status == :ok
      assert report.ready?
      assert report.installation_id == installation.id
      assert check(report, :database_latency).status == :ok
      assert check(report, :migrations).status == :ok
      assert check(report, :oban).status == :ok
      assert check(report, :oldest_available_job).status == :ok
      assert check(report, :schedule_lag).status == :ok
      assert check(report, :stale_attempts).status == :ok
      assert check(report, :missing_jobs).status == :ok
      assert check(report, :cleanup_lag).status == :ok
      assert report.alert_thresholds.schedule_lag_ms == :timer.minutes(5)

      assert json_response(get(conn, ~p"/health/live"), 200) == %{"status" => "ok"}

      assert json_response(get(conn, ~p"/health/ready"), 200) == %{
               "status" => "ok",
               "checks" => %{"database" => "ok", "migrations" => "ok", "queues" => "ok"}
             }

      {:ok, view, _html} = live(log_in(conn, token), ~p"/settings/operations")
      assert has_element?(view, "#operations-health")
      assert has_element?(view, "#operations-ready")
      assert has_element?(view, "#operations-alerts")
      assert has_element?(view, "#operations-samples-empty")
    end
  end

  describe "database down" do
    test "diagnostics are unhealthy, ready is 503, live stays 200", %{conn: conn} do
      %{member: member, installation: installation} = InstallationsFixtures.install()
      put_probe(HealthProbes.DatabaseDown)

      log =
        capture_log(fn ->
          assert {:ok, report} = OperationsHealth.diagnostics(Scope.new(member))
          assert report.status == :unhealthy
          refute report.ready?
          assert check(report, :database_latency).status == :unhealthy
          assert check(report, :schedule_lag).status == :unknown
          assert check(report, :oldest_available_job).samples == []

          body = json_response(get(conn, ~p"/health/ready"), 503)
          assert body["status"] == "error"
          assert body["checks"]["database"] == "error"
          refute inspect(body) =~ installation.id
          refute inspect(body) =~ "postgres"
          refute inspect(body) =~ "db.internal"

          assert json_response(get(conn, ~p"/health/live"), 200) == %{"status" => "ok"}
        end)

      assert log =~ "health.ready"
      refute log =~ "postgres"
      refute log =~ "db.internal"
    end
  end

  describe "oban unavailable" do
    test "marks queues unhealthy without leaking job arguments", %{conn: conn} do
      %{member: member} = InstallationsFixtures.install()
      put_probe(HealthProbes.QueuesDown)

      assert {:ok, report} = OperationsHealth.diagnostics(Scope.new(member))
      assert check(report, :oban).status == :unhealthy
      refute report.ready?

      body = json_response(get(conn, ~p"/health/ready"), 503)
      assert body["checks"]["queues"] == "error"
      assert Enum.sort(Map.keys(body)) == ["checks", "status"]
      refute inspect(report) =~ "expected_node_id"
    end
  end

  describe "old queue" do
    test "a 20-minute available job is degraded and does not fail public ready", %{conn: conn} do
      %{member: member, installation: installation} = InstallationsFixtures.install()
      %{member: other} = InstallationsFixtures.install()
      ours = Ecto.UUID.generate()
      theirs = Ecto.UUID.generate()
      insert_available_job!(installation.id, minutes_ago(20), ours)
      insert_available_job!(other.installation_id, minutes_ago(20), theirs)

      assert {:ok, report} = OperationsHealth.diagnostics(Scope.new(member))
      queue = check(report, :oldest_available_job)
      assert queue.status == :degraded
      assert report.ready?
      assert Enum.any?(queue.samples, &(&1.execution_id == ours))
      refute Enum.any?(queue.samples, &(&1.execution_id == theirs))

      body = json_response(get(conn, ~p"/health/ready"), 200)
      assert body["status"] == "ok"
      refute inspect(body) =~ ours
      refute inspect(body) =~ theirs
      refute inspect(report) =~ "expected_node_id"
    end
  end

  describe "late schedule" do
    test "a due clock older than five minutes is degraded for this tenant only" do
      %{member: member, installation: installation} = InstallationsFixtures.install()
      %{installation: other} = InstallationsFixtures.install()
      ours = ExecutionsFixtures.version(installation.id)
      theirs = ExecutionsFixtures.version(other.id)
      ours_schedule = schedule(ours, %{next_run_at: minutes_ago(10)})
      theirs_schedule = schedule(theirs, %{next_run_at: minutes_ago(10)})

      assert {:ok, report} = OperationsHealth.diagnostics(Scope.new(member))
      lag = check(report, :schedule_lag)
      assert lag.status == :degraded
      assert Enum.any?(lag.samples, &(&1.id == ours_schedule.id))
      refute Enum.any?(lag.samples, &(&1.id == theirs_schedule.id))
      assert Health.readiness().status == :ok
    end
  end

  describe "stale attempt" do
    test "a started attempt older than the stale window is listed with an execution link" do
      %{session_token: token, member: member, installation: installation} =
        InstallationsFixtures.install()

      %{installation: other} = InstallationsFixtures.install()
      node_id = Ecto.UUID.generate()
      version = ExecutionsFixtures.version(installation.id)

      execution =
        ExecutionsFixtures.execution(version, %{status: "running", current_node_id: node_id})

      step = ExecutionsFixtures.step_execution(execution, %{status: "running", node_id: node_id})
      {:ok, attempt} = StepAttempt.create(step)

      other_version = ExecutionsFixtures.version(other.id)

      other_execution =
        ExecutionsFixtures.execution(other_version, %{
          status: "running",
          current_node_id: node_id
        })

      other_step =
        ExecutionsFixtures.step_execution(other_execution, %{
          status: "running",
          node_id: node_id
        })

      {:ok, other_attempt} = StepAttempt.create(other_step)

      cutoff =
        DateTime.add(DateTime.utc_now(), -(Concurrency.stale_after_seconds() + 60), :second)

      Repo.update_all(from(a in StepAttempt, where: a.id == ^attempt.id),
        set: [started_at: cutoff]
      )

      Repo.update_all(from(a in StepAttempt, where: a.id == ^other_attempt.id),
        set: [started_at: cutoff]
      )

      assert {:ok, report} = OperationsHealth.diagnostics(Scope.new(member))
      stale = check(report, :stale_attempts)
      assert stale.status == :degraded
      assert Enum.any?(stale.samples, &(&1.id == execution.id))
      refute Enum.any?(stale.samples, &(&1.id == other_execution.id))

      {:ok, view, _html} =
        live(log_in(build_conn(), token), ~p"/settings/operations")

      assert has_element?(view, "#affected-execution-#{execution.id}")
      refute has_element?(view, "#affected-execution-#{other_execution.id}")
    end
  end

  describe "missing jobs" do
    test "a queued execution with an open slot and no job is reported" do
      %{member: member, installation: installation} = InstallationsFixtures.install()
      version = ExecutionsFixtures.version(installation.id)
      execution = ExecutionsFixtures.execution(version, %{status: "queued"})

      assert {:ok, report} = OperationsHealth.diagnostics(Scope.new(member))
      missing = check(report, :missing_jobs)
      assert missing.status == :degraded
      assert Enum.any?(missing.samples, &(&1.id == execution.id))
    end
  end

  describe "authorization" do
    test "editors and viewers cannot read diagnostics or the operations page", %{conn: conn} do
      %{session_token: token, member: member} = InstallationsFixtures.install()
      editor = InstallationsFixtures.set_role(member, "editor")

      assert {:error, %PumbleAutomation.Error{class: :permission}} =
               OperationsHealth.diagnostics(Scope.new(editor))

      {:ok, editor_view, _html} = live(log_in(conn, token), ~p"/settings/operations")
      assert has_element?(editor_view, "#operations-forbidden")
      refute has_element?(editor_view, "#operations-checks")
      refute has_element?(editor_view, "#operations-alerts")

      {:ok, settings_view, _html} = live(log_in(conn, token), ~p"/settings")
      refute has_element?(settings_view, "#settings-operations")

      viewer_install = InstallationsFixtures.install()
      viewer = InstallationsFixtures.set_role(viewer_install.member, "viewer")

      assert {:error, %PumbleAutomation.Error{class: :permission}} =
               OperationsHealth.diagnostics(Scope.new(viewer))

      {:ok, viewer_view, _html} =
        live(log_in(build_conn(), viewer_install.session_token), ~p"/settings/operations")

      assert has_element?(viewer_view, "#operations-forbidden")
    end

    test "a visitor is sent to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/settings/operations")
      assert to == BrowserSession.sign_in_path()
    end
  end
end
