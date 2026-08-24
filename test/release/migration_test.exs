defmodule PumbleAutomation.Release.MigrationTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @application Path.join(@root, "lib/pumble_automation/application.ex")
  @container_smoke Path.join(@root, "scripts/container-smoke.sh")
  @ci Path.join(@root, ".github/workflows/ci.yml")
  @dockerfile Path.join(@root, "Dockerfile")
  @dockerignore Path.join(@root, ".dockerignore")
  @migrate Path.join(@root, "rel/overlays/bin/migrate")
  @release Path.join(@root, "lib/pumble_automation/release.ex")
  @migration_integration Path.join(@root, "scripts/release-migration-integration.sh")

  @history_migration Path.join(
                       @root,
                       "priv/repo/migrations/20260823230831_add_executions_history_cursor_index.exs"
                     )

  @identity_migration Path.join(
                        @root,
                        "priv/repo/migrations/20260823232058_add_workflow_version_identity_hash.exs"
                      )

  test "the repository serializes release runners with a PostgreSQL advisory lock" do
    assert PumbleAutomation.Repo.config()[:migration_lock] == :pg_advisory_lock
  end

  test "the real concurrent history index repairs its invalid retry boundary" do
    migration = File.read!(@history_migration)
    integration = File.read!(@migration_integration)

    assert migration =~ "index.indisvalid"
    assert migration =~ "DROP INDEX CONCURRENTLY"
    refute migration =~ "def change"
    assert integration =~ "seed_invalid_history_index"
    assert integration =~ "history_retry=proved"
  end

  test "workflow identity objects require their exact catalog definitions" do
    migration = File.read!(@identity_migration)
    integration = File.read!(@migration_integration)

    for catalog_check <- [
          "target.oid = 'workflow_versions'::regclass",
          "index.indisunique",
          "index.indnkeyatts",
          "index.indnatts",
          "index.indexprs IS NULL",
          "index.indpred IS NULL",
          "pg_get_indexdef(index.indexrelid)",
          "pg_get_expr(catalog_constraint.conbin",
          "catalog_constraint.contype::text",
          "catalog_constraint.connamespace = current_schema()::regnamespace"
        ] do
      assert migration =~ catalog_check
    end

    assert migration =~ ~s(["workflow_id", second_key])
    assert migration =~ "existing workflow version index does not match its required definition"

    assert migration =~
             "existing workflow version constraint does not match its required definition"

    assert integration =~ "seed_wrong_identity_objects"
    assert integration =~ "CHECK (source_hash IS NULL OR length(source_hash) = 64);"
    assert integration =~ "AND convalidated"
    assert integration =~ "wrong-owner identity index was accepted"
    assert integration =~ "wrong-definition identity index was accepted"
    assert integration =~ "wrong_objects=rejected_recovered"
  end

  test "migrations are an explicit one-shot release command, not a web boot child" do
    application_source = File.read!(@application)
    release_source = File.read!(@release)
    migrate_source = File.read!(@migrate)

    refute application_source =~ "Ecto.Migrator"
    assert release_source =~ "Ecto.Migrator.with_repo"
    assert release_source =~ "pg_try_advisory_lock"
    assert release_source =~ "pg_advisory_unlock"
    assert migrate_source =~ "PumbleAutomation.Release.migrate()"

    assert {:ok, %{type: :regular, mode: mode}} = File.stat(@migrate)
    assert Bitwise.band(mode, 0o111) != 0
  end

  test "the image is digest pinned, candidate labelled, and numeric non-root" do
    dockerfile = File.read!(@dockerfile)

    assert dockerfile =~ "hexpm/elixir:1.20.3-erlang-29.0.5-alpine-3.24.1@sha256:"
    assert dockerfile =~ "alpine:3.24.1@sha256:"
    assert dockerfile =~ "org.opencontainers.image.revision"
    assert dockerfile =~ "org.opencontainers.image.version"
    assert dockerfile =~ "USER 10001:10001"
    assert dockerfile =~ ~s(ENTRYPOINT ["/sbin/tini", "--"])
    refute dockerfile =~ "COPY . ."
  end

  test "the runtime image configuration does not define application secrets" do
    dockerfile = File.read!(@dockerfile)

    for name <- [
          "DATABASE_URL",
          "SECRET_KEY_BASE",
          "PUMBLE_CLIENT_SECRET",
          "PUMBLE_APP_KEY",
          "PUMBLE_SIGNING_SECRET",
          "ENCRYPTION_KEY"
        ] do
      refute dockerfile =~ name
    end
  end

  test "the strict build context excludes development assets and seed scripts" do
    dockerignore = File.read!(@dockerignore)

    assert String.starts_with?(dockerignore, "*\n")
    assert dockerignore =~ "!config/prod.exs"
    assert dockerignore =~ "!priv/repo/migrations/*.exs"
    assert dockerignore =~ "priv/release_test/"
    assert dockerignore =~ "priv/repo/migrations/.formatter.exs"
    assert dockerignore =~ "priv/repo/seeds.exs"
    refute dockerignore =~ "!priv/repo/**"
    refute dockerignore =~ "!assets/**"
  end

  test "the hardened smoke verifies the runtime init, trust store, timezone data, and TLS" do
    container_smoke = File.read!(@container_smoke)

    assert container_smoke =~ ~s(["/sbin/tini","--"])
    assert container_smoke =~ "/etc/ssl/certs/ca-certificates.crt"
    assert container_smoke =~ "/usr/share/zoneinfo/UTC"
    assert container_smoke =~ ":crypto.hash(:sha256, \"container-crypto-probe\")"
    assert container_smoke =~ ":ssl.connect"
    assert container_smoke =~ ":public_key.pkix_verify_hostname_match_fun(:https)"
    assert container_smoke =~ ~s(--add-host "host.docker.internal:host-gateway")
  end

  test "CI installs an exact Trivy release through a commit-pinned action" do
    ci = File.read!(@ci)

    assert ci =~
             "aquasecurity/setup-trivy@81e514348e19b6112ce2a7e3ecbafe19c1e1f567"

    assert ci =~ "version: v0.74.0"
    refute ci =~ ~r{aquasecurity/setup-trivy@v}
  end

  test "the container gate blocks fixable vulnerabilities and never silently accepts no-fix findings" do
    container_smoke = File.read!(@container_smoke)

    assert container_smoke =~ "--severity HIGH,CRITICAL"
    assert container_smoke =~ ".FixedVersion"
    assert container_smoke =~ "fixable HIGH/CRITICAL vulnerabilities block release"
    assert container_smoke =~ "CONTAINER_SMOKE_ACCEPT_UNFIXED_SHA256"
    assert container_smoke =~ "unresolved no-fix findings require recorded risk acceptance"
    assert container_smoke =~ "unresolved inventory sha256"
    refute container_smoke =~ "--ignore-unfixed"
  end
end
