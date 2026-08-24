# Delivery semantics — ingress deduplication

This document is the operator-facing record of how inbound deliveries
become `received_events` rows. It does not change ADR-0006. Delivery remains
**at-least-once**. This application **does not claim exactly-once** delivery,
exactly one job attempt, or exactly one remote effect.

Plan sources: Section 17.1, Section 18, P8-T02. Probe evidence: `PR-01`
(open), matrix rows `I-1` to `I-9`.

The stored key is `PumbleAutomation.Ingress.Deduplication`. The
`:delivery_key` on a normalized Pumble struct is still the `I-9` byte digest
and is not written to `received_events.dedup_key`.

## Guarantees

- One stored received-event row per accepted `(installation_id, provider, dedup_key)`.
- A documented provider identity wins over body heuristics. Two bodies that
  share that identity collapse onto one receipt.
- Keys that may contain secrets or attacker-controlled length are length-capped
  (1024 bytes) and hashed (SHA-256) before they are indexed. The stored key is
  a short tag plus 64 hex characters, never the raw header or payload field.
- A payload with no safe identity is accepted as a **distinct** receipt rather
  than collapsed onto another event.

## Not guaranteed

- Exactly one HTTP callback from Pumble or a webhook caller.
- That a documented `rid` / `triggerId` / lifecycle `id` is unique or that it
  repeats on retry. Those fields are documented as present; uniqueness is
  `PR-01` and still open. Using them as the strongest *documented* identity
  can suppress two genuine events if the provider reuses an id. It can also
  accept a retry twice if the provider mints a new id. Both are at-least-once
  failure modes, not exactly-once ones.
- That a fallback body digest distinguishes two different events whose bytes
  collide (SHA-256) or that it collapses a retry whose body or signature
  changed.

## Per-class keys

| Class | Provider | Key material | Missing identity |
|---|---|---|---|
| `event` | `pumble` | `class` + event type + `rid` (`provider_id`) | `I-9` digest + 900s bucket |
| `interaction` | `pumble` | trigger id + type + documented action identity (`on_action`, `view.id`, menu query). **Not** `sourceId` (object id, `I-5`) | `I-9` digest + 900s bucket, or distinct if no body |
| `lifecycle` | `pumble` | provider event `id` + type/terminal state + workspace id | `I-9` digest + 900s bucket, or distinct if no body |
| `webhook` | `webhook` | hashed `Idempotency-Key` scoped to the endpoint | **each authenticated request is distinct** |
| `schedule` | `schedule` | schedule id + scheduled-for UTC instant | typed rejection |
| `manual` | `browser` | caller request id | generated one-time id (distinct) |

The unique index is already tenant- and provider-scoped, so installation id
is not hashed into the key.

## Fallback window

The fallback bucket is **900 seconds**, aligned to the Unix epoch
(`floor(unix_seconds / 900)`).

- Same body, same signature, same bucket: one key.
- Same body and signature in the next bucket: a different key.

This is the weakest conservative fallback `PR-01` still allows: it deduplicates
byte-identical retries inside the window `PR-02` uses to look for retries, and
it refuses to let a body hash become a permanent suppressor. Collision
limitation: two different events that hash to the same `I-9` digest inside one
bucket collapse. SHA-256 makes that a documentation point, not an expected
operational failure.

Webhook deliveries **without** `Idempotency-Key` do not use this window.
P8-T02 requires them to be distinct even when the body repeats. Section 17.1's
"endpoint + body + time bucket" alternative is not used.

## Execution crash windows

Delivery and execution are both **at-least-once**. A worker or test process
may die at a named boundary. Recovery uses the same claim, finalize, and
reconcile paths as a live worker. This application does not claim exactly-once
effects.

Named boundaries (`PumbleAutomation.FailureInjection`, test-only):

| Boundary | If the process dies | Recovery |
|---|---|---|
| before claim commit | no attempt, execution still queued | the same Oban job claims again |
| after claim, before a write | started attempt, execution running | reconcile retries a read-only/idempotent node; otherwise `paused_uncertain` |
| before network write | same as after claim | same rule |
| after write/timeout | the remote effect may already exist | `paused_uncertain`, never a silent retry |
| before finalize | started attempt still open | same stale-attempt rule |
| before next-job insert | finalize transaction rolls back | same stale-attempt rule |
| after finalize, before job return | durable state already committed | a duplicate job for the old generation is a no-op |
| approval decision | pending approval unchanged | a later verified click decides once |
| schedule dispatch | clock not advanced | the next tick dispatches the occurrence once |

A delay or approval wait is a row plus a durable job. There is no process
timer to restore after restart. Reconcile repairs missing wait/timeout jobs
and does not invent catch-up work. Duplicate callbacks collapse on
`dedup_key`. Two workers may race; one claim wins and the other is a no-op.

## Integrity anomaly

When a second insert loses on the unique index and the new raw-body SHA-256
does not match the stored digest, the existing row is returned and telemetry
`[:pumble_automation, :ingress, :dedup, :integrity_anomaly]` is emitted with
provider, class, type, and strategy. The second body is discarded. That is a
visible integrity signal, not a rewrite of history.

Typical cause: a documented id was reused for a different payload. Until
`PR-01` closes, treat that as provider-id uncertainty, not as proof that the
first body was wrong.

## Telemetry

`[:pumble_automation, :ingress, :dedup, :key]` is emitted for every derived
key. Metadata:

- `provider`, `class`, `strategy`
- `fallback?` — `true` only for the `I-9` + bucket strategy
- `window_seconds` — `900` on fallback, otherwise `nil`

No raw body, signature, idempotency header, or unhashed provider id is
included.

## Retention

Receipt rows are retained for 30 days (`received_events.retain_until`). That
is a storage window, not the fallback dedup window. After retention, a later
callback with the same documented id may insert again. The same windows are
documented for operators in `docs/product/retention.md`: execution detail 90
days (terminal rows only), audit 365 days, expired OAuth/session rows promptly,
and a 30-day uninstall grace.
