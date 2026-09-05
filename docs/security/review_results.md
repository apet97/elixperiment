# Security and dependency review

This record separates source review, offline verification, live API evidence,
temporary deployment evidence, and behavior that remains unverified. A result
belongs only to the exact commit and artifact named by its receipt.

## Exact verified checkpoint

The exact clean candidate named by `tmp/offline_acceptance_receipt.json` passed
all 19 local gates in `./scripts/verify.sh`. The receipt records the tested
commit, timestamp, test counts, lockfile hash, local image ID, and OCI revision
label. It also records that live certification was excluded.

The gate includes strict compilation, Credo, Dialyzer, `mix sobelow --config`,
`mix hex.audit`, `gitleaks`, release assembly, release migrations, and hardened
container smoke.

The image value in the receipt is a local Docker image ID, not a registry
digest. The receipt is the authoritative local result; a receipt from a
different commit must not inherit this review.

## Source boundaries reviewed

### Tenant isolation

- Web code receives a trusted `PumbleAutomation.Scope`; it does not query the
  repository directly.
- Tenant-owned records use compound installation/resource lookups.
- Foreign identifiers return the same not-found result as absent identifiers.
- Jobs re-check tenant identity before claiming durable work.

Primary proof: `test/security/tenant_isolation_test.exs` and
`test/security/release_gate_test.exs`.

### Secret handling

- Installation credentials and user credentials use AES-256-GCM envelopes.
- Connection secrets are write-only by default and are selected and decrypted
  only at the outbound-request boundary.
- Logs, audits, receipts, and diagnostics use explicit allowlists and redaction.
- Production secret-class values are required at runtime and remain empty in
  `.env.example`.

Primary proof: `test/pumble_automation/crypto/vault_test.exs`,
`test/pumble_automation/connections/secret_test.exs`,
`test/observability/logging_test.exs`, and the gitleaks gate.

### OAuth and callbacks

- OAuth state is random, stored as a digest, single-use, atomically consumed,
  expires, and carries only a local return path.
- Pumble callbacks require raw-body HMAC verification. A missing signing secret,
  missing signature, or invalid signature fails closed.
- Callback routes disable ordinary request logging.
- The supplied workspace API key was exercised only by the read-only harness.
  That run did not establish the key's complete capability set. The key is not
  an OAuth client credential, application signing secret, callback-signing
  authority, or Marketplace authority.

Primary proof: OAuth-state, web-security, signature, signature-plug, and release
gate tests.

### At-least-once execution

- Accepted callbacks receive a durable deduplication key.
- Execution and step identities are unique and stale jobs do not advance state.
- Completed steps are not run again by duplicate jobs.
- A non-idempotent write that may have happened without a definitive response is
  not automatically retried. The execution pauses as `PAUSED_UNCERTAIN` with a
  bounded diagnostic summary for an authorized workspace owner.

Primary proof: ingress deduplication, execution retry-policy, node, uncertainty,
and release-gate tests.

### Outbound HTTP and resource limits

- Generic HTTP targets are resolved, rejected when unsafe, pinned for dispatch,
  and revalidated on redirects.
- Peer verification remains enabled; credential-derived headers are stripped on
  cross-origin redirects.
- Workflow size, depth, context, queue, rate, and lineage limits are closed and
  bounded.

Primary proof: `test/security/http_action_adversarial_test.exs`,
`test/security/limits_test.exs`, and `test/security/loop_prevention_test.exs`.
Named HTTP residuals remain in `http_action_review.md`.

### Production surface and dependencies

- Production disables development routes and forces HTTPS.
- Health endpoints reveal only `ok` or `error`.
- The release runs as numeric UID/GID `10001:10001`; the local smoke drops
  capabilities, sets `no-new-privileges`, and uses a read-only root filesystem.
- Runtime dependencies are locked. The verification gate runs retired-package,
  advisory, static-security, and secret scans.

The lockfile intentionally pins hackney 4.0.3 for the tzdata transitive
dependency; tzdata downloads are disabled at runtime. See ADR-0011.

## Findings at the exact checkpoint

**Unresolved critical:** none.

**Unresolved high:** none.

No critical or high defect was waived at the named checkpoint. This statement
does not cover a later dirty worktree, a different image, or an untested
deployment.

## Live and deployment evidence at the checkpoint

The candidate-bound API-key preflight receipt records one public contract read
and four authenticated reads. It bound the exact commit, script, reviewed
public contract, clean worktree, and sacrificial workspace. It made no write
and created no resource. The API key is not an OAuth client credential,
application signing secret, callback-signing authority, or Marketplace
authority.

The exact local image migrated a disposable PostgreSQL database and returned
HTTP 200 for local liveness and readiness. The runtime used numeric UID/GID
`10001:10001`, a read-only root filesystem, dropped capabilities, and
`no-new-privileges`. Two account-less public tunnel attempts against candidate
`f83722ee9ee2c82ff5f33a0ed47e6de14e7a9a6a` returned HTTP 530; this is a
historical negative observation, not a current public probe, so public HTTPS
reachability remains unproved.

OAuth installation, token exchange, provider-delivered signed callbacks,
workflow execution, lifecycle delivery, and Pumble action writes remain
unproved. No registry artifact, durable platform, stable DNS, managed TLS,
restore, rollback, traffic switch, staging deployment, production deployment,
or Marketplace submission was proved. No Marketplace submission was started.

See [`docs/evidence/live_validation.md`](../evidence/live_validation.md) for the
evidence-layer table.
