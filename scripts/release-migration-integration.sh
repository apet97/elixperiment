#!/usr/bin/env bash

# Integration proof for the assembled release migration command. It uses only
# uniquely named local test databases and removes them on every exit path.

set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"

release_dir=${RELEASE_DIR:-"${repo_root}/_build/prod/rel/pumble_automation"}
release_bin="${release_dir}/bin/migrate"

if [[ -n ${PSQL_BIN:-} ]]; then
  psql_bin=$PSQL_BIN
elif command -v psql >/dev/null 2>&1; then
  psql_bin=$(command -v psql)
elif [[ -x /opt/homebrew/opt/postgresql@16/bin/psql ]]; then
  psql_bin=/opt/homebrew/opt/postgresql@16/bin/psql
else
  printf 'release-migration-integration: PostgreSQL psql client is required\n' >&2
  exit 1
fi

[[ -x "$psql_bin" ]] || {
  printf 'release-migration-integration: PSQL_BIN is not executable\n' >&2
  exit 1
}

[[ -x "$release_bin" ]] || {
  printf 'release-migration-integration: build the production release first\n' >&2
  exit 1
}

base_suffix="${$}_${RANDOM}"
empty_partition="_release_empty_${base_suffix}"
backfill_partition="_release_backfill_${base_suffix}"
retry_partition="_release_retry_${base_suffix}"
wrong_objects_partition="_release_wrong_objects_${base_suffix}"
history_retry_partition="_release_history_retry_${base_suffix}"
tx_partition="_release_tx_${base_suffix}"
non_tx_partition="_release_non_tx_${base_suffix}"
compat_partition="_release_compat_${base_suffix}"
created_partitions=()
temp_root=$(mktemp -d "${TMPDIR:-/tmp}/pumble-release-migration.XXXXXX")

case "$temp_root" in
  "${TMPDIR:-/tmp}"/pumble-release-migration.*) ;;
  *)
    printf 'release-migration-integration: refusing unsafe temp directory\n' >&2
    exit 1
    ;;
esac

cleanup() {
  status=$?
  trap - EXIT INT TERM

  for partition in "${created_partitions[@]}"; do
    case "$partition" in
      _release_*_[0-9]*_[0-9]*)
        MIX_ENV=test MIX_TEST_PARTITION="$partition" \
          mix ecto.drop --force >/dev/null 2>&1 || true
        ;;
    esac
  done

  if [[ -d "$temp_root" && "$temp_root" == "${TMPDIR:-/tmp}"/pumble-release-migration.* ]]; then
    rm -rf -- "$temp_root"
  fi

  exit "$status"
}

trap cleanup EXIT INT TERM

create_database() {
  local partition=$1

  MIX_ENV=test MIX_TEST_PARTITION="$partition" mix ecto.create >/dev/null
  created_partitions+=("$partition")
}

database_name() {
  printf 'pumble_automation_test%s' "$1"
}

run_migrate() {
  local migrate_bin=$1
  local partition=$2
  local database
  database=$(database_name "$partition")

  env \
    DATABASE_URL="ecto://postgres:postgres@localhost:5432/${database}" \
    DATABASE_SSL=false \
    PUBLIC_BASE_URL=http://localhost:4000 \
    PORT=4000 \
    SECRET_KEY_BASE=ssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssss \
    SESSION_SIGNING_SALT=release-test-salt \
    PUMBLE_CLIENT_ID=release-test-client \
    PUMBLE_CLIENT_SECRET=release-test-client-secret \
    PUMBLE_APP_KEY=release-test-application-key \
    PUMBLE_SIGNING_SECRET=release-test-signing-secret \
    ENCRYPTION_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA \
    ENCRYPTION_KEY_VERSION=1 \
    "$migrate_bin"
}

migrate_to() {
  local partition=$1
  local version=$2

  MIX_ENV=test MIX_TEST_PARTITION="$partition" \
    mix ecto.migrate --to "$version" >/dev/null
}

psql_scalar() {
  local partition=$1
  local sql=$2
  local database
  database=$(database_name "$partition")

  PGPASSWORD=postgres "$psql_bin" \
    --host localhost \
    --username postgres \
    --dbname "$database" \
    --tuples-only \
    --no-align \
    --set ON_ERROR_STOP=1 \
    --command "$sql"
}

