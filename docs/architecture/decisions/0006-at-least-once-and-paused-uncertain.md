# ADR-0006: At-least-once delivery and `PAUSED_UNCERTAIN`

**Status:** Accepted

## Context

Pumble can deliver a callback more than once. Oban can run a job more than once.
A remote HTTP write can leave bytes without returning a definitive response. The
system must state honest semantics instead of claiming exactly-once behavior.

## Evidence

- `docs/architecture/delivery_semantics.md` defines receipt deduplication and the
  explicit at-least-once boundary.
- `PumbleAutomation.Executions.StateMachine`, `Attempt`, and `Effect` enforce
  generation-aware claim, execute, and finalize behavior with stable effect keys.
- `docs/operations/uncertain_effects.md` defines operator recovery for ambiguous
  writes; crash-window and race tests prove that completed effects are not silently
  repeated.
- Error classes distinguish `ambiguous_transport` and `side_effect_uncertain`.

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
  and a configured lifetime bound.

## Reversal condition

Reconsider a specific action only when the remote API supports a proven idempotency
key, which allows safe automatic retry for that action.
