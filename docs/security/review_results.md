# Security and dependency review record

> [!NOTE]
> This file preserves reviews made at several implementation phases. Early
> forward-looking statements are historical and are superseded by later
> addenda in this file. Current candidate proof comes from a clean
> `./scripts/verify.sh` run, not from an earlier phase label.

This is the release-gate review for plan task P13-T07. It is not advisory.
High or critical findings must be remediated or they block P16.

**Reviewed parent:** `acc514e5009c75b55ec83457ec5d041541e45ab8`
(`docs: ledger P13-T06 complete`, 2026-08-19).

This artifact is introduced in the P13-T07 feature commit on top of that
parent. The
[historical implementation ledger](../archive/implementation-ledger.md) records
that commit SHA after it lands.

**Toolchain:** Elixir 1.20.3 / OTP 29 / PostgreSQL 16.

## Commands and results

| Command | Result |
|---|---|
| `mix sobelow --config` | `SCAN COMPLETE` (exit 0). `.sobelow-conf` `exit: "low"`, empty `ignore`. |
| `mix hex.audit` | `No retired or security advisory packages found`. |
| `mix credo --strict` | 0 issues after enabling `UnsafeToAtom` and `LeakyEnvironment`. |
| `mix credo --strict --only UnsafeToAtom,UnsafeExec,LeakyEnvironment,ApplicationConfigInModuleAttribute,Dbg,IExPry` | 0 issues. |
| `gitleaks detect --source . --redact` (P2 scanner, v8.30.1) | Clean after `.gitleaks.toml` allowlists below. Pre-allowlist git-history hits are documented false positives, not production secrets. |
| `gitleaks detect --no-git --source . --redact` | Same allowlisted placeholders; `_build/`, `deps/`, and `tmp/` excluded. |
| `mix test test/security` | 113 passed (12 new in `threat_closure_test.exs`). |
| `./scripts/verify.sh` | `all 9 gates passed`. Full suite: 1996 tests + 1 doctest (1997 passed). |

Start-of-session `./scripts/verify.sh` failed twice on known EXPLAIN-plan flakes
(`trigger_bindings_lookup_index`, `executions_retention_index`) under seed
`591548`. Those tests were not changed. They are leftovers, not findings.

## Secret scan (redacted)

Scanner: **gitleaks** (CI `.github/workflows/ci.yml` `gitleaks/gitleaks-action@v2`;
local `gitleaks detect --source . --redact`).

### Generated release config

`mix release` remains P16. Production configuration is not baked into the
repository:

- `config/runtime.exs` loads `SECRET_KEY_BASE` and other secrets through
  `PumbleAutomation.Config` and does not embed a quoted `secret_key_base`.
- `config/prod.exs` sets `:dev_routes` false and `force_ssl`.
- `.env.example` documents every runtime variable. Secret-class values are
  empty assignments (`DATABASE_URL=`, `SECRET_KEY_BASE=`, …). `.env` is
  gitignored.

A container/image scan is P16/P18-T03.

### Documented false positives (not unresolved high findings)

| Location | Why it is not a production secret |
|---|---|
| `config/dev.exs` `secret_key_base` | Phoenix local placeholder. Production refuses to boot without `SECRET_KEY_BASE`. |
| `config/test.exs` `secret_key_base` | Test-only Endpoint key. |
| `test/support/http_test_server.ex` private key | Ephemeral CA for `http.test.local` in the SafeHttp TLS harness (P10). |

Allowlisted in `.gitleaks.toml` with path constraints so a new credential in
another file still fails the scan.

## Dangerous-pattern search

Searched `lib/**/*.ex` and production config. Proof:
`test/security/threat_closure_test.exs`.

