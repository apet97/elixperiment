# Security and dependency review

This record separates source review, offline verification, live API evidence,
temporary deployment evidence, and behavior that remains unverified. A result
belongs only to the exact commit and artifact named by its receipt.

## Exact verified checkpoint

Clean commit `7c6680aa0663417790c4e8e5f61b649d7b0a8eec` passed all 19 local gates in
`./scripts/verify.sh` on 2026-08-25. The run passed 2,335 tests and 1 doctest,
strict compilation, Credo, Dialyzer, `mix sobelow --config`, `mix hex.audit`,
`gitleaks`, release assembly, release migrations, and the hardened container
smoke.

The gate built local image
`sha256:2120f16478fff70c4c6e0fb8beb05f420b2705a8393995f3ef28ce7486dd7b88`.
Its OCI revision label names the same commit. This is a local Docker image ID,
not a registry digest.

The repository changed after that checkpoint. Those later changes require a
new clean commit and a fresh receipt before they inherit any completion claim.
The current `tmp/offline_acceptance_receipt.json`, when produced by a clean
`./scripts/verify.sh` run, is the authoritative local result.

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

The bounded API-key preflight passed at `2026-08-25T00:13:32Z`. It made one
public contract read and four authenticated reads. It bound the exact commit,
script, reviewed public contract, clean worktree, and sacrificial workspace. It
made no write and created no resource. The successful result was captured in
transient standard output; the ignored receipt file still belonged to an older
candidate and was not treated as current evidence.

The exact local image ran behind a temporary HTTPS tunnel. Local and tunneled
liveness and readiness returned HTTP 200. This proves one temporary test
runtime only.

At that checkpoint, OAuth installation, token exchange, signed callback
delivery, workflow execution, lifecycle delivery, and Pumble action writes were
not proved. No registry artifact, durable platform, stable DNS, managed TLS,
restore, rollback, traffic switch, staging deployment, production deployment,
or Marketplace submission was proved. No Marketplace submission was started.

See [`docs/evidence/live_validation.md`](../evidence/live_validation.md) for the
evidence-layer table.