seed_invalid_history_index() {
  local partition=$1
  local database
  local locker_client
  local locker_backend
  local builder_client
  local builder_backend
  local observed=false
  database=$(database_name "$partition")

  PGPASSWORD=postgres "$psql_bin" \
    --host localhost \
    --username postgres \
    --dbname "$database" \
    --set ON_ERROR_STOP=1 \
    --command \
    "BEGIN; UPDATE executions SET updated_at = updated_at WHERE false; SELECT pg_sleep(30); COMMIT;" \
    >"${temp_root}/history-locker.log" 2>&1 &
  locker_client=$!

  for _attempt in {1..100}; do
    if [[ $(psql_scalar "$partition" \
      "SELECT count(*) FROM pg_locks WHERE relation = 'executions'::regclass AND mode = 'RowExclusiveLock' AND granted") -gt 0 ]]; then
      observed=true
      break
    fi
    sleep 0.05
  done

  [[ "$observed" == true ]] || {
    printf 'release-migration-integration: history-index locker did not acquire its lock\n' >&2
    exit 1
  }

  locker_backend=$(psql_scalar "$partition" \
    "SELECT pid FROM pg_locks WHERE relation = 'executions'::regclass AND mode = 'RowExclusiveLock' AND granted LIMIT 1")
  [[ "$locker_backend" =~ ^[0-9]+$ ]] || {
    printf 'release-migration-integration: history-index locker backend is unknown\n' >&2
    exit 1
  }

  PGPASSWORD=postgres "$psql_bin" \
    --host localhost \
    --username postgres \
    --dbname "$database" \
    --set ON_ERROR_STOP=1 \
    --command \
    "CREATE INDEX CONCURRENTLY executions_installation_history_cursor_index ON executions (installation_id, inserted_at DESC, id DESC)" \
    >"${temp_root}/history-builder.log" 2>&1 &
  builder_client=$!
  observed=false

  for _attempt in {1..100}; do
    if [[ $(psql_scalar "$partition" \
      "SELECT count(*) FROM pg_index WHERE indexrelid = to_regclass('executions_installation_history_cursor_index') AND NOT indisvalid") -eq 1 ]]; then
      observed=true
      break
    fi
    sleep 0.05
  done

  [[ "$observed" == true ]] || {
    printf 'release-migration-integration: concurrent history index did not reach its invalid boundary\n' >&2
    exit 1
  }

  builder_backend=$(psql_scalar "$partition" \
    "SELECT pid FROM pg_stat_activity WHERE datname = current_database() AND query LIKE 'CREATE INDEX CONCURRENTLY executions_installation_history_cursor_index%' AND pid <> pg_backend_pid() LIMIT 1")
  [[ "$builder_backend" =~ ^[0-9]+$ ]] || {
    printf 'release-migration-integration: history-index builder backend is unknown\n' >&2
    exit 1
  }

  [[ $(psql_scalar "$partition" "SELECT pg_terminate_backend(${builder_backend})") == t ]] || {
    printf 'release-migration-integration: history-index builder did not terminate\n' >&2
    exit 1
  }

  if wait "$builder_client"; then
    printf 'release-migration-integration: cancelled history-index build unexpectedly succeeded\n' >&2
    exit 1
  fi

  [[ $(psql_scalar "$partition" "SELECT pg_terminate_backend(${locker_backend})") == t ]] || {
    printf 'release-migration-integration: history-index locker did not terminate\n' >&2
    exit 1
  }

  wait "$locker_client" 2>/dev/null || true

  [[ $(psql_scalar "$partition" \
    "SELECT count(*) FROM pg_index WHERE indexrelid = to_regclass('executions_installation_history_cursor_index') AND NOT indisvalid") -eq 1 ]] || {
    printf 'release-migration-integration: invalid history index was not preserved for retry\n' >&2
    exit 1
  }
}

assert_history_index_repaired() {
  local partition=$1

  [[ $(psql_scalar "$partition" \
    "SELECT count(*) FROM pg_index WHERE indexrelid = to_regclass('executions_installation_history_cursor_index') AND indisvalid") -eq 1 ]] || {
    printf 'release-migration-integration: history index retry did not produce a valid index\n' >&2
    exit 1
  }

  [[ $(psql_scalar "$partition" \
    "SELECT count(*) FROM schema_migrations WHERE version = 20260823230831") -eq 1 ]] || {
    printf 'release-migration-integration: repaired history migration was not recorded\n' >&2
    exit 1
  }
}

