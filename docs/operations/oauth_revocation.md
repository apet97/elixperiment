# OAuth, revocation, uninstall, and key rotation

Audience: internal operators. Do not copy this file into public support
articles.

Related:

- [Incidents](incidents.md)
- [Retention](../product/retention.md)
- Runtime variables: `../../.env.example`

## Result

Lifecycle and credentials stay tenant-scoped. A 401 or uninstall makes stored
tokens unusable before the HTTP ack finishes. Rotation never prints a secret.

## 401 / 403 and scope loss

### Symptom

Outbound Pumble calls fail with HTTP 401 (class `authentication`) or 403
(`missing_scope` or `authorization`). Those classes never retry. Onboarding
may show **scope-degraded** or ask the owner to reconnect.

### Checks

1. Open `/` (onboarding) and `/settings`. Read installation status.
2. Open `/members` if a user-token action failed.
3. Open `/audit` for `pumble_callback` lifecycle events
   (`APP_UNAUTHORIZED`, `APP_UNINSTALLED`).
4. Compare required scopes on the workflow version with the stored snapshot.
   Empty granted snapshot means unknown, not zero grants.

### Safe action

1. For 401: the credential is gone or revoked. Reinstall the app or reconnect
   the user from onboarding. Do not paste a token into IEx.
2. For 403: the app lacks a scope. Update the Pumble app grant, then
   reinstall so this application stores the new snapshot. Then reactivate
   the workflow if activation still blocks.
3. Do not requeue the failed step. Create a new run after credentials work.

### Stop / escalate

- Stop if you are about to change `bot_scopes` in SQL.
- Escalate Marketplace scope changes to the app owner.

## Uninstall and tenant deletion

### Symptom

Pumble sends `APP_UNINSTALLED`, or an owner clicks **Delete workspace data**
on `/audit` (`#audit-delete-tenant`). Status becomes `uninstalled`.
Credentials are cleared immediately. Workflow rows remain for 30 days.

### Checks

1. Confirm `/settings` uninstall guidance (`#settings-uninstall`).
2. Confirm `/audit` shows the lifecycle or `owner_requested` reason.
3. Confirm `/health/ready` is still 200. Uninstall of one tenant must not
   take the node out of rotation.

### Safe action

Owner UI (audited):

1. `/audit` → **Delete workspace data** → confirm `#audit-delete-submit`.
2. Same command:

<!-- command-status: proven-local -->
```elixir
PumbleAutomation.Operations.initiate_tenant_deletion(scope)
```

Pumble-driven uninstall is `Installations.Service.apply_lifecycle/3` with
`source: "pumble_callback"` only. Do not call it from a webhook or browser
source.

Integrity maintenance enqueues due purges after the grace window. Do not
pause tenant purge.

Reinstall of the same workspace during grace restores the tenant instead of
creating a second installation.

### Stop / escalate

- Stop if you are about to `DELETE FROM installations` by hand.
- Stop if you are about to resume executions for an uninstalled tenant.
- Escalate legal or Marketplace removal to the human owner. There is no
  legal hold in product.

## Signing secret, app key, and OAuth client secret

### Symptom

Callbacks fail signatures, or every outbound Pumble call fails 401 after a
console rotation.

### Checks

1. Confirm which value changed in the Pumble developer console. Do not print
   it.
2. Confirm the runtime variable name in `.env.example`:
   `PUMBLE_SIGNING_SECRET`, `PUMBLE_APP_KEY`, `PUMBLE_CLIENT_SECRET`,
   `PUMBLE_CLIENT_ID`.

### Safe action

Redeploy with the new value in the platform secret store.

<!-- command-status: planned-owner-approval -->
```bash
# planned — production secret replace and rolling restart; blocked by B-001
# Replace PUMBLE_SIGNING_SECRET (or APP_KEY / CLIENT_SECRET) in the secret store.
# Restart the release. Do not echo the value.
```

Expect replayed callbacks after a signing-secret change. App key changes
fail every API call until the new value is live.

### Stop / escalate

- Stop if a runbook step says to `echo` the secret.
- Escalate console access to the production owner.

## Webhook credential rotation

Owner: `/settings`, **Rotate credentials**
(`#rotate-webhook-<id>`), confirm `#webhook-rotate-submit`. The new bearer
token and, when raw-body signatures are required, the new HMAC signing secret
are shown once. Both previous credentials remain valid for
`PumbleAutomation.Ingress.WebhookEndpoint.rotation_overlap_seconds/0`, then
expire together. Callers must switch both values during that overlap.

