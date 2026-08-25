# Implemented threat-model closure

This file maps the current requirements in
[`docs/contract/threat_model.md`](../contract/threat_model.md) to source and
offline regression tests. A passing test proves the named local boundary for
the exact tested commit; it is not live-provider or deployment proof.

| Threat | Boundary | Mitigation | Implementation | Offline proof | Residual risk |
| --- | --- | --- | --- | --- | --- |
| Cross-workspace access | Context and query | Trusted `Scope`; compound tenant/resource lookups; foreign identifiers return not found | `PumbleAutomation.Scope`; installation policies | `test/security/tenant_isolation_test.exs`; `test/security/release_gate_test.exs` | Queue parking does not bypass tenant scoping. |
| OAuth CSRF | OAuth callback | Hashed one-time state, atomic consumption, expiry, and local return paths | `PumbleAutomation.Installations.OauthStates` | `test/pumble_automation/installations/oauth_state_test.exs`; `test/security/web_security_test.exs`; `test/security/release_gate_test.exs` | Provider consent and token exchange still require live proof. |
| Forged callback | Pumble ingress | Raw-body HMAC-SHA256, constant-time comparison, and fail-closed missing-secret behavior | `PumbleAutomation.Pumble.Signature`; `PumbleAutomationWeb.Plugs.VerifyPumbleSignature` | `test/pumble_automation/pumble/signature_test.exs`; `test/pumble_automation_web/plugs/verify_pumble_signature_test.exs`; `test/security/release_gate_test.exs` | Provider timestamp details remain recorded in the probe register. |
| Replay | Ingress | Durable deduplication; webhook idempotency keys; no exactly-once claim | `PumbleAutomation.Ingress.Deduplication`; `PumbleAutomation.Ingress.Service` | `test/pumble_automation/ingress/deduplication_test.exs`; `test/pumble_automation/ingress/pumble_ingestion_test.exs`; `test/pumble_automation_web/controllers/inbound_webhook_controller_test.exs` | A fallback time-bucket key can split a duplicate at the bucket boundary. |
| Token leak | Storage and logging | AES-256-GCM envelopes, write-only secret loading, filtered parameters, and audit allowlists | `PumbleAutomation.Crypto.Vault`; `PumbleAutomation.Connections`; `PumbleAutomation.Audit.AuditEvent` | `test/pumble_automation/crypto/vault_test.exs`; `test/security/web_security_test.exs`; `test/pumble_automation/audit/audit_test.exs`; `test/security/release_gate_test.exs` | Logs and diagnostic exports remain sensitive operational data. |
| SSRF | Generic HTTP action | Resolve, reject, pin, and revalidate redirects; peer-verified TLS; no high-level redirect bypass | `PumbleAutomation.Connections.SafeHttp.Transport`; `PumbleAutomation.Connections.UrlPolicy` | `test/security/http_action_adversarial_test.exs`; `test/security/release_gate_test.exs` | Production DNS and network-namespace behavior require deployment proof; see `http_action_review.md`. |
| Workflow bomb | Compiler and runtime | Closed limit catalog, hard caps, and typed bounded overrides | `PumbleAutomation.Limits`; `PumbleAutomation.Workflows.Validator` | `test/security/limits_test.exs`; `test/security/release_gate_test.exs` | Excess work is parked by policy instead of silently executed. |
| Recursion loop | Pumble events | Own-bot filter plus authenticated lineage depth and descendant caps | `PumbleAutomation.Executions.Lineage`; `PumbleAutomation.Ingress.TriggerMatcher` | `test/security/loop_prevention_test.exs`; `test/security/release_gate_test.exs` | Including bot messages is an explicit per-trigger warning. |
| Job flood | Ingress and schedules | Workspace quotas, durable database limits, and fail-closed in-process rate limits | `PumbleAutomation.Limits`; `PumbleAutomation.RateLimiter` | `test/security/limits_test.exs`; `test/security/release_gate_test.exs` | The in-process limiter is per node; start with one application replica. |
| Approval spoof | Interaction callback | Actor policy plus a one-time, HMAC-bound token stored only as a digest | `PumbleAutomation.Executions.ApprovalService` | `test/pumble_automation/executions/approval_decision_test.exs`; `test/pumble_automation/executions/approval_request_test.exs`; `test/security/release_gate_test.exs` | A post-commit message-update failure does not reopen the decision. |
| Scope escalation | Pumble client | Closed requested-scope catalog; omitted known scopes block locally; provider `403` is permanent | `PumbleAutomation.Pumble.Scopes`; workflow dependency and activation modules | `test/pumble_automation/workflows/dependencies_test.exs`; `test/pumble_automation/workflows/activation_test.exs`; `test/pumble_automation/pumble/client/error_test.exs` | A recorded request is not proof that Pumble granted the scope. |
| Log leakage | Observability | Structured field allowlist, value redaction, credential filters, and callback logging disabled | `PumbleAutomation.Logging`; `config/config.exs` | `test/observability/logging_test.exs`; `test/security/web_security_test.exs`; `test/security/release_gate_test.exs` | Retention and access controls belong to the deployment's log drain. |
| Stored content injection | LiveView | HEEx escaping, restrictive CSP, and no raw HTML rendering | `PumbleAutomationWeb.Plugs.SecurityHeaders`; LiveView templates | `test/security/web_security_test.exs`; `test/security/threat_closure_test.exs`; `test/pumble_automation_web/live/execution_live_test.exs` | Inline styles are allowed for LiveView show/hide; scripts remain self-only. |
| Admin abuse | Support tools | Finite tenant-scoped operation catalog, role checks, audit trail, and no SQL/eval/global-admin surface | `PumbleAutomation.Operations` | `test/pumble_automation/audit/audit_test.exs`; `test/pumble_automation_web/live/audit_live/index_test.exs`; `test/security/release_gate_test.exs` | No cross-tenant super-admin UI exists. |
| Dependency compromise | Build | Lockfile, advisory scans, minimal runtime dependencies, and documented overrides | `mix.lock`; `scripts/verify.sh`; ADR-0011 | `mix hex.audit`; `test/security/threat_closure_test.exs`; the exact-commit offline gate | A clean local scan cannot attest a future registry or deployment environment. |

## Data handling invariants

- Raw credentials do not belong in logs, workflow JSON, execution history,
  metrics, receipts, or ordinary errors.
- A tenant identifier alone is never authorization.
- Production builds do not expose development routes.
- Delivery and execution use at-least-once semantics. External effects are not
  exactly-once. When a non-idempotent write may have happened but no definitive
  response arrived, execution pauses as `PAUSED_UNCERTAIN` for an authorized
  workspace owner to resolve.
