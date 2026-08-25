# ADR-0009: Tenant-scoped application boundary

**Status:** Accepted

## Context

One deployment serves many Pumble workspaces from one database. Cross-workspace
data access is the highest-impact failure in the threat model.

## Evidence

- `%PumbleAutomation.Scope{installation_id, member_id, role}` is the trusted
  browser-context boundary; tenant queries use compound installation and record IDs.
- Callback classifiers, webhook token lookup, jobs, approval decisions, and audit
  records derive or re-verify installation identity instead of accepting a workspace
  override from an untrusted caller.
- `docs/security/threat_model.md` identifies cross-workspace access as a critical
  threat, and the adversarial tenant suites test each boundary.
- Hidden fields and route prefixes are never authorization.

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
