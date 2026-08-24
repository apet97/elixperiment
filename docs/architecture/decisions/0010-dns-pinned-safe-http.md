# ADR-0010: DNS-pinned safe HTTP

**Status:** Accepted
**Plan decision:** ADR-010 in plan Section 7

## Context

The generic HTTP action is the only broad external integration primitive in v1. A
workspace user supplies the URL. An ordinary HTTP client resolves the host again
when it connects, which allows DNS rebinding to reach internal addresses.

## Evidence

- Plan Section 7, row ADR-010: "DNS-pinned generic HTTP — required to defend against
  rebinding".
- Plan Section 26, SSRF algorithm, steps 1 to 15: parse and validate the URI, reject
  userinfo, resolve A and AAAA, reject blocked addresses, connect to a validated IP
  tuple, keep the original hostname for SNI and Host, stream with a hard byte cap,
  and re-resolve and revalidate every redirect.
- Plan Section 26: blocked headers list, and HTTPS by default with HTTP only by an
  explicit owner-level override and warning.
- Plan Section 27, SSRF row: mitigation is resolve, reject, pin, revalidate
  redirects; proof is IP-range and rebinding tests.
- Plan Section 31: HTTP request body 256 KiB, response body 1 MiB, redirects 3.
- Plan Section 8: Mint is the pinned low-level HTTP client; Req is the Pumble client.
- Plan task P1-T05 invariant: Req is not used to bypass the pinned-IP SSRF transport.

## Decision

All outbound HTTP that a user can address goes through one Safe HTTP transport built
on Mint. The transport resolves the host, validates every returned address against
the block list, and then connects to a validated IP tuple while it keeps the
original hostname for SNI, certificate verification, and the Host header.

Redirects are handled by the caller-side transport, are re-resolved and revalidated
at every hop, and are capped at three. Response bodies stream and stop at a hard
byte cap. Compression handling is disabled.

Req is used only for the Pumble API, whose base URL is fixed configuration. Req is
never used for a user-supplied URL.

## Alternatives

- A high-level client with automatic redirect following. Rejected: it re-resolves
  the host inside the client, which is exactly the rebinding window.
- An allow-list of user-registered domains only. Rejected: a domain allow-list does
  not stop a permitted domain from resolving to an internal address.

## Consequences

- The transport is hand-written on Mint and needs an adversarial security suite
  (plan phase P10).
- Some convenience features of a high-level client are unavailable and must be
  implemented, including redirects, timeouts, and body limits.
- Connection secrets stay isolated from the request rendering path so that no
  secret appears in an error or a log.

## Reversal condition

Reconsider if a maintained Elixir HTTP client offers connect-to-pinned-IP with
per-hop redirect revalidation as a supported feature, proved by a compatibility
spike.
