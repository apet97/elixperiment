# ADR-0009: Tenant-scoped application boundary

**Status:** Accepted
**Plan source:** Section 28, with Section 9.2 and the cross-workspace row of
Section 27. This decision has no separate row in the Section 7 log.

## Context

One deployment serves many Pumble workspaces from one database. Cross-workspace
data access is the highest-impact failure in the threat model.

## Evidence

- Plan Section 28: use `%PumbleAutomation.Scope{installation_id, member_id, role}`;
  every browser context function receives a scope; every tenant query filters
  installation ID; tenant objects are fetched by `(installation_id, id)`; jobs carry
  installation ID and verify it against the loaded record; callbacks derive the
  installation from the verified payload or workspace mapping; webhook token lookup
  resolves one installation and never accepts a caller-supplied workspace override;
  the approval callback verifies installation, approval, actor, and token together;
  audit events include installation; support tooling is tenant-scoped and audited.
- Plan Section 28: hidden fields and route prefixes are never authorization.
- Plan Section 27, cross-workspace access row: boundary is context/query, the
  mitigation is trusted scope and compound filters, and the proof is tenant
  adversarial tests.
- Plan Section 9.2: allowed domain dependencies and forbidden edges, including
  LiveViews bypassing authorization contexts.
- Plan phase gate P13 (Section 41.1): tenant matrix and threat closure pass.

## Decision

Tenant scope is a first-class argument, not ambient state. Every context function
that serves a browser request receives a `Scope` struct. Every tenant-table query
filters on installation ID, and every tenant record load uses the compound key
`(installation_id, id)`.

A tenant identifier that comes from the caller is never authorization by itself. The
installation is derived from a verified source: a verified callback payload, a
resolved webhook token, or the authenticated browser session.

## Alternatives

- A process-dictionary or connection-assigned implicit tenant. Rejected: an implicit
  value is easy to lose in a job, a task, or a LiveView event.
- A database schema or database per workspace. Rejected: it conflicts with the
  single-database model of ADR-0005 and adds migration cost per tenant.

## Consequences

- Function signatures across contexts carry `Scope`, which is verbose by design.
- Oban job arguments carry installation ID, and the worker re-verifies it against
  the loaded record.
- Adversarial tenant tests are required proof, not optional.
- Support and admin tooling gets no unscoped access path.

## Reversal condition

Reconsider only if a legal or contractual requirement forces physical data
separation per tenant.
