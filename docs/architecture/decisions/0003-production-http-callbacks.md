# ADR-0003: HTTP callbacks in production

**Status:** Accepted

## Context

Pumble can deliver events and interactions to the add-on. The transport used in
production must be supported by the platform, must be verifiable, and must match
what the marketplace expects at installation time.

## Evidence

- `docs/evidence/pumble_source_matrix.md` records the source-supported callback
  classes, payloads, and signature algorithm.
- `PumbleAutomationWeb.Router`, `CacheRawBody`, and `VerifyPumbleSignature` put a
  body-size gate and exact-byte HMAC verification before callback classification.
- `test/pumble_automation_web/controllers/pumble_callback_controller_test.exs`
  and the security suites cover valid, invalid, malformed, and oversized requests.

## Decision

Production receives Pumble traffic only through signed HTTPS callbacks on fixed
routes. The endpoint verifies the HMAC over the exact raw request bytes before any
business handling.

There is no production bypass when the signing secret is absent. A missing secret
is a rejection, not a permission.

## Alternatives

- A socket or streaming connection to Pumble. Rejected: not shown to be supported
  by the source documentation, and it is not marketplace-aligned.
- Polling the Pumble API for changes. Rejected: it is slower, it costs more calls,
  and it does not deliver interaction callbacks.

## Consequences

- The application must be reachable at a stable public HTTPS address.
- Raw-body capture must run before any JSON body parser in the plug pipeline.
- Interactive callback classes must answer inside the configured three-second
  acceptance path, so durable work is handed to Ingress.
- Signature fixtures for valid and invalid cases are required test material.

## Reversal condition

Reconsider if Pumble documents and supports a different production transport, and a
probe proves signature verification and the response contracts on that transport.
