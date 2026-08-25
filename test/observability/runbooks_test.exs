defmodule PumbleAutomation.Observability.RunbooksTest do
  @moduledoc """
  Operational runbooks match implemented commands and UI, cover every failure
  class, label unverified production steps, and execute locally.
  """

  use PumbleAutomationWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Ecto.Migrator
  alias PumbleAutomation.Crypto.Rotation
  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Health
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Maintenance
  alias PumbleAutomation.Operations
  alias PumbleAutomation.Operations.Health, as: OperationsHealth
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomationWeb.BrowserSession

  @runbooks [
    "docs/operations/local_development.md",
    "docs/operations/deployment.md",
    "docs/operations/incidents.md",
    "docs/operations/queues.md",
    "docs/operations/uncertain_effects.md",
    "docs/operations/oauth_revocation.md",
    "docs/operations/backup_restore.md",
    "docs/operations/rollback.md"
  ]

  @evidence "docs/evidence/runbook_game_day.md"

  @failure_classes [
    "database unavailable",
    "callbacks failing signatures",
    "401 / 403",
    "429 / 5xx",
    "stuck queues",
    "schedule lag",
    "stale attempts",
    "uncertain effects",
    "uninstall",
    "secret-key rotation",
    "migration failure",
    "rollback"
  ]

  @required_paths [
    "/health/live",
    "/health/ready",
    "/settings/operations",
    "/executions",
    "/audit",
    "/secrets",
    "/settings"
  ]

  @required_ids [
    "#operations-health",
    "#audit-reconcile",
    "#audit-requeue",
    "#resolve-succeeded-prompt",
    "#resolve-failed-prompt",
    "#resolve-retry-prompt",
    "#uncertain-retry-acknowledge",
    "#cancel-prompt",
    "#audit-delete-tenant"
  ]

  @secret_echo ~r/echo\s+\$\{?(SECRET_KEY_BASE|ENCRYPTION_KEY|PUMBLE_CLIENT_SECRET|PUMBLE_APP_KEY|PUMBLE_SIGNING_SECRET|DATABASE_URL)/i

  @command_status ~r/<!-- command-status: (proven-local|planned-not-executed) -->\s*```(\w+)\n(.*?)```/s
  @fence ~r/```(\w+)\n.*?```/s

  setup do
    on_exit(fn ->
      Enum.each(Maintenance.kinds(), &Maintenance.resume/1)
    end)

    :ok
  end

  describe "files and coverage" do
    test "every named runbook exists and covers first-response sections" do
      for path <- @runbooks do
        assert File.exists?(path), path
        body = File.read!(path)
        assert body =~ "### Symptom" or body =~ "## Symptom", path
        assert body =~ "### Checks" or body =~ "## Checks", path
        assert body =~ "### Safe action" or body =~ "## Safe action", path
        assert body =~ "### Stop conditions" or body =~ "## Stop conditions", path
      end

      corpus = corpus()

      for class <- @failure_classes do
        assert String.downcase(corpus) =~ String.downcase(class), class
      end

      for path <- @required_paths do
        assert corpus =~ path, path
      end

      for id <- @required_ids do
        assert corpus =~ id, id
      end

      assert corpus =~ "occupancy-parked"
      assert corpus =~ "planned-not-executed"
      refute corpus =~ "planned-owner-approval"
      refute corpus =~ "B-001"
      refute String.downcase(corpus) =~ "stop / escalate"
      refute String.downcase(corpus) =~ "escalate"
      refute String.downcase(corpus) =~ "reviewer"
      refute String.downcase(corpus) =~ "peer review"
      assert corpus =~ "PumbleAutomation.Maintenance.run_once"
      assert corpus =~ "PumbleAutomation.Operations.run_reconciliation"
      assert corpus =~ "PumbleAutomation.Executions.Engine.resolve_uncertain"
      assert corpus =~ "PumbleAutomation.Crypto.Rotation"
      assert corpus =~ "load_in_query: false"
    end

    test "every fenced command is labelled proven or planned" do
      for path <- @runbooks do
        body = File.read!(path)
        fences = Regex.scan(@fence, body)
        labelled = Regex.scan(@command_status, body)
        assert length(fences) == length(labelled), "#{path} has unlabelled command fences"

        for [_, status, _lang, command] <- Regex.scan(@command_status, body) do
          if status == "planned-not-executed" do
            assert command =~ "planned"
            assert command =~ "not executed" or command =~ "not verified"
          end
        end
      end
    end

    test "relative markdown links resolve and commands do not print secrets" do
      for path <- [@evidence | @runbooks] do
        body = File.read!(path)
        refute body =~ @secret_echo, path
        refute body =~ "PGPASSWORD="
        refute body =~ "--password="
        refute body =~ "IO.inspect"
        refute body =~ "Bearer ey"

        for [_, _status, _lang, command] <- Regex.scan(@command_status, body) do
          refute command =~ ~r/\bUPDATE\s+[a-z_"]/i, "#{path} command mutates SQL"
          refute command =~ ~r/\bDELETE FROM\b/i, "#{path} command mutates SQL"
          refute command =~ ~r/\bINSERT INTO\b/i, "#{path} command mutates SQL"
        end

        for [_, target] <- Regex.scan(~r/\[[^\]]+\]\(([^)]+)\)/, body) do
          dest = target |> String.split("#") |> hd() |> String.trim()

          cond do
            dest == "" ->
              :ok

            String.starts_with?(dest, "http://") or String.starts_with?(dest, "https://") ->
              :ok

            true ->
              resolved = Path.expand(dest, Path.dirname(path))
              assert File.exists?(resolved), "#{path} -> #{target} (#{resolved})"
          end
        end
      end
    end

    test "game-day evidence names the local commands and the evidence checklist" do
      evidence = File.read!(@evidence)
      assert evidence =~ "non-production"
      assert evidence =~ "GET /health/live"
      assert evidence =~ "Maintenance.run_once(:reconcile)"
      assert String.downcase(evidence) =~ "occupancy-parked"
      assert evidence =~ "Evidence checklist"
      assert evidence =~ "planned-not-executed"
    end
  end

  describe "local game-day simulations" do
    test "health probes, diagnostics, reconcile, rotation, and schema dump succeed", %{
      conn: conn
    } do
      %{session_token: token, member: member} = InstallationsFixtures.install()
      scope = Scope.new(member)

      {elixir_out, 0} =
        System.cmd("elixir", ["--version"], env: cleared_secrets_env())

      assert elixir_out =~ "Elixir 1.20"

      assert Health.liveness() == :ok
      ready = Health.readiness()
      assert ready.status == :ok

      assert json_response(get(conn, ~p"/health/live"), 200) == %{"status" => "ok"}

      assert json_response(get(conn, ~p"/health/ready"), 200) == %{
               "status" => "ok",
               "checks" => %{"database" => "ok", "migrations" => "ok", "queues" => "ok"}
             }

      assert {:ok, report} = OperationsHealth.diagnostics(scope)
      assert report.ready?
      assert report.status in [:ok, :degraded]
      refute inspect(report) =~ "test-client-secret"
      refute inspect(report) =~ "bot-access-token"

      {:ok, view, _html} = live(log_in(conn, token), ~p"/settings/operations")
      assert has_element?(view, "#operations-health")
      assert has_element?(view, "#operations-alerts")

      assert Maintenance.run_once(:reconcile) in [:ok, {:snooze, 1}]
      assert {:ok, summary} = Engine.reconcile(scope)
      assert is_integer(summary.count)
      assert {:ok, owner_summary} = Operations.run_reconciliation(scope)
      assert is_integer(owner_summary.count)

      assert {:ok, %{scanned: scanned, rotated: rotated}} =
               Rotation.rotate(Installation, :encrypted_bot_token,
                 version_field: :token_key_version
               )

      assert scanned >= 0
      assert rotated >= 0

      assert Repo.query!("SELECT 1").rows == [[1]]

      versions = Migrator.migrations(Repo)
      assert versions != []
      assert Enum.all?(versions, fn {status, _version, _name} -> status == :up end)

      incomplete =
        Repo.aggregate(
          from(job in Oban.Job,
            where: job.state in ^["available", "scheduled", "executing", "retryable"]
          ),
          :count
        )

      assert is_integer(incomplete)

      dump_schema!()
    end
  end

  defp corpus do
    Enum.map_join([@evidence | @runbooks], "\n", &File.read!/1)
  end

  defp log_in(conn, token) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Test.put_req_cookie(BrowserSession.cookie(), token)
  end

  defp dump_schema! do
    repo = Application.get_env(:pumble_automation, Repo)
    binary = pg_dump_binary()

    {output, 0} =
      System.cmd(
        binary,
        [
          "--schema-only",
          "-h",
          repo[:hostname],
          "-U",
          repo[:username],
          "-d",
          repo[:database]
        ],
        env:
          cleared_secrets_env() ++
            [{"PGPASSWORD", repo[:password]}, {"PGSSLMODE", "disable"}],
        stderr_to_stdout: true
      )

    assert output =~ "schema_migrations"
    refute output =~ "test-client-secret"
    refute output =~ "test-signing-secret"
    refute output =~ "bot-access-token"
    output
  end

  defp cleared_secrets_env do
    [
      {"SECRET_KEY_BASE", nil},
      {"ENCRYPTION_KEY", nil},
      {"ENCRYPTION_LEGACY_KEYS", nil},
      {"PUMBLE_CLIENT_SECRET", nil},
      {"PUMBLE_APP_KEY", nil},
      {"PUMBLE_SIGNING_SECRET", nil},
      {"DATABASE_URL", nil}
    ]
  end

  defp pg_dump_binary do
    System.find_executable("pg_dump") ||
      Enum.find(
        [
          "/opt/homebrew/opt/postgresql@16/bin/pg_dump",
          "/usr/local/opt/postgresql@16/bin/pg_dump"
        ],
        &File.exists?/1
      ) ||
      flunk("pg_dump is required to prove the local schema-dump runbook command")
  end
end