| Pattern | Result |
|---|---|
| Web-layer `PumbleAutomation.Repo` | None. Credo `NoWebLayerRepo` + `tenant_isolation_test.exs`. |
| Raw SQL `Repo.query` | Only `lib/pumble_automation/health/repo_probe.ex:27` (`SELECT 1`). |
| `String.to_atom/1` | None in `lib/`. Credo `UnsafeToAtom` now enabled. `test/support/data_case.ex` uses `String.to_existing_atom/1`. |
| `:erlang.binary_to_term` / `binary_to_term` | None. |
| `System.cmd` / `:os.cmd` / `Code.eval` | None. Credo `UnsafeExec` and `LeakyEnvironment` enabled or already on. |
| TLS `verify: :verify_none` | None. |
| TLS `verify: :verify_peer` | `lib/pumble_automation/connections/safe_http/transport.ex:111`; `lib/pumble_automation/pumble/client/transport.ex:188`; `lib/pumble_automation/pumble/oauth_client.ex:166`. Test-only `verify_fun` in SafeHttp is the documented custom-CA path. |
| Debug routes | `lib/pumble_automation_web/router.ex:146` LiveDashboard is behind `Application.compile_env(:pumble_automation, :dev_routes)`. `config/prod.exs:28` sets it false. `test/security/web_security_test.exs` `LiveDashboard is not compiled into this router`. |
| `Phoenix.HTML.raw` in templates | None. |

## Manual boundary review

### OAuth

- Install and callback are unauthenticated by necessity
  (`lib/pumble_automation_web/router.ex:95-99`).
- CSRF control is hashed one-time state
  (`lib/pumble_automation/installations/oauth_states.ex:112-126`).
- Return destinations are local paths (`ReturnPaths`).
- Consent host is the configured Pumble host (`web_security_test.exs`).
- Revoked-installation sign-in remains allowed so owners can reinstall;
  uninstalled/deleted `signin`/`connect_user` are refused
  (`:installation_unusable`, P13-T05).

### Signature

- Scheme is `HMAC-SHA256(secret, timestamp <> ":" <> raw_body)` lowercase hex
  (`lib/pumble_automation/pumble/signature.ex`).
- Compare is `Plug.Crypto.secure_compare/2`.
- Plug fails closed when the signing secret is absent.
- Callback scope uses `log: false` (`router.ex:130`).

### Tenant

- Compound lookups and `Policy.not_found/0` for foreign ids.
- Jobs cannot retarget another tenant (`tenant_isolation_test.exs`).
- Web modules do not name `Repo`.

### SafeHttp

- DNS pin + IP policy + redirect revalidation as in
  `docs/security/http_action_review.md`.
- Residuals there were re-read; none were upgraded to critical/high.

### Session

- Cookie: Secure, HttpOnly, SameSite=Lax (`web_security_test.exs`).
- CSRF on browser mutations, including sign-out.
- Host allowlist; `X-Forwarded-Host` ignored.
- CORS deny.
- Production `force_ssl` with health excluded.

### Approval

- Token stored as digest; button value HMAC-bound
  (`approval_service.ex:109`, `:1070-1071`).
- Unauthorized and duplicate clicks are stale/no-op.
- Role/group selectors refused.
- Uninstall/cancel rotate nonce and digest (P11-T07).

### Uninstall

- `APP_UNINSTALLED` / `APP_UNAUTHORIZED` apply only from `pumble_callback`
  (`lifecycle_ingestion_test.exs`).
- Credentials purged; sessions revoked; 30-day grace then tenant purge
  (P13-T04). Owner `Operations.initiate_tenant_deletion/1` is tenant-scoped
  and audited (P13-T06).
- `Lifecycle.degrade_dependent_workflows/1` remains the named P3 no-op.
  That is leftover product behaviour, not an uninstall credential leak.

## Dependency lockfile, transitives, and licenses

Direct runtime and toolchain pins match `mix.lock` at the reviewed parent.
`mix hex.audit` reported no retired or advisory packages.

Notable override: **hackney 4.0.3** (ADR-0011) because tzdata 1.1.4 asks for
hackney 1.x, which fails `mix hex.audit`. tzdata autoupdate is disabled, so
hackney is unused at runtime.

Git deps (compile/false, asset sources):

- `heroicons` tag `v2.2.0` — MIT

Hex licenses observed from `deps/*/hex_metadata.config` (direct and
transitive): Apache-2.0, MIT, BSD-3-Clause, BSD. No copyleft runtime
dependency. `metrics` (BSD) and `unicode_util_compat` (Apache 2.0) appear as
Erlang transitives of TLS stacks.

`phoenix_live_dashboard` remains a Mix dependency. Production does not compile
its routes (`:dev_routes false`). Dropping the package is optional P16 cleanup,
not a high finding.

## Findings

**Unresolved critical:** none.

**Unresolved high:** none.

No blanket accepted-risk label is applied to a critical or high defect.

### Concrete later work (not P13 blockers)

