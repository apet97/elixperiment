# Incidents

This runbook provides direct first-response paths for supported failure modes.

Every class below has one first-response path: symptom, checks, safe action,
then stop conditions. Detailed recovery lives in the linked runbook. Alert
candidates also live in [metrics.md](metrics.md). Owner UI for queue health is
`/settings/operations`.

Related:

- [Queues](queues.md)
- [Uncertain effects](uncertain_effects.md)
- [OAuth, revocation, and keys](oauth_revocation.md)
- [Backup and restore](backup_restore.md)
- [Rollback](rollback.md)
- [Maintenance](maintenance.md)
- [Logging](logging.md)
- Game day: [runbook_game_day.md](../evidence/runbook_game_day.md)

Do not run `UPDATE`, `DELETE`, or `INSERT` for ordinary recovery. Read-only
`SELECT` is allowed when it does not return tokens or message text.

## Alert versus readiness

| Signal | Alert (look) | Ready failure (cannot accept durable work) |
|---|---|---|
| Database ping | ≥ 200ms | ≥ 2000ms or unreachable |
| Oldest available Oban job | ≥ 15 minutes | ≥ 6 hours |
| Discarded jobs | ≥ 1 | not a public-ready signal (investigate) |
| Due-schedule lag | ≥ 5 minutes | ≥ 6 hours |
| Stale attempts | ≥ 1 (started > 30 minutes) | not a public-ready signal |
| Missing advance jobs | ≥ 1, excluding occupancy-parked queued rows | not a public-ready signal |
| Retention sweep lag | ≥ 26 hours | ≥ 72 hours |
| `/health/ready` | n/a | database, migrations, or Oban probe error |

Public `/health/ready` stays the three cheap probes. A single late job must
not take the node out of rotation.

## Database unavailable

### Symptom

`GET /health/ready` returns HTTP 503. JSON `checks.database` is `error`.
`GET /health/live` stays HTTP 200. Owner diagnostics show **Database latency**
unhealthy. Queue, schedule, and execution checks become `unknown`.

### Checks

1. Call the probes. Do not restart the app because liveness is already ok.

<!-- command-status: proven-local -->
```bash
curl -sS -o /dev/null -w "%{http_code}\n" http://localhost:4000/health/live
curl -sS http://localhost:4000/health/ready
```

2. Confirm PostgreSQL is running locally, or that the managed instance is up.
3. Open `/settings/operations` as an owner. Confirm the failure is the
   database check, not a late job.
4. Optional read-only probe of the local catalog (no passwords on the
   command line):

<!-- command-status: proven-local -->
```bash
psql -h localhost -U postgres -d pumble_automation_dev -c "SELECT 1"
```

### Safe action

1. Restore PostgreSQL connectivity. Keep the app process up so the
   orchestrator does not restart-loop.
2. When ping succeeds, confirm `/health/ready` returns HTTP 200.
3. Then inspect `/settings/operations` for leftover discarded jobs.

### Stop conditions

- Stop if you are about to change liveness so it queries the database.
- Stop if you are about to run mutating SQL.
- Stop before a production restore. Follow
  [backup_restore.md](backup_restore.md); production restore is not verified by
  this repository.

## Callbacks failing signatures

### Symptom

