# ADR-0010: DNS-pinned safe HTTP

**Status:** Accepted

## Context

The generic HTTP action is the only broad external integration primitive in v1. A
workspace user supplies the URL. An ordinary HTTP client resolves the host again
when it connects, which allows DNS rebinding to reach internal addresses.

## Evidence

- `PumbleAutomation.Connections.UrlPolicy`, `IpPolicy`, and `SafeHttp` parse and
  validate URLs, resolve A and AAAA records, reject blocked addresses, connect to a
  validated IP, preserve the hostname for SNI and Host, and revalidate redirects.
- `docs/security/threat_model.md` identifies DNS rebinding and credential leakage;
  the Safe HTTP security suites cover IP ranges, redirects, headers, and rebinding.
- `docs/contract/dependency_policy.md` assigns Mint to user-addressed Safe HTTP and
  Req only to the fixed Pumble API base URL.
- Product limits cap request bodies at 256 KiB, responses at 1 MiB, and redirects
  at three.

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

- The transport is hand-written on Mint and has an adversarial security suite.
- Some convenience features of a high-level client are unavailable and must be
  implemented, including redirects, timeouts, and body limits.
- Connection secrets stay isolated from the request rendering path so that no
  secret appears in an error or a log.

## Reversal condition

Reconsider if a maintained Elixir HTTP client offers connect-to-pinned-IP with
per-hop redirect revalidation as a supported feature, proved by a compatibility
spike.
