defmodule PumbleAutomationWeb.HealthControllerTest do
  # Not async: these tests swap the readiness probe in the application
  # environment, which is global, and the endpoint runs the real probe in a
  # process the test does not own, which needs the shared sandbox.
  use PumbleAutomationWeb.ConnCase, async: false

  alias Ecto.Migrator
  alias PumbleAutomation.Health
  alias PumbleAutomation.Health.RepoProbe
  alias PumbleAutomation.HealthProbes
  alias PumbleAutomation.Repo

  @check_event [:pumble_automation, :health, :check]

  # Points readiness at a stand-in probe for one test and restores the default
  # afterwards, so a failure in one test cannot make the next one fail too.
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

  describe "GET /health/live" do
    test "answers 200 with a minimal body", %{conn: conn} do
      conn = get(conn, ~p"/health/live")

      assert json_response(conn, 200) == %{"status" => "ok"}
    end

    test "answers 200 while every dependency is down", %{conn: conn} do
      put_probe(HealthProbes.DatabaseDown)

      assert json_response(get(conn, ~p"/health/live"), 200) == %{"status" => "ok"}
    end

    test "runs no database query", %{conn: conn} do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "health-live-repo-#{inspect(ref)}",
        [:pumble_automation, :repo, :query],
        fn _event, _measurements, _metadata, _config -> send(test_pid, {ref, :queried}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("health-live-repo-#{inspect(ref)}") end)

      assert json_response(get(conn, ~p"/health/live"), 200) == %{"status" => "ok"}
      refute_receive {^ref, :queried}, 100
    end
  end

  describe "GET /health/ready when everything is healthy" do
    test "answers 200 and reports every check as ok", %{conn: conn} do
      conn = get(conn, ~p"/health/ready")

      assert json_response(conn, 200) == %{
               "status" => "ok",
               "checks" => %{"database" => "ok", "migrations" => "ok", "queues" => "ok"}
             }
    end

    test "the migration check sees the applied schema" do
      assert Enum.all?(Migrator.migrations(Repo), fn {status, _version, _name} ->
               status == :up
             end)

      assert RepoProbe.migration_status() == :ok
    end

    test "the database probe answers under its timeout" do
      assert RepoProbe.ping(2_000) == :ok
    end

    test "the queue probe sees the supervised job runtime" do
      assert RepoProbe.queue_status() == :ok
    end
  end

  describe "GET /health/ready when a dependency fails" do
    test "answers 503 when the database is unreachable", %{conn: conn} do
      put_probe(HealthProbes.DatabaseDown)

      assert json_response(get(conn, ~p"/health/ready"), 503) == %{
               "status" => "error",
               "checks" => %{"database" => "error", "migrations" => "ok", "queues" => "ok"}
             }
    end

    test "answers 503 when the schema is behind the release", %{conn: conn} do
      put_probe(HealthProbes.MigrationsPending)

      assert json_response(get(conn, ~p"/health/ready"), 503) == %{
               "status" => "error",
               "checks" => %{"database" => "ok", "migrations" => "error", "queues" => "ok"}
             }
    end

    test "fails closed when a probe raises or exits", %{conn: conn} do
      put_probe(HealthProbes.Raising)

      assert json_response(get(conn, ~p"/health/ready"), 503) == %{
               "status" => "error",
               "checks" => %{"database" => "error", "migrations" => "error", "queues" => "ok"}
             }
    end

    test "leaks no reason, host, or credential into the body", %{conn: conn} do
      put_probe(HealthProbes.Raising)

      body = json_response(get(conn, ~p"/health/ready"), 503)

      assert Enum.sort(Map.keys(body)) == ["checks", "status"]
      assert Enum.sort(Map.keys(body["checks"])) == ["database", "migrations", "queues"]
      assert Enum.all?(Map.values(body["checks"]), &(&1 in ["ok", "error"]))

      raw = Jason.encode!(body)
      refute raw =~ "postgres"
      refute raw =~ "db.internal"
      refute raw =~ "connection refused"
      refute raw =~ "RuntimeError"
    end
  end

  describe "readiness reporting" do
    test "reports every failing check rather than stopping at the first" do
      report = Health.readiness(probe: HealthProbes.Raising)

      assert report.status == :error
      assert report.checks == [database: :error, migrations: :error, queues: :ok]
      assert length(report.errors) == 2
      assert Enum.all?(report.errors, &(&1.class == :dependency))
    end

    test "the retained error details name the check and not the exception message" do
      report = Health.readiness(probe: HealthProbes.Raising)
      [database_error | _rest] = report.errors

      assert database_error.details.check == :database
      refute inspect(database_error) =~ "db.internal"
      refute inspect(database_error) =~ "postgres"
    end

    test "the default probe is the repository probe" do
      assert Health.configured_probe() == RepoProbe
    end
  end

  describe "telemetry" do
    test "emits latency and outcome for every probe" do
      test_pid = self()
      handler = "health-check-test"

      :telemetry.attach(
        handler,
        @check_event,
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      Health.readiness(probe: HealthProbes.DatabaseDown)

      assert_receive {:telemetry, @check_event, %{duration: database_duration},
                      %{check: :database, status: :error}}

      assert is_integer(database_duration)

      assert_receive {:telemetry, @check_event, %{duration: _},
                      %{check: :migrations, status: :ok}}

      assert_receive {:telemetry, @check_event, %{duration: _}, %{check: :queues, status: :ok}}
    end
  end
end
