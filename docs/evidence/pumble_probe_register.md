# Pumble protocol probe register

Original review date: 2026-08-15. Last evidence update: 2026-09-05.
Companion file: `pumble_source_matrix.md`.

Each probe resolves one unknown. Each probe is bounded: one hypothesis, one
weakest acceptable conclusion, one action set, one cleanup.

## Current live status

The 2026-09-05 API-key preflight was separate from these probes. It passed 1
public contract read and 4 authenticated reads. It made no write and did not
start OAuth. The private app configuration page was observed, but installation
remained pending.

No OAuth response bytes, callback delivery, lifecycle event, interaction, or
Pumble write was observed. The preflight does not change any probe status in
this register.

## Rules for every probe

1. **Run each probe separately.** A read-only API-key preflight does not close
   an OAuth, callback, lifecycle, interaction, or write probe.
2. **Sacrificial workspace only.** Probes marked `SACRIFICIAL` require a
   throwaway Pumble workspace and a throwaway OAuth add-on registration.
   Never run them against a customer or personal workspace.
3. **Unique prefix.** Every artifact a probe creates uses the prefix
   `probe-<ID>-<UTC timestamp>`, for example `probe-PR-02-20260901T101500Z`.
   This makes cleanup verifiable.
4. **Record shapes, not secrets.** Capture header names, field names, status
   codes, and ordering. Never record token values, signing secrets, workspace
   IDs, app IDs, user IDs, e-mail addresses, or message text written by a real
   person. Replace every identifier with a placeholder such as `<wsid>`
   before the result is written to the repository.
5. **A failed or absent observation is not support.** If an event does not
   arrive, the conclusion is "not observed in this run", never "does not
   happen". Record the observation window.
6. **`BLOCKED` is a valid state.** If credentials are missing, mark the probe
   `BLOCKED` and keep the conservative assumption named in the probe.
7. **Current credential status.** OAuth installation did not complete in the
   2026-09-05 run. Every OAuth-dependent probe remains open. Do not treat the
   API key as OAuth application credentials or callback-signing authority.
