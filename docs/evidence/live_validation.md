# Live validation record

This record separates offline proof, bounded API proof, temporary runtime
proof, and behavior that remains unverified. Dynamic values are intentionally
kept in the ignored receipts under `tmp/`; the receipt's `git_sha` must equal
`git rev-parse HEAD` before any claim is reused.

## Offline proof

`./scripts/verify.sh` is the release-candidate gate. The latest successful
receipt reports all 19 gates and its test counts. It also binds the
lockfile hash, local image ID, OCI revision label, clean working tree, and
`live_certification: "excluded"`.

The image ID in the receipt is local-only. It is not a registry digest and does
not prove a hosted deployment. The gate covers formatting, compilation, tests,
static/security analysis, release assembly and migrations, UI checks, secret
scanning, and hardened container smoke.

## Read-only Pumble API proof

The latest `tmp/live_api_preflight_receipt.json` is a candidate-bound,
redacted receipt. It records:

- one public contract read and four authenticated reads;
- identity, workspace, channel, message-list, and message-search response-shape
  checks;
- exact candidate/script/contract/clean-tree bindings; and
- zero writes, created resources, or test residue.

The API key was supplied only through the private `SAC_WS_API_KEY` runtime
variable. It is not an OAuth client credential, application key, callback-
signing secret, installation grant, or Marketplace authority. The preflight
does not have a message-write mode.

## Temporary local runtime proof

The exact receipt-bound image was exercised with a disposable PostgreSQL 16
database. Release migrations completed, and both local probes returned HTTP
200:

- `GET /health/live` — process liveness;
- `GET /health/ready` — database, migration, and Oban readiness.

The app container ran as numeric UID/GID `10001:10001` with a read-only root
filesystem, all capabilities dropped, `no-new-privileges`, a bounded temporary
filesystem, and no host mounts. Callback signature and route behavior remain
covered by the offline security and web test gates; no provider callback was
used for this temporary runtime.

Two account-less Cloudflare quick-tunnel attempts were also made against the
local port. Both returned HTTP 530, so public HTTPS reachability, stable DNS,
and provider callback delivery are not claimed. The disposable containers and
tunnel processes are removed after validation.

## Browser and OAuth boundary

The private app configuration page was observed previously in the authorized
sacrificial workspace, but installation did not complete. No OAuth token-
exchange response bytes, authenticated onboarding, provider callback, event,
or interaction delivery were observed. No OAuth application credentials or
callback-signing secret were available for this run, and the workspace API key
cannot substitute for them.

## Unverified boundaries

| Boundary | Status |
| --- | --- |
| OAuth installation and token exchange | Not proved |
| Browser onboarding after OAuth | Not proved |
| Provider-delivered signed callback | Not proved |
| Live event or interaction handling | Not proved |
| Live workflow execution | Not proved |
| Pumble message, reply, direct-message, or reaction write | Not proved |
| Reinstall, revocation, uninstall, and lifecycle delivery | Not proved |
| Durable deployment, registry digest, restore, rollback, and traffic switching | Not proved |
| Marketplace review or publication | Not submitted; no submission started |

Do not use the successful offline gate, read-only API preflight, or temporary
local runtime as evidence for any unverified row.
