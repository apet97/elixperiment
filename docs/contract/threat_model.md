# Threat model, data classification, and tenant isolation

This is the current threat-requirements model. It was derived from Sections 27
and 28 of the [historical implementation plan](../archive/planning/implementation-plan.md),
with phase attribution from Section 41.1. It adds no implicit waiver.

A risk without a viable mitigation is release-blocking. It is recorded, not waived
implicitly. A change to this document requires a new ADR.

---

## 1. Threat table (plan Section 27)

The threat, boundary, mitigation, and automated proof columns are taken from plan
Section 27. The closing phase is taken from the phase gate scopes in plan
Section 41.1.

| Threat | Boundary | Mitigation | Automated proof | Closing phase |
|---|---|---|---|---|
| Cross-workspace access | Context/query | Trusted scope and compound filters | Tenant adversarial tests | P13 (tenant matrix), first enforced in P5 |
| OAuth CSRF | OAuth callback | One-time hashed state | Invalid/reused/expired state tests | P3 (identity) |
| Forged callback | Pumble ingress | Raw-body HMAC and constant-time compare | Valid/invalid fixture tests | P4 (Pumble boundary) |
| Replay | Ingress | Durable dedupe key | Duplicate-delivery tests | P8 (ingress) |
| Token leak | Storage/logging | Authenticated encryption and redaction | Log capture and secret scan | P3 (encrypted credentials), rechecked in P13 |
| SSRF | HTTP action | Resolve, reject, pin, revalidate redirects | IP-range and rebinding tests | P10 (safe HTTP) |
| Workflow bomb | Compiler/runtime | Node, depth, size, lifetime limits | Limit tests | P6 (compiler), limits closed in P13 |
| Recursion loop | Pumble events | Own-bot filter and lineage ceiling | Loop tests | P13 (loop protection) |
| Job flood | Ingress/schedules | Workspace limits and rate controls | Quota tests | P13 (limits), first enforced in P8 |
| Approval spoof | Interaction | Actor policy and one-time token | Unauthorized/double-click tests | P11 (durable waits, approval) |
| Scope escalation | Pumble client | Explicit required-scope matrix | Activation/scope tests | P4 (scope maps), activation checks in P6 |
| Log leakage | Observability | Field allowlist and redaction | Captured-log tests | P14 (privacy-safe observability) |
| Stored content injection | LiveView | Escaped rendering and CSP | UI security tests | P12 (UI), web security in P13 |
| Admin abuse | Support tools | No unscoped access; audited operations | Authorization tests | P13 (audit and threat closure) |
| Dependency compromise | Build | Lockfile, audit, minimal deps | Hex audit and review | P1 (dependency policy), audit gate in P15 |

Every high-severity threat has an owner boundary and an automated proof. No threat
in this table is closed by manual review alone.

---

## 2. Data classification

Plan Section 27 does not contain a classification table. The classes below are
derived from plan task P1-T04 and from the token-leak mitigation in Section 27. The
full classification, including per-field storage decisions, closes in P1-T04.

| Data | Class | Storage and handling rule |
|---|---|---|
| Pumble credentials (installation tokens, signing secrets) | Secret | Authenticated encryption at rest. Never in logs, metrics, workflow JSON, execution history, job arguments, or ordinary errors. Server-side only. |
| User secrets and external HTTP connection credentials | Secret | Authenticated encryption at rest. Redacted in every rendering path. Isolated from URL and error rendering (see ADR-0010). |
| Workflow definitions and compiled versions | Tenant confidential | Normal database storage, tenant-scoped. Must contain no raw credential; secrets are referenced, not embedded. |
| Callback bodies and inbound webhook bodies | Tenant confidential | Size-limited, tenant-scoped, retained under the retention policy. Raw bytes are retained only as long as verification and dedupe need them. |
| Execution data, steps, attempts, sanitized values | Tenant confidential | Normal database storage, tenant-scoped. Values are sanitized before display. |
| Audit data | Tenant confidential, integrity-sensitive | Append-only, includes installation ID, tenant-scoped read access. |
| Logs and metrics | Operational | Structured field allowlist, redaction. No raw credential and no unnecessary message content. |

Invariants, from plan task P1-T04:

- no raw credential appears in logs, workflow JSON, execution history, metrics, or
  ordinary errors;
- tenant ID alone is never authorization;
- debug routes are absent in production.

---

## 3. Tenant isolation stance (plan Section 28)

The scope struct is `%PumbleAutomation.Scope{installation_id, member_id, role}`.

Rules:

- every browser context function receives a scope;
- every tenant query filters installation ID;
- tenant objects are fetched by `(installation_id, id)`;
- jobs carry installation ID and verify it against the loaded record;
- callbacks derive the installation from the verified payload or workspace mapping;
- webhook token lookup resolves one installation and never accepts a
  caller-supplied workspace override;
- the approval callback verifies installation, approval, actor, and token together;
- audit events include installation;
- support tooling is tenant-scoped and audited.

Hidden fields and route prefixes are never authorization.

See ADR-0009 for the decision record.

---

## 4. Related limits and controls

- Resource limits: plan Section 31 (nodes, depth, definition size, body sizes,
  redirects, retries, delay, execution lifetime, lineage depth).
- Loop prevention: plan Section 29 (own-bot filter, bot-token actions, lineage depth
  ceiling of three, dedupe, step and lifetime caps).
- Error taxonomy and retry matrix: plan Section 30.
- SSRF algorithm and blocked headers: plan Section 26.