seed_workflow_version_before_identity() {
  local partition=$1

  # The single-quoted expression is Elixir source and must not be shell-expanded.
  # shellcheck disable=SC2016
  MIX_ENV=test MIX_TEST_PARTITION="$partition" \
    mix run --no-start -e '
      installation_id = Ecto.UUID.generate()
      workflow_id = Ecto.UUID.generate()
      version_id = Ecto.UUID.generate()
      dump_uuid = &Ecto.UUID.dump!/1
      source = %{"steps" => [%{"type" => "send_message"}], "trigger" => %{"type" => "manual"}}
      compiled = %{"instructions" => [%{"operation" => "send_message"}]}
      definition_hash = PumbleAutomation.Workflows.WorkflowVersion.definition_hash(source)

      {:ok, :seeded, _started} =
        Ecto.Migrator.with_repo(PumbleAutomation.Repo, fn repo ->
          Ecto.Adapters.SQL.query!(
            repo,
            "INSERT INTO installations (id, pumble_workspace_id, status, inserted_at, updated_at) VALUES ($1, $2, $3, now(), now())",
            [dump_uuid.(installation_id), "release-backfill-workspace", "active"]
          )

          Ecto.Adapters.SQL.query!(
            repo,
            "INSERT INTO workflows (id, installation_id, name, status, inserted_at, updated_at) VALUES ($1, $2, $3, $4, now(), now())",
            [
              dump_uuid.(workflow_id),
              dump_uuid.(installation_id),
              "Release backfill workflow",
              "draft"
            ]
          )

          Ecto.Adapters.SQL.query!(
            repo,
            """
            INSERT INTO workflow_versions
              (id, installation_id, workflow_id, version_number, source_definition,
               compiled_definition, compiler_version, definition_hash, required_scopes,
               referenced_secret_ids, referenced_connection_ids, inserted_at)
            VALUES
              ($1, $2, $3, 1, $4, $5, $6, $7, $8, $9, $10, now())
            """,
            [
              dump_uuid.(version_id),
              dump_uuid.(installation_id),
              dump_uuid.(workflow_id),
              source,
              compiled,
              "release-compiler-v1",
              definition_hash,
              ["messages:write", "channels:read"],
              Enum.map(
                ["ffffffff-ffff-4fff-8fff-ffffffffffff", "11111111-1111-4111-8111-111111111111"],
                dump_uuid
              ),
              Enum.map(
                ["eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", "22222222-2222-4222-8222-222222222222"],
                dump_uuid
              )
            ]
          )

          :seeded
        end)
    ' >/dev/null
}

seed_partial_identity_boundary() {
  local partition=$1

  # The single-quoted expression is Elixir source and must not be shell-expanded.
  # shellcheck disable=SC2016
  MIX_ENV=test MIX_TEST_PARTITION="$partition" \
    mix run --no-start -e '
      {:ok, :partial, _started} =
        Ecto.Migrator.with_repo(PumbleAutomation.Repo, fn repo ->
          Ecto.Adapters.SQL.query!(
            repo,
            "ALTER TABLE workflow_versions ADD COLUMN source_hash varchar(64)",
            []
          )

          :partial
        end)
    ' >/dev/null
}

seed_wrong_identity_objects() {
  local partition=$1

  psql_scalar "$partition" "
    ALTER TABLE workflow_versions
      ADD COLUMN source_hash varchar(64),
      ADD COLUMN identity_hash varchar(64);

    ALTER TABLE workflow_versions
      ADD CONSTRAINT workflow_versions_source_hash_check
      CHECK (source_hash IS NULL OR length(source_hash) = 64);

    CREATE TABLE release_wrong_identity_owner (
      workflow_id uuid NOT NULL,
      identity_hash varchar(64)
    );

    CREATE UNIQUE INDEX workflow_versions_workflow_id_identity_hash_index
      ON release_wrong_identity_owner (workflow_id, identity_hash);
  " >/dev/null
}

