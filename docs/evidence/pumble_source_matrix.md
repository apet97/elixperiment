# Pumble source-evidence matrix

Date: 2026-08-15. Last verified: 2026-08-25.

This matrix converts the supplied Pumble corpus into a traceable protocol
record for the Elixir/Phoenix port. Every protocol claim used by the product
contract appears here with a status and a source.

## Status vocabulary

| Status | Meaning |
|---|---|
| `SUPPORTED` | The supplied corpus states the item directly. |
| `INFERRED` | The corpus does not state the item. This matrix derives it. An inference is not evidence. |
| `PROBE REQUIRED` | The corpus is silent, ambiguous, or self-contradictory. A live probe must decide it. See `pumble_probe_register.md`. |

## Source keys

| Key | File |
|---|---|
| `G01` | Supplied snapshot: `01-overview-and-project-map.md` (not stored in this repository) |
| `G02` | Supplied snapshot: `02-core-framework-auth-and-runtime.md` (not stored in this repository) |
| `G03` | Supplied snapshot: `03-api-clients-and-v1-type-system.md` (not stored in this repository) |
| `G04` | Supplied snapshot: `04-events-contexts-interactivity-and-blocks.md` (not stored in this repository) |
| `G05` | Supplied snapshot: `05-cli-examples-docs-and-deployment.md` (not stored in this repository) |
| `SDK` | Public [Pumble Node SDK at commit `36bb7ed`](https://github.com/CAKE-com/pumble-node-sdk/tree/36bb7edf091b9d24b39d6e70302ebbb3a1759fe3). Row citations use `SDK source:` with a path relative to that root plus the function name. |
| `SDKDOC` | Markdown documentation shipped inside the same SDK repository (`docs/`). Cited as `SDK docs:`. This is vendor documentation, not executable source, and never proves server behavior. |
| `CLI` | Published `pumble-cli` 1.1.11 package (`dist/`) and its matching public [source at commit `4ba6ff9`](https://github.com/CAKE-com/pumble-node-sdk/tree/4ba6ff96bec4abebd345d891effd33568d20e802/pumble-cli). Row citations name the published file first and the source path when useful. |

## Corpus limits (read before using any row)

1. **The Node SDK source was cross-checked on 2026-08-15.** Rows carrying an
   `SDK source:` citation were verified against the exact public commit linked
   above.
   Rows without one still rest on guide content only. **The guides were found
   to be wrong on the signature contract** (see `X-2` and `H-7`); treat any
   uncited guide claim about wire details as unverified.
2. **The SDK source describes an SDK client, not the Pumble server.** It proves
   what the Node SDK sends, accepts, computes, and requires. It does not prove
   what the Pumble server does: retries, replay, rate limits, expiry, scope
   enforcement, and event ordering are all server behavior and stay
   `PROBE REQUIRED` no matter how clear the client code is.
3. **Only the seven documented subscribed events are proven** (`G04` section
   1.1). No other event name may be treated as real.
4. No token, signing secret, workspace ID, app ID, or private message content
   is recorded in this file.

---

## 1. Callback classes

The transport receives one POST per callback. `G02` section 7.1 and `G04`
section 2.3 list the classification guards. `G04` section 7 gives the
per-class response contract.

| # | Callback class | Wire `messageType` | Response contract | Status | Source |
|---|---|---|---|---|---|
| C-1 | Pumble event | `PUMBLE_EVENT` or `APP_EVENT` | Plain `200` body `ok`. No ack helper exists. | `SUPPORTED` | `G02` 7.1; `G04` 1.3, 6.6. SDK source: `pumble-sdk/src/core/adapters/http/AddonHttpListener.ts`, `handleMessage()` — `res.send('ok')` then async dispatch |
| C-2 | Slash command | `SLASH_COMMAND` | `ack`/`nack` within 3 s; optional `say`; optional `spawnModalView` | `SUPPORTED` | `G02` 9; `G04` 6.1, 7. SDK source: `AddonHttpListener.handleMessage()` → `AddonService.postSlashCommand()`; SDK docs: `docs/basic-concepts.md:231` (3 s) |
| C-3 | Global shortcut | `SHORTCUT` with `type='GLOBAL'` | `ack`/`nack` within 3 s; `say`; `spawnModalView` | `SUPPORTED` | `G04` 2.2, 6.2, 7. SDK source: `pumble-sdk/src/core/types/payloads.ts`, `isGlobalShortcut()`; `AddonService.postGlobalShortcut()` |
| C-4 | Message shortcut | `SHORTCUT` with `type='ON_MESSAGE'` | `ack`/`nack` within 3 s; `say` as reply; `fetchMessage`; `spawnModalView` | `SUPPORTED` | `G04` 2.2, 6.2, 7. SDK source: `payloads.ts`, `isMessageShortcut()`; `AddonService.postMessageShortcut()` |
| C-5 | Block interaction, source `VIEW` | `BLOCK_INTERACTION` with `sourceType='VIEW'` | `ack`/`nack`; `updateView`; `pushModalView` | `SUPPORTED` | `G04` 2.2, 4.3, 6.3. SDK source: `payloads.ts`, `isBlockInteractionView()`; `AddonService.postBlockInteractionView()` (context has no `say`) |
| C-6 | Block interaction, source `MESSAGE` | `BLOCK_INTERACTION` with `sourceType='MESSAGE'` | `ack`/`nack`; `say` as reply; `updateView`; `spawnModalView` | `SUPPORTED` | `G04` 4.3, 6.3. SDK source: `payloads.ts`, `isBlockInteractionMessage()`; `AddonService.postBlockInteractionMessage()` |
| C-7 | Block interaction, source `EPHEMERAL_MESSAGE` | `BLOCK_INTERACTION` with `sourceType='EPHEMERAL_MESSAGE'` | `ack`/`nack`; `updateView`; `spawnModalView` | `SUPPORTED` | `G04` 4.3, 6.3. SDK source: `payloads.ts`, `isBlockInteractionEphemeralMessage()`; `AddonService.postBlockInteractionEphemeralMessage()` |
| C-8 | View action | `VIEW_ACTION` with `viewActionType='SUBMIT'` or `'CLOSE'` | `ack`/`nack`; optional `spawnModalView` | `SUPPORTED` | `G04` 2.2, 6.5. SDK source: `payloads.ts`, `isViewAction()` and `ViewActionPayload`; `core/types/types.ts`, `ViewActionType = 'SUBMIT' \| 'CLOSE'` |
| C-9 | Dynamic menu | `DYNAMIC_MENU` | `response({onAction, options, triggerId, value?})` or `nack`. No `ack`. | `SUPPORTED` | `G04` 4.3, 6.4. SDK source: `AddonHttpListener.handleMessage()` passes only `response` and `nack` to `postDynamicSelectMenu()`; `AddonService.dynamicSelectMenu()` builds the echo envelope |

Notes:

- The `MessageType` enum has exactly seven values (`SLASH_COMMAND`,
  `SHORTCUT`, `APP_EVENT`, `PUMBLE_EVENT`, `BLOCK_INTERACTION`,
  `DYNAMIC_MENU`, `VIEW_ACTION`). `SHORTCUT` splits into C-3 and C-4 by the
  `type` field, and `BLOCK_INTERACTION` splits into C-5 to C-7 by
  `sourceType`. `SUPPORTED`. `G04` 2.1. SDK source:
  `pumble-sdk/src/core/types/payloads.ts`, `enum MessageType`.
- **Dispatch guard order (verified).** `isPumbleEvent` first (early `return`),
  then `isMessageShortcut`, `isGlobalShortcut`, `isSlashCommand` (each with an
  early `return`), then `isBlockInteractionView`,
  `isBlockInteractionMessage`, `isBlockInteractionEphemeralMessage`,
  `isDynamicMenuInteraction`, `isViewAction` — the last five are sequential
  `if` statements with **no** `return`, so a body matching two of them would
  dispatch twice. `SUPPORTED`. SDK source:
  `pumble-sdk/src/core/adapters/http/AddonHttpListener.ts`, `handleMessage()`.
  Every guard nevertheless discriminates on a single-valued field
  (`messageType`, then `type` or `sourceType`), so a well-formed body matches
  exactly one class. See `X-5`.
- Whether the Pumble server ever sends a body matching two guards is server
  behavior and stays `PROBE REQUIRED`. See `PR-16`.

---

## 2. Subscribed events

### 2.1 User-selectable workflow trigger events

The product contract exposes these five as workflow triggers.

| # | Event | Payload type | Key wire fields | Status | Source |
|---|---|---|---|---|---|
| E-1 | `NEW_MESSAGE` | `NotificationMessage` | `mId`, `wId`, `cId`, `trId`, `stc`, `trMt`, `aId`, `tx`, `bl`, `ty`, `ts`, `tsm`, `st`, `rid`, `f`, `lId`, `att`, `sm`, `mm`, `md`, `mc`, `mu`, `au`, `e`, `eph` | `SUPPORTED` | `G04` 1.1, 1.2. SDK source: `pumble-sdk/src/core/types/pumble-events.ts`, `type NotificationMessage` |
| E-2 | `UPDATED_MESSAGE` | `NotificationMessage` | same field set as E-1 | `SUPPORTED` | `G04` 1.1, 1.2. SDK source: `pumble-events.ts`, `EventMap` |
| E-3 | `REACTION_ADDED` | `NotificationReaction` | `wId`, `cId`, `mId`, `mat` (message author), `uId` (reactor), `rc` (code), `ty`, `rid` | `SUPPORTED` | `G04` 1.2. SDK source: `pumble-events.ts`, `type NotificationReaction` |
| E-4 | `CHANNEL_CREATED` | `NotificationChannel` | `wId`, `cId`, `cN`, `cU`, `cT`, `ty`, `rid` | `SUPPORTED` | `G04` 1.2. SDK source: `pumble-events.ts`, `type NotificationChannel` |
| E-5 | `WORKSPACE_USER_JOINED` | `NotificationWorkspaceUserJoined` | `uId`, `uN`, `uE`, `afp`, `asp`, `wId`, `ty`, `tz`, `sts`, `pt`, `pp`, `cs`, `rid`, `st`, `ro`, `au`, `ib` | `SUPPORTED` | `G04` 1.2. SDK source: `pumble-events.ts`, `type NotificationWorkspaceUserJoined` |

The `EventMap` in `pumble-sdk/src/core/types/pumble-events.ts` has exactly
seven keys, which confirms corpus limit 3: `REACTION_ADDED`, `NEW_MESSAGE`,
`UPDATED_MESSAGE`, `CHANNEL_CREATED`, `APP_UNINSTALLED`, `APP_UNAUTHORIZED`,
`WORKSPACE_USER_JOINED`. No other event name is typed by the SDK.

There is no documented `REACTION_REMOVED`, no message-deleted event, and no
channel-membership event. A remove-reaction *action* exists (`A-6`), but no
matching event does. Any workflow trigger outside E-1 to E-5 is unproven.

### 2.2 Lifecycle and control-plane events

The product contract forbids these as user-selectable triggers.

| # | Event | Payload type | Key wire fields | Status | Source |
|---|---|---|---|---|---|
| L-1 | `APP_UNINSTALLED` | `NotificationAppUninstalled` | `id`, `app`, `workspace`, `installedBy`, `botUser`, `uninstalledAt` | `SUPPORTED` | `G04` 1.1, 1.2. SDK source: `pumble-sdk/src/core/types/pumble-events.ts`, `type NotificationAppUninstalled` |
| L-2 | `APP_UNAUTHORIZED` | `NotificationAppUnauthorized` | `id`, `app`, `appInstallation`, `workspaceUser`, `workspace`, `grantedScopes[]`, `accessGranted` | `SUPPORTED` | `G04` 1.1, 1.2. SDK source: `pumble-events.ts`, `type NotificationAppUnauthorized` |

Notes:

- The two lifecycle payloads use full field names, not the abbreviated names
  used by E-1 to E-5. `SUPPORTED`. `G04` section 1.2. SDK source:
  `pumble-events.ts` — `NotificationAppUninstalled` and
  `NotificationAppUnauthorized` next to the abbreviated types in one file.
  The adapter must not assume one naming style. Note that `uninstalledAt` is
  typed `Date`, so its wire encoding (epoch millis or ISO 8601) is not proven
  by the type and must be handled defensively.
- `grantedScopes` on `APP_UNAUTHORIZED` is the only place in the corpus where
  Pumble returns a scope list at runtime. Whether the same list arrives at
  install time is `PROBE REQUIRED`. See `PR-07`.
- `accessGranted: boolean` suggests `APP_UNAUTHORIZED` may also report a
  re-grant, not only a revoke. The corpus does not say. `PROBE REQUIRED`.
  See `PR-06`.
- Whether `APP_UNINSTALLED` is delivered at all after the token is revoked,
  and in what order relative to `APP_UNAUTHORIZED`, is `PROBE REQUIRED`.
  See `PR-06`.

### 2.3 Event envelope

| Item | Detail | Status | Source |
|---|---|---|---|
| Envelope shape | `{messageType, body, eventType, workspaceId, workspaceUserIds[]}` | `SUPPORTED` | `G04` 1.3. SDK source: `pumble-sdk/src/core/types/payloads.ts`, `type PumbleEventPayload` |
| `body` is a JSON **string** on the wire | The adapter runs `JSON.parse(message.body)` before dispatch | `SUPPORTED` | `G02` 7.1; `G04` 1.3. SDK source: `core/adapters/http/AddonHttpListener.ts`, `handleMessage()`; identical in `core/adapters/socket/AddonWebsocketListener.ts`, `handleMessage()` |
| `workspaceUserIds` is deduplicated | "If more than one user that can receive this event have authorized the app they will be in this list. You will receive only one copy of the event." | `SUPPORTED` | `G04` 1.3. SDK source: `payloads.ts`, doc comment on `PumbleEventPayload.workspaceUserIds` |
| Both `PUMBLE_EVENT` and `APP_EVENT` classify as an event | `isPumbleEvent` accepts either | `SUPPORTED` | `G04` 1.3. SDK source: `payloads.ts`, `isPumbleEvent()` |
| Which `messageType` carries which event name | Not stated in the corpus and **not decided by the SDK source either**: `isPumbleEvent()` accepts both values and nothing downstream branches on the choice. Server behavior. | `PROBE REQUIRED` | `PR-16`; see `X-3` |
| Event match filters (`match`, `includeBotMessages`) | Applied inside the SDK, not by Pumble. The served manifest flattens each event declaration to its plain `name` string and drops `options` and `handler`. | `SUPPORTED` | `G02` 8.1; `G04` 6.6. SDK source: `core/util/ManifestProcessor.ts`, `prepareForServing()` (`events.map(event => event.name)`); `core/services/AddonService.ts`, `message()` and `reaction()` do the filtering after receipt |
| Consequence: the Elixir port must implement trigger filtering itself | Pumble receives only plain event names, so it cannot filter; every subscribed event is delivered and filtering is local | `SUPPORTED` | SDK source: `ManifestProcessor.prepareForServing()` (options are stripped from what Pumble is told) plus `AddonService.message()` (filtering happens on the received payload) |

---

## 3. Payload identity fields

The normalized ingress contract needs a `delivery_key` per callback.

| # | Callback class | Candidate identity field | Uniqueness | Stability across redelivery | Status | Source |
|---|---|---|---|---|---|---|
| I-1 | Pumble event (E-1 to E-5) | `rid` ("request id") | unstated | unstated | `PROBE REQUIRED` | `G04` 1.2; `PR-01` |
| I-2 | Message events | `mId` + `tsm` | identifies the message, not the delivery | an edit reuses `mId` | `PROBE REQUIRED` | `G04` 1.2; `PR-01` |
| I-3 | Slash command | `triggerId` | unstated | unstated | `PROBE REQUIRED` | `G04` 2.2; `PR-01` |
| I-4 | Global / message shortcut | `triggerId` | unstated | unstated | `PROBE REQUIRED` | `G04` 2.2; `PR-01` |
| I-5 | Block interaction | `triggerId` plus `sourceId` | unstated | unstated | `PROBE REQUIRED` | `G04` 2.2; `PR-01` |
| I-6 | View action | `triggerId` plus `view.id` | unstated | unstated | `PROBE REQUIRED` | `G04` 2.2; `PR-01` |
| I-7 | Dynamic menu | `triggerId` plus `onAction` plus `query` | keystroke-scoped | not applicable | `PROBE REQUIRED` | `G04` 2.2; `PR-01` |
| I-8 | `APP_UNINSTALLED` / `APP_UNAUTHORIZED` | `id` | unstated | unstated | `PROBE REQUIRED` | `G04` 1.2; `PR-01` |
| I-9 | Composite fallback delivery key | SHA-256 over the raw body plus the received signature | deterministic per byte-identical delivery | safe default while `PR-01` is open | `INFERRED` | `docs/architecture/delivery_semantics.md` |

No corpus statement says that `rid` or `triggerId` is unique, monotonic, or
repeated on a retry. Treating either as an idempotency key without `PR-01`
would be a convenient interpretation, not evidence.

**What the SDK source adds to `I-1` to `I-8` (annotation only, no upgrade).**
The source proves *presence and type*, never uniqueness or redelivery
stability, because those are server properties:

- `rid` is declared `string` and commented `// Request id` on every
  abbreviated event payload. SDK source:
  `pumble-sdk/src/core/types/pumble-events.ts` (`NotificationMessage`,
  `NotificationReaction`, `NotificationChannel`,
  `NotificationWorkspaceUserJoined`). The two lifecycle payloads carry `id`
  instead and have no `rid`.
- `triggerId` is a required `string` on `SlashCommandPayload`,
  `GlobalShortcutPayload`, `MessageShortcutPayload`,
  `BlockInteractionPayload`, `ViewActionPayload`, and `DynamicMenuPayload`.
  SDK source: `pumble-sdk/src/core/types/payloads.ts`.
- The SDK uses `triggerId` **only as an addressing token echoed back** in the
  modal and dynamic-menu envelopes, never as a deduplication key. SDK source:
  `core/services/AddonService.ts`, `createViewContext()`,
  `createViewFunctionActionContext()`, and `dynamicSelectMenu()`. The SDK
  performs no deduplication of any kind anywhere in the receive path.
- `sourceId` (required on `BlockInteractionPayload`) is the **source object
  id**, not a delivery id: for `sourceType='MESSAGE'` the SDK passes it as the
  message id to `fetchMessage`, and for `sourceType='VIEW'` the docs use it as
  `parentViewId`. SDK source: `AddonService.postBlockInteractionMessage()`;
  SDK docs: `docs/modals-views.md`. It must not be treated as a delivery key.
- Consequence: `I-9` (SHA-256 over the raw body plus the signature header)
  remains the working delivery key until `PR-01` closes. The source strengthens
  it rather than replacing it.

---

## 4. Acknowledgement types

| # | Mechanism | Wire result | Applies to | Status | Source |
|---|---|---|---|---|---|
| K-1 | `ack(msg?)` | `200`, `content-type: application/json`, body `{message: arg}` (`{}` when `arg` is omitted, since `undefined` is dropped by JSON) | C-2 to C-8 | `SUPPORTED` | `G02` 7.1; `G04` 4.1. SDK source: `pumble-sdk/src/core/adapters/http/AddonHttpListener.ts`, `ackFunction()` |
| K-2 | `nack(msg?, status?)` | `status` with `{message}`; default **400 on HTTP**, **500 on socket** — the two adapters differ | C-2 to C-9 | `SUPPORTED` | `G02` 7.1, 7.3; `G04` 8. SDK source: `AddonHttpListener.nackFunction()` (`status: number = 400`); `core/adapters/socket/AddonWebsocketListener.ts`, `handleMessage()` (`status: status \|\| 500`). That Pumble shows `message` to the user is **not** proven by source — server behavior, `PR-14` |
| K-3 | `response(obj)` | `200`, `content-type: application/json`, arbitrary JSON body | C-2 to C-9 modal and menu responses | `SUPPORTED` | `G02` 7.1; `G04` 4.1. SDK source: `AddonHttpListener.responseFunction()` |
| K-4 | Dynamic-menu options response | `response({onAction, options, triggerId, value?})`, where `onAction` and `triggerId` are echoed from the request payload and `value` is echoed when present | C-9 only. No `ack` exists on this class. | `SUPPORTED` | `G04` 2.2, 4.3, 6.4. SDK source: `core/services/AddonService.ts`, `dynamicSelectMenu()`; envelope type `DynamicMenuOptionsResponse` in `core/types/payloads.ts`. An empty/absent options result calls `nack` instead |
| K-5 | Modal envelope | `{triggerId, view, viewType:'NATIVE'\|'INTEGRATION', action:'OPEN'\|'UPDATE'\|'PUSH'}` written through K-3 | C-2 to C-8 | `SUPPORTED` | `G04` 2.2, 5.3. SDK source: `AddonService.createViewContext()` (`action:'OPEN'`; `viewType` is `'INTEGRATION'` only for storage-integration credentials) and `createViewFunctionActionContext()` (`updateView` → `'UPDATE'`, `pushModalView` → `'PUSH'`, both always `'NATIVE'`) |
| K-6 | Event acknowledgement | The HTTP adapter answers `res.send('ok')` (plain text, status 200) and dispatches synchronously-but-unawaited through an `EventEmitter`. No ack callback is offered. The socket adapter sends **nothing at all** for events. | C-1 | `SUPPORTED` | `G02` 7.1. SDK source: `AddonHttpListener.handleMessage()`; `AddonWebsocketListener.handleMessage()`; `AddonService.postEvent()` |
| K-7 | 3-second deadline | Every trigger must be acknowledged within 3 s, "otherwise Pumble will consider it an error and return an ephemeral message to the user that your app is not available to handle the trigger" | C-2 to C-8 | `SUPPORTED` | `G02` 9; `G05` 3.2, 3.10. SDK docs: `docs/basic-concepts.md:231`; repeated per endpoint in `docs/manifest.md` and per trigger in `docs/triggers-reference.md`. Vendor documentation, not source; the exact server timer stays `PR-14` |
| K-8 | Single-response guard | All three helpers check `!res.headersSent` before writing, so the first writer wins and later calls are silent no-ops on the HTTP adapter | C-2 to C-9 | `SUPPORTED` | `G02` 7.1; `G04` 4.1. SDK source: `AddonHttpListener.ackFunction()`, `nackFunction()`, `responseFunction()`. **The socket adapter has no such guard** and will send every frame — see `X-1` |
| K-9 | What Pumble does after a late or missing ack | Retry, drop, or user-visible error only — server behavior, absent from source. The SDK never sets a timer, never retries, and never detects its own lateness. | C-2 to C-8 | `PROBE REQUIRED` | `PR-02`, `PR-14` |
| K-10 | Whether a non-2xx on C-1 causes redelivery | Server behavior, absent from source. Note that the SDK answers `200 'ok'` **before** the handler runs, so a handler crash is invisible to Pumble and can never trigger a redelivery. | C-1 | `PROBE REQUIRED` | `PR-02`. SDK source: `AddonHttpListener.handleMessage()` (response precedes dispatch) |
| K-11 | Block-interaction loading spinner completion | When `loadingTimeout > 0` the SDK awaits the handler and then calls `POST /v1/interactions/complete` with `{channelId, sourceId, sourceType, triggerId}` on the **internal** client, using the *user* token. This is a second HTTP call, separate from the callback response. | C-5 to C-7 | `SUPPORTED` | SDK source: `core/services/AddonService.ts`, `blockInteractionView()` / `blockInteractionMessage()` / `blockInteractionEphemeralMessage()` wrappers and `notifyBlockInteractionProcessingCompleted()`; `api/v1/InteractionsClientInternalV1.ts`, `completeProcessing()`. See `X-6` and the conflict noted in this matrix's section 6.4 |

---

## 5. Contradictions in the corpus

Each was re-checked against the SDK source on 2026-08-15. Four are `RESOLVED`,
one is `RESOLVED` at the client level with a server residue, one stays open.

### X-1 — Acknowledgement versus modal response (the ordering contradiction) — `RESOLVED`

**Resolution: on HTTP, an ack and a modal are mutually exclusive. The first
write wins and the second call is a silent no-op, so `ack()` before
`spawnModalView()` drops the modal. The corpus examples are wrong.**

- SDK source: `pumble-sdk/src/core/adapters/http/AddonHttpListener.ts` —
  `ackFunction()`, `nackFunction()`, and `responseFunction()` each open with
  `if (!res.headersSent)`. There is exactly one `express.Response` per
  callback and all three helpers write it.
- SDK source: `pumble-sdk/src/core/services/AddonService.ts`,
  `createViewContext()` and `createViewFunctionActionContext()` —
  `spawnModalView`, `updateView`, and `pushModalView` are all thin wrappers
  over the same `response` callback. There is no second channel.
- SDK docs: `docs/modals-views.md` states inline, in the `VIEW` handler
  example, `// no need to call ctx.ack when pushing new modal`.
- SDK example: `examples/addon-pumble-zendesk/src/index.ts`, global shortcut
  handler — it calls `spawnModalView(...)` and then acks **only on the failure
  path** (`if (!success) { await ctx.ack(); }`). Vendor code treats the two as
  alternatives, exactly as the guard implies.
- Residue, still `PR-14`: what the *user* sees when a callback is answered
  with a modal envelope and no ack (server-side rendering), and whether the
  socket adapter — which has **no** `headersSent` guard and would send both
  frames (SDK source: `core/adapters/socket/AddonWebsocketListener.ts`,
  `handleMessage()`) — behaves differently. Production uses HTTP, so this does
  not block.
- Standing rule, now proven rather than precautionary: the Elixir transport
  writes exactly one response per callback and chooses an ack **or** a modal
  envelope, never both.

### X-2 — Signature header name and precedence — `RESOLVED`

**Resolution: both header names in the corpus are wrong. Neither
`X-Pumble-Signature` nor `X-Signature` appears anywhere in the SDK. The real
headers are `x-pumble-request-signature` and `x-pumble-request-timestamp`,
both mandatory, and there is no fallback and therefore no precedence
question.**

- SDK source: `pumble-sdk/src/core/adapters/http/middlewares.ts`,
  `verifySignature()` — `TIMESTAMP_HEADER = 'x-pumble-request-timestamp'`,
  `SIGNATURE_HEADER = 'x-pumble-request-signature'`. If **either** is absent
  the middleware answers `403 'Invalid signature!'` and does not call `next()`.
- Corroborated independently in SDK docs:
  `docs/advanced-concepts.md`, section "Request Signature Verification",
  which reproduces the same function.
- A repository-wide search for `X-Signature` and `X-Pumble-Signature` across
  the SDK source, its docs, its CLI, and its examples returns zero matches.
- This also resolves the encoding and the replay window. See `H-7` to `H-10`,
  which were rewritten. A timestamp header **does** exist, so a replay window
  is implementable.
- `PR-03` is `RESOLVED BY SOURCE` for header names, algorithm, signing string,
  and encoding.

### X-3 — Two event message types — `OPEN`

`isPumbleEvent` accepts `PUMBLE_EVENT` **or** `APP_EVENT`, both appear in the
`MessageType` enum, and **the SDK source does not decide between them either**:
nothing downstream of `isPumbleEvent()` branches on the value, and no mapping
from event name to `messageType` exists anywhere in the tree. SDK source:
`pumble-sdk/src/core/types/payloads.ts`, `enum MessageType` and
`isPumbleEvent()`. Which value the server puts on which event is server
behavior. The guess "lifecycle events use `APP_EVENT`" remains a guess and
must not be coded as fact. Status `PROBE REQUIRED`. Probe `PR-16`.

### X-4 — Development signature bypass versus the security invariant — `RESOLVED`

**Resolution: no bypass exists in this SDK version. Verification is
unconditional.**

- SDK source: `pumble-sdk/src/core/adapters/http/AddonHttpListener.ts`,
  `registerMessageEndpoints()` — every callback path is registered as
  `this.server.post(paths, rawBody(), verifySignature(this.manifest.signingSecret), handler)`.
  There is no conditional, no environment check, and no "skip if the secret is
  empty" branch. An empty `signingSecret` would produce a wrong HMAC and
  therefore a `403`, i.e. it fails closed already.
- The guide claim that the middleware "skips verification when no signing
  secret is configured" (`G02` 7.2, `G04` 8) is not true of this version.
  Either the guides describe an older build or they are wrong; either way the
  guide statement is retired.
- The callback security contract (no production bypass when the signing secret is
  absent) is therefore **aligned with** the SDK, not a divergence from it. Status
  `SUPPORTED`.
- One real divergence remains and is deliberate: the SDK compares signatures
  with `!==` (SDK source: `middlewares.ts`, `verifySignature()`), which is not
  constant time. The Elixir port must use a constant-time comparison. See
  `H-7`.

### X-5 — Non-exclusive classification guards — `RESOLVED` (client level); server residue in `PR-16`

**Resolution: the guards are sequential `if` statements and the last five lack
an early `return`, so a dual-matching body really would dispatch twice — but
every guard discriminates on a single-valued field, so no well-formed body can
match two classes.**

- SDK source: `pumble-sdk/src/core/adapters/http/AddonHttpListener.ts`,
  `handleMessage()` — `isPumbleEvent`, `isMessageShortcut`,
  `isGlobalShortcut`, and `isSlashCommand` each `return`; the block-interaction
  trio, `isDynamicMenuInteraction`, and `isViewAction` do not.
- SDK source: `pumble-sdk/src/core/types/payloads.ts` — every guard is an
  equality test on `message.messageType`, refined by an equality test on
  `message.type` (`'GLOBAL'` versus `'ON_MESSAGE'`) or `message.sourceType`
  (`'VIEW'` versus `'MESSAGE'` versus `'EPHEMERAL_MESSAGE'`). These are
  mutually exclusive by construction. The guide's "a message could
  theoretically match multiple guards" describes a defensive coding style, not
  an observed protocol case.
- Residue: whether the server ever emits a malformed body carrying two
  discriminators is unprovable from client source. `PR-16` stays open for that
  one question. The Elixir classifier rejects such a body as malformed rather
  than dispatching twice.

### X-6 — Ack deadline versus loading timeout — `RESOLVED`

**Resolution: they are two unrelated mechanisms. `loadingTimeout` is a
per-block-element spinner duration in seconds, ended by a separate API call.
It does not extend the 3-second acknowledgement deadline.**

- SDK docs: `docs/blocks.md` — on each interactive element, "If greater than
  zero, a loading state is activated upon click and will last for a maximum of
  the given value (in seconds). Loading will stop upon action completion."
  The block examples use `"loadingTimeout": 5`; nothing in the SDK caps it at
  15 or ties it to the response.
- SDK source: `pumble-sdk/src/core/services/AddonService.ts` — the
  `blockInteractionView` / `blockInteractionMessage` /
  `blockInteractionEphemeralMessage` wrappers return early when
  `ctx.payload.loadingTimeout <= 0`, and otherwise await the handler and then
  call `notifyBlockInteractionProcessingCompleted(ctx.payload)`, which issues
  `POST /v1/interactions/complete` (SDK source:
  `api/v1/InteractionsClientInternalV1.ts`, `completeProcessing()`). The
  spinner is stopped by that call, **not** by `ack` or `updateView`.
- SDK docs: `docs/basic-concepts.md:231` — "Every trigger received must be
  acknowledged within 3 seconds", with no block-interaction exception; the
  same 3 s appears on every endpoint in `docs/manifest.md` and every trigger
  in `docs/triggers-reference.md`.
- Consequence and open decision: stopping the spinner requires the internal
  `POST /v1/interactions/complete` endpoint, which this matrix's section 6.4 forbids. The
  Elixir port must either use `loadingTimeout: 0` on every interactive element
  it emits (recommended, and the only path that avoids the internal API), or
  record an explicit decision to call the internal endpoint. Until that is
  decided, emit `loadingTimeout: 0`.
- `PR-14` keeps only its ack-deadline half (what happens on a late or missing
  response); the `loadingTimeout` half is closed.

---

## 6. API operations used by the product contract

Base URL default `https://api-ga.pumble.com`, overridable by the
`PUMBLE_API_URL` environment variable. Consent screen default
`https://app.pumble.com/access-request` (`PUMBLE_CONSENT_SCREEN_URL`); file
upload default `https://files.pumble.com` (`PUMBLE_FILEUPLOAD_URL`).
`SUPPORTED`. `G01` section 4. SDK source:
`pumble-sdk/src/constants/index.ts`. The Elixir client contract requires a fixed
configured base URL, so it must not read the value from a token
or a callback — the SDK likewise resolves it from process configuration only,
never from a payload.

### 6.1 Supported action-node operations

| # | Product action | Operation | HTTP and path | Status | Source |
|---|---|---|---|---|---|
| A-1 | Send Pumble message | `messages.postMessageToChannel(channelId, payload)` | `POST /v1/channels/{cId}/messages` | `SUPPORTED` | `G03` 4.2. SDK source: `pumble-sdk/src/api/v1/MessagesApiClientV1.ts`, `urls.postMessageToChannel` and `postMessageToChannel()` |
| A-2 | Reply to a message | `messages.reply(threadRootId, channelId, payload)` | `POST /v1/channels/{cId}/messages/{trId}` | `SUPPORTED` | `G03` 4.2. SDK source: `MessagesApiClientV1.ts`, `urls.reply` and `reply()` — note the path is `.../messages/{threadRootId}`, the same shape as `fetchMessage` but with `POST` |
| A-3 | Ephemeral message (product UI feedback) | `messages.postEphemeral(channelId, payload, targetUser, ...others)` | `POST /v1/channels/{cId}/messages` with body `{ephemeral:{sendToUsers:[...]}, ...message}` | `SUPPORTED` | `G03` 4.2. SDK source: `MessagesApiClientV1.ts`, `postEphemeral()` (and `replyEphemeral()` for the threaded form) |
| A-4 | Direct-message a user | `messages.dmUser(userId, payload)` = `GET /v1/channels/direct?participantIds=<self,target>` inside a `try/catch`, then on failure or empty result `POST /v1/channels/direct` with `{participantIds:[...]}`, then A-1 against `result.channel.id` | two or three calls | `SUPPORTED` | `G03` 4.1, 4.2. SDK source: `MessagesApiClientV1.ts`, `dmUser()`; `api/v1/ChannelsApiClientV1.ts`, `getDirectChannel()` (participant list includes the caller and is deduplicated) and `createDirectChannel()` |
| A-5 | Add reaction | `messages.addReaction(messageId, {code, skinTone?})` | `POST /v1/messages/{mId}/reactions` with the request as the JSON body | `SUPPORTED` | `G03` 4.2. SDK source: `MessagesApiClientV1.ts`, `addReaction()` |
| A-6 | Remove reaction | `messages.removeReaction(messageId, {code})` | `DELETE /v1/messages/{mId}/reactions` **with a JSON body**, same path as A-5 | `SUPPORTED` | `G03` 4.2. SDK source: `MessagesApiClientV1.ts`, `removeReaction()` — `{method:'delete', url, data: request}`; the body is passed as `data`, never as a query parameter |
| A-7 | Generic external HTTP request | Not a Pumble operation | not applicable | not applicable | product contract |

`A-6` sends a request body on a `DELETE`, now confirmed in source: the SDK
passes `data` on a `delete` request and offers no query-parameter form. The
Elixir HTTP client must support a body on `DELETE`. Whether the *server* also
accepts the code as a query parameter is server behavior and stays
`PROBE REQUIRED` (`PR-17`) — but the SDK proves the documented form is the only
one the vendor client ever sends, so no alternative may be assumed.

The SDK sends the same body-on-`DELETE` shape for
`deleteEphemeralMessage` (`DELETE /v1/channels/{cId}/messages/{mId}/ephemeral`
with `{deleteForUsers:[...]}`), which confirms this is a house pattern rather
than a one-off. SDK source: `MessagesApiClientV1.ts`,
`deleteEphemeralMessage()`.

Reaction codes are validated as `:.*:` with length 3 to 200 (`G03` section
5.5, `ReactionRequest`). This is a client-side type note; server enforcement
is `INFERRED`.

### 6.2 Read and support operations

| # | Purpose | Operation | HTTP and path | Status | Source |
|---|---|---|---|---|---|
| A-8 | Resolve a triggering message | `messages.fetchMessage(messageId, channelId)` | `GET /v1/channels/{cId}/messages/{mId}` | `SUPPORTED` | `G03` 4.2. SDK source: `pumble-sdk/src/api/v1/MessagesApiClientV1.ts`, `fetchMessage()` |
| A-9 | Channel metadata for conditions | `channels.getChannelDetails(channelId)` | `GET /v1/channels/{cId}` | `SUPPORTED` | `G03` 4.1. SDK source: `api/v1/ChannelsApiClientV1.ts`, `getChannelDetails()` |
| A-10 | Channel picker in the builder | `channels.listChannels(types?)` | `GET /v1/channels[?types=PUBLIC,PRIVATE,DIRECT,SELF]` (comma-joined, omitted when the list is empty) | `SUPPORTED` | `G03` 4.1. SDK source: `ChannelsApiClientV1.ts`, `listChannels()` |
| A-11 | User picker and member sync | `users.listWorkspaceUsers()` | `GET /v1/workspaceUsers` | `SUPPORTED` | `G03` 4.3. SDK source: `api/v1/UsersApiClientV1.ts`, `listWorkspaceUsers()` |
| A-12 | Single user lookup | `users.userInfo(userId)` | `GET /v1/workspaceUsers/{userId}` | `SUPPORTED` | `G03` 4.3. SDK source: `UsersApiClientV1.ts`, `userInfo()` |
| A-13 | Workspace name for the console | `workspace.getWorkspaceInfo()` — **the corpus name `getWorkspace()` is wrong** | `GET /v1/workspace` | `SUPPORTED` | `G03` 4.5 (path only). SDK source: `api/v1/WorkspaceApiClientV1.ts`, `getWorkspaceInfo()` |
| A-14 | Identify the installing user | `users.getProfile()` | `GET /oauth2/me` — note this is **not** under `/v1`; it is a sibling of `/oauth2/access` on the same base URL | `SUPPORTED` | `G03` 4.3. SDK source: `UsersApiClientV1.ts`, `urls.getProfile` and `getProfile()` |
| A-15 | Onboarding Home view | `app.publishHomeView(workspaceUserId, payload)` | `POST /v1/app/homeView/workspaceUsers/{userId}` | `SUPPORTED` | `G03` 4.7. SDK source: `api/v1/AppClientV1.ts`, `publishHomeView()` |

### 6.3 Lifecycle operations

| # | Purpose | Operation | HTTP and path | Status | Source |
|---|---|---|---|---|---|
| A-16 | Exchange the OAuth code | `POST {PUMBLE_API_URL}/oauth2/access` with a `multipart/form-data` body carrying exactly three fields, named `client-id`, `client-secret`, `code` (hyphenated, not underscored), with the boundary `content-type` taken from the form encoder | returns `{accessToken, botToken?, userId, botId?, workspaceId}` and **nothing else** | `SUPPORTED` | `G02` 6.1, 6.3. SDK source: `pumble-sdk/src/auth/OAuth2Client.ts`, `generateAccessToken()`; response type `OAuth2AccessTokenResponse` in `auth/types.ts` |
| A-17 | Consent screen | `ClientUtils.generateAuthUrl({defaultWorkspaceId?, state?, redirectUrl?, isReinstall?})` | Browser `GET {PUMBLE_CONSENT_SCREEN_URL}`, default `https://app.pumble.com/access-request`, with query `redirectUrl` (defaults to `manifest.redirectUrls[0]`), `clientId` (= `manifest.id`), `state?`, `defaultWorkspaceId?`, `isReinstall?` (literal string `'true'`, set only when truthy), `scopes` | `SUPPORTED` | `G01` 4; `G02` 5. SDK source: `core/services/ClientUtils.ts`, `generateAuthUrl()`; SDK docs: `docs/authorization.md` |
| A-18 | Scope string format in the consent URL | same call as A-17 | Query value `scopes` = `[...(scopes.userScopes ?? []), ...(scopes.botScopes ?? []).map(s => 'bot:' + s)].join(',')` | `SUPPORTED` | `G02` 5. SDK source: `ClientUtils.generateAuthUrl()`; SDK docs: `docs/authorization.md` gives the worked example `messages:read,bot:messages:write` |
| A-19 | Revoke the caller's own token | `app.removeAuthorization()` | `DELETE /v1/app/authorization`, no body | `SUPPORTED` | `G03` 4.7. SDK source: `api/v1/AppClientV1.ts`, `removeAuthorization()` |
| A-20 | Uninstall from the workspace | `app.uninstallApp()` | `DELETE /v1/app/installation`, no body | `SUPPORTED` | `G03` 4.7. SDK source: `AppClientV1.ts`, `uninstallApp()` |
| A-21 | Token refresh endpoint | none exists | **No refresh endpoint exists in the SDK**, and the token-exchange response type carries no `expiresIn`, `expiresAt`, `refreshToken`, or scope field. The vendor documentation states plainly: "Generated access tokens do not need to be refreshed." Whether the *server* ever expires or revokes a token anyway is still unproven. | `PROBE REQUIRED` (narrowed) | `G03` 7; `PR-04`. SDK source: `auth/types.ts`, `type OAuth2AccessTokenResponse` (five fields, no expiry); `auth/OAuth2Client.ts` (one method only); SDK docs: `docs/authorization.md:51` |
| A-22 | Reinstall replaces the stored tokens | `CredentialsStore.saveTokens(response)` after A-16 | The SDK's own stores upsert by `workspaceId`: `saveTokens` overwrites `botId`/`botToken` when both are present in the response, and always overwrites `userTokens[userId]`. That is client-side storage behavior, now proven. Whether the *server* issues new token values and invalidates the old ones on reinstall is not proven. | `SUPPORTED` (client store) / `PROBE REQUIRED` (server) | `G02` 5, 6.5; `PR-05`. SDK source: `auth/stores/JsonFileTokenStore.ts`, `saveTokens()`; interface `auth/stores/CredentialsStore.ts` |

`A-16` is a `multipart/form-data` POST, not JSON and not
`application/x-www-form-urlencoded`, now confirmed in source: the SDK builds a
`FormData` and passes `data.getHeaders()` as the request headers. The Elixir
client must encode it as multipart with the same hyphenated field names. Note
that this request carries **no** `token` or `x-app-token` header — it uses a
bare `axios.post`, not the authenticated instance. SDK source:
`auth/OAuth2Client.ts`, `generateAccessToken()`.

The OAuth **error** response shape is still not shown anywhere, in the corpus
or in the SDK. Status `PROBE REQUIRED` (`PR-15`). Two source findings sharpen
that probe:

- The SDK's built-in redirect handler reads only `req.query['code']` and
  treats its absence as the sole error case, answering with a generic
  `'Could not authorize! Authorization code not found'`. It never inspects an
  `error` or `error_description` parameter. SDK source:
  `core/services/AddonService.ts`, `setupOAuth()`.
- **The SDK never validates `state`.** It generates the parameter in
  `generateAuthUrl()` but the redirect handler ignores it entirely. The Elixir
  port must implement strict `state` validation itself; this is a deliberate
  security divergence from the SDK, in the same class as the constant-time
  comparison in `X-4`. SDK source: `AddonService.setupOAuth()` versus
  `ClientUtils.generateAuthUrl()`.

### 6.4 Operations outside the supported product scope

Listed to prove they were considered and are not in the v1 dependency set:
`messages.editMessage`, `deleteMessage`, `editAttachments`,
`fetchMessages`, `fetchThreadReplies`, `searchMessages`, all scheduled-message
operations, all file-upload operations, `channels.createChannel`,
`addUsersToChannel`, `removeUserFromChannel`, `users.updateCustomStatus`, and
all `calls` operations. All are `SUPPORTED` by `G03` sections 4.1 to 4.6 and
all were confirmed present in SDK source (`pumble-sdk/src/api/v1/`), but are
outside the supported product action catalogue.

`InteractionsClientInternalV1` (`POST /v1/interactions/complete`) is marked
internal in `G03` section 4.8 and must not be used. **Source raises a conflict
here:** the SDK calls this endpoint automatically after every block-interaction
handler whose payload has `loadingTimeout > 0`, so it is the only known way to
clear the client-side loading spinner. SDK source:
`api/v1/InteractionsClientInternalV1.ts`, `completeProcessing()`, invoked from
`core/services/AddonService.ts`, `notifyBlockInteractionProcessingCompleted()`.
It is reached through a separate `ApiClientInternal`, not the public
`ApiClient`, and always with the **user** token. The resolution recorded in
`X-6` is to emit `loadingTimeout: 0` on every interactive element the add-on
produces, which makes the endpoint unnecessary. Any change to that decision
must be recorded explicitly.

---

## 7. Headers

### 7.1 Outbound, on every Pumble API call

| # | Header | Value | Status | Source |
|---|---|---|---|---|
| H-1 | `token` | The OAuth access token or the bot token, lowercase header name, raw value with no scheme prefix | `SUPPORTED` | `G03` 1, 3. SDK source: `pumble-sdk/src/api/ApiClient.ts`, constructor — `headers: { 'content-type': ..., token: client.accessToken, 'x-app-token': client.appKey }` |
| H-2 | `x-app-token` | The manifest `appKey` | `SUPPORTED` | `G03` 3. SDK source: `api/ApiClient.ts`, constructor |
| H-3 | `content-type` | `application/json` on the JSON API instance | `SUPPORTED` | `G03` 3. SDK source: `api/ApiClient.ts`, constructor. Set as a default on the axios instance, so it is present on `GET` and `DELETE` too |
| H-4 | Missing H-1 or H-2 returns `401` | "both required or the API returns 401". Server behavior; the SDK simply always sends both and throws locally if `accessToken` is absent | `SUPPORTED` (guide) / server-side unverified | `G03` 3. SDK source: `api/ApiClient.ts` throws `'Client is not authenticated'` before any request when the token is missing |
| H-5 | No `Authorization: Bearer` header is used | Confirmed by exhaustive read of the client: the only auth headers set anywhere are `token` and `x-app-token` | `SUPPORTED` | `G03` 1, 3. SDK source: `api/ApiClient.ts`; `api/BaseApiClient.ts` adds no headers of its own |
| H-6 | File-host calls carry H-1 and H-2 but no base URL | The file-host axios instance sets both auth headers and no `baseURL`; the separate file-upload instance sets `baseURL: PUMBLE_FILEUPLOAD_URL` and **no** auth headers. Not used in v1. | `SUPPORTED` | `G03` 1. SDK source: `api/ApiClient.ts`, `fileHostAxiosInstance` and `fileuploadAxiosInstance` |
| H-16 | The OAuth exchange is unauthenticated | `POST /oauth2/access` is sent through a bare `axios.post`, not the authenticated instance, so it carries neither H-1 nor H-2 — only the multipart `content-type` | `SUPPORTED` | SDK source: `auth/OAuth2Client.ts`, `generateAccessToken()` |

### 7.2 Inbound, on every callback

**This subsection was rewritten on 2026-08-15 against SDK source. The previous
version, taken from the guides, was wrong on the header names, wrong on the
signed content, and wrong about the absence of a timestamp header. Do not use
any earlier copy.**

| # | Header | Detail | Status | Source |
|---|---|---|---|---|
| H-7 | `x-pumble-request-signature` | The signature. Value = `HMAC-SHA256(key = signingSecret, message = "<timestamp>:<rawBody>")` rendered as **lowercase hexadecimal**, with **no** prefix, scheme, or version tag. The signed string is **not** the raw body alone: the timestamp header value and a literal `:` are prepended. | `SUPPORTED` | SDK source: `pumble-sdk/src/core/adapters/http/middlewares.ts`, `verifySignature()` — `` const signingPayload = `${timestamp}:${rawBody}` ``, `crypto.createHmac('sha256', signingSecret).update(signingPayload).digest().toString('hex')`. Reproduced in SDK docs: `docs/advanced-concepts.md`, "Request Signature Verification" |
| H-8 | `X-Signature` / `X-Pumble-Signature` | **Neither header exists.** Both names come from the guides and appear nowhere in the SDK source, its docs, its CLI, or its examples. There is no fallback header and therefore no precedence rule. | `SUPPORTED` (that they do not exist in the SDK) | SDK source: repository-wide search at the pinned commit returns zero matches for either name; the only signature constant is in `middlewares.ts`, `verifySignature()`. See `X-2` |
| H-9 | Signature encoding and prefix | Lowercase hex, no prefix. Resolved. | `SUPPORTED` | SDK source: `middlewares.ts`, `verifySignature()` — `.digest().toString('hex')` |
| H-10 | Timestamp header | `x-pumble-request-timestamp` **exists** and is mandatory. It is part of the signed string, so it cannot be tampered with independently. Its unit and format (epoch seconds, epoch millis, or ISO 8601) are **not** determined by the code, which treats it as an opaque string. A replay window is therefore implementable once the unit is observed. | `SUPPORTED` (existence, mandatory, signed) / `PROBE REQUIRED` (unit and format, and whether the server enforces any window of its own) | SDK source: `middlewares.ts`, `verifySignature()` — `TIMESTAMP_HEADER`; `PR-03` for the unit |
| H-11 | Raw body must be retained before JSON parsing | A custom middleware accumulates `data` chunks into a string, assigns `req.rawBody`, then sets `req.body = JSON.parse(req.rawBody)`. It runs before the verifier, and the verifier reads `req.rawBody`. A proxy must forward the body byte-intact. | `SUPPORTED` | SDK source: `middlewares.ts`, `rawBody()`; wiring in `core/adapters/http/AddonHttpListener.ts`, `registerMessageEndpoints()` — `post(paths, rawBody(), verifySignature(...), handler)`. The corpus claim that `express.raw({type:'*/*'})` is used is wrong |
| H-17 | Rejection behavior | A missing timestamp header, a missing signature header, or a mismatch all produce `403` with the plain-text body `Invalid signature!`, and the handler is never reached | `SUPPORTED` | SDK source: `middlewares.ts`, `verifySignature()` |
| H-18 | Comparison is **not** constant time | The SDK compares with `testSignature !== signature`, a short-circuiting string comparison. The Elixir port must use a constant-time comparison. Deliberate divergence, same class as the `state` validation gap in this matrix's section 6.3. | `SUPPORTED` (that the SDK does this) / `INFERRED` (that the divergence is required) | SDK source: `middlewares.ts`, `verifySignature()`; callback security contract |

Implementation notes for the Elixir transport, all derived from
`middlewares.ts`:

1. Read the raw body **before** any JSON decoding, and keep the exact bytes.
   The SDK concatenates chunks into a UTF-8 string; the Elixir port should HMAC
   the raw binary, which is equivalent for valid UTF-8 and safer otherwise.
2. Build the signing string as `timestamp <> ":" <> raw_body`, using the
   header value exactly as received, without parsing or normalizing it.
3. Compare in constant time against a lowercase-hex rendering.
4. Reject with `403` when either header is absent. Never fall back to an
   unverified path.
5. Header names are lowercase on the wire in HTTP/2 and are case-insensitive
   in HTTP/1.1; match case-insensitively.

### 7.3 Response headers from the Pumble API

| # | Item | Detail | Status | Source |
|---|---|---|---|---|
| H-12 | Rate-limit headers | No header name appears in the corpus, and **none appears in the SDK source or its docs either** — a repository-wide search for `429`, `Retry-After`, and "rate limit" over the SDK returns zero matches. Absence in a client is not proof of absence on the server. | `PROBE REQUIRED` | `PR-08` |
| H-13 | `429` and `5xx` are possible | Listed among the observed statuses; the guide advises the caller to back off. Not corroborated by source. | `SUPPORTED` (guide only) | `G03` 7 |
| H-14 | `Retry-After` on `429` | Represented by `retry_after` on the Elixir error struct, never stated in the corpus, and absent from the SDK | `INFERRED` | `PR-08` |
| H-15 | The supplied client implements no retry, no backoff, and no rate limiting | `BaseApiClient.request` is a single `axiosInstance.request(config)` returning `result.data`. There is no interceptor, no retry wrapper, no queue, and no concurrency cap anywhere in the client. Errors propagate as raw axios rejections. | `SUPPORTED` | `G03` 2, 7. SDK source: `pumble-sdk/src/api/BaseApiClient.ts`, `request()`; `api/ApiClient.ts`, `request()` — the axios instances are created with no interceptors |

---

## 8. Scopes

The corpus never publishes a complete scope catalog (`G05` section 3.8 calls
its own list "non-exhaustive"), **but the SDK documentation does.** SDK docs:
`docs/api-client.md`, section "Scopes", introduced as "The list of all
available scopes". The catalog, verbatim:

| Scope | Vendor description |
|---|---|
| `messages:read` | Read messages |
| `messages:write` | Write messages |
| `messages:edit` | Edit messages |
| `messages:delete` | Delete messages |
| `attachments:write` | Write attachments |
| `user:read` | Read user profile |
| `status:write` | Write user status |
| `reaction:read` | Receive reactions |
| `reaction:write` | React to messages |
| `channels:list` | List channels |
| `channels:read` | Get channel information |
| `channels:write` | Write channels |
| `users:list` | List all workspace users |
| `workspace:read` | Read workspace information |
| `calls:write` | Create permanent calls |
| `files:write` | Write messages with files |

This closes the *vocabulary* question: any scope string outside these sixteen
is not a Pumble scope. It does **not** close the *mapping* question — vendor
documentation is not server enforcement, and the descriptions are one line
each. Per-operation mapping stays `PR-07`. Note that the guide-derived list
above contained no `status:write`, `reaction:read`, `reaction:write`,
`workspace:read`, or `calls:write`; those five were missing, not absent.

Bot scopes appear in the consent URL with a `bot:` prefix. `SUPPORTED`. `G02`
section 5. SDK source: `core/services/ClientUtils.ts`, `generateAuthUrl()`.
The manifest keeps them in two separate arrays. SDK source:
`core/types/types.ts`, `AddonManifest.scopes`.

| # | Operation | Likely scope | Status | Source |
|---|---|---|---|---|
| S-1 | A-1, A-2, A-3, A-4 (post, reply, ephemeral, DM) | `messages:write` | `INFERRED` | `G05` 2.1, 2.3; SDK docs `docs/api-client.md` "Write messages" |
| S-2 | A-8 (fetch message) and event delivery for E-1, E-2 | `messages:read` | `INFERRED` | `G05` 2.1; SDK docs "Read messages" |
| S-3 | A-5, A-6 (reactions) | `reaction:write` — "React to messages" is the only catalog entry that can cover a reaction write, and the vocabulary is now closed | `INFERRED` (was `PROBE REQUIRED`; the scope **string** is now known, the mapping is not) | SDK docs: `docs/api-client.md`, "Scopes"; enforcement `PR-07` |
| S-4 | A-4 direct-channel create step | `channels:write` | `INFERRED` | `G05` 2.1; SDK docs "Write channels" |
| S-5 | A-9, A-10 (channel details, list) | `channels:read` (A-9), `channels:list` (A-10) — the catalog splits them exactly this way ("Get channel information" versus "List channels"), which corroborates the split | `INFERRED` | `G05` 2.3; SDK docs: `docs/api-client.md`. SDK docs `docs/triggers-reference.md` also ties `getChannelDetails` to "the `channels:read` scope ... granted for the user or bot" |
| S-6 | A-11, A-12 (user list, user info) | `users:list` (A-11), `user:read` (A-12) | `INFERRED` | `G05` 2.3; SDK docs "List all workspace users" / "Read user profile" |
| S-7 | A-13 (workspace) | `workspace:read` — "Read workspace information", the only workspace scope in the closed catalog | `INFERRED` (was `PROBE REQUIRED`) | SDK docs: `docs/api-client.md`, "Scopes"; enforcement `PR-07` |
| S-8 | A-15 (publish Home view) | Still unknown. The closed catalog contains **no** home-view scope, so either the Home view needs no scope, or it is covered by an existing one, or the catalog is incomplete despite its claim. This is the one mapping the source makes *more* uncertain, not less. | `PROBE REQUIRED` | `PR-07` |
| S-9 | E-3 `REACTION_ADDED` delivery | `reaction:read` — the catalog description is literally "Receive reactions", i.e. it names event delivery rather than an API read | `INFERRED` (was `PROBE REQUIRED`) | SDK docs: `docs/api-client.md`, "Scopes"; enforcement `PR-07` |
| S-10 | E-4 `CHANNEL_CREATED` delivery | unknown; plausibly `channels:read` or `channels:list`, but no catalog entry names event delivery for channels | `PROBE REQUIRED` | `PR-07` |
| S-11 | E-5 `WORKSPACE_USER_JOINED` delivery | unknown; plausibly `users:list`, but nothing states it | `PROBE REQUIRED` | `PR-07` |
| S-12 | L-1, L-2 delivery | unknown; no catalog entry covers app lifecycle, which weakly suggests unconditional delivery to an installed app | `PROBE REQUIRED` | `PR-07` |
| S-13 | Missing scope returns `403` | "`403` → missing scope — fix `manifest.json#scopes` and reinstall". Server behavior, corroborated by no source. | `SUPPORTED` (guide only) | `G03` 7 |
| S-14 | The SDK does not enforce scopes client-side | Confirmed exhaustively: no API client method reads, checks, or references `manifest.scopes`. The only consumer of `scopes` in the whole tree is the consent-URL builder. | `SUPPORTED` | `G03` 6. SDK source: `core/services/ClientUtils.ts`, `generateAuthUrl()` is the sole reader; `api/v1/*.ts` never mention scopes |
| S-15 | Bot scopes and user scopes are separate sets in the manifest | `scopes: {userScopes: string[], botScopes: string[]}`, both required | `SUPPORTED` | `G04` 3.2. SDK source: `core/types/types.ts`, `type AddonManifest` |
| S-16 | The scope vocabulary is a closed set of sixteen strings | Vendor documentation calls it "the list of all available scopes" | `SUPPORTED` (as vendor documentation) | SDK docs: `docs/api-client.md`, "Scopes" |

Consequence for reinstall scope revalidation: the add-on cannot
compute "required scopes per workflow" reliably until `PR-07` closes. Until
then, scope revalidation must be conservative and must never auto-disable a
workflow on an unproven scope mapping.

---

## 9. Manifest entries the product needs

The product contract fixes the manual entry points. The manifest fields exist
and are proven.

| # | Item | Manifest field | Status | Source |
|---|---|---|---|---|
| M-1 | One slash command | `slashCommands: [{command, url, ...}]`; the SDK type requires `command` and `url` and allows arbitrary extra keys (`description`, `usageHint`) | `SUPPORTED` | `G04` 3.1, 3.2; `G05` 3.8. SDK source: `pumble-sdk/src/core/types/types.ts`, `type SlashCommand` |
| M-2 | One global shortcut | `shortcuts: [{name, url, shortcutType:'GLOBAL'}]` | `SUPPORTED` | `G04` 3.1, 7. SDK source: `core/types/types.ts`, `type Shortcut` (discriminated on `shortcutType`) |
| M-3 | One message shortcut | `shortcuts: [{name, url, shortcutType:'ON_MESSAGE'}]` | `SUPPORTED` | `G04` 3.1, 7. SDK source: `core/types/types.ts`, `type Shortcut`; matched at dispatch by `payload.type === 'ON_MESSAGE'` in `payloads.ts`, `isMessageShortcut()` |
| M-4 | Shortcut `name` is normalized | The CLI Runner sets `name = displayName.toLowerCase().replace(/\s+/g, '_')` and keeps the original as `displayName`. The **normalized** value is what arrives in the callback `shortcut` field and what handler routing compares against. | `SUPPORTED` | `G02` 3.3. SDK source: `pumble-sdk/src/core/services/Runner.ts` (shortcut mapping, both the `'GLOBAL'` and `'ON_MESSAGE'` branches); routing in `core/services/AddonService.ts`, `globalShortcut()` / `messageShortcut()` |
| M-5 | Event subscription URL and list | `eventSubscriptions: {url, events?}` — `url` required, `events` optional | `SUPPORTED` | `G04` 3.2. SDK source: `core/types/types.ts`, `type ManifestEvents` |
| M-6 | Block interaction and view action endpoints | `blockInteraction: {url}`, `viewAction: {url}`, both optional | `SUPPORTED` | `G04` 3.2. SDK source: `core/types/types.ts`, `AddonManifest`; served shape in `core/util/ManifestProcessor.ts`, `prepareForServing()` (handlers are stripped, only `url` survives) |
| M-7 | Dynamic menus | `dynamicMenus: [{url, onAction}]`; the served form keeps exactly `url` and `onAction` | `SUPPORTED` | `G04` 3.2. SDK source: `core/types/types.ts`, `type DynamicMenu`; `ManifestProcessor.prepareForServing()` |
| M-8 | Default Home view | Published CLI 1.1.11 requires `defaultHomeView: {enabled, blocks}` and sends the supplied manifest directly with `PUT`. This product sends the neutral disabled value `{enabled: false, blocks: []}`. | `SUPPORTED` (CLI payload contract). The prose manifest guide at the matching source commit calls the field optional and shows `null`, so this record follows the executable CLI type. This does not prove Home-tab rendering behavior. | CLI: `dist/types.d.ts`, `type AddonManifest`; `dist/services/PumbleApiClient.js`, `updateApp()`; matching source: `src/types.ts` and `src/services/PumbleApiClient.ts`. |
| M-9 | Redirect URLs must be absolute HTTPS in production | Stated in the guides. The SDK resolves relative redirect URLs against a host at serve time (`ADDON_HOST` when set, otherwise `https://<req.hostname>`), so a relative entry becomes absolute HTTPS in the served manifest. | `SUPPORTED` | `G05` 4.4. SDK source: `core/util/ManifestProcessor.ts`, `getAbsoluteUrl()`; host selection in `core/adapters/http/AddonHttpListener.ts`, `serveManifest()` |
| M-10 | Secrets are stripped before serving or publication | `prepareForServing` destructures out `appKey`, `clientSecret`, and `signingSecret` and spreads only the remainder | `SUPPORTED` | `G02` 8.1; `G05` 4.4. SDK source: `core/util/ManifestProcessor.ts`, `prepareForServing()` — `const {appKey, clientSecret, signingSecret, ...removedSecrets} = manifest`. Note `id` (the client ID) is **not** stripped |
| M-11 | Runtime workflows cannot register new command or shortcut names | The manifest is static and is synced by the CLI or the developer console | `INFERRED` (product contract) | `G05` 1.4, 4.3 |
| M-12 | Marketplace launch link and listing behavior | `listingUrl?`, `helpUrl?`, `welcomeMessage?`, `offlineMessage?` are all declared optional `string` fields on the manifest type, and **the SDK does nothing with any of them** — they are passed through `prepareForServing` untouched and never read by the runtime. Their behavior is entirely server-side. | `SUPPORTED` (the fields exist and are inert client-side) / `PROBE REQUIRED` (runtime behavior) | `G05` 4.3; `PR-13`. SDK source: `core/types/types.ts`, `AddonManifest`; absence of any other reference in the tree |
| M-13 | Registration identity and bot mode | `name`, `displayName`, and `bot` are required by the Pumble manifest payload. This product also renders `botTitle` and explicitly disables development-only `socketMode`. | `SUPPORTED` | `G05` 4.3, manifest payload table and manual-create example |

---

## 10. Message metadata generated by Pumble

Workflow matching needs to distinguish add-on-generated messages from human
messages so a workflow cannot trigger itself.

| # | Item | Detail | Status | Source |
|---|---|---|---|---|
| N-1 | `WorkspaceUser` has `isAddonBot` and `isPumbleBot` flags | Both are optional booleans on the **API** type, not on the event payload | `SUPPORTED` | `G03` 5.6. SDK source: `pumble-sdk/src/api/v1/types.ts` |
| N-2 | `Channel` has `isAddonBot` and `isPumbleBot` flags | Both are optional booleans | `SUPPORTED` | `G03` 5.6. SDK source: `api/v1/types.ts` |
| N-3 | The SDK `includeBotMessages` option exists for `NEW_MESSAGE` and `UPDATED_MESSAGE` | Typed only for those two events; `REACTION_ADDED` gets `match` alone and every other event gets `never` | `SUPPORTED` | `G02` 3.1; `G04` 3.1. SDK source: `core/types/types.ts`, `type OptionsForEvent`; consumed in `core/services/AddonService.ts`, `message()` |
| N-4 | How the SDK decides "bot message" from the event payload | **Resolved: it compares the author id with the bot's own workspace-user id.** When `includeBotMessages` is falsy the SDK awaits `getBotUserId()` and drops the event if `payload.body.aId === botUserId`. `getBotUserId()` returns `botClient.workspaceUserId`, which comes from the credential store's `getBotUserId(workspaceId)`, i.e. the `botId` saved at token exchange. No subtype, no flag, and no API lookup is involved. | `SUPPORTED` | SDK source: `core/services/AddonService.ts`, `message()` (the `if (!matcher.includeBotMessages)` branch) and `createEventContext()`'s `getBotUserId`; `core/services/ClientUtils.ts`, `getBotClient()`; `auth/stores/JsonFileTokenStore.ts`, `getBotUserId()` |
| N-5 | Message `subtype` (`st`) values | The field exists and is typed `string` with the comment `// subtype`. No value list appears in the source, the docs, or the corpus, and the SDK never reads it. | `PROBE REQUIRED` | `PR-10`. SDK source: `core/types/pumble-events.ts`, `NotificationMessage.st` |
| N-6 | Whether a bot-posted message produces a `NEW_MESSAGE` callback to the same app | Still server behavior, so still a probe — **but the source implies yes.** The `includeBotMessages` option, defaulting to `false`, and the explicit `aId === botUserId` drop would both be dead code if the server never delivered the app's own messages back. Treat self-trigger loops as possible until `PR-10` proves otherwise. | `PROBE REQUIRED` (annotated) | `PR-10`. SDK source: `AddonService.message()` |
| N-7 | Loop-prevention rule for the Elixir port | Compare the message author `aId` against the stored bot user ID from the token store and suppress self-triggered runs. This is no longer an assumption: it is exactly what the vendor SDK does, byte for byte. | `SUPPORTED` (was `INFERRED`) | `G02` 6.4. SDK source: `AddonService.message()`; `ClientUtils.getBotClient()` |
| N-8 | The default is to exclude bot messages | Every path that omits `options` builds `{match: /.*/, includeBotMessages: false}`, and a bare string or RegExp option also yields `includeBotMessages: false` | `SUPPORTED` | SDK source: `core/services/AddonService.ts`, constructor (event registration) and `message()` |

---

## 11. Other unknowns carried into the probe register

| # | Item | Status | Probe |
|---|---|---|---|
| U-1 | Callback retry and replay behavior. Source adds only that the SDK itself never retries and never deduplicates, and that it answers events `200` before running the handler | `PROBE REQUIRED` | `PR-02` |
| U-2 | OAuth token expiry and refresh. Source narrows it: the exchange response has no expiry field and the vendor documentation says tokens "do not need to be refreshed" (`docs/authorization.md:51`). Server-side expiry or revocation is still unproven | `PROBE REQUIRED` (narrowed) | `PR-04` |
| U-3 | Server-side idempotency on writes. Source confirms the client sends no idempotency key of any kind; `lId` (`localId`) appears on the inbound `NotificationMessage` but is never sent on an outbound write | `PROBE REQUIRED` | `PR-09`. SDK source: `api/v1/MessagesApiClientV1.ts`, `processMessagePayload()` builds `{text, blocks, attachments, files}` only |
| U-4 | Exact `WorkspaceUser.role` values (`role` is typed `string`; the event carries `ro`, also typed `string`). Source confirms both are open strings, so the port must not switch on a closed set | `PROBE REQUIRED` | `PR-11`. SDK source: `core/types/pumble-events.ts`, `NotificationWorkspaceUserJoined.ro`; `api/v1/types.ts`, `WorkspaceUser.role` |
| U-5 | Callback body size limit and message size limit. Source confirms the 20-file cap is enforced **client-side** by the SDK, which throws `"Message can not have more than 20 files."` before any request. No inbound callback size limit exists anywhere | `PROBE REQUIRED` | `PR-12`. SDK source: `api/v1/MessagesApiClientV1.ts`, `processFiles()` |
| U-6 | Marketplace launch-link behavior. Source confirms the manifest fields are inert client-side (see `M-12`) | `PROBE REQUIRED` | `PR-13` |

---

## 12. Coverage check against the product contract

| Product capability | Covered by |
|---|---|
| Pumble event triggers | E-1 to E-5 |
| Control-plane events | L-1, L-2 |
| Manual entries | M-1 to M-4 |
| Schedule, inbound webhook, manual run | No Pumble protocol dependency beyond A-1 to A-6 |
| Action nodes | A-1 to A-6 |
| Install and reinstall | A-16 to A-18, A-22 |
| Sign in to the web UI | A-14 |
| Members and roles | A-11, A-12, U-4 |
| Uninstall and delete data | L-1, A-19, A-20 |
| Callback transport | H-7 to H-11, X-2, X-4 |
| Callback classes | C-1 to C-9 |
| Normalized event | I-1 to I-9 |
| Pumble client | H-1 to H-6, H-12 to H-15 |
| OAuth lifecycle | A-16 to A-22, L-1, L-2 |

No row in this matrix marks an unproven behavior as proven. Every
`PROBE REQUIRED` row names a probe ID in `pumble_probe_register.md`.

---

## 13. SDK source cross-check, 2026-08-15

Source: [Pumble Node SDK at commit `36bb7ed`](https://github.com/CAKE-com/pumble-node-sdk/tree/36bb7edf091b9d24b39d6e70302ebbb3a1759fe3).
Files read in full: `pumble-sdk/src/core/adapters/http/middlewares.ts`,
`core/adapters/http/AddonHttpListener.ts`,
`core/adapters/socket/AddonWebsocketListener.ts`,
`core/services/AddonService.ts`, `core/services/ClientUtils.ts`,
`core/util/ManifestProcessor.ts`, `core/types/payloads.ts`,
`core/types/pumble-events.ts`, `core/types/contexts.ts`,
`core/types/types.ts`, `auth/OAuth2Client.ts`, `auth/types.ts`,
`auth/stores/CredentialsStore.ts`, `auth/stores/JsonFileTokenStore.ts`,
`api/ApiClient.ts`, `api/BaseApiClient.ts`, `constants/index.ts`, and all of
`api/v1/`. Vendor documentation under `docs/` was used only where marked
`SDK docs:`.

### What the cross-check changed

1. **The signature contract was wrong in the guides and is now corrected.**
   Header names, signed string, and encoding all changed. See `X-2` and
   this matrix's section 7.2. This is the single highest-risk correction in the file: an
   implementation built on the previous `H-7` would have failed every
   signature check.
2. **The development signature bypass does not exist.** See `X-4`.
3. **Ack and modal are mutually exclusive.** See `X-1`.
4. **`loadingTimeout` is unrelated to the ack deadline.** See `X-6`, and the
   new open decision about `POST /v1/interactions/complete` in this matrix's section 6.4.
5. **The scope vocabulary is closed at sixteen strings.** See this matrix's section 8.
6. **Bot-message detection is `aId === botUserId`.** See `N-4` and `N-7`.

### What the cross-check could not change

Client source cannot prove server behavior. These stay probes regardless of
how clear the SDK is: callback retry and replay (`PR-02`), delivery-identity
uniqueness (`PR-01`), token expiry and revocation (`PR-04`), reinstall token
replacement (`PR-05`), uninstall and unauthorized ordering (`PR-06`), scope
enforcement (`PR-07`), rate limits (`PR-08`), write idempotency (`PR-09`),
self-delivery of bot messages (`PR-10`), role values (`PR-11`), size limits
(`PR-12`), launch-link behavior (`PR-13`), the ack-deadline half of `PR-14`,
OAuth error payloads (`PR-15`), the `messageType` mapping and dual-match
question (`PR-16`), and server acceptance of the reaction and menu forms
(`PR-17`).

### Offline fixture catalog

Machine-readable provenance for every stored adapter fixture lives in
`priv/pumble/fixtures/catalog.json`. Shapes tagged `SUPPORTED` are SDK-source
verified. Concrete values are `INFERRED`. Rows tagged `PROBE` (today:
`oauth/exchange_error.json` / `PR-15`) must not be promoted to fact by a
fixture update. Live recordings belong to bounded live validation.

### Deliberate divergences from the SDK, carried into the Elixir port

| # | SDK behavior | Port behavior | Reason |
|---|---|---|---|
| D-1 | Signature compared with `!==` | Constant-time comparison | Timing side channel. `H-18` |
| D-2 | `state` generated but never validated on redirect | Strict `state` validation, reject on mismatch | CSRF. This matrix's section 6.3 |
| D-3 | Sequential non-returning guards could dispatch twice | Single-class classifier; a dual-match body is rejected as malformed | `X-5` |
| D-4 | Events answered `200` before the handler runs | Same (fast ack), but with durable persistence before responding | `K-10`, `PR-02` |
| D-5 | Calls the internal `POST /v1/interactions/complete` | Emits `loadingTimeout: 0` and never calls it | This matrix's section 6.4, `X-6` |
| D-6 | No retry, no backoff, no rate limiting | Client-side pacing and backoff | `H-15`, `PR-08` |
