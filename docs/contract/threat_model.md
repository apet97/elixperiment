# Threat model, data classification, and tenant isolation

This is the current threat-requirements model. It defines the required
mitigations, automated proof, data handling, and tenant-isolation rules.

A risk without a viable mitigation is release-blocking. Record it explicitly;
do not treat missing evidence as a waiver.

---

## 1. Threat table

Each row defines the enforcement boundary, mitigation, and required automated
proof.

| Threat | Boundary | Mitigation | Automated proof | Implementation area |
|---|---|---|---|---|
| Cross-workspace access | Context/query | Trusted scope and compound filters | Tenant adversarial tests | Tenant scope and authorization |
| OAuth CSRF | OAuth callback | One-time hashed state | Invalid/reused/expired state tests | Installation identity |
| Forged callback | Pumble ingress | Raw-body HMAC and constant-time compare | Valid/invalid fixture tests | Pumble callback boundary |
| Replay | Ingress | Durable dedupe key | Duplicate-delivery tests | Ingress deduplication |
| Token leak | Storage/logging | Authenticated encryption and redaction | Log capture and secret scan | Credentials and observability |
| SSRF | HTTP action | Resolve, reject, pin, revalidate redirects | IP-range and rebinding tests | Safe HTTP transport |
| Workflow bomb | Compiler/runtime | Node, depth, size, lifetime limits | Limit tests | Compiler and runtime limits |
| Recursion loop | Pumble events | Own-bot filter and lineage ceiling | Loop tests | Event matching and lineage |
| Job flood | Ingress/schedules | Workspace limits and rate controls | Quota tests | Ingress and execution limits |
| Approval spoof | Interaction | Actor policy and one-time token | Unauthorized/double-click tests | Durable approvals |
| Scope escalation | Pumble client | Explicit required-scope matrix | Activation/scope tests | Scope mapping and activation |
| Log leakage | Observability | Field allowlist and redaction | Captured-log tests | Privacy-safe observability |
| Stored content injection | LiveView | Escaped rendering and CSP | UI security tests | Web rendering |
| Admin abuse | Support tools | No unscoped access; audited operations | Authorization tests | Tenant-scoped operations |
| Dependency compromise | Build | Lockfile, audit, minimal deps | Hex audit and advisory checks | Dependency policy and release gate |

Every high-severity threat has an enforcement boundary and automated proof.

---

## 2. Data classification

The classes below define the current storage and handling rules.

| Data | Class | Storage and handling rule |
|---|---|---|
| Pumble credentials (installation tokens, signing secrets) | Secret | Authenticated encryption at rest. Never in logs, metrics, workflow JSON, execution history, job arguments, or ordinary errors. Server-side only. |
| User secrets and external HTTP connection credentials | Secret | Authenticated encryption at rest. Redacted in every rendering path. Isolated from URL and error rendering (see ADR-0010). |
| Workflow definitions and compiled versions | Tenant confidential | Normal database storage, tenant-scoped. Must contain no raw credential; secrets are referenced, not embedded. |
| Callback bodies and inbound webhook bodies | Tenant confidential | Size-limited, tenant-scoped, retained under the retention policy. Raw bytes are retained only as long as verification and dedupe need them. |
| Execution data, steps, attempts, sanitized values | Tenant confidential | Normal database storage, tenant-scoped. Values are sanitized before display. |
| Audit data | Tenant confidential, integrity-sensitive | Append-only, includes installation ID, tenant-scoped read access. |
| Logs and metrics | Operational | Structured field allowlist, redaction. No raw credential and no unnecessary message content. |

Invariants:

- no raw credential appears in logs, workflow JSON, execution history, metrics, or
  ordinary errors;
- tenant ID alone is never authorization;
- debug routes are absent in production.

---

## 3. Tenant isolation stance

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

- Resource limits: `PumbleAutomation.Limits` (nodes, depth, definition size,
  body sizes, redirects, retries, delay, execution lifetime, lineage depth).
- Loop prevention: `PumbleAutomation.Executions.Lineage` and
  `PumbleAutomation.Ingress.TriggerMatcher` (own-bot filter, lineage depth,
  dedupe, step and lifetime caps).
- Error taxonomy and retry matrix:
  [`delivery_semantics.md`](../architecture/delivery_semantics.md).
- Server-side request forgery (SSRF) algorithm and blocked headers: ADR-0010
  and [`http_action_review.md`](../security/http_action_review.md).