remove_wrong_source_hash_constraint() {
  local partition=$1

  psql_scalar "$partition" \
    "ALTER TABLE workflow_versions DROP CONSTRAINT workflow_versions_source_hash_check" \
    >/dev/null
}

remove_wrong_identity_owner() {
  local partition=$1

  psql_scalar "$partition" \
    "DROP INDEX workflow_versions_workflow_id_identity_hash_index; DROP TABLE release_wrong_identity_owner" \
    >/dev/null
}

seed_wrong_identity_index_definition() {
  local partition=$1

  psql_scalar "$partition" "
    CREATE INDEX workflow_versions_workflow_id_identity_hash_index
      ON workflow_versions (identity_hash, workflow_id)
      WHERE identity_hash IS NOT NULL
  " >/dev/null
}

remove_wrong_identity_index() {
  local partition=$1

  psql_scalar "$partition" \
    "DROP INDEX workflow_versions_workflow_id_identity_hash_index" \
    >/dev/null
}

assert_workflow_version_expansion_compatible() {
  local partition=$1

  # The single-quoted expression is Elixir source and must not be shell-expanded.
  # shellcheck disable=SC2016
  MIX_ENV=test MIX_TEST_PARTITION="$partition" \
    mix run --no-start -e '
      snapshot = %{
        source_definition: %{"steps" => [%{"type" => "send_message"}], "trigger" => %{"type" => "manual"}},
        compiled_definition: %{"instructions" => [%{"operation" => "send_message"}]},
        compiler_version: "release-compiler-v1",
        required_scopes: ["messages:write", "channels:read"],
        referenced_secret_ids: ["ffffffff-ffff-4fff-8fff-ffffffffffff", "11111111-1111-4111-8111-111111111111"],
        referenced_connection_ids: ["eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", "22222222-2222-4222-8222-222222222222"]
      }

      expected = PumbleAutomation.Workflows.WorkflowVersion.identity_hash(snapshot)
      legacy_source = %{"steps" => [], "trigger" => %{"type" => "manual"}}
      legacy_source_hash = PumbleAutomation.Workflows.WorkflowVersion.definition_hash(legacy_source)
      legacy_version_id = Ecto.UUID.dump!(Ecto.UUID.generate())

      {:ok, compatible?, _started} =
        Ecto.Migrator.with_repo(PumbleAutomation.Repo, fn repo ->
          %{rows: [[source_hash, identity_hash, definition_hash, installation_id, workflow_id]]} =
            Ecto.Adapters.SQL.query!(
              repo,
              "SELECT source_hash, identity_hash, definition_hash, installation_id, workflow_id FROM workflow_versions WHERE version_number = 1",
              []
            )

          Ecto.Adapters.SQL.query!(
            repo,
            """
            INSERT INTO workflow_versions
              (id, installation_id, workflow_id, version_number, source_definition,
               definition_hash, inserted_at)
            VALUES ($1, $2, $3, 2, $4, $5, now())
            """,
            [legacy_version_id, installation_id, workflow_id, legacy_source, legacy_source_hash]
          )

          %{rows: [[nil, nil]]} =
            Ecto.Adapters.SQL.query!(
              repo,
              "SELECT source_hash, identity_hash FROM workflow_versions WHERE id = $1",
              [legacy_version_id]
            )

          %{rows: [[source_lookup_id, 1]]} =
            Ecto.Adapters.SQL.query!(
              repo,
              "SELECT id, count(*) OVER () FROM workflow_versions WHERE workflow_id = $1 AND definition_hash = $2 LIMIT 1",
              [workflow_id, legacy_source_hash]
            )

          legacy_version =
            repo.get!(
              PumbleAutomation.Workflows.WorkflowVersion,
              Ecto.UUID.load!(legacy_version_id)
            )

          exact_legacy_identity =
            PumbleAutomation.Workflows.WorkflowVersion.identity_hash(%{
              source_definition: legacy_source,
              compiled_definition: nil,
              compiler_version: nil,
              required_scopes: [],
              referenced_secret_ids: [],
              referenced_connection_ids: []
            })

          endpoint =
            %PumbleAutomation.Ingress.WebhookEndpoint{}
            |> PumbleAutomation.Ingress.WebhookEndpoint.changeset(%{
              installation_id: Ecto.UUID.load!(installation_id),
              workflow_id: Ecto.UUID.load!(workflow_id),
              workflow_version_id: legacy_version.id,
              public_id: "release-signature-proof",
              token_digest: :crypto.hash(:sha256, "release-bearer-proof"),
              enabled: true,
              require_signature: true,
              signing_secret:
                PumbleAutomation.Ingress.WebhookEndpoint.generate_signing_secret(),
              signing_secret_key_version:
                PumbleAutomation.Ingress.WebhookEndpoint.signing_secret_key_version()
            })
            |> repo.insert!()

          %{rows: [[false, true, true]]} =
            Ecto.Adapters.SQL.query!(
              repo,
              "SELECT enabled, signature_enabled, require_signature FROM webhook_endpoints WHERE id = $1",
              [Ecto.UUID.dump!(endpoint.id)]
            )

          source_hash == definition_hash and identity_hash == expected and
            source_lookup_id == legacy_version_id and
            PumbleAutomation.Workflows.WorkflowVersion.legacy_intact?(legacy_version) and
            PumbleAutomation.Workflows.WorkflowVersion.identity_hash(legacy_version) ==
              exact_legacy_identity and
            PumbleAutomation.Ingress.WebhookEndpoint.enabled?(endpoint)
        end)

      if not compatible?, do: System.halt(1)
    ' >/dev/null
}