Do not put the token in a query string. Callers use `Authorization: Bearer`
or `x-webhook-token`.

For signature-required endpoints, callers also send the fixed
`x-webhook-signature` header as `sha256=<64 lowercase hex characters>`. The
digest is `HMAC-SHA256(signing_secret, raw_request_body)`. The canonical input
is the exact request-body bytes: do not re-encode JSON or normalize whitespace,
key order, escaping, or trailing newlines. This credential is unrelated to
Pumble callback signing.

## Workflow secret values

Owner UI: `/secrets`. Values are write-only. Replace a secret by submitting a
new value. The UI never renders the old value.

`PumbleAutomation.Crypto.Rotation` **cannot** re-encrypt `secrets.value`
(`load_in_query: false`). After an encryption-key rotation, keep
`ENCRYPTION_LEGACY_KEYS` so reads still work. To move a secret onto the new
primary key, the owner re-enters it in `/secrets`.

## Encryption key rotation (`ENCRYPTION_KEY`)

### Symptom

A planned key rotation, or rows whose envelope version is not the primary
version.

### Checks

1. Confirm `ENCRYPTION_KEY_VERSION` will increase by one.
2. Confirm the outgoing key will be listed in `ENCRYPTION_LEGACY_KEYS`.
3. Confirm you can still decrypt a bot token after the deploy (boolean
   check only; do not print the token).

### Safe action

1. Deploy with new primary key, new version, and legacy read keys. This
   step is **planned** in production (B-001).
2. Re-encrypt installation bot tokens and user access tokens in bounded
   batches until `rotated` is 0:

<!-- command-status: proven-local -->
```elixir
alias PumbleAutomation.Crypto.Rotation
alias PumbleAutomation.Installations.Installation
alias PumbleAutomation.Installations.UserAuthorization

Rotation.rotate(Installation, :encrypted_bot_token, version_field: :token_key_version, limit: 100)
Rotation.rotate(UserAuthorization, :encrypted_access_token, version_field: :token_key_version, limit: 100)
```

3. Keep running batches until both calls return `rotated: 0`.
4. Tenant secrets: re-enter via `/secrets` or keep the legacy key. Do not
   call `Rotation.rotate` on `PumbleAutomation.Connections.Secret`.
5. Generic webhook HMAC secrets also use `load_in_query: false`. Do not call
   `Rotation.rotate` on `PumbleAutomation.Ingress.WebhookEndpoint`. An owner
   can rotate that endpoint's credentials in `/settings`, which issues a new
   signing secret under the current primary key. Otherwise keep the legacy key.
6. Remove `ENCRYPTION_LEGACY_KEYS` only after every ciphertext is on the
   primary version, including secrets you re-entered.

### `SECRET_KEY_BASE` and session-salt rotation

Changing `SESSION_SIGNING_SALT` invalidates every browser session. Changing
`SECRET_KEY_BASE` has a larger blast radius in this release:

- every browser session and LiveView token becomes invalid;
- every generic-webhook bearer digest stops matching, so callers get 401
  until an owner rotates that endpoint and installs the newly shown token;
- every pending Pumble approval button fails its action MAC and stored family
  digest; and
- lineage headers minted before the change fail verification for their
  remaining 15-minute lifetime.

The encrypted generic-webhook signing secret is keyed by `ENCRYPTION_KEY`, so
it is not lost. The bearer digest is keyed directly by `SECRET_KEY_BASE` and
has no legacy-key overlap. Do not describe this as a session-only rotation.

Use a maintenance window. Inventory enabled webhook endpoints and pending
approvals before the change. Replace `SECRET_KEY_BASE` in the platform secret
store, restart the entire fleet with one value, and require users to sign in
again. For every enabled generic webhook, an owner must use **Rotate
credentials** and update its caller with both newly shown credentials. Cancel
executions that were waiting for approval and start replacement runs after the
restart; do not force their decisions in SQL. Wait at least 15 minutes before
assuming all old lineage headers have expired.

This rotation is a redeploy, not a `Rotation.rotate` call. It cannot be a
zero-downtime rolling key change in this release because there is no legacy
`SECRET_KEY_BASE` verifier. Stop if the maintenance window, endpoint-owner
coordination, pending-approval cleanup, or whole-fleet restart is not approved.

### Stop / escalate

- Stop if the new key is not deployed and you already discarded the old key.
- Stop if a command would print ciphertext or plaintext.
- Stop if `rotated` is non-zero and you are about to drop the legacy key.
- Escalate production key ceremony to the production owner.
