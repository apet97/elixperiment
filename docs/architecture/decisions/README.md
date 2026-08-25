# Architecture decision records

This directory holds the architecture decision records (ADRs) for the Pumble
workflow-automation add-on.

The records explain why the current implementation is shaped as it is. Source,
tests, and exact-commit verification receipts remain authoritative. The records
contain technical rationale only.

When implementation changes invalidate a record, update the documentation and
the affected tests together. A later record may supersede an earlier one when
preserving the old rationale is useful.

## Allowed statuses

| Status | Meaning |
|---|---|
| `Proposed` | Describes an idea that is not the current implementation. |
| `Accepted` | Describes the current implementation. |
| `Superseded` | Retained for context but replaced by a named later record. |

`0001-record-template.md` is not a decision record. It carries the status
`Template` and is exempt from this table.

## Reading the records

- Numbers are sequential and never reused. `0001` is the template.
- Existing records can retain source notes that explain their rationale.
- Each record states when its decision should be reconsidered.
- An ADR is not evidence of implementation. Current implementation evidence is
  executable tests and the exact-commit verification receipt.

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
