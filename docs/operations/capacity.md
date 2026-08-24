# Local capacity proof

## Scope

`scripts/load-smoke.sh` is a bounded, local-only proof for the application's
obvious high-volume paths. It uses the test database and Phoenix endpoint. It
makes no call to Pumble or any other external service.

The proof gates deterministic behavior, query shape, and bounded work. It also
records elapsed local timings to help compare two runs on the same machine.
Those timings are **not production SLOs**, deployment evidence, or alert
thresholds. A passing run says nothing about a load balancer, production
database sizing, network latency, or Pumble's service behavior.

## Candidate binding

Every run records:

- `git_sha`: the checked-out commit;
- `worktree_dirty`: whether the tested tree differs from that commit; and
- `source_fingerprint_sha256`: a digest over the commit, tracked diffs, and
  untracked source/test/operations files relevant to this proof.

A clean run (`worktree_dirty=false`) binds directly to `git_sha`. A dirty run
is developer evidence only and is bound to the source fingerprint, not claimed
as proof of the commit by itself.

Run the proof from the repository root:

```bash
./scripts/load-smoke.sh
```

The default evidence log is `tmp/capacity-local.log`, which is ignored by Git.
Choose another local path with `CAPACITY_EVIDENCE_FILE`. Do not point it at a
published artifact location until the candidate is clean and the log has been
reviewed.

## Bounded workload

The fixtures deliberately stay within configured tenant limits while crossing
the scheduler's global batch boundary.

| Path | Local fixture | Deterministic gate |
|---|---:|---|
| Signed Pumble callback | 6 unique deliveries against 25 active bindings | 6 HTTP 200 acknowledgements, receipts, and executions; five advance jobs admitted and one execution parked by the tenant concurrency limit; one selective indexed match per delivery |
| Signed generic webhook | 6 unique exact-body HMAC deliveries | 6 HTTP 202 receipts and executions; five advance jobs admitted and one execution parked; all receipt IDs distinct |
| Workflow index | 60 rows in the subject tenant plus 12 in another tenant | Three 20-row pages, 60 distinct tenant rows, exactly two queries per page, bounded SQL shape, no draft document in results |
| Execution history | `history_page_max + 5` rows plus 12 in another tenant | First page clamps to the configured maximum, cursor returns the final five, one query per page, no context or trigger document in results |
| Scheduler | 75 due clocks across three tenants, 25 per tenant | The first production worker run dispatches the 50-row batch and returns `{:snooze, 1}`; the next run dispatches the final 25 without waiting for another cron minute; all tenants finish with 25 runs; 15 jobs are admitted and 60 executions remain durably parked under the five-slot tenant cap |

The callback binding count equals the default per-tenant active-workflow limit.
The scheduler uses three tenants at the default limit of 25 active workflows.
The global due set is 75 clocks, which crosses the 50-clock worker batch. The
default queued-execution limit is 1,000, so all 75 executions are accepted.

## Query and queue assertions

The tests use PostgreSQL `EXPLAIN ANALYZE` with sequential scans disabled for
small fixtures, matching the repository's other index proofs. They assert:

- trigger candidates use index access and do not sequentially scan
  `trigger_bindings` or `workflows`;
- workflow tenant scans use index access, and emitted list SQL contains the
  tenant predicate, ordering, limit, and offset;
- history SQL contains the tenant predicate, ordering, and limit, and its plan
  uses the order-preserving `executions_installation_history_cursor_index`
  created by `20260823230831_add_executions_history_cursor_index.exs`, rather
  than sorting the whole tenant;
- due schedules use the due index;
- the production path locks installation, workflow, and schedule in that
  order;
- candidate installation and schedule claims use `SKIP LOCKED`, and
  deterministic two-connection tests prove that another tenant dispatches
  while an installation or schedule row is locked;
- the schedule lock query contains `LIMIT` and `FOR UPDATE SKIP LOCKED`;
- workflow pages stay at two queries and history pages at one, independent of
  the number of rows rendered; and
- one scheduler claim stays within a conservative structural ceiling of 30
  repository queries. This is a runaway-query guard, not a latency target.

Plans are represented in the evidence log by booleans and a short SHA-256
digest. The log does not reproduce tenant IDs, request bodies, credentials, or
raw query parameters.

## Timing evidence

Passing tests print `CAPACITY_METRIC` lines containing the item count, total
microseconds, and average microseconds for the local batch. The scheduler line
also records the first-run and continuation query counts, the continuation
count, and per-tenant semantic counts.

Compare timings only when the commit/fingerprint, database state, runtime,
hardware, and test command are comparable. A slower observation is a prompt to
investigate; it is not by itself a release failure. Release failure is driven
by the semantic and query-shape assertions above.

The evidence log is the authoritative per-run timing record. Keeping volatile
machine timings in that candidate-bound artifact, rather than presenting one
developer laptop's numbers as a permanent target here, preserves their status
as environment-specific observations.

## What this does not prove

This local smoke does not prove:

- staging or production deployment capacity;
- multi-node rate-limit or scheduler behavior;
- real Pumble callback delivery latency or retry behavior;
- database pool saturation under deployment-sized concurrency;
- queue latency while production workers execute external actions; or
- infrastructure, autoscaling, backup, failover, or marketplace readiness.

Those claims require environment-bound evidence under separately authorized
deployment or live-test work. Do not turn the local observations into a
production SLO, and do not use this script to call the sacrificial or a
production Pumble workspace.
