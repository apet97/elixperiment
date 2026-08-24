# Identity behaviors that remain live-probe dependent (P3-T07)

Date: 2026-08-15. Task: `P3-T07` of
the [historical implementation plan](../archive/planning/implementation-plan.md).
Companion files: `pumble_source_matrix.md` (P0-T03),
`pumble_probe_register.md` (P0-T04).

The identity suite proves what *this application* does. It runs offline against
stubs and fixtures, so it cannot prove what *Pumble's server* does. This file
names the second set: every identity behavior whose fixture is a hypothesis, the
probe that would settle it, and the assumption the code holds until then.

Nothing here is a known defect. Each entry is a claim the test suite deliberately
does not make.

## How to read a row

* **Assumed today** — what the code and the fixtures behave as if were true.
* **Probe** — the entry in `pumble_probe_register.md` that settles it.
* **If the probe disproves it** — the change that would follow.

## The rows

### 1. The token exchange response shape — `PR-04`, `PR-15`

* **Assumed today:** the exchange answers
  `{accessToken, botToken?, userId, botId?, workspaceId}` and nothing else: no
  expiry, no refresh token, no granted-scope list. This is what
  `priv/pumble/fixtures/oauth/exchange_success.json` encodes.
* **Support:** `RESOLVED BY SOURCE` for the *type* (`A-16`, and the `PR-04`
  source note). The server's actual bytes are still unobserved.
* **Probe:** `PR-04` steps 2 and 3, `PR-15` steps 1 and 2.
* **If disproved:** an expiry field would make
  `PumbleAutomation.Installations.UserAuthorization` need a real expiry column
  rather than an `authorized_at` timestamp, and the whole reauthorization path
  would change.

### 2. The rejected-exchange body — `PR-15`

* **Assumed today:** a refusal carries a non-2xx status; the field names in
  `priv/pumble/fixtures/oauth/exchange_error.json` (`error`,
  `error_description`) are a hypothesis and nothing reads them.
* **Support:** none. The status class is the only proven part.
* **Probe:** `PR-15` steps 4 to 7.
* **If disproved:** only the fixture changes. The controller maps every refusal
  to one generic failure and deliberately does not branch on the body, so no
  behavior depends on this row.

### 3. Whether a reinstall really replaces the tokens on Pumble's side — `PR-05`

* **Assumed today:** a reinstall returns fresh credential values, and the
  previous ones stop working. The suite proves only our half: the ciphertext in
  the row is replaced and the old sessions are revoked when the installer
  changed.
* **Support:** client-side only (`PR-05` source note).
* **Probe:** `PR-05`, especially step 4 (a *different* authorizing user).
* **If disproved:** if Pumble keeps the old bot token alive, an uninstall would
  need to call a revocation endpoint rather than relying on deletion of our
  copy.

### 4. Whether an omitted `botToken` on reinstall means "unchanged" — `PR-05`

* **Assumed today:** it means the grant is incomplete. This application refuses
  the reinstall and keeps the previous credentials
  (`exchange_success_without_bot_token.json`). The Node SDK instead silently
  keeps the old bot token, which is the failure mode `PR-05`'s source note
  warns about.
* **Support:** the SDK's behavior is proven; the server's intent is not.
* **Probe:** `PR-05` step 3.
* **If disproved:** the refusal becomes a "keep the existing credential"
  branch. It is refused today because refusing is the recoverable direction.

### 5. Uninstall and unauthorized delivery, and their order — `PR-06`

* **Assumed today:** `PumbleAutomation.Installations.Lifecycle` is driven by
  callbacks that may arrive more than once, out of order, or not at all, so
  `uninstall/2` and `mark_unauthorized/2` are idempotent and independent. The
  suite proves the idempotence; it cannot prove the delivery.
* **Support:** none for delivery.
* **Probe:** `PR-06`.
* **If disproved:** an ordering guarantee would allow a simpler state machine,
  but the current one stays correct either way. A *no-delivery* finding would
  make a reconciliation sweep necessary.

### 6. The scope snapshot means what we asked for, not what was granted — `PR-07`

* **Assumed today:** the exchange carries no granted-scope list, so
  `Installation.bot_scopes` and `Installation.user_scopes` record the set this
  application *requested* at the time. The identity suite proves the snapshot is
  replaced, not merged, when the requested set changes across a reinstall.
* **Support:** the absent field is `RESOLVED BY SOURCE`; the mapping from
  product operation to scope is not.
* **Probe:** `PR-07`.
* **If disproved:** should the server ever return granted scopes, the snapshot
  becomes an authority check rather than a record of intent, and a partially
  granted install would have to be detected at exchange time.

### 7. Workspace role values — `PR-11`

* **Assumed today:** this application's roles (`owner`, `editor`, `viewer`) are
  its own and are never read from Pumble. A member's Pumble role is not fetched,
  and OAuth never changes an existing member's role.
* **Support:** the decision is ours; the vocabulary on Pumble's side is not
  known.
* **Probe:** `PR-11`.
* **If disproved:** nothing in the identity path changes. A future feature that
  wants to mirror workspace administrators would depend on this probe.

### 8. Second-person sign-in identity — `PR-01`, `PR-15`

* **Assumed today:** `userId` in the exchange response identifies a person
  stably across sign-ins and reinstalls, so it is the key a `WorkspaceMember`
  and a `UserAuthorization` are matched on.
* **Support:** none beyond the field's presence.
* **Probe:** `PR-15` step 1 run twice for two different people, cross-checked
  against `PR-01`'s actor identity fields.
* **If disproved:** an unstable `userId` would silently create a second member
  for the same person, which is why the suite asserts member and authorization
  counts rather than only their contents.

## What is *not* on this list

The following are settled by source or by this repository's own code, and the
identity suite proves them offline. They need no probe:

* the signature scheme over the raw body (`H-7`, `H-9`, `X-2`) — proven by
  source and tested in `test/pumble_automation/pumble/signature_test.exs`;
* `state` minting, expiry, single use, and the refusal to validate it loosely
  (`D-2`) — this application's own behavior;
* every rollback, revocation, retention, and redaction claim — all of them are
  properties of this code and are tested directly.

## Cross-references

| Row | Probe | Fixture or test that carries the assumption |
|---|---|---|
| 1 | `PR-04`, `PR-15` | `priv/pumble/fixtures/oauth/exchange_success.json` |
| 2 | `PR-15` | `priv/pumble/fixtures/oauth/exchange_error.json` |
| 3 | `PR-05` | `test/pumble_automation/installations/identity_contract_test.exs` |
| 4 | `PR-05` | `priv/pumble/fixtures/oauth/exchange_success_without_bot_token.json` |
| 5 | `PR-06` | `test/pumble_automation/installations/lifecycle_test.exs` |
| 6 | `PR-07` | `test/pumble_automation/installations/identity_contract_test.exs` |
| 7 | `PR-11` | `test/pumble_automation/installations/policy_test.exs` |
| 8 | `PR-01`, `PR-15` | `test/pumble_automation/installations/identity_contract_test.exs` |
