# Maintenance scheduling

Reconciliation, retention, OAuth/session cleanup, and integrity run on Oban
cron. Operators do not have to remember to invoke them. Pause and run-once
live on `PumbleAutomation.Maintenance`.

## Jobs

| Kind | Worker | Cron (UTC) | Unique | Budget |
|---|---|---|---|---|
| reconcile | `ReconciliationWorker` | `*/5 * * * *` | one incomplete worker | 10s / 100 repairs |
| cleanup | `CleanupWorker` `kind=cleanup` | `17 * * * *` | one incomplete per kind | 10s / 500 rows |
| integrity | `CleanupWorker` `kind=integrity` | `47 * * * *` | one incomplete per kind | 10s / 50 rows |
| retention sweep | `RetentionWorker` (no installation id) | `23 3 * * *` | one incomplete sweep | 10s / 20×500 rows |
| tenant purge | `RetentionWorker` (installation id) | event-driven | one incomplete per tenant | existing purge batches |

An empty tick is typically well under one second. A full batch snoozes one
second and continues from remaining due rows. A discarded job does not block
the next cron insert.

## Commands

```elixir
PumbleAutomation.Maintenance.pause(:retention)
PumbleAutomation.Maintenance.resume(:retention)
PumbleAutomation.Maintenance.run_once(:reconcile)
PumbleAutomation.Maintenance.run_once(scope, :integrity)
```

Pause skips the scheduled worker. Run-once sets `force` and still runs. Owner
run-once is audited as `admin.maintenance_run`. Job args are kind, optional
tenant id, batch size, and cursor only.

Tenant purge after uninstall is never paused.

## Safe repair vs alert

Integrity repairs: stale enabled bindings/schedules for a non-live version,
missing wait/timeout/advance jobs via `Engine.reconcile/1`, and due uninstalled
purges. It alerts (does not rewrite versions) for live workflows whose
`referenced_secret_ids` name a missing secret. Occupancy-parked queued rows
are not missing jobs.

Exhausted jobs surface as discarded rows on the owner operations page.
