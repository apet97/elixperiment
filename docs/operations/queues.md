# Queues and schedules

Audience: internal operators. Do not copy this file into public support
articles.

Related:

- [Incidents](incidents.md)
- [Maintenance](maintenance.md)
- [Uncertain effects](uncertain_effects.md)
- [Metrics](metrics.md)

## Result

Durable work lives in PostgreSQL and Oban. Occupancy is five running or
waiting executions per workspace. Extra executions stay `queued` without an
Oban job until a slot opens. Those parked rows are **not** missing jobs.

## Symptom

Oldest available job is older than 15 minutes, discarded jobs exist, due
schedules lag, stale attempts exist, or "missing jobs" is non-zero on
`/settings/operations`.

## Checks

1. Sign in as an owner. Open `/settings/operations` (`#operations-health`).
2. Read overall diagnostics and **Durable work ready**. Public `/health/ready`
   can still be 200 while this page is degraded.
3. Read each check: database latency, migration version, Oban availability,
   oldest available job, discarded jobs, due schedule lag, stale attempts,
   missing jobs, cleanup lag.
4. Use **Affected work** links. They are tenant-scoped. Job arguments are
   not shown.
5. Confirm occupancy before you treat a queued row as lost. If five
   executions already occupy slots, queued rows without jobs are parked on
   purpose.

Read-only count of incomplete Oban jobs (no args, no tokens):

<!-- command-status: proven-local -->
```elixir
import Ecto.Query
alias PumbleAutomation.Repo
Repo.aggregate(from(j in Oban.Job, where: j.state in ^["available", "scheduled", "executing", "retryable"]), :count)
```

Owner snapshot:

<!-- command-status: proven-local -->
```elixir
{:ok, report} = PumbleAutomation.Operations.Health.diagnostics(scope)
report.status
report.ready?
Enum.map(report.checks, &{&1.name, &1.status, &1.value})
```

`scope` is the signed-in owner's `PumbleAutomation.Scope`. Do not print it
in a ticket if it includes identifiers you do not need.

## Safe action

### Missing jobs that are not occupancy-parked

Owner UI: `/audit`, button **Run reconciliation** (`#audit-reconcile`).

Same command in IEx as that owner:

<!-- command-status: proven-local -->
```elixir
PumbleAutomation.Operations.run_reconciliation(scope)
```

System tick (all tenants, bounded):

<!-- command-status: proven-local -->
```elixir
PumbleAutomation.Maintenance.run_once(:reconcile)
```

`Engine.reconcile/1` inserts missing advance, delay, and approval-timeout
jobs. Duplicate reconcile is a no-op once gaps are gone. Uninstall cancels
leftover in-flight work instead of resuming it.

### Discarded (exhausted) jobs

Owner UI: `/audit`, form **Discarded job id**, button **Requeue safe job**
(`#audit-requeue`).

<!-- command-status: proven-local -->
```elixir
PumbleAutomation.Operations.requeue_safe_job(scope, job_id)
```

Safe means: the job names this tenant, the worker is an allowlisted repair
target, no step attempt was opened, and the job is discarded, cancelled, or
retryable. Anything else returns an instruction. Do not retry from SQL.

Unsafe-repair message from the product:

`This job cannot be retried automatically. Run reconciliation for missing work, or resolve a paused step. Do not repair jobs in SQL.`

### Pause or run one maintenance kind

<!-- command-status: proven-local -->
```elixir
PumbleAutomation.Maintenance.pause(:retention)
PumbleAutomation.Maintenance.resume(:retention)
PumbleAutomation.Maintenance.run_once(:reconcile)
PumbleAutomation.Maintenance.run_once(scope, :integrity)
```

Pause skips the scheduled worker. Run-once still runs. Tenant purge after
uninstall is never paused. Owner run-once is audited as `admin.maintenance_run`.

Kinds and cron (UTC) are in [maintenance.md](maintenance.md).

### Cancel stuck user work

Editors and owners: `/executions/:id`, **Cancel execution** (`#cancel-prompt`).
Owner cancel-all is `Engine.cancel_all/2` (no global UI button besides
per-execution cancel). Running cancel sets a durable request; finalize does
not start the next step.

## Stop / escalate

- Stop if you are about to `INSERT` into `oban_jobs` by hand.
- Stop if you are about to treat occupancy-parked queued rows as missing jobs.
- Stop if a discarded job already has a step attempt — resolve uncertainty
  or cancel; do not requeue.
- Escalate when oldest available work is older than 6 hours and ready is
  still 200: the node accepts work, but the backlog is stuck. That is an
  incident, not a load-balancer flap.
