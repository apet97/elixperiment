# ADR-0003: HTTP callbacks in production

**Status:** Accepted
**Plan decision:** ADR-002 in plan Section 7

## Context

Pumble can deliver events and interactions to the add-on. The transport used in
production must be supported by the platform, must be verifiable, and must match
what the marketplace expects at installation time.

## Evidence

- Plan Section 7, row ADR-002: "HTTP callbacks in production — source-supported,
  signed, marketplace-aligned".
- Plan Section 9: Pumble reaches the Phoenix endpoint over HTTPS callbacks through
  a body-size gate, a raw-body cache, HMAC verification, and a callback classifier.
- Plan Section 12.1: production callback paths are fixed and HTTPS-only; the
  endpoint rejects oversized bodies, retains exact raw bytes, computes HMAC-SHA256,
  compares in constant time, rejects missing or malformed signatures, and parses
  JSON only after the raw bytes are retained.
- Plan Section 12.2: seven callback classes, each with its own response contract.

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
- Interactive callback classes must answer inside the interactive acceptance path
  (plan Section 9, under three seconds), so the work is handed to Ingress.
- Signature fixtures for valid and invalid cases are required test material.

## Reversal condition

Reconsider if Pumble documents and supports a different production transport, and a
probe proves signature verification and the response contracts on that transport.
