# Metrics

Operational metrics answer whether ingress, execution, queues, and limits are
healthy. They are not a second copy of the log stream. Identifiers that belong
on a log line stay off the metric series.

There is no vendor metrics SDK. Reporters consume Phoenix, Ecto, Oban, and
domain events through `Telemetry.Metrics` (`PumbleAutomationWeb.Telemetry` and
`PumbleAutomation.Telemetry`). LiveDashboard in development reads the same
specs.

## Cardinality

Allowed labels are a closed set: `operation`, `type`, `status`, `error_class`,
and a few equally bounded companions (`class`, `outcome`, `source`, `kind`,
`queue`, `check`, `from`, `status_class`, `event_type`).

Never label a series by workflow, execution, user, installation, job, attempt,
correlation, or workspace id. Those values may appear on the raw telemetry
event so logs can correlate a run. The metric adapter drops them.

HTTP status codes are bucketed as `status_class`: `2xx`, `4xx`, `5xx`, `ok`,
or `error`.

Metrics contain no tokens, bodies, signatures, or message text.

## Units

| Kind | Unit | Why |
|---|---|---|
| Callback, Pumble client, HTTP action, Oban job, Phoenix, Ecto | native time, converted to milliseconds by `Telemetry.Metrics` | `System.monotonic_time/0` spans |
| Step, execution, approval | `duration_ms` (integer milliseconds) | wall-clock from stored timestamps |
| Queue age, schedule lag | `age_ms` / `lag_ms` (integer milliseconds) | `DateTime.diff/3` |

Event names and measurements are stable. Adding a vendor reporter must not
rename them.

## Section 32

| Metric | Event | Measurement | Tags | Meaning | Alert candidate |
|---|---|---|---|---|---|
| callback count/latency/status | `[:pumble_automation, :pumble, :callback, :stop]` | `duration` | class, outcome, status_class | One verified callback handled | p95 ≥ 1500ms (internal budget); 5xx outcome |
| signature failures | `[:pumble_automation, :pumble, :callback, :verify]` | `count` | status | Plug verified, refused, or rate-limited | `unauthorized` or `rate_limited` rising |
| dedupe hits | `[:pumble_automation, :ingress, :dedup, :record]` | `count` | outcome, class | First receipt versus duplicate key | duplicate ratio collapse (ingress broken) |
| execution counts by state | `[:pumble_automation, :executions, :transition]` | `count` | from, status, operation | Create and finalize state changes | `paused_uncertain` or `failed` spike |
| step latency by type | `[:pumble_automation, :executions, :step, :stop]` | `duration_ms` | type, status, kind, error_class | One attempt's duration | p95 by node type |
| retries | `[:pumble_automation, :executions, :retry]` | `count` | type, error_class | Engine-owned retryable finalize | sustained retry without recovery |
| uncertain outcomes | `[:pumble_automation, :executions, :uncertain]` | `count` | type, error_class | Ambiguous write pause | any sustained non-zero |
| Pumble API status/latency | `[:pumble_automation, :pumble, :client, :stop]` | `duration` | operation, status_class, error_class | One Pumble HTTP call | 5xx / timeout class |
| external HTTP status/latency | `[:pumble_automation, :executions, :http_action]` | `duration` | operation, status, error_class | HTTP action node | uncertain or 5xx class |
| queue depth and age | `[:pumble_automation, :oban, :queue]` | `depth`, `age_ms` | queue | Incomplete Oban jobs, polled | depth or age rising on `executions` |
| schedule lag | `[:pumble_automation, :schedule, :lag]` | `lag_ms` | operation | Oldest due enabled clock | lag ≫ 60s |
| expired approvals | `[:pumble_automation, :executions, :approval, :stop]` | `duration_ms` | status, type | Decision or timeout; `timed_out` is expiry | timeout rate vs decisions |
| per-workspace limit rejections | `[:pumble_automation, :limits, :hit]` | `count` | source | Limit or rate-limit refusal (not per-tenant series) | any source saturating |

Schedule dispatch also emits `[:pumble_automation, :schedule, :dispatch]` with
`lag_ms` per enqueued occurrence. Retention sweeps/purges emit counts of
deleted rows. Reconciliation emits `[:pumble_automation, :executions, :reconcile]`.
Trigger match count is `[:pumble_automation, :ingress, :matcher, :match]`.

Health probes already emit `[:pumble_automation, :health, :check]`. Public
`/health/live` and `/health/ready` stay minimal (`ok`/`error` only). Owner
diagnostics live at `/settings/operations` (`PumbleAutomation.Operations.Health`).
Maintenance ticks emit `[:pumble_automation, :maintenance, :run]` (`kind`,
`status`) and unsafe integrity findings emit
`[:pumble_automation, :maintenance, :alert]`. Discarded maintenance jobs appear
in the owner `discarded_jobs` check; uniqueness does not include discarded
rows, so the next cron tick still inserts. Diagnostic ZIP export is P14-T06.

## Alert candidates (operators)

- Callback p95 at or above 1500ms, or 5xx outcomes
- Signature `unauthorized` or `rate_limited` without a matching traffic drop
- Uncertain-effect count not returning to zero
- `executions` queue age growing while depth stays high
- Due-schedule lag beyond one dispatcher minute
- Limit hits on `callback_failures` or occupancy-related sources
- Database ping ≥ 200ms (alert) or ≥ 2000ms / unreachable (readiness)
- Oldest available job ≥ 15 minutes (alert). Six hours means stuck work, not a
  one-job blip; public `/health/ready` still fails only when the database,
  schema, or Oban supervisor cannot accept durable work
- Any discarded (exhausted) job
- Any stale attempt (started > 30 minutes) or missing advance job that is not
  occupancy-parked
- Retention sweep lag ≥ 26 hours once maintenance is scheduled

A telemetry handler failure is logged by the telemetry library and ignored.
It must not fail a callback, job, or finalize.
