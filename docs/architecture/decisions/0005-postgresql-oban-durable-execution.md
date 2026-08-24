# ADR-0005: PostgreSQL and Oban durable execution

**Status:** Accepted
**Plan decisions:** ADR-003 and ADR-004 in plan Section 7

## Context

Executions can wait for days, can span restarts, and must survive process, node,
and deployment loss. Progress must not depend on in-memory process state.

## Evidence

- Plan Section 7, row ADR-003: "PostgreSQL is durable truth — survives process,
  node, and deployment loss".
- Plan Section 7, row ADR-004: "Oban for asynchronous progression — durable jobs in
  the same database; transactional insertion".
- Plan Section 9: Ingress persists, looks up active triggers, creates executions,
  and inserts Oban jobs inside one `Ecto.Multi`.
- Plan Section 9.1: initial queues `ingress` 20, `executions` 20, `schedules` 2,
  `maintenance` 2 — starting limits, not permanent scaling values.
- Plan Section 19: execution state changes use row locks and optimistic lock
  versions.
- Plan Section 20: Oban and transaction model.
- Plan Section 31: delay up to 365 days; execution lifetime up to 30 days.

## Decision

PostgreSQL holds the durable truth for installations, workflows, versions,
executions, steps, attempts, and audit records. Oban runs asynchronous progression
using the same PostgreSQL database.

Job insertion happens in the same transaction as the state change that the job
serves. A GenServer, an ETS table, or a process mailbox is never the record of
progress.

## Alternatives

- Redis, Kafka, RabbitMQ, or Temporal for queueing. Rejected in plan Section 6 as
  non-goals; they split the transaction boundary across two systems.
- In-process supervised state for waiting executions. Rejected: a deployment or a
  crash would lose a wait that may last days.

## Consequences

- One database is the single operational dependency, so backup and restore cover
  both state and queue (plan Section 36).
- A duplicated or late job must be a no-op, which ADR-0006 governs.
- Queue concurrency values are configuration and can be tuned without an ADR.
- Database availability limits application availability.

## Reversal condition

Reconsider if measured job throughput or queue latency cannot be met by PostgreSQL
and Oban at the target load after tuning, with the measurement recorded.