| Item | Owner task |
|---|---|
| Structured, redacted application logs | P14-T01 (this change; `docs/operations/logging.md`) |
| Diagnostic ZIP packaging | P14-T06 |
| Security integration suite consolidation | P15-T05 |
| Release/container/image secret and advisory scan | P16, P18-T03 |
| Named HTTP excerpt / DNS residuals | `docs/security/http_action_review.md`; re-check in P15-T05 |
| `Connections.test_connection/2` typed refusal | later product task; not SSRF |

## Conclusion

Every Section 27 threat has a mitigation and automated proof. Log-schema
completion is P14-T01 (`docs/operations/logging.md`). Residual statements
above are accurate. This review names parent commit
`acc514e5009c75b55ec83457ec5d041541e45ab8`.

## P15-T05 security integration suite

This section is additive. It does not rewrite the P13-T07 review.

**Parent of this suite:** the P15-T04 ledger commit. The implementing SHA
is recorded in the
[historical implementation ledger](../archive/implementation-ledger.md) after
the feature commit.

Discoverable scenarios live in `test/security/release_gate_test.exs`. Each
case uses a unique `CANARY-P15T05-…` value where a leak assertion is
required. The suite is offline and release-blocking.

| Scenario | Proof |
|---|---|
| Forged callback | 401; canary absent from captured logs; no receipt |
| Malformed signed callback | 400/401, not 500; canary absent |
| Replayed signed event | one `received_events` row |
| Unknown OAuth state | redirect; token exchange never called |
| Revoked session | `Sessions.fetch/2` is `:error` |
| Cross-tenant claim | Engine.claim returns `:noop`; row stays `queued` |
| Webhook brute force | 401/429; no execution |
| Approval spoof | unauthorized actor and flipped MAC stay `pending` |
| SSRF loopback | `http_not_allowed` / `target_blocked` `:loopback` before a socket |
| Oversized webhook | Plug 413; no execution |
| Recursion | lineage depth 4 is `:lineage_depth_exceeded` |
| Log/export leak | unique canary absent from diagnostics inspect and logs |
| Admin surface | LiveDashboard path not compiled |
| Uninstall | `encrypted_bot_token` SQL read is NULL |

Existing suites remain the deeper proofs: `threat_closure_test.exs`,
`web_security_test.exs`, `loop_prevention_test.exs`, `limits_test.exs`,
`tenant_isolation_test.exs`, `http_action_adversarial_test.exs`.

HTTP residuals in `docs/security/http_action_review.md` were re-read.
None were upgraded to critical or high.

**Unresolved critical:** none.

**Unresolved high:** none.

## Adversarial audit remediation (2026-08-23)

Additive pass on the current working tree (`c4d505d` parent + uncommitted
remediation). This does not replace the P13-T07 or P15-T05 reviews above.

| Finding | Severity | Fix | Regression proof |
|---|---|---|---|
| Schedule dispatcher queue-cap starvation | P1 | `admit_queued_quota/2` before `Engine.create/2`; skip+advance on cap | `test/pumble_automation/executions/workers/schedule_dispatcher_test.exs` |
| Approval retry unique abort (`25P02`) | P1 | Lookup pending row; savepoint insert; `{:existing, _}` attach; skip duplicate delivery job | `test/pumble_automation/executions/approval_request_test.exs` |
| Webhook `require_signature` UI lie | P1 | Checkbox removed; validator `:webhook_signature_unsupported` | `test/pumble_automation/workflows/validator_semantic_test.exs` |
| Ingress ACK on retryable queue cap | P1 | `queued_executions_limit` is `retryable?: true` in `Engine.create/2` | `test/security/limits_test.exs` |
| Uncertain resolve does not wake occupancy | P2 | `apply_resolve/5` calls `wake_after/2` on terminal resolve | `test/pumble_automation/executions/uncertainty_test.exs` |
| Dispatcher lock order | P2 | Peek → lock installation → lock schedule | `schedule_dispatcher_test.exs` |
| LiveView confirm-assign bypasses (batch 1) | P2 | `require_confirmed/*` on show, execution, secret, connection, member, edit | LiveView tests under `test/pumble_automation_web/live/` |
| HTTP `http://` vs UrlPolicy drift | P2 | Validator rejects `http://` | `validator_semantic_test.exs` |
| Preview fails open on version load error | P2 | `preview_version/2` propagates compile/decode errors | `workflow_activation_live_test.exs` |
| LiveView confirm bypasses (batch 2) | P2 | Rotate, tenant delete, list deactivate/delete_draft | `admin_live_test.exs`, `audit_live/index_test.exs`, `workflow_live/index_test.exs` |
| Stale comments / dead publics / gate hardening | P3 | Removed unused accessors; `verify.sh` unused-deps, conflict markers, receipt fail-closed | `test/verification/offline_gate_test.exs` |

