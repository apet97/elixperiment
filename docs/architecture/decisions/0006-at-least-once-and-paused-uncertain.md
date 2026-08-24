# ADR-0006: At-least-once delivery and `PAUSED_UNCERTAIN`

**Status:** Accepted
**Plan decision:** ADR-009 in plan Section 7

## Context

Pumble can deliver a callback more than once. Oban can run a job more than once.
A remote HTTP write can leave bytes without returning a definitive response. The
system must state honest semantics instead of claiming exactly-once behavior.

## Evidence

- Plan Section 7, row ADR-009: "At-least-once plus uncertainty — honest semantics
  for duplicate delivery and ambiguous writes".
- Plan Section 6: "exactly-once claims" is an explicit non-goal.
- Plan Section 18.1: guaranteed — one stored received-event row per accepted dedupe
  key; one logical execution per execution key; one logical step row per
  execution/node; stale jobs do not advance state; completed steps are not executed
  again by duplicate jobs.
- Plan Section 18.2: not guaranteed — one callback delivery, one job attempt, or one
  remote effect when the remote API lacks idempotency and the outcome is ambiguous.
- Plan Section 18.3: effect key `installation_id / execution_id / node_id`.
- Plan Section 18.4: a write is uncertain when dispatch began, no definitive
  response was obtained, and remote idempotency cannot prove safe retry.
- Plan Section 19: `RUNNING -> PAUSED_UNCERTAIN`; `PAUSED_UNCERTAIN -> RUNNING |
  FAILED | COMPLETED`.
- Plan Section 30: error classes `ambiguous_transport` and `side_effect_uncertain`.

## Decision

Delivery is at-least-once. Deduplication and the claim-execute-finalize sequence
give effect-level idempotence for completed steps, not exactly-once delivery.

An ambiguous non-idempotent write does not retry automatically. The execution moves
to `PAUSED_UNCERTAIN` and stores the effect key, attempt, request summary, error
class, timing, whether bytes may have left, any remote correlation ID, and operator
guidance. An operator resolves it, which moves the execution to `RUNNING`, `FAILED`,
or `COMPLETED`.

No document, UI text, or API response claims exactly-once behavior.

## Alternatives

- Automatic retry on every ambiguous write. Rejected: it can duplicate a real
  external effect that the user cannot undo.
- Automatic failure on every ambiguous write. Rejected: it discards work that may
  have succeeded and hides the ambiguity from the operator.

## Consequences

- Every effectful step needs a stable effect key and a durable attempt record.
- The UI and the runbooks need an operator resolution path.
- Uncertain executions accumulate until an operator acts, so they need visibility
  and a lifetime bound (plan Section 31).

## Reversal condition

Reconsider a specific action only when the remote API supports a proven idempotency
key, which allows safe automatic retry for that action.
