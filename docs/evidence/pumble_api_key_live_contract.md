# Pumble API-key read-only contract snapshot

## Evidence source

This snapshot records the public Pumble API-key reference that was reviewed on
2026-08-24.

- Source: [Pumble API-key reference](https://pumble-api-keys.addons.marketplace.cake.com/api-docs/)
- Full response SHA-256: `85c42e355ed662ba6b1436b9c9c0e19b4bf045036e77c5d7c10622d943e54e48`
- Verification command:
  `curl -fsSL --max-time 15 https://pumble-api-keys.addons.marketplace.cake.com/api-docs/ | shasum -a 256`

The reference is public. The smoke script does not send the API key to this
URL. The script makes one public request and compares the full response with the
reviewed hash. A changed or unavailable response blocks the preflight before
the script sends an API-key request.

## Supported contract

The script accepts only the explicit `--preflight-only` command. It requires an
exact clean candidate and script match before it makes a request. It uses the
documented identity and channel contracts. It uses live-observed pagination
envelopes for the two message operations.

Run this command only after `./scripts/verify.sh` passes:

```bash
mix run --no-start --no-compile --no-deps-check --no-listeners scripts/live_api_smoke.exs --preflight-only
```

The command does not compile, check dependencies, start Mix listeners, or start
the Phoenix application. The script blocks if `:pumble_automation` is already
started. It also blocks if a database, queue, web, or host-application runtime
is active before or after the minimal start. After those checks, it starts only
`:req` and its declared dependencies.

Do not use the default `mix run` command. It can start the Phoenix application,
Repo, Oban queues and cron, and the web endpoint before the script guard runs.
The guard cannot undo those application-side effects.

| Operation | Required success shape |
| --- | --- |
| `GET /myInfo` | HTTP 200 with one identity object. |
| `GET /listChannels` | HTTP 200 with a bare array. Each entry contains `channel`, `pinnedMessages`, and `users`. |
| `GET /listMessages` | HTTP 200 with a `messages` array and Boolean `hasMoreBefore` and `hasMoreAfter` fields. The script requests one item. |
| `POST /searchMessages` | HTTP 200 with a `content` array, a Boolean `hasMore` field, and a nonnegative integer `totalElements` field. The request uses only the documented `text` and `in` fields. |

The public reference examples show bare arrays for both message operations.
Bounded live reads on candidate
`1b37e1bc7e9fe3518703dd75fdf7bbb6ac5a01bf` returned HTTP 200 with the
pagination envelopes in this table. No message content or provider ID was
stored. The script still binds the exact public-reference hash. It reports the
live response-shape checks as separate proof boundaries. This document does not
claim that the public examples and the live runtime agree.

The search operation is a read even though it uses HTTP POST. The script
searches for one new random marker. It requires an empty `content` array,
`hasMore: false`, and `totalElements: 0`. This check proves the observed live
shape. It does not prove that search is complete or immediately consistent.

## Safety boundaries

The script binds the identity to one fixed sacrificial workspace and rejects
any mismatch. It then binds exactly one eligible public channel. The channel
name must contain `test`, `sandbox`, or `automation` as a separate name segment.
The script does not support a channel override.

The script uses these request caps:

- One unauthenticated public contract request.
- Four authenticated API read requests.
- Five total requests.

The receipt contains a safe UTC timestamp; fixed command and schema metadata;
outcome and reason values; request counts and caps; commit and contract hashes;
and booleans and read counts. It does not contain the API key, workspace ID,
user ID, channel ID, message data, channel name, or search marker.

## No write implementation

The smoke script does not implement write operations. It has no send, reply,
reaction, delete, retry, recovery, or cleanup path.

This limit applies only to the API-key preflight and live-validation harness.
It does not disable the product's Pumble action nodes.

This boundary is intentional. The public reference does not guarantee that
list or search results are exhaustive and immediately consistent. It also does
not document an idempotency key for message creation. Therefore, a client
cannot recover a message ID authoritatively after a send commits but its
response is lost. A bounded test cannot guarantee cleanup in that case.

Add write behavior only after an authoritative contract proves idempotent
creation or complete bounded recovery, safe delete retries, and authoritative
absence checks. A contract change also requires a new reviewed snapshot, hash,
and focused tests.

## Evidence boundary

This document records an offline review of a public API-key reference and a
bounded read-only check of its live response envelopes. It does not prove a
live workspace write, cleanup, OAuth, callback signatures, event delivery,
installation lifecycle behavior, deployment, rollback, or Marketplace
readiness. An API key is not OAuth application credentials. It is not callback-
signing authority. The bounded live checks created no resource and left no
residue.