assert_table() {
  local partition=$1
  local table=$2
  local expected=$3

  # The single-quoted expression is Elixir source and must not be shell-expanded.
  # shellcheck disable=SC2016
  if MIX_ENV=test MIX_TEST_PARTITION="$partition" RELEASE_TEST_TABLE="$table" \
      mix run --no-start -e '
        table = System.fetch_env!("RELEASE_TEST_TABLE")

        {:ok, exists?, _started} =
          Ecto.Migrator.with_repo(PumbleAutomation.Repo, fn repo ->
            %{rows: [[exists?]]} =
              Ecto.Adapters.SQL.query!(repo, "SELECT to_regclass($1) IS NOT NULL", [table])

            exists?
          end)

        if exists?, do: :ok, else: System.halt(1)
      ' >/dev/null 2>&1; then
    actual=true
  else
    actual=false
  fi

  [[ "$actual" == "$expected" ]] || {
    printf 'release-migration-integration: unexpected table state for %s\n' "$table" >&2
    exit 1
  }
}

assert_version_absent() {
  local partition=$1
  local version=$2

  # The single-quoted expression is Elixir source and must not be shell-expanded.
  # shellcheck disable=SC2016
  if MIX_ENV=test MIX_TEST_PARTITION="$partition" RELEASE_TEST_VERSION="$version" \
      mix run --no-start -e '
        {version, ""} = Integer.parse(System.fetch_env!("RELEASE_TEST_VERSION"))

        {:ok, absent?, _started} =
          Ecto.Migrator.with_repo(PumbleAutomation.Repo, fn repo ->
            %{rows: [[count]]} =
              Ecto.Adapters.SQL.query!(repo, "SELECT count(*) FROM schema_migrations WHERE version = $1", [version])

            count == 0
          end)

        if absent?, do: :ok, else: System.halt(1)
      ' >/dev/null 2>&1; then
    return 0
  fi

  printf 'release-migration-integration: failed migration version was recorded\n' >&2
  exit 1
}

assert_compat_rows() {
  local partition=$1

  # The single-quoted expression is Elixir source and must not be shell-expanded.
  # shellcheck disable=SC2016
  MIX_ENV=test MIX_TEST_PARTITION="$partition" \
    mix run --no-start -e '
      {:ok, compatible?, _started} =
        Ecto.Migrator.with_repo(PumbleAutomation.Repo, fn repo ->
          %{rows: [[total, old_shape_rows]]} =
            Ecto.Adapters.SQL.query!(
              repo,
              "SELECT count(*), count(*) FILTER (WHERE new_value IS NULL) FROM release_compat_records",
              []
            )

          total == 2 and old_shape_rows == 1
        end)

      if compatible?, do: :ok, else: System.halt(1)
    ' >/dev/null
}

copy_release() {
  local name=$1
  local target="${temp_root}/${name}"

  cp -R "$release_dir" "$target"
  printf '%s' "$target"
}

