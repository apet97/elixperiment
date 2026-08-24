# HTTP action security review (P10-T05)

Static review of the generic HTTP boundary after P10-T01 through P10-T04.
The adversarial suite in `test/security/http_action_adversarial_test.exs`
is the automated proof. This note records what the Mint path actually does,
which residual risks remain, and which operational controls are defence in
depth rather than a correctness dependency.

## Scope

Outbound workflow HTTP is the only user-addressable network primitive in v1.
Pumble API calls stay on Req against a fixed configured host and are out of
scope here (ADR-0010). `Connections.test_connection/2` remains a typed
`:not_yet_supported` refusal; this review does not add a live probe.

## Mint usage

`PumbleAutomation.Connections.SafeHttp.Transport` is the only connector:

- `Mint.HTTP.connect/4` is called with an IP **string** produced by
  `:inet.ntoa/1`, never with the original hostname. That is deliberate: a
  hostname at connect time would re-open DNS, which is the rebinding window.
- The original hostname is passed as Mint `hostname:` for SNI, certificate
  identity, and the HTTP Host header.
- `protocols: [:http1]` only. HTTP/2 is disabled so a second protocol cannot
  change framing or header compression behaviour.
- There is no proxy option. `HTTP_PROXY` / `HTTPS_PROXY` are unread. A
  `:proxy` option on `UrlPolicy.approve/2` or `SafeHttp.request/3` is a
  permanent refusal.
- The transport does not follow redirects. `HttpRequest.run/2` follows at
  most three Location hops and re-enters URL policy on each hop.
- Req is not aliased from `SafeHttp`, `Transport`, or `HttpRequest`.

## Certificate options

HTTPS transport options (production path):

- `verify: :verify_peer`
- `depth: 3`
- `versions: [:"tlsv1.2", :"tlsv1.3"]`
- `customize_hostname_check` with
  `:public_key.pkix_verify_hostname_match_fun(:https)`
- trust store `:public_key.cacerts_get()` unless tests inject `:cacerts`

There is no `verify_none`, no custom cipher-suite weakening, and no option
that swaps the connect address for the certificate name.

Tests inject a private CA list for `http.test.local`. OTP 26+ treats a
self-signed leaf as `:selfsigned_peer` even when that leaf is the trust
anchor, so the test-only `verify_fun` allows that one class and still
checks the hostname. Production does not install that function.

A certificate that does not match the original hostname is
`:tls_verify_failed` at phase `:connect` with `request_written?: false`.

## SSRF algorithm (observed)

Matches plan Section 26:

1. Render the URL without putting secrets into diagnostics.
2. Parse; reject userinfo, fragments, and non-canonical IP tricks.
3. HTTPS by default; HTTP only with `allow_http: true`.
4. Resolve A and AAAA through an injectable resolver (OS in production).
5. Refuse the set if **any** address is blocked (`IpPolicy`).
6. Connect to one already-validated IP tuple.
7. Keep the original hostname for SNI, verify, and Host.
8. Stream with a hard body cap; `Accept-Encoding: identity`; refuse
   `Content-Encoding` other than identity.
9. Redirects are manual, capped at three, re-resolved and revalidated.

A blocked case never calls the connector with the prohibited address. The
adversarial suite injects a connect function that fails the test if it is
invoked for those URLs.

## Secrets and diagnostics

- Wire `Authorization` is filled from a secret placeholder after URL policy.
- `Inspect` on the request struct omits `:headers` and `:body`.
- Response capture is an allowlist of header names, SHA-256 of the body, and
  a 256-byte excerpt. `Set-Cookie` is dropped. There is no cookie jar.
- JSON excerpts run through `Error.sanitize/1`, so keys that look like
  credentials become `"[REDACTED]"`.
- Engine diagnostics copy scalar output fields (including `body_excerpt`)
  through the same sanitizer. Persisted rows in the adversarial suite do not
  contain the planted bearer token.

## Residual risks (explicit)

These are not treated as passing-looking gaps. They are named so P13/P15
can re-check them rather than assuming the HTTP node is a perfect oracle.

1. **Unstructured body echo.** If a remote returns the caller's secret as
   ordinary text (not under a secret-named JSON key), the 256-byte excerpt
   can persist that echo. The product never stores the full body. Operators
   must treat excerpts as possibly sensitive. JSON keys matching the secret
   pattern are redacted.
2. **Percent-encoded CR in a path.** Literal CR/LF/space in URLs and header
   values are refused. A `%0d` sequence in a path is not decoded by the
   path checker; Mint will send it as three characters. That is not header
   injection on this HTTP/1 client, but it is not a semantic path normaliser.
3. **Pin TTL.** An approved target expires after 10 seconds. Callers
   re-approve; they do not refresh a pin in place. A rebind **after**
   approve and **before** connect cannot move the socket: connect uses the
   pin, not a second lookup. Expiry is a hard fail, not a silent re-resolve.
4. **Production DNS.** Tests inject answers. Production uses
   `:inet.getaddrs/2`. A resolver that lies is still constrained by IP
   policy on every returned address and by pinning at connect. It is not
   constrained by this process seeing the "real" internet.
5. **IPv6-mapped and dual-stack mixed sets.** Any blocked address in the
   answer set blocks the whole name. Mapped IPv4 (`::ffff:0:0/96`) is
   blocked even when the embedded IPv4 would have been public.
6. **No network-namespace proof in CI.** Destination addresses are proved
   by an injectable Mint connector that records the IP tuple. An optional
   container/netns test was not added; it would be defence-in-depth
   evidence, not a substitute for pinning.
7. **`test_connection/2` is still a typed refusal.** Owners cannot probe a
   connection from the UI yet. That is leftover product work, not an SSRF
   hole: the refusal takes no network effect.

## Operational egress controls (defence in depth)

These do **not** make the application correct. They reduce blast radius if
a future client bypasses this module:

- Default-deny egress except to intended public destinations.
- Block link-local and ULA, including cloud metadata
  (`169.254.169.254`, `fd00:ec2::254`) at the host or VPC edge.
- Do not run the node with a reachable IMDS hop or an HTTP proxy.
- Keep `allow_http` off in production unless an owner has explicitly
  accepted cleartext.

A deployment that relies only on egress filtering, without this DNS-pin
path, is not in conformance with ADR-0010.

Re-checked in P15-T05: the seven named residuals are unchanged. None were
upgraded to critical or high. Loopback HTTPS still fails closed as
`:target_blocked` / `:loopback` before a socket opens
(`test/security/release_gate_test.exs`).

## Review conclusion

The mandated SSRF scenarios pass in the adversarial suite: blocked ranges
and names open no socket; mixed DNS is fail-closed; pins survive a later
private answer; redirects re-resolve; Host/SNI stay on the original name;
credentials do not follow an origin change; compressed bodies are refused;
timeouts distinguish connect from post-write; planted secrets do not appear
in captured logs or stored execution rows. Residual risks above are
accepted as named, not as silent exceptions.
