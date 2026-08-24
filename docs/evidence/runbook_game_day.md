# Runbook game day (P14-T05)

Date: 2026-08-19. Task: `P14-T05` of
the [historical implementation plan](../archive/planning/implementation-plan.md).
Environment: local non-production (Elixir 1.20.3 / OTP 29 / PostgreSQL 16).
Starting HEAD: `ce91140` (ledger P14-T04). Feature parent: `9d5edd2`.

This is the game-day evidence for operational runbooks. Commands ran against
the local test application, not a production host. Production deploy, backup,
and image rollback remain **planned** (blocker B-001 / P16).

Public support docs stay separate: `docs/operations/local_development.md` is
the shareable local guide. The other files in `docs/operations/` named by
this task are internal operator detail. They do not name production hosts.

## Review checklist

- [x] Every operational failure class has symptom → checks → safe action → stop/escalate.
- [x] Commands match implemented Mix tasks, IEx APIs, and UI ids.
- [x] No command prints secrets.
- [x] Ordinary recovery does not use mutating SQL.
- [x] Occupancy-parked queued rows are not treated as missing jobs.
- [x] Unproven production commands are labelled `planned-owner-approval`.
- [x] Commands that change production infrastructure require owner approval.

Failure classes covered: database unavailable, callbacks failing signatures,
401/403 scope loss, 429/5xx surge, stuck queues, schedule lag, stale
attempts, uncertain effects, uninstall, secret-key rotation, migration
failure, rollback.

## Commands executed (non-production)

| Command | Result |
|---|---|
| `elixir --version` | Elixir 1.20.3 / OTP 29 (start-of-session and `runbooks_test.exs`) |
| `brew services list \| grep postgresql@16` | `started` |
| `mix deps.get` | dependencies unchanged / fetched |
| `GET /health/live` via ConnCase | HTTP 200, `{"status":"ok"}` |
| `GET /health/ready` via ConnCase | HTTP 200, checks database/migrations/queues `ok` |
| `Health.liveness/0` | `:ok` |
| `Health.readiness/0` | `%{status: :ok, ...}` |
| `Operations.Health.diagnostics/1` | `{:ok, report}` with `ready?` true on a healthy owner tenant |
| `Maintenance.run_once(:reconcile)` | `:ok` or `{:snooze, 1}` |
| `Engine.reconcile/1` | `{:ok, map}` |
| `Rotation.rotate(Installation, :encrypted_bot_token)` | `{:ok, %{scanned: _, rotated: _}}` without printing tokens |
| `pg_dump --schema-only` of `pumble_automation_test` | exit 0; output has `schema_migrations`; no planted secrets |
| `Ecto.Migrator.migrations/1` | every shipped migration is `:up` in the test database |
| `./scripts/verify.sh` | all 9 gates passed; `mix test` 2052 tests + 1 doctest (2053 passed) |

`mix phx.server` and `curl http://localhost:4000/health/*` are the operator
commands when a dev server is running. The game-day suite exercises the same
controller and health modules through ConnCase because tests do not start
the dev daemon.

`MIX_ENV=test mix ecto.drop/create/migrate` remains the proven schema replay
from `docs/operations/migrations.md`. It was not re-run as a destructive
step during this game day; `Migrator.migrations/1` confirmed the test schema
is fully applied.

## Peer / manual review

Reviewer: P14-T05 implementer. Assumptions checked:

- Owner UI paths `/settings/operations`, `/audit`, `/executions/:id`,
  `/settings`, `/secrets` match LiveView modules and element ids.
- `Operations.requeue_safe_job/2` still refuses jobs that opened an attempt.
- `Crypto.Rotation` still cannot rotate `secrets.value`.
- Public ready still excludes detailed queue checks.
- Diagnostic ZIP remains P14-T06 and is out of scope here.