**Offline gate (this pass):** `./scripts/verify.sh` on 2026-08-22T23:51:22Z —
`all 9 gates passed`, `offline acceptance passed`, **2185 tests + 1 doctest**,
receipt `tmp/offline_acceptance_receipt.json`.

**Still blocked (not findings):** P16 deploy target, P17 live OAuth credentials,
P18 marketplace owner.

## Adversarial audit pass 2 (2026-08-23)

| Finding | Severity | Fix | Regression proof |
|---|---|---|---|
| Secret replace without inline form | P2 | `replace` requires `replacing_id == secret_id` | `secret_live/index_test.exs` |
| Comparator catalog drift (`in` / `is_present`) | P3 | Added to `Predicate.comparators/0`; validator unary set; expressions uses single catalog | `pure_domain_matrix_test.exs`, `validator_semantic_test.exs`, `node_forms_test.exs` |

## Candidate hardening review (2026-08-24)

This section is additive. It records the current candidate work on top of
starting HEAD `16dc07c9bafb01b4ac4e0dcfcf5bbb42b6a3e3c8`. A completion claim in
this section applies only to the clean commit named by a successful
`tmp/offline_acceptance_receipt.json` from `./scripts/verify.sh`.

This section supersedes conflicting current-state claims in the 2026-08-23
sections. In particular, the row that says webhook signatures are unsupported
is stale. Generic inbound webhooks now support an optional signing secret and
raw-body signature verification.

### Security and reliability corrections

