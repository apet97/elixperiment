# Architecture decision records

This directory holds the architecture decision records (ADRs) for the Pumble
workflow-automation add-on.

Accepted ADRs in this directory describe the current architecture decisions.
The initial records were derived from Section 7 of the
[historical implementation plan](../../archive/planning/implementation-plan.md).
The archived plan preserves rationale but is not current product status.

## When an ADR is required

Write a new ADR when any of these is true:

- an accepted architecture decision must change;
- a new architecture decision is needed;
- a direct runtime dependency is added, replaced, or removed (see
  `docs/contract/dependency_policy.md`);
- the frozen product contract changes (see `docs/contract/product_contract.md`);
- a security boundary, tenant-isolation rule, or delivery-semantics claim changes;
- a proposed Pumble manifest entry point changes.

Do not change an existing accepted ADR to record a new decision. Add a new ADR and
mark the old one `Superseded`.

An implementation-driven architecture change must include evidence and update
the affected acceptance tests.

## Allowed statuses

| Status | Meaning |
|---|---|
| `Proposed` | Written, not yet approved. Not binding. |
| `Accepted` | Approved and binding on implementation. |
| `Superseded` | Replaced by a later ADR. The replacing ADR number is named in the record. |

A record never moves back from `Superseded` to `Accepted`. Write a new record instead.

`0001-record-template.md` is not a decision record. It carries the status
`Template` and is exempt from this table.

## Rules

- Records are append-only. Correct a mistake with a new record, not by deleting history.
- Numbers are sequential and never reused. `0001` is the template.
- Existing records retain their historical plan citations as rationale.
- Every record states a reversal condition.
- An ADR is not evidence of implementation. Current implementation evidence is
  executable tests and the exact-commit verification receipt. The
  [implementation ledger](../../archive/implementation-ledger.md) is historical.

## Files

| File | Subject |
|---|---|
| `0001-record-template.md` | Template. Copy it to start a new record. |
| `0002-modular-monolith.md` | Modular monolith |
| `0003-production-http-callbacks.md` | HTTP callbacks in production |
| `0004-structured-ast-immutable-graph.md` | Structured AST compiled to an immutable graph |
| `0005-postgresql-oban-durable-execution.md` | PostgreSQL and Oban durable execution |
| `0006-at-least-once-and-paused-uncertain.md` | At-least-once delivery and `PAUSED_UNCERTAIN` |
| `0007-fixed-pumble-entry-points.md` | Fixed Pumble command and shortcuts |
| `0008-liveview-outline-editor.md` | LiveView outline editor |
| `0009-tenant-scoped-application-boundary.md` | Tenant-scoped application boundary |
| `0010-dns-pinned-safe-http.md` | DNS-pinned safe HTTP |
| `0011-tzdata-schedule-math.md` | tzdata for schedule timezone math |