Pumble retries callbacks. Logs show `pumble.callback` with status
`unauthorized`. Metric
`[:pumble_automation, :pumble, :callback, :verify]` counts `unauthorized`
or `rate_limited`. HTTP status for a bad signature is **401** (this
application, not the vendor SDK's 403).

### Checks

1. Confirm `PUMBLE_SIGNING_SECRET` matches the Pumble app. Do not print it.
2. Confirm the proxy does not decode, gzip, or re-encode `/pumble/callbacks`.
3. Confirm both headers exist: `x-pumble-request-signature` and
   `x-pumble-request-timestamp`.
4. Confirm clock skew is small. The verifier uses the timestamp in the
   signed string.

### Safe action

1. Fix the signing secret or the raw-body proxy. Redeploy if the secret
   changed. Expect replayed deliveries.
2. If the surge is abusive, the existing callback-failure rate limit answers
   429. Do not disable signature checks.

### Stop conditions

- Stop if you are about to log the raw callback body or the signature header.
- Stop if you are about to accept unsigned callbacks "temporarily".
- Stop if the signing value cannot be confirmed from the private app
  configuration. Do not guess or bypass signature verification.

## 401 / 403 scope loss

### Symptom

Pumble actions fail permanently with class `authentication` (401) or
`missing_scope` / `authorization` (403). A 403 proves that Pumble refused the
operation; the stored scope snapshot records only what the application
requested. Executions do not retry those classes. The installation can remain
active, so later independent runs can fail again until its permissions change.

### Checks

1. Open `/settings` and onboarding. Note installation status (`active`,
   `degraded`, `revoked`, `uninstalled`).
2. Open `/audit` and filter for lifecycle actions.
3. Open a failing execution at `/executions/:id`. Read the sanitized error
   class. It must not show a token.
4. Treat the scopes shown in `/settings` as the recorded install request, not as
   provider-confirmed grants.

### Safe action

Follow [oauth_revocation.md](oauth_revocation.md). Review the configured scope
request and the app permissions. If the request changed, reinstall the app so
the new request is recorded. Start a new run after access works; do not retry
the failed step from SQL.

### Stop conditions

- Stop if you are about to paste a bot token into a ticket.
- Stop before a Marketplace permission change. Marketplace changes are outside
  this runbook.

## 429 / 5xx surge

### Symptom

Retries rise. Metric `[:pumble_automation, :executions, :retry]` stays
non-zero. Pumble or HTTP nodes report `rate_limited`, `remote_transient`,
or timeouts. Engine retries up to five attempts with the configured backoff
(1s, 5s, 30s, 120s, 600s) plus full jitter. A valid `Retry-After` is
clamped to 1–900 seconds.

### Checks

1. Open `/settings/operations`. Note oldest available job age and discarded
   jobs.
2. Open `/executions` and filter recent `running` or `paused_uncertain`.
3. Distinguish 429 (back off) from 401/403 (do not retry).

### Safe action

1. Let the engine retry. Do not raise Oban `max_attempts` to chase a
   provider outage.
2. If occupancy is full, excess executions stay queued without a job. That
   is expected. See [queues.md](queues.md).
3. If writes timed out after bytes may have been sent, the run pauses
   uncertain. Do not retry those from the queue. See
   [uncertain_effects.md](uncertain_effects.md).

### Stop conditions

- Stop if you are about to requeue a job that already opened a step attempt.
- Stop manual retries during a sustained Pumble 5xx incident. Provider recovery
  is outside this application.

## Stuck queues

See [queues.md](queues.md). First response: `/settings/operations`, then
owner **Run reconciliation** on `/audit` (`#audit-reconcile`). Occupancy-parked
queued rows are not missing jobs.

## Schedule lag

### Symptom

**Due schedule lag** on `/settings/operations` is degraded (≥ 5 minutes) or
unhealthy (≥ 6 hours). Metric `[:pumble_automation, :schedule, :lag]`.

### Checks

1. Confirm Oban is available on `/health/ready`.
2. Confirm maintenance is not paused:

<!-- command-status: proven-local -->
```elixir
PumbleAutomation.Maintenance.paused?(:reconcile)
```

3. Open the due workflow from the operations sample link.

### Safe action

1. Resume maintenance if it was paused.
2. Run one reconcile tick:

<!-- command-status: proven-local -->
```elixir
PumbleAutomation.Maintenance.run_once(:reconcile)
```

3. The dispatcher cron is every minute. Do not insert schedule rows in SQL.

### Stop conditions

- Stop if you are about to change `next_run_at` in SQL.
- Stop new manual repair attempts if lag stays above 6 hours after Oban is
  healthy. Preserve diagnostics and investigate the dispatcher path.

## Stale attempts

### Symptom

**Stale attempts** ≥ 1. An attempt stayed `started` for more than 30 minutes
on a `running` execution.

### Checks

1. Open the sample execution from `/settings/operations`.
2. Confirm whether an effect may already have been sent (Pumble/HTTP write).

### Safe action

1. Owner **Run reconciliation** on `/audit`. Reconciliation retries only
   when the attempt is safe to repeat. Ambiguous writes pause uncertain.
2. Resolve uncertain rows on `/executions/:id`. Never in SQL.

### Stop conditions

- Stop if you are about to delete the attempt row.
- Stop repeated reconciliation if the stale count does not fall and the node is
  otherwise ready. Inspect the affected execution before any further action.

## Uncertain effects

See [uncertain_effects.md](uncertain_effects.md). First response: owner opens
`/executions/:id` and uses **Mark succeeded**, **Mark failed**, or **Retry
with duplicate risk**.

## Uninstall

See [oauth_revocation.md](oauth_revocation.md). Credentials become unusable
immediately. Do not dispatch new effects. Owner **Delete workspace data** on
`/audit` starts the 30-day grace, then purge.

## Secret-key rotation

See [oauth_revocation.md](oauth_revocation.md). First response: rotate one
kind of key at a time, keep the previous encryption key as a legacy read key,
and never print the new value.

## Migration failure

### Symptom

New instance stays unready. `/health/ready` `checks.migrations` is `error`.
The previous instance should still serve.

### Checks

1. Confirm the previous instance `/health/ready` is still 200.
2. Read migration status locally:

<!-- command-status: proven-local -->
```bash
MIX_ENV=test mix ecto.migrations
```

### Safe action

1. Leave the old instance in rotation.
2. Follow [rollback.md](rollback.md). Do not `mix ecto.rollback` in
   production.
3. After a failed expand migration in development, repair with a new
   migration or a test-database replay. Never edit an applied migration
   file.

### Stop conditions

- Stop if you are about to drop a column the previous release still reads.
- Stop before a production schema repair. Production migration and rollback are
  not verified by this repository.

## Rollback

See [rollback.md](rollback.md). First response: keep the previous image
serving. Do not schema-downgrade.

## Unverified production actions

Any platform deploy, production migration, production restore, production
image rollback, or production encryption-key change is **planned but not
executed or verified**. Local Mix and IEx commands above are proven in this
repository.