migration_directory() {
  local copied_release=$1
  local matches=("${copied_release}"/lib/pumble_automation-*/priv/repo/migrations)

  [[ ${#matches[@]} -eq 1 && -d "${matches[0]}" ]] || {
    printf 'release-migration-integration: release migration directory is ambiguous\n' >&2
    exit 1
  }

  printf '%s' "${matches[0]}"
}

# Empty database plus two simultaneous runners. Both must exit successfully,
# and a third invocation must be a no-op success.
create_database "$empty_partition"
run_migrate "$release_bin" "$empty_partition" >"${temp_root}/runner-one.log" 2>&1 &
runner_one=$!
run_migrate "$release_bin" "$empty_partition" >"${temp_root}/runner-two.log" 2>&1 &
runner_two=$!

if ! wait "$runner_one"; then
  sed -n '1,160p' "${temp_root}/runner-one.log" >&2
  exit 1
fi

if ! wait "$runner_two"; then
  sed -n '1,160p' "${temp_root}/runner-two.log" >&2
  exit 1
fi

run_migrate "$release_bin" "$empty_partition" >/dev/null
assert_table "$empty_partition" schema_migrations true
assert_table "$empty_partition" executions true

# Prove the current release upgrades real pre-existing data, not only an empty
# schema. Stop immediately before the identity-hash migration, seed one old
# workflow version, and let the assembled release backfill and constrain it.
create_database "$backfill_partition"
migrate_to "$backfill_partition" 20260823230831
seed_workflow_version_before_identity "$backfill_partition"
run_migrate "$release_bin" "$backfill_partition" >/dev/null
assert_workflow_version_expansion_compatible "$backfill_partition"

# Retry the current expand migration from an exact partial-DDL boundary. The
# first new column exists but no backfill, constraints, or indexes do; the
# release must complete the migration and preserve the same compatibility
# guarantees instead of failing on the already-present column.
create_database "$retry_partition"
migrate_to "$retry_partition" 20260823230831
seed_workflow_version_before_identity "$retry_partition"
seed_partial_identity_boundary "$retry_partition"
run_migrate "$release_bin" "$retry_partition" >/dev/null
assert_workflow_version_expansion_compatible "$retry_partition"

# A same-named constraint with a weaker expression and a valid same-named
# identity indexes with the wrong owner or with the wrong key order, uniqueness,
# and predicate must never be accepted or silently replaced. Each failed run
# must leave its mismatched object intact and the migration version absent.
# After an operator removes only the named wrong object, the assembled release
# must retry to completion.
create_database "$wrong_objects_partition"
migrate_to "$wrong_objects_partition" 20260823230831
seed_workflow_version_before_identity "$wrong_objects_partition"
seed_wrong_identity_objects "$wrong_objects_partition"

if run_migrate "$release_bin" "$wrong_objects_partition" >"${temp_root}/wrong-constraint.log" 2>&1; then
  printf 'release-migration-integration: wrong same-named constraint was accepted\n' >&2
  exit 1
fi

assert_version_absent "$wrong_objects_partition" 20260823232058

[[ $(psql_scalar "$wrong_objects_partition" \
  "SELECT count(*) FROM pg_constraint WHERE conrelid = 'workflow_versions'::regclass AND conname = 'workflow_versions_source_hash_check' AND convalidated") -eq 1 ]] || {
  printf 'release-migration-integration: wrong constraint was silently replaced\n' >&2
  exit 1
}

remove_wrong_source_hash_constraint "$wrong_objects_partition"

if run_migrate "$release_bin" "$wrong_objects_partition" >"${temp_root}/wrong-index-owner.log" 2>&1; then
  printf 'release-migration-integration: wrong-owner identity index was accepted\n' >&2
  exit 1
fi

assert_version_absent "$wrong_objects_partition" 20260823232058

[[ $(psql_scalar "$wrong_objects_partition" \
  "SELECT count(*) FROM pg_index WHERE indexrelid = to_regclass('workflow_versions_workflow_id_identity_hash_index') AND indrelid = 'release_wrong_identity_owner'::regclass AND indisvalid") -eq 1 ]] || {
  printf 'release-migration-integration: wrong-owner valid index was silently replaced\n' >&2
  exit 1
}

remove_wrong_identity_owner "$wrong_objects_partition"
seed_wrong_identity_index_definition "$wrong_objects_partition"

if run_migrate "$release_bin" "$wrong_objects_partition" >"${temp_root}/wrong-index-definition.log" 2>&1; then
  printf 'release-migration-integration: wrong-definition identity index was accepted\n' >&2
  exit 1
fi

assert_version_absent "$wrong_objects_partition" 20260823232058

[[ $(psql_scalar "$wrong_objects_partition" \
  "SELECT count(*) FROM pg_index WHERE indexrelid = to_regclass('workflow_versions_workflow_id_identity_hash_index') AND indrelid = 'workflow_versions'::regclass AND indisvalid AND NOT indisunique AND indpred IS NOT NULL") -eq 1 ]] || {
  printf 'release-migration-integration: wrong-definition valid index was silently replaced\n' >&2
  exit 1
}

remove_wrong_identity_index "$wrong_objects_partition"
run_migrate "$release_bin" "$wrong_objects_partition" >/dev/null
assert_workflow_version_expansion_compatible "$wrong_objects_partition"

# Cancel this release's real concurrent history-index build after PostgreSQL
# publishes its invalid catalog row. A retry must remove only that exact invalid
# index, rebuild it, record the migration, and continue through the current tip.
create_database "$history_retry_partition"
migrate_to "$history_retry_partition" 20260823223452
seed_invalid_history_index "$history_retry_partition"
run_migrate "$release_bin" "$history_retry_partition" >/dev/null
assert_history_index_repaired "$history_retry_partition"

# A normal transactional migration rolls back its own DDL and does not record
# its version, while the preceding successful migration remains applied.
create_database "$tx_partition"
tx_release=$(copy_release transactional)
tx_migrations=$(migration_directory "$tx_release")
cp priv/release_test/migrations/29990101000001_release_fixture_before_failure.exs "$tx_migrations/"
cp priv/release_test/migrations/29990101000002_release_fixture_transactional_failure.exs "$tx_migrations/"

if run_migrate "${tx_release}/bin/migrate" "$tx_partition" >"${temp_root}/transactional.log" 2>&1; then
  printf 'release-migration-integration: transactional failure unexpectedly succeeded\n' >&2
  exit 1
fi

assert_table "$tx_partition" release_fixture_before_failure true
assert_table "$tx_partition" release_fixture_transaction_rolled_back false
assert_version_absent "$tx_partition" 29990101000002

# A non-transactional migration can leave DDL behind, but its version is not
# falsely marked applied. The non-zero release task exit keeps a new deploy out
# of service and gives the operator an exact repair boundary.
create_database "$non_tx_partition"
non_tx_release=$(copy_release non_transactional)
non_tx_migrations=$(migration_directory "$non_tx_release")
cp priv/release_test/migrations/29990101000003_release_fixture_non_transactional_failure.exs "$non_tx_migrations/"

if run_migrate "${non_tx_release}/bin/migrate" "$non_tx_partition" >"${temp_root}/non-transactional.log" 2>&1; then
  printf 'release-migration-integration: non-transactional failure unexpectedly succeeded\n' >&2
  exit 1
fi

assert_table "$non_tx_partition" release_fixture_non_transactional_partial true
assert_version_absent "$non_tx_partition" 29990101000003

# Simulate the declared one-release rollback window: the old shape is created,
# the expand migration adds only a nullable column, then old-column and
# new-column writes both succeed against the expanded schema.
create_database "$compat_partition"
compat_release=$(copy_release compatibility)
compat_migrations=$(migration_directory "$compat_release")
cp priv/release_test/migrations/29990101000004_release_fixture_old_schema.exs "$compat_migrations/"
run_migrate "${compat_release}/bin/migrate" "$compat_partition" >/dev/null
cp priv/release_test/migrations/29990101000005_release_fixture_expand_schema.exs "$compat_migrations/"
run_migrate "${compat_release}/bin/migrate" "$compat_partition" >/dev/null
assert_compat_rows "$compat_partition"

printf 'release-migration-integration: PASS empty=true concurrent_runners=2 current_backfill=proved partial_retry=proved wrong_objects=rejected_recovered history_retry=proved rollback_write=proved signature_rollback=proved transactional_failure=proved non_transactional_failure=proved compatibility=proved\n'
