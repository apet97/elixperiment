# ADR-0005: PostgreSQL and Oban durable execution

**Status:** Accepted

## Context

Executions can wait for days, can span restarts, and must survive process, node,
and deployment loss. Progress must not depend on in-memory process state.

## Evidence

- The Ecto schemas and migrations store installations, workflow versions,
  executions, attempts, approvals, and audit records in PostgreSQL.
- Ingress and execution services use `Ecto.Multi` to commit state and Oban job
  insertion together.
- `config/config.exs` defines the initial `ingress`, `executions`, `schedules`,
  and `maintenance` queue limits.
- Execution state transitions use row locks, generation checks, and optimistic
  lock versions; the crash-window tests exercise replay and stale jobs.

## Decision

PostgreSQL holds the durable truth for installations, workflows, versions,
executions, steps, attempts, and audit records. Oban runs asynchronous progression
using the same PostgreSQL database.

Job insertion happens in the same transaction as the state change that the job
serves. A GenServer, an ETS table, or a process mailbox is never the record of
progress.

## Alternatives

- Redis, Kafka, RabbitMQ, or Temporal for queueing. Rejected because they split
  the transaction boundary across two systems without a demonstrated need.
- In-process supervised state for waiting executions. Rejected: a deployment or a
  crash would lose a wait that may last days.

## Consequences

- One database is the single operational dependency, so backup and restore cover
  both state and queue (`docs/operations/backup_restore.md`).
- A duplicated or late job must be a no-op, which ADR-0006 governs.
- Queue concurrency values are configuration and can be tuned without an ADR.
- Database availability limits application availability.

## Reversal condition

Reconsider if measured job throughput or queue latency cannot be met by PostgreSQL
and Oban at the target load after tuning, with the measurement recorded.