| Boundary | Current correction | Offline regression proof |
|---|---|---|
| Signed-webhook rollback | Signature-required endpoints store the active state in `signature_enabled` and keep the legacy `enabled` bit false. A previous binary therefore sees the endpoint as disabled after rollback. It cannot accept a bearer-only request. | `test/pumble_automation/ingress/webhook_endpoint_test.exs`; `test/pumble_automation/workflows/activation_test.exs`; `scripts/release-migration-integration.sh` (`signature_rollback=proved`) |
| Workflow-version identity | The expand migration keeps the legacy `(workflow_id, definition_hash)` constraint. It adds nullable `source_hash` and `identity_hash` fields and backfills current rows. A current writer refuses the same source revision with a different compiled snapshot as `snapshot_requires_source_revision`. This keeps old writers compatible without silently changing an immutable version. The migration also validates the exact owner, table, columns, order, uniqueness, access method, expression, predicate, and constraint shape before it accepts a same-named catalog object. A valid but mismatched object fails closed and remains intact. | `test/pumble_automation/workflows/workflow_version_test.exs`; `test/pumble_automation/workflows/activation_test.exs`; `test/pumble_automation/workflows/deactivation_test.exs`; `test/release/migration_test.exs`; `scripts/release-migration-integration.sh` |
| Secret-header redirects | The HTTP action tracks the exact header names that came from encrypted secrets. A cross-origin redirect removes those headers. It does not depend on a fixed list of common credential names. | `test/security/http_action_adversarial_test.exs`; `test/pumble_automation/executions/nodes/http_request_node_test.exs` |
| Dispatch evidence | Diagnostics use `confirmed`, `not_sent`, `possibly_sent`, or `unknown`. Here, `confirmed` means that a remote response was received. It does not prove that a remote side effect occurred. Redirect refusals and local extraction failures retain the safe remote status. A direct unkeyed POST that loses the transport after body write pauses as uncertain. Response body, header, and compression-policy failures after that write also pause as uncertain. An unkeyed POST followed by a 302 or 303 redirect pauses as uncertain if the rewritten GET receives 429 or 5xx, or if the GET times out or cannot connect or resolve DNS. The original POST is not retried automatically. | `test/pumble_automation/executions/retry_policy_test.exs`; `test/pumble_automation/executions/nodes/http_request_node_test.exs`; `test/security/http_action_adversarial_test.exs` |
| Bounded text capture | HTTP excerpts, normalized callback strings, provider IDs, stop reasons, execution diagnostics, and approval prompts clip only at a valid UTF-8 boundary. Invalid HTTP binary data becomes a length-only description that is safe to encode as JSON. Boundary-crossing multibyte values remain encodable and persistable instead of turning a legitimate event or stop into a permanent failure. | `test/pumble_automation/executions/nodes/http_request_node_test.exs`; `test/pumble_automation/executions/approval_request_test.exs`; `test/pumble_automation/executions/node_runner_test.exs`; `test/pumble_automation/ingress/deduplication_test.exs`; `test/pumble_automation/pumble/normalizer_test.exs`; `test/pumble_automation_web/live/execution_live_test.exs` |
| Schedule dispatch | The dispatcher uses one lock order: installation, workflow, then schedule. It uses `SKIP LOCKED`, a bounded scan, a 50-clock batch, and a one-second continuation when more work is due. The capacity fixture dispatches 75 clocks across three tenants as 50 plus 25 and ends with 25 executions for each tenant. | `test/pumble_automation/executions/workers/schedule_dispatcher_test.exs`; `test/performance/scheduler_capacity_test.exs` |
| Approval versus uninstall | Approval decisions and timeouts take the installation share lock before they change approval or execution state. A committed uninstall prevents a waiting timeout from applying its effect. | `test/pumble_automation/executions/approval_decision_test.exs`; `test/pumble_automation/executions/approval_timeout_test.exs` |
| `SECRET_KEY_BASE` rotation | The key protects browser sessions, generic-webhook bearer digests, approval action message authentication codes, and lineage values. Rotation is a whole-fleet maintenance action. Operators must rotate affected webhook endpoints and cancel or restart pending approvals as the runbook specifies. | `docs/operations/oauth_revocation.md`; `test/observability/runbooks_test.exs` |
| Concurrent history index | The release harness creates the real interrupted `CREATE INDEX CONCURRENTLY` boundary. It waits for the invalid catalog row, terminates the index builder, runs the release migration again, and verifies the exact valid index definition. A mismatched index with the target name fails closed. | `priv/repo/migrations/20260823230831_add_executions_history_cursor_index.exs`; `scripts/release-migration-integration.sh`; `test/release/migration_test.exs` |
| One-time schedules | The validator accepts a naive ISO 8601 `run_at` value when a valid IANA time zone is present. The calculator resolves the local wall time through that time zone. Activation materializes the same UTC instant. | `test/pumble_automation/workflows/validator_semantic_test.exs`; `test/pumble_automation/workflows/schedule_calculator_test.exs`; `test/pumble_automation/workflows/activation_test.exs` |
| Database failure tests | Tests that install database-wide failure triggers now run serially. This prevents one module from changing another module's database while the full suite runs. | `test/pumble_automation/executions/create_execution_test.exs`; `test/pumble_automation/executions/finalize_test.exs`; `test/pumble_automation/workflows/activation_test.exs`; `test/pumble_automation/workflows/deactivation_test.exs` |

### Proof boundary

The local release and container implementation is present. The local release
migration harness covers empty and current databases, concurrent migration
runners, partial migration retry, rollback compatibility, and the interrupted
history-index retry. This is offline proof only. It is not deployment,
restore, production rollback, or post-deployment proof.

The supplied sacrificial-workspace API key can authorize only the API
operations that its workspace grants. It is not an OAuth client credential,
an application signing secret, callback-signing authority, or Marketplace
authority. A bounded smoke must read it only from the private runtime variable
`SAC_WS_API_KEY`. It must not print or persist the value. This section claims
no live mutation, live cleanup, OAuth flow, callback delivery, lifecycle
delivery, deployment, or publication evidence. The separate
[API-key contract snapshot](../evidence/pumble_api_key_live_contract.md)
defines the read-only preflight and explains why the API-key preflight and
live-validation harness has no mutation mode. This harness limit does not
disable the product's Pumble action nodes.

**Current candidate conclusion:** the final adversarial review found no
remaining actionable P0, P1, or P2 defect in the reviewed product diff. The
clean commit named by the successful offline receipt passed the complete local
gate. This is not deployment, production rollback, or full live Pumble proof,
and it does not change the blocked authority boundaries above.