8. **`RESOLVED BY SOURCE` is a terminal state.** Added 2026-08-15 after the
   public [Pumble Node SDK at commit `36bb7ed`](https://github.com/CAKE-com/pumble-node-sdk/tree/36bb7edf091b9d24b39d6e70302ebbb3a1759fe3)
   was cross-checked (see `pumble_source_matrix.md` section 13). A probe or a
   probe step marked `RESOLVED BY SOURCE` need not be run, because vendor
   source code proves the answer. Entries are **kept, never deleted, never
   renumbered**, so that existing references stay valid.
9. **Source can only resolve client-side questions.** Source proves what the
   SDK computes, verifies, sends, and requires. It never proves what the
   Pumble *server* does. Retries, replay, rate limits, expiry, ordering, scope
   enforcement, and token replacement stay probes no matter how clear the SDK
   is. Where source narrows a probe without closing it, the probe carries a
   `Source note:` paragraph and stays open.

## Prerequisites shared by most probes

| Item | Detail |
|---|---|
| `SETUP-A` | A sacrificial Pumble workspace whose owner is the operator. At least two members: the installing owner and one second test user. At least one public test channel with the probe prefix in its name. |
| `SETUP-B` | A throwaway Pumble add-on registration on that workspace, with its own app ID, client secret, app key, and signing secret. Credentials live only in the operator's local environment, never in the repository. |
| `SETUP-C` | A public HTTPS collector that logs, for every request: full header set, exact raw body bytes, byte length, receipt timestamp with millisecond precision, and the response the collector returned. The collector must be able to return a chosen status code and a chosen delay per path. |
| `SETUP-D` | The collector subscribes to all seven documented events and declares one slash command, one global shortcut, one message shortcut, one block interaction endpoint, one view action endpoint, and one dynamic menu. |

`SETUP-C` is the single most valuable initial live-probe artifact. Most probes are
just a scripted interaction plus a read of its log.

---

## Probe index

| ID | Subject | Status after source cross-check | Sacrificial | Owner action | Affects |
|---|---|---|---|---|---|
| `PR-01` | Delivery identity fields for all callback classes | OPEN (annotated) | yes | yes | callback transport, delivery and execution schema |
| `PR-02` | Callback retry, replay, and timeout behavior | OPEN (annotated) | yes | yes | callback transport, execution recovery |
| `PR-03` | Signature header name, precedence, encoding, timestamp | **RESOLVED BY SOURCE** except the timestamp unit | yes | no | callback signature verification |
| `PR-04` | OAuth token expiry and refresh | OPEN, narrowed | yes | yes | installation credential lifecycle |
| `PR-05` | Reinstall token replacement | OPEN (annotated) | yes | yes | reinstall behavior |
| `PR-06` | Uninstall and unauthorized delivery and ordering | OPEN (annotated) | yes | yes | installation lifecycle, tenant teardown |
| `PR-07` | Exact scope matrix | OPEN, narrowed (vocabulary closed) | yes | yes | installation scope snapshot, actions |
| `PR-08` | Rate-limit headers and `429` shape | OPEN (annotated) | yes | no | action pacing, Pumble client errors |
| `PR-09` | Server-side idempotency on writes | OPEN (annotated) | yes | no | action safety, retry policy |
| `PR-10` | App-generated message metadata and self-trigger loops | OPEN, narrowed (detection rule resolved) | yes | no | trigger matching |
| `PR-11` | Workspace role values | OPEN (annotated) | yes | yes | member role mapping |
| `PR-12` | Callback and message size limits | OPEN (annotated) | yes | no | callback body limits, action payload validation |
| `PR-13` | Marketplace launch-link behavior | OPEN (annotated) | yes | yes | listing behavior, live validation |
| `PR-14` | Slash, shortcut, and modal response ordering | **PARTLY RESOLVED BY SOURCE** — steps 1 to 4 and the `loadingTimeout` half closed; the ack-deadline half stays open | yes | yes | callback responses, modal UI |
| `PR-15` | OAuth redirect and error payloads | OPEN (annotated) | yes | yes | OAuth install and error handling |
| `PR-16` | Callback classification and `messageType` values | OPEN, narrowed (guard exclusivity resolved) | yes | yes | callback classification |
| `PR-17` | Reaction write semantics and dynamic-menu response contract | OPEN, narrowed (client-side forms resolved) | yes | no | reaction actions, dynamic pickers |

"Owner action" means a human must click inside Pumble; the probe cannot run
unattended.

No probe was deleted or renumbered by the 2026-08-15 source cross-check. The
`Status` column records only what source evidence closed.

---

## PR-01 — Delivery identity fields

> **Source note (2026-08-15).** Still open — uniqueness and redelivery
> stability are server properties. Source narrows the field list only.
> `rid` is a required `string` commented `// Request id` on all four
> abbreviated event payloads, and absent from the two lifecycle payloads,
> which carry `id` instead (SDK source:
> `pumble-sdk/src/core/types/pumble-events.ts`). `triggerId` is required on
> every interaction payload (SDK source: `core/types/payloads.ts`).
> Critically, **the SDK uses `triggerId` purely as an addressing token echoed
> into modal and menu envelopes, never as a deduplication key**, and performs
> no deduplication anywhere (SDK source: `core/services/AddonService.ts`,
> `createViewContext()` and `dynamicSelectMenu()`). `sourceId` on a block
> interaction is the source **object** id (a message id or a parent view id),
> not a delivery id, so it must not be used as one. Fallback `I-9` (SHA-256
> over the raw body plus the signature header) stands until this probe runs.

**Unknown:** stable unique delivery identities for all callback types. Matrix
rows `I-1` to `I-8`.

**Hypothesis:** `rid` on event payloads and `triggerId` on interaction
payloads are unique per delivery, and a redelivery of the same logical event
repeats the same value.

**Weakest acceptable conclusion:** the set of fields that are present and
non-empty on each callback class, and whether any field repeats across two
deliveries of the same logical action. If nothing repeatable is proven, the
add-on uses the composite key `I-9` (SHA-256 of the raw body plus the
signature header) and does not claim provider-side identity.

**Setup:** `SETUP-A` to `SETUP-D`. Collector returns `200` immediately for
every path.

**Action:**
1. Post one message in the probe channel; capture the `NEW_MESSAGE` callback.
2. Edit that message; capture `UPDATED_MESSAGE`.
3. Add one reaction; capture `REACTION_ADDED`.
4. Create one probe-prefixed channel; capture `CHANNEL_CREATED`.
5. Invite the second test user; capture `WORKSPACE_USER_JOINED`.
6. Run the slash command, the global shortcut, and the message shortcut once
   each.
7. Open a modal, click one button in it, submit it, and type in one dynamic
   menu.
8. Repeat step 1 with identical text five minutes later.

**Expected observation:** for each callback, the presence, format, and length
of `rid`, `triggerId`, `sourceId`, `view.id`, and the lifecycle `id`. Whether
step 8 produced a different `rid` from step 1 (it must, if `rid` is per
delivery).

**Cleanup:** delete the probe messages, remove the reaction, archive or delete
the probe channel, deactivate the second test user if it was created for this
probe.

**Affects:** callback transport and the delivery and execution schema.

---

## PR-02 — Retry, replay, and timeout behavior

> **Source note (2026-08-15).** Still fully open — retry and replay are
> server behavior and no client code can prove them. Source adds three facts
> that make the probe more important, not less. (1) The SDK contains no retry,
> no backoff, no deduplication, and no timer anywhere (SDK source:
> `pumble-sdk/src/api/BaseApiClient.ts`, `request()` — one axios call, no
> interceptors). (2) For events, the HTTP adapter answers `res.send('ok')`
> **before** dispatching to the handler, so a handler crash is invisible to
> Pumble and can never provoke a redelivery (SDK source:
> `core/adapters/http/AddonHttpListener.ts`, `handleMessage()`). The Elixir
> port must therefore persist the delivery durably before answering. (3) The
> socket adapter sends **no** response at all for events, which means the
> event channel has no application-level acknowledgement in either adapter.

**Unknown:** exact replay behavior. Matrix rows `K-9`, `K-10`, `U-1`.

**Hypothesis:** Pumble retries a callback when the endpoint answers a `5xx`
status or does not answer within the deadline, and the retry carries an
identity field that matches the first attempt.

**Weakest acceptable conclusion:** for each response the collector returns
(`200`, `400`, `401`, `500`, no answer within 3 s, no answer within 30 s,
TCP reset), record whether a second delivery arrived, how long after, how many
attempts followed, and whether any payload field was identical. If no retry is
observed in a 10-minute window, the conclusion is "no retry observed in 10
minutes", and the add-on must still be idempotent because absence is not
proof.

**Setup:** `SETUP-A` to `SETUP-D`. The collector must serve one path per
response mode so each mode is isolated.

**Action:** trigger one `NEW_MESSAGE` and one slash command against each
response mode, one mode at a time, with at least 15 minutes between modes.

**Expected observation:** attempt count, inter-attempt delay, backoff shape,
and whether the slash-command user saw a timeout error in the Pumble client
(the operator records the visible user-facing text).

**Cleanup:** delete probe messages; restore the collector to `200` for all
paths.

**Affects:** transport idempotency and execution retry policy.

---

## PR-03 — Signature header name, precedence, encoding, and timestamp

> **`RESOLVED BY SOURCE` — SDK source:
> `pumble-sdk/src/core/adapters/http/middlewares.ts`, `verifySignature()`
> (corroborated by SDK docs `docs/advanced-concepts.md`, "Request Signature
> Verification").** The entry is kept for traceability; the probe below need
> not be run except for the one residual step named at the end.
>
> **Resolved answers:**
> - Header names: `x-pumble-request-signature` (signature) and
>   `x-pumble-request-timestamp` (timestamp). **Both are mandatory.**
> - The corpus names `X-Pumble-Signature` and `X-Signature` **do not exist**.
>   A repository-wide search of the SDK source, docs, CLI, and examples
>   returns zero matches for either. There is no fallback and therefore no
>   precedence question. Matrix contradiction `X-2` is `RESOLVED`.
> - Algorithm: HMAC-SHA256, keyed with the manifest `signingSecret`.
> - **Signed string: `` `${timestamp}:${rawBody}` ``** — the timestamp header
>   value, a literal colon, then the raw body. **Not the raw body alone.**
> - Encoding: lowercase hexadecimal (`.digest().toString('hex')`), no prefix.
> - Rejection: `403` with plain-text body `Invalid signature!` when either
>   header is missing or the digest differs.
> - A timestamp header **does** exist, so a replay window is implementable.
>   The earlier conclusion "no replay window exists" is withdrawn.
> - The SDK compares with `!==`, which is **not** constant time. The port
>   diverges deliberately and compares in constant time (matrix `D-1`).
>
> **Residual step, still worth running once credentials exist:** the timestamp
> **unit and format** (epoch seconds, epoch milliseconds, or ISO 8601). The
> code treats it as an opaque string and never parses it, so source cannot
> decide this. Capture one real header value and record its format. This is
> the only reason to keep the probe runnable, and it does not block
> implementation, because the verifier must use the value verbatim regardless.
>
> Everything below this line is the original probe definition, retained
> unchanged for the record.

**Unknown:** signature header and timestamp details. Matrix contradiction `X-2`,
rows `H-7` to `H-10`.

**Hypothesis:** Pumble sends exactly one signature header, named
`X-Pumble-Signature`, whose value is the lowercase hexadecimal HMAC-SHA256 of
the raw request bytes keyed with the signing secret, and sends no timestamp
header. *(Disproven by source on every point except the hex encoding.)*

**Weakest acceptable conclusion:** the exact header names present on a real
callback, the exact value encoding, and whether any header carries a timestamp
or a nonce. If both `X-Pumble-Signature` and `X-Signature` appear, record
whether their values are equal. If no timestamp header exists, the add-on
cannot implement a replay window from headers and must rely on stored delivery
keys instead.

**Setup:** `SETUP-A` to `SETUP-D`. Collector logs the complete header list in
received order, unmodified.

**Action:** send one callback of each class from `PR-01`. Offline, recompute
HMAC-SHA256 over the exact stored bytes with the signing secret and compare
against each candidate header value in hex and in base64. Then send one
deliberately altered replay of a captured body to the collector and confirm
that the recomputed comparison fails (this validates the verifier, not Pumble).

**Expected observation:** header names, one matching encoding, and the absence
or presence of a timestamp header.

**Cleanup:** delete probe messages. Rotate the sacrificial signing secret
after the probe.

**Affects:** callback signature verification.

---

## PR-04 — OAuth token expiry and refresh

> **Source note (2026-08-15).** Narrowed, not closed. Step 1 is
> `RESOLVED BY SOURCE`: the token-exchange response type is exactly
> `{accessToken, botToken?, userId, botId?, workspaceId}` — **no `expiresIn`,
> no `expiresAt`, no `refreshToken`, no scope list** (SDK source:
> `pumble-sdk/src/auth/types.ts`, `type OAuth2AccessTokenResponse`). No
> refresh endpoint exists anywhere in the SDK; `OAuth2Client` has exactly one
> method (SDK source: `auth/OAuth2Client.ts`). Vendor documentation states
> plainly: "Generated access tokens do not need to be refreshed" (SDK docs:
> `docs/authorization.md:51`). **Steps 2 and 3 still matter**, because the
> absence of an expiry field is not a promise that the server never revokes a
> token, and a `401` after a long idle interval would still have to be
> handled. Run the long-interval probe; skip step 1.

**Unknown:** OAuth token expiry and refresh behavior. Matrix rows `A-21`, `U-2`.

**Hypothesis:** the access token and the bot token do not expire on a fixed
schedule, and no refresh endpoint exists; recovery from `401` is a fresh
authorization.

**Weakest acceptable conclusion:** whether the token exchange response
contains any expiry field at all, and whether a token still authorizes a read
call after a long idle interval. If a token fails after an interval, record
the interval bound and the exact error body.

**Setup:** `SETUP-A`, `SETUP-B`. One completed install. Store the token
exchange response **shape** only; never the values.

**Action:**
1. Record every key present in the `POST /oauth2/access` response body.
2. Call `GET /oauth2/me` with the user token and with the bot token at
   T+0, T+1 h, T+24 h, T+7 d, T+30 d.
3. Record the status and the error body for the first failure, if any.

**Expected observation:** presence or absence of `expiresIn`, `expiresAt`,
`refreshToken`, or a scope list in the exchange response; the first failing
interval, if any.

**Cleanup:** none needed during the observation window. Uninstall the probe
app from the sacrificial workspace at the end and rotate the client secret.

**Affects:** installation and credential lifecycle.

---

## PR-05 — Reinstall token replacement

> **Source note (2026-08-15).** Still open — whether the *server* issues new
> token values and invalidates the old ones is unprovable from client code.
> Source resolves only the client half: the SDK's stores upsert by
> `workspaceId`, overwriting `botId` and `botToken` whenever both are present
> in the response and always overwriting `userTokens[userId]` (SDK source:
> `pumble-sdk/src/auth/stores/JsonFileTokenStore.ts`, `saveTokens()`;
> interface `auth/stores/CredentialsStore.ts`). Note that `saveTokens` writes
> the bot credentials **only when both `botId` and `botToken` are present**, so
> a reinstall response that omits them silently leaves the previous bot token
> in place — a failure mode the Elixir store must handle explicitly. Step 4
> (a different authorizing user) remains the most valuable step, because the
> store is keyed by `userId` and would accumulate rather than replace.

**Unknown:** matrix row `A-22` and reinstall behavior.

**Hypothesis:** a reinstall through the consent screen with `isReinstall=true`
returns a new access token and a new bot token for the same workspace, the
previous tokens stop working, and `botId` and `workspaceId` stay the same.

**Weakest acceptable conclusion:** whether the second exchange returns
different token values for the same workspace, and whether the first token
still authorizes `GET /oauth2/me` afterwards. If the old token keeps working,
the add-on must revoke it explicitly through `DELETE /v1/app/authorization`.

**Setup:** `SETUP-A`, `SETUP-B`, one completed install, one stored token
fingerprint (a salted hash of the token, never the token).

**Action:**
1. Complete the consent flow again with `isReinstall=true`.
2. Compare fingerprints of the old and new access token, bot token, `botId`,
   `userId`, and `workspaceId`.
3. Call `GET /oauth2/me` with the old access token and with the old bot token.
4. Repeat the reinstall with a **different** workspace member as the
   authorizing user and record whether `userId` changes while `botId` stays.

**Expected observation:** which credentials change, which survive, and whether
authorization identity can change across a reinstall (this decides whether the
add-on must revoke sessions).

**Cleanup:** uninstall the probe app; rotate the client secret.

**Affects:** reinstall behavior and session revocation rules.

---

## PR-06 — Uninstall and unauthorized delivery and ordering

> **Source note (2026-08-15).** Still fully open — delivery, ordering, and
> latency are server behavior. Source confirms only the payload shapes
> (`NotificationAppUninstalled`, `NotificationAppUnauthorized`) and that the
> SDK offers **no** built-in handling for either event: there is no lifecycle
> hook, and neither `deleteForWorkspace` nor `deleteForUser` on the credential
> store is ever called by the SDK itself (SDK source:
> `pumble-sdk/src/auth/stores/CredentialsStore.ts` declares them;
> no caller exists in `core/`). Teardown is entirely the add-on's
> responsibility. Note also that `uninstalledAt` is typed `Date`, so its wire
> encoding is unproven and must be parsed defensively — add that to the
> observation list for actions 3 and 4.

**Unknown:** uninstall and unauthorized delivery. Matrix rows `L-1`, `L-2`.

**Hypothesis:** removing one user's authorization delivers `APP_UNAUTHORIZED`
with `accessGranted: false`, and uninstalling the app from the workspace
delivers `APP_UNINSTALLED`; both arrive on the event endpoint before the
tokens stop working.

**Weakest acceptable conclusion:** which of the two events actually arrives
for which owner action, in which order, with what latency, and whether either
arrives at all after the credentials are already invalid. If neither arrives
reliably, the add-on must detect uninstall by observing repeated `401`
responses and must not depend on the callback.

**Setup:** `SETUP-A` to `SETUP-D`, one completed install with two authorized
users.

**Action:** perform each of the following separately, with the collector
logging receipt timestamps, and probe `GET /oauth2/me` every 10 seconds
before and after each action:
1. The second user revokes their own authorization in Pumble.
2. The add-on calls `DELETE /v1/app/authorization` with the second user token.
3. The workspace owner uninstalls the app from the workspace UI.
4. On a fresh install, the add-on calls `DELETE /v1/app/installation`.

**Expected observation:** the event name, the `accessGranted` value, the field
set, the ordering relative to the first `401`, and whether a self-initiated
uninstall (action 4) produces the same callback as an owner-initiated one
(action 3).

**Cleanup:** reinstall the probe app for later probes, or leave the workspace
clean if this is the last probe of the session.

**Affects:** uninstall and unauthorized handling, and tenant-data teardown.

---

## PR-07 — Exact scope matrix

> **Source note (2026-08-15).** Narrowed, not closed. The **vocabulary** is
> now a closed set of sixteen strings, published by the vendor as "the list of
> all available scopes" (SDK docs: `docs/api-client.md`, section "Scopes"):
> `messages:read`, `messages:write`, `messages:edit`, `messages:delete`,
> `attachments:write`, `user:read`, `status:write`, `reaction:read`,
> `reaction:write`, `channels:list`, `channels:read`, `channels:write`,
> `users:list`, `workspace:read`, `calls:write`, `files:write`. This closes
> matrix `S-3` (`reaction:write`), `S-7` (`workspace:read`), and `S-9`
> (`reaction:read`, described as "Receive reactions") at the level of *which
> string*, and it lets step 1 use a much smaller candidate grid. It does
> **not** close the **mapping**: vendor prose is not server enforcement.
> Steps 2, 3, and 4 still run. One finding makes the probe more urgent, not
> less: **the catalog contains no Home-view scope**, so matrix `S-8` (A-15,
> `publishHomeView`) is now *more* uncertain — either it needs no scope, or it
> rides on another, or the catalog is incomplete despite its claim. Test A-15
> explicitly. Source also confirms the SDK enforces nothing client-side: the
> only reader of `manifest.scopes` in the entire tree is the consent-URL
> builder (SDK source: `pumble-sdk/src/core/services/ClientUtils.ts`,
> `generateAuthUrl()`).

**Unknown:** exact scope mapping. Source-matrix section 8, rows `S-1` to `S-12`.

**Hypothesis:** each product operation requires exactly one documented scope,
and the strings observed in the example manifests are the full set the product
needs.

**Weakest acceptable conclusion:** for every operation in source-matrix section 6.1
to 6.3 and for every subscribed event, the minimum scope set under which the
call succeeds and the exact `403` body when it is missing. If a required scope
cannot be identified, the add-on requests the configured superset and never
auto-disables a workflow on a scope inference.

**Setup:** `SETUP-A`, `SETUP-B`. Use several probe app registrations, each
declaring a different narrow scope set, so scopes can be varied without
re-editing one app repeatedly.

**Action:**
1. Install with the minimal plausible scope set for each operation group.
2. Call every operation `A-1` to `A-6`, `A-8` to `A-15`, `A-19`, `A-20` once
   with the bot token and once with the user token. Record status per call.
3. Add one scope at a time and repeat the failing calls.
4. For each subscribed event, record whether the event still arrives when the
   related read scope is absent.
5. Record the complete scope list the consent screen displays, and the
   `grantedScopes` array from an `APP_UNAUTHORIZED` callback.

**Expected observation:** an operation-to-scope table with observed status
codes, and the authoritative scope-string list from the consent screen.

**Cleanup:** uninstall every probe registration; delete probe channels and
messages created during the write calls.

**Affects:** scope snapshots, action-node authorization, and reinstall scope
revalidation.

---

## PR-08 — Rate-limit headers and `429` shape

> **Source note (2026-08-15).** Still fully open. A repository-wide search of
> the SDK source and its documentation for `429`, `Retry-After`, and "rate
> limit" returns **zero** matches, which is a finding about the vendor client,
> not about the server. Source confirms the client has no defence whatsoever:
> `BaseApiClient.request()` is a single axios call with no interceptor, no
> retry, no backoff, and no concurrency cap (SDK source:
> `pumble-sdk/src/api/BaseApiClient.ts`; `api/ApiClient.ts` creates the axios
> instances without interceptors). The Elixir client must add pacing of its
> own regardless of what this probe finds (matrix `D-6`).

**Unknown:** rate-limit headers. Matrix rows `H-12` to `H-15`.

**Hypothesis:** the Pumble API returns `429` with a `Retry-After` header and
with limit and remaining headers.

**Weakest acceptable conclusion:** whether any `429` can be produced at all
from a sacrificial workspace at a safe request rate, and if so the exact
header names and the response body. If no `429` is produced, the client keeps
a conservative fixed concurrency limit and treats a missing `Retry-After` as
"back off by a default interval".

**Setup:** `SETUP-A`, `SETUP-B`, one install. A rate ramp script with a hard
stop.

**Action:** call the cheapest read operation (`GET /oauth2/me`) in a ramp: 1,
2, 5, 10, 20 requests per second, each step for 10 seconds, stopping at the
first non-`2xx`. Record all response headers for the last `2xx` and for the
first non-`2xx`. Repeat once with a write operation (`A-1` to the probe
channel) at a much lower ramp: 1, 2, 5 per second, maximum 60 total messages.

**Expected observation:** the first limiting status, its headers, and its body.

**Cleanup:** delete every probe message created by the write ramp. Cap total
write volume at 60 messages.

**Affects:** Pumble client error classification and action pacing.

---

## PR-09 — Server-side idempotency on writes

> **Source note (2026-08-15).** Still fully open — deduplication is server
> behavior. Source resolves one sub-question in step 2: **the SDK never sends
> `localId` on an outbound write.** `processMessagePayload()` builds exactly
> `{text, blocks, attachments, files}` and drops everything else (SDK source:
> `pumble-sdk/src/api/v1/MessagesApiClientV1.ts`). `lId` appears only on the
> **inbound** `NotificationMessage` (SDK source:
> `core/types/pumble-events.ts`). So `localId` is not a client-supplied
> idempotency key in the vendor client; step 2 must first establish whether
> the API accepts the field at all before it can test deduplication with it.
> No request in the whole client carries any idempotency header or key.

**Unknown:** server-side write idempotency. Matrix row `U-3`.

**Hypothesis:** Pumble does not deduplicate writes; two identical
`postMessageToChannel` calls create two messages, and there is no client-side
idempotency key field.

**Weakest acceptable conclusion:** whether repeating a byte-identical write
creates a duplicate, and whether `localId` (`Message.localId`, matrix `G03`
5.6) or any other request field influences deduplication. If nothing
deduplicates, the safety rule stands: an external write with an ambiguous
outcome pauses and never retries automatically.

**Setup:** `SETUP-A`, `SETUP-B`, one install, one probe channel.

**Action:**
1. Post the same text twice with identical bodies; count resulting messages.
2. Post twice with the same `localId` value, if the API accepts the field on
   the request; count resulting messages and record whether the field is
   echoed back.
3. Add the same reaction code twice to one message; record the second status.
4. Remove a reaction that is not present; record the status.

**Expected observation:** duplicate counts and the status codes for repeated
reaction writes (these decide whether reaction actions are safely retryable).

**Cleanup:** delete every probe message and reaction created.

**Affects:** retry and resume semantics and action safety classification.

---

## PR-10 — App-generated message metadata and self-trigger loops

> **Source note (2026-08-15).** Narrowed. The *detection rule* is
> `RESOLVED BY SOURCE`: when `includeBotMessages` is falsy the SDK awaits
> `getBotUserId()` and drops the event if `payload.body.aId === botUserId`,
> where `getBotUserId()` returns the bot client's `workspaceUserId`, i.e. the
> `botId` stored at token exchange (SDK source:
> `pumble-sdk/src/core/services/AddonService.ts`, `message()` and
> `createEventContext()`; `core/services/ClientUtils.ts`, `getBotClient()`;
> `auth/stores/JsonFileTokenStore.ts`, `getBotUserId()`). No subtype, no flag,
> and no API lookup is used. Matrix `N-4` is upgraded to `SUPPORTED` and `N-7`
> is no longer an assumption — it is exactly what the vendor SDK does.
>
> **Still open, and now more strongly implied:** whether a bot-posted message
> is delivered back to the same app (matrix `N-6`). The existence of an
> `includeBotMessages` option defaulting to `false`, together with an explicit
> author-id drop, would be dead code if the server never sent them. **Assume
> self-trigger loops are possible** until step 1 proves otherwise. Steps 1 to
> 6 all still run; step 6 (the `st` value list, matrix `N-5`) is untouched by
> source, which types `st` as a bare `string` and never reads it.

**Unknown:** Pumble-generated message metadata. Matrix rows `N-1` to `N-7`.

**Hypothesis:** a message posted by the add-on bot produces a `NEW_MESSAGE`
callback to the same add-on, and the callback carries a distinguishing marker
in `st` (subtype) or an author ID equal to the bot user ID.

**Weakest acceptable conclusion:** whether a bot-posted message is delivered
back to the same app, and which single field reliably identifies it. If no
field is reliable, the add-on suppresses self-triggering by comparing the
author `aId` with the stored bot user ID and records the residual risk.

**Setup:** `SETUP-A` to `SETUP-D`, one install with a bot token, one probe
channel.

**Action:**
1. Post a message with the bot token; observe whether a `NEW_MESSAGE`
   callback arrives, and capture the full payload.
2. Post an ephemeral message; observe whether a callback arrives and whether
   `eph` is true.
3. Post a threaded reply; capture `trId`, `stc`, and `trMt`.
4. Post a message with `blocks` and with `attachments`; capture `bl` and `att`.
5. Post a message as a human user for comparison, and diff the two payloads
   field by field.
6. Record every distinct `st` value seen across all captures.

**Expected observation:** the field-level diff between a bot message and a
human message, and the `st` value list.

**Cleanup:** delete all probe messages, including ephemeral ones where
deletion is possible.

**Affects:** trigger binding and loop prevention.

---

## PR-11 — Workspace role values

> **Source note (2026-08-15).** Still fully open. Source confirms the premise
> of the conservative rule rather than the hypothesis: both `role` on the API
> type and `ro` on `NotificationWorkspaceUserJoined` are typed as bare
> `string`, with no enum, union, or constant anywhere in the SDK (SDK source:
> `pumble-sdk/src/api/v1/types.ts`, `WorkspaceUser`;
> `core/types/pumble-events.ts`, `NotificationWorkspaceUserJoined.ro`). The
> vendor client therefore treats the role set as open, which is the behavior
> the add-on must also adopt. `status` / `st` are likewise bare strings.

**Unknown:** exact workspace role values. Matrix row `U-4`.

**Hypothesis:** `WorkspaceUser.role` and the `ro` field on
`WORKSPACE_USER_JOINED` use the same small closed set of uppercase strings.

**Weakest acceptable conclusion:** the exact strings observed for owner,
admin, and regular member on the sacrificial workspace. The add-on must treat
the set as open and must never fail closed on an unrecognized role string; it
maps unknown roles to the least-privileged internal role.

**Setup:** `SETUP-A` with at least three members holding different Pumble
roles, `SETUP-B`, one install with the user-list scope.

**Action:** call `GET /v1/workspaceUsers` and `GET /v1/workspaceUsers/{id}`;
record the distinct `role` and `status` values. Change one member's role in
the Pumble UI and re-read. Invite one new member and capture `ro` on the
`WORKSPACE_USER_JOINED` callback.

**Expected observation:** the observed value set for `role`, `status`, and
`ro`, and whether the event field and the API field agree.

**Cleanup:** restore the changed member role; deactivate the invited test
member.

**Affects:** member and role mapping.

---

## PR-12 — Callback and message size limits

> **Source note (2026-08-15).** Still fully open — every limit named here is
> enforced by the server. Source resolves one detail of step 2: **the 20-file
> cap is enforced client-side by the SDK**, which throws
> `"Message can not have more than 20 files."` before issuing any request
> (SDK source: `pumble-sdk/src/api/v1/MessagesApiClientV1.ts`,
> `processFiles()`). That is a vendor client rule, so the *server* limit is
> still unknown and step 2 should attempt 20 and note that going higher cannot
> be tested through the SDK. No inbound callback size limit exists anywhere in
> the SDK: the `rawBody()` middleware accumulates chunks without any cap (SDK
> source: `core/adapters/http/middlewares.ts`), so the Elixir transport must
> impose its own cap and reject oversized bodies **before** parsing.

**Unknown:** callback and message size limits. Matrix row `U-5`.

**Hypothesis:** the largest inbound callback is bounded by the largest
possible message payload, and a message `text` above 100000 characters is
rejected with `400`.

**Weakest acceptable conclusion:** an observed upper bound for the inbound
callback body in bytes, and the status code and error body when an outbound
message exceeds the limit. The transport's own body cap must be set above the
observed maximum plus a margin, and must reject larger bodies before parsing.

**Setup:** `SETUP-A` to `SETUP-D`, one install, one probe channel. The
collector records `Content-Length` and the actual byte count for every
request.

**Action:**
1. Post messages of increasing size (1 KB, 10 KB, 40 KB, 100 KB of text) and
   record both the API status and the inbound callback byte size.
2. Post a message with the maximum documented 20 files (small placeholder
   files with the probe prefix) and record the callback byte size.
3. Post a message with a large `blocks` array (100 blocks) and record both.
4. Attempt one message above the documented 100000-character limit and record
   the rejection status and body.

**Expected observation:** the largest callback observed in bytes, and the
rejection behavior at the text limit.

**Cleanup:** delete every probe message and every uploaded probe file.

**Affects:** callback body-size rejection and action payload validation.

---

## PR-13 — Marketplace launch-link behavior

> **Source note (2026-08-15).** Still fully open. Source confirms the
> hypothesis' premise: `listingUrl`, `helpUrl`, `welcomeMessage`, and
> `offlineMessage` are optional `string` fields on the manifest type that the
> SDK **never reads** — they pass through `prepareForServing` untouched and
> have no runtime consumer anywhere in the tree (SDK source:
> `pumble-sdk/src/core/types/types.ts`, `type AddonManifest`;
> `core/util/ManifestProcessor.ts`). Whatever identity Pumble does or does not
> attach to a launch link is entirely server-side, so this probe is
> unavoidable. The conservative rule stands: the console authenticates
> independently and never trusts a URL parameter for tenancy.

**Unknown:** app launch-link identity behavior. Matrix row `M-12`.

**Hypothesis:** `listingUrl` opens the add-on console in a browser with no
Pumble-supplied identity, so the console must authenticate the user
independently.

**Weakest acceptable conclusion:** whether Pumble appends any query parameter,
fragment, or header identifying the workspace or the user when a member opens
the add-on from the marketplace listing, the Home view, or the app directory.
If nothing identifying is supplied, the console requires its own sign-in and
never trusts a URL parameter for tenancy.

**Setup:** `SETUP-A`, `SETUP-B`, one install, `listingUrl` and `helpUrl`
pointing at collector paths that log the full request line and headers.

**Action:** as the owner and as the second member, open the add-on from every
entry point available in the Pumble client: the marketplace listing, the
installed-apps list, the Home view, and the help link. Record each inbound
request.

**Expected observation:** query string, referrer, and any Pumble-specific
header on each entry point.

**Cleanup:** none. Reset `listingUrl` and `helpUrl` after the probe.

**Affects:** marketplace listing behavior and live validation.

---

## PR-14 — Slash, shortcut, and modal response ordering

> **PARTLY `RESOLVED BY SOURCE`.**
>
> **Response ordering — `RESOLVED BY SOURCE`: SDK source
> `pumble-sdk/src/core/adapters/http/AddonHttpListener.ts`, `ackFunction()` /
> `nackFunction()` / `responseFunction()` (all guarded by
> `if (!res.headersSent)`) and `core/services/AddonService.ts`,
> `createViewContext()` / `createViewFunctionActionContext()` (modal helpers
> are wrappers over the same single `response` callback).** On HTTP there is
> exactly one response per callback; the first writer wins and later calls are
> silent no-ops. `ack()` before `spawnModalView()` therefore discards the
> modal. Corroborated by SDK docs `docs/modals-views.md`
> ("no need to call ctx.ack when pushing new modal") and by
> `examples/addon-pumble-zendesk/src/index.ts`, whose global-shortcut handler
> acks **only** when the modal was not spawned. Matrix `X-1` is `RESOLVED`.
> **Strategies 1 to 4 below need not be run.** Strategy 1 (modal only, no ack)
> is the one the port implements.
>
> **`loadingTimeout` — `RESOLVED BY SOURCE`: SDK source
> `core/services/AddonService.ts`, the `blockInteraction*` wrappers and
> `notifyBlockInteractionProcessingCompleted()`;
> `api/v1/InteractionsClientInternalV1.ts`, `completeProcessing()`.**
> `loadingTimeout` is a per-block-element spinner duration in seconds
> (SDK docs `docs/blocks.md`), ended by `POST /v1/interactions/complete`, not
> by `ack` or `updateView`. It does **not** extend the acknowledgement
> deadline. Matrix `X-6` is `RESOLVED`. **The `loadingTimeout` half of step 5
> need not be run**, and the port sidesteps the internal endpoint entirely by
> emitting `loadingTimeout: 0` (matrix `D-5`).
>
> **Still open:** what the server does on a late or missing response — the
> 3-second deadline is vendor documentation only (SDK docs
> `docs/basic-concepts.md:231`), and no source sets or observes a timer. Run
> **only the first half of step 5**: delay the response past 3 s and record
> what the user sees and whether a retry follows. This overlaps `PR-02`; run
> the two together. Matrix rows `K-7`, `K-9`.

**Unknown:** slash, shortcut, and modal response ordering. Matrix
contradictions `X-1` and `X-6`, rows `K-7` to `K-9`.

**Hypothesis:** on HTTP transport, exactly one response may be written per
callback. `ack()` followed by `spawnModalView()` sends only the ack, and no
modal opens, contrary to the example code in the corpus.

**Weakest acceptable conclusion:** for each of the four response strategies
below, whether the modal opened and whether the user saw an error. The
transport then implements only the strategy proven to work, and this register
records the corpus examples as unreliable.

**Setup:** `SETUP-A` to `SETUP-D`. The collector must be able to select the
strategy per invocation, for example by the slash command text.

**Action:** invoke the slash command, the global shortcut, the message
shortcut, a block interaction, and a view action once per strategy:
1. Send only the modal envelope, no ack.
2. Send an ack, then attempt the modal envelope on the same response.
3. Send the modal envelope, then attempt an ack.
4. Send an ack, wait 1 s, and attempt to open the modal through a second,
   separate HTTP call to the Pumble API, if any such endpoint is discoverable.
5. Separately, delay the response past 3 s and then past a block
   `loadingTimeout` of 15 s, and record whether the 15 s value extends the
   deadline for block interactions.

**Expected observation:** for each combination, whether the modal appeared,
what the Pumble client displayed, and how long the spinner ran. The operator
records the user-visible outcome, since it cannot be read from the wire.

**Cleanup:** close all opened modals; delete any messages the strategies
posted.

**Affects:** per-class callback responses and console modal behavior.

---

## PR-15 — OAuth redirect and error payloads

> **Source note (2026-08-15).** Still fully open — every error shape here is
> produced by the server. Source sharpens the probe in two ways, one of which
> is a security finding. (1) The exchange request is fully pinned: a
> `multipart/form-data` `POST` to `{PUMBLE_API_URL}/oauth2/access` with exactly
> three hyphenated fields `client-id`, `client-secret`, `code`, sent through a
> bare axios call that carries **neither** the `token` nor the `x-app-token`
> header (SDK source: `pumble-sdk/src/auth/OAuth2Client.ts`,
> `generateAccessToken()`). (2) **The SDK never validates `state`.** It
> generates the parameter in `generateAuthUrl()` but the built-in redirect
> handler reads only `req.query['code']`, treats its absence as the sole error
> case, and ignores `state`, `error`, and `error_description` entirely (SDK
> source: `core/services/AddonService.ts`, `setupOAuth()`; contrast
> `core/services/ClientUtils.ts`, `generateAuthUrl()`). The Elixir port must
> implement strict `state` validation itself — a deliberate divergence
> recorded as matrix `D-2` — so **step 3 tests the port's own behavior, not
> Pumble's**, and must still be run. Steps 4 to 7 are unaffected.

**Unknown:** OAuth redirect and error payloads. Source-matrix row `A-16`,
source-matrix section 6.3.

**Hypothesis:** the redirect carries `code` and the `state` value unchanged as
query parameters, and a denied consent returns an error parameter rather than
no request at all.

**Weakest acceptable conclusion:** the exact query parameter names on a
successful redirect, on a denied consent, and on an invalid request; plus the
status code and body of `POST /oauth2/access` for a reused code, an expired
code, a wrong client secret, and a wrong redirect URL. The state check must
stay strict regardless of the result.

**Setup:** `SETUP-A`, `SETUP-B`. The redirect URL points at a collector path
that logs the full request line without following any further redirect.

**Action:**
1. Complete consent normally; record the redirect query parameters.
2. Deny consent; record what arrives, if anything.
3. Complete consent with a `state` value the collector then rejects; confirm
   the add-on refuses the exchange.
4. Exchange the same code twice; record the second response status and body.
5. Exchange with a deliberately wrong client secret; record status and body.
6. Exchange a code after 15 minutes; record status and body.
7. Send the consent request with a redirect URL that is not registered;
   record what the consent screen shows.

**Expected observation:** parameter names, error names, and the error body
shape for each failure mode.

**Cleanup:** uninstall any install created by step 1; rotate the sacrificial
client secret after step 5.

**Affects:** OAuth install endpoint and error handling.

---

## PR-16 — Callback classification and `messageType` values

> **Source note (2026-08-15).** Narrowed. The **guard-exclusivity** half
> (matrix `X-5`) is `RESOLVED BY SOURCE` at the client level: every guard is an
> equality test on a single-valued field — `messageType`, then `type`
> (`'GLOBAL'` / `'ON_MESSAGE'`) or `sourceType` (`'VIEW'` / `'MESSAGE'` /
> `'EPHEMERAL_MESSAGE'`) — so no well-formed body can match two classes (SDK
> source: `pumble-sdk/src/core/types/payloads.ts`). The guides' "a message
> could theoretically match multiple guards" describes defensive style, not an
> observed case. It is nonetheless a real hazard in the vendor client:
> `handleMessage()` gives the block-interaction trio, `isDynamicMenuInteraction`
> and `isViewAction` sequential `if`s with **no** early `return`, so a
> dual-matching body would dispatch twice (SDK source:
> `core/adapters/http/AddonHttpListener.ts`). The port rejects such a body as
> malformed instead (matrix `D-3`).
>
> **The `messageType` half (matrix `X-3`) stays fully open.** Source does not
> decide it either: `isPumbleEvent()` accepts `PUMBLE_EVENT` **or**
> `APP_EVENT`, nothing downstream branches on the choice, and no event-name to
> `messageType` mapping exists anywhere in the SDK. The tidy guess "lifecycle
> events use `APP_EVENT`" remains a guess and must not be coded as fact. This
> probe's main remaining job is to build the event-name to `messageType` table.

**Unknown:** source-matrix contradictions `X-3` and `X-5`, section 2.3.

**Hypothesis:** ordinary events use `messageType: 'PUMBLE_EVENT'`, lifecycle
events use `'APP_EVENT'`, and no callback ever matches two classification
guards.

**Weakest acceptable conclusion:** the observed `messageType` value for each
of the seven documented events and for each interaction class. If a callback
were ever to match two classes, the Elixir classifier must reject it as
malformed rather than dispatch twice.

**Setup:** `SETUP-A` to `SETUP-D`. The collector classifies each body against
all nine guards independently and logs every guard that matched.

**Action:** trigger all seven documented events and all nine callback classes
from `PR-01`, plus the uninstall and unauthorized actions from `PR-06`.

**Expected observation:** a table of event name to `messageType`, and the
count of callbacks that matched more than one guard (expected: zero).

**Cleanup:** shared with `PR-01` and `PR-06`.

**Affects:** callback classification.

---

## PR-17 — Reaction write semantics and dynamic-menu response contract

> **Source note (2026-08-15).** Narrowed. Both **client-side** forms are now
> pinned, so steps 1 and 3 become confirmations rather than discoveries;
> server acceptance still has to be observed.
> - `removeReaction` issues `{method:'delete', url:'/v1/messages/{id}/reactions',
>   data: request}` — the reaction code goes in the **body** of a `DELETE`, and
>   the SDK offers no query-parameter form at all (SDK source:
>   `pumble-sdk/src/api/v1/MessagesApiClientV1.ts`, `removeReaction()`). The
>   same body-on-`DELETE` pattern appears on `deleteEphemeralMessage`, so it is
>   a house convention, not a slip. **Step 2 (query-parameter form) is the only
>   genuinely open reaction question** and is now a "does the server also
>   accept it" test, not a "which form is correct" test.
> - The dynamic-menu response envelope is pinned to
>   `{onAction, options, triggerId, value?}`, where `onAction` and `triggerId`
>   are echoed verbatim from the request payload and `value` is echoed when
>   present; an empty or absent options result calls `nack` instead of
>   `response` (SDK source: `core/services/AddonService.ts`,
>   `dynamicSelectMenu()`; type `DynamicMenuOptionsResponse` in
>   `core/types/payloads.ts`). **Step 4 stays fully open** — which of those
>   fields the *server* actually requires cannot be read from the client, and
>   the SDK simply always sends all of them.

**Unknown:** matrix rows `A-6` (a `DELETE` carrying a body) and `K-4`
(dynamic-menu response), both of which the product depends on.

**Hypothesis:** `DELETE /v1/messages/{id}/reactions` requires the reaction
code in the request body and rejects a query-parameter form; the dynamic-menu
response must echo `onAction` and `triggerId` exactly, or Pumble shows no
options.

**Weakest acceptable conclusion:** whether the Elixir HTTP client must send a
body on `DELETE`, and which fields of the dynamic-menu response are mandatory.
If a form cannot be proven, the client uses the form the corpus documents and
nothing else.

**Setup:** `SETUP-A` to `SETUP-D`, one install, one probe channel, one probe
message carrying a `dynamic_select_menu`.

**Action:**
1. Remove a reaction with the code in the body; record the status.
2. Remove a reaction with the code as a query parameter and an empty body;
   record the status.
3. Answer a dynamic-menu callback with the full documented envelope; confirm
   options appear.
4. Answer with `onAction` omitted, then with `triggerId` omitted, then with an
   empty `options` array, then with `nack`. Record what the user sees in each
   case.
5. Answer later than 3 s and record what the menu shows.

**Expected observation:** the working reaction-removal form and the minimum
valid dynamic-menu response.

**Cleanup:** delete the probe message carrying the menu and any reactions
added during the probe.

**Affects:** reaction actions and console dynamic pickers.

---

## Coverage check

### Product unknowns, one probe each

| Unknown | Probe |
|---|---|
| stable unique delivery identities for all callback types | `PR-01` |
| exact replay behavior | `PR-02` |
| signature-header precedence and any timestamp header | `PR-03` |
| OAuth token expiry and refresh behavior | `PR-04` |
| reinstall token replacement | `PR-05` |
| uninstall/unauthorized event ordering | `PR-06` |
| exact scope matrix | `PR-07` |
| Pumble rate-limit headers | `PR-08` |
| Pumble server-side idempotency | `PR-09` |
| app-generated message metadata | `PR-10` |
| exact Pumble role values | `PR-11` |
| callback and message size limits | `PR-12` |
| Marketplace launch-link behavior | `PR-13` |

### Required probe topics

| Required topic | Probe |
|---|---|
| callback retry behavior and stable event IDs | `PR-02`, `PR-01` |
| slash / shortcut / modal response ordering | `PR-14` |
| OAuth redirect and error payloads | `PR-15` |
| reinstall token replacement | `PR-05` |
| exact scope mapping | `PR-07` |
| rate-limit headers | `PR-08` |
| Pumble-generated message metadata | `PR-10` |
| uninstall delivery | `PR-06` |

### Matrix `PROBE REQUIRED` rows, one probe each

| Matrix rows | Probe | State after the 2026-08-15 source cross-check |
|---|---|---|
| `I-1` to `I-8` | `PR-01` | open; field presence proven, uniqueness not |
| `K-9`, `K-10`, `U-1` | `PR-02` | open |
| `H-8`, `H-9`, `X-2` | `PR-03` | **resolved by source**; rows upgraded to `SUPPORTED` |
| `H-10` | `PR-03` | existence resolved by source; **unit and format still open** |
| `A-21`, `U-2` | `PR-04` | narrowed; exchange-response shape resolved by source |
| `A-22` (verification) | `PR-05` | client store resolved by source; server side open |
| `L-1`, `L-2` notes | `PR-06` | open |
| `S-3`, `S-7`, `S-9` | `PR-07` | scope **string** resolved by SDK docs; enforcement open |
| `S-8`, `S-10`, `S-11`, `S-12` | `PR-07` | open; `S-8` widened by the closed catalog |
| `H-12`, `H-14` | `PR-08` | open |
| `U-3` | `PR-09` | open; `localId` shown not to be sent by the client |
| `N-4` | `PR-10` | **resolved by source** (`aId === botUserId`) |
| `N-5`, `N-6` | `PR-10` | open; `N-6` strongly implied by `includeBotMessages` |
| `U-4` | `PR-11` | open; both fields confirmed to be open strings |
| `U-5` | `PR-12` | open; the 20-file cap shown to be client-side |
| `M-12`, `U-6` | `PR-13` | open; manifest fields confirmed inert client-side |
| `X-1` | `PR-14` | **resolved by source**; one response per callback |
| `X-6` | `PR-14` | **resolved by source**; `loadingTimeout` is not a deadline |
| `K-7`, `K-9` (late/missing ack) | `PR-14` | open |
| `A-16` error shape | `PR-15` | open; request form pinned, `state` gap found |
| `X-5` | `PR-16` | **resolved by source** at client level; dual-match open |
| `X-3`, source-matrix section 2.3 `messageType` mapping | `PR-16` | open |
| `A-6` alternative form, `K-4` minimum fields | `PR-17` | client forms pinned by source; server acceptance open |

Every `PROBE REQUIRED` row in `pumble_source_matrix.md` maps to at least one
probe. Every probe names the component its result affects. Rows resolved by
source keep their probe reference so claim-to-evidence traceability stays
intact.

### Probes and probe steps resolved by source, 2026-08-15

| Probe | Resolved | Still to run |
|---|---|---|
| `PR-03` | header names, algorithm, signing string, encoding, rejection status, absence of a fallback header | timestamp unit and format only |
| `PR-14` | strategies 1 to 4 (response ordering); the `loadingTimeout` half of step 5 | the late-response half of step 5, jointly with `PR-02` |
| `PR-04` | step 1 (exchange-response shape) | steps 2 and 3 (long-interval validity) |
| `PR-10` | the bot-message detection rule (matrix `N-4`) | steps 1 to 6 for delivery and `st` values |
| `PR-16` | guard exclusivity (matrix `X-5`) at the client level | the `messageType` mapping (matrix `X-3`) |
| `PR-17` | the client-side request forms in steps 1 and 3 | step 2, step 4, step 5 |
| `PR-07` | the scope **vocabulary** (sixteen strings) | the whole operation-to-scope mapping |

No probe was deleted and no probe was renumbered.
