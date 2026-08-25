# Live validation record

This record separates the proof layers for the candidate tested on 2026-08-25.
It does not contain credentials, workspace identifiers, provider identifiers,
channel details, message content, or personal data.

## Exact candidate

| Item | Evidence |
| --- | --- |
| Git commit | `7c6680aa0663417790c4e8e5f61b649d7b0a8eec` |
| Working tree at offline gate | Clean |
| Offline gate | `./scripts/verify.sh`: 19 of 19 gates passed |
| Automated tests | 2,335 tests and 1 doctest passed |
| Local image ID | `sha256:2120f16478fff70c4c6e0fb8beb05f420b2705a8393995f3ef28ce7486dd7b88` |
| OCI revision label | Exact candidate commit |

The image value is a local Docker image ID. It is not a registry digest and
does not prove that an image was published.

## Offline proof

The 19-gate receipt binds the clean commit, lockfile, test counts, production
release, release migrations, hardened container smoke, and OCI revision label.
The gate passed with 2,335 tests and 1 doctest. Live certification remained
excluded from this offline command.

This proof covers the repository and the local release artifact. It does not
prove current Pumble behavior, an OAuth installation, a callback, a Pumble
write, or a durable deployment.

## Read-only live API proof

At `2026-08-25T00:13:32Z`, the isolated API-key preflight passed for the exact
candidate and one authorized sacrificial workspace.

| Check | Result |
| --- | --- |
| Candidate, script, public contract, and clean-tree binding | Passed |
| Preflight script SHA-256 | `ee2fb54345052b67f8344561491103e9ac19868526a0ff35fe117ac0e91c9f77` |
| Reviewed public response SHA-256 | `85c42e355ed662ba6b1436b9c9c0e19b4bf045036e77c5d7c10622d943e54e48` |
| Public contract request | 1 read; exact reviewed response hash matched |
| Authenticated requests | 4 bounded reads |
| Identity and workspace binding | Passed |
| Channel-list response shape | Passed |
| Message-list response shape | Passed |
| Message-search response shape | Passed |
| Writes or created resources | None |
| Test residue from this preflight | None |

The key was supplied through the private `SAC_WS_API_KEY` runtime variable. The
transient standard-output receipt excluded the key and all workspace, user,
channel, message, and marker values. The existing ignored receipt file belongs
to an earlier candidate. It is not evidence for this run. A final clean-candidate
run must replace that file before the result is cited.

The API key does not prove OAuth, installation, callback signatures, lifecycle
delivery, or application writes.

## Temporary deployment proof

The local image ran as container `pumble-wa-app-7c6680a`. The container used the
exact candidate revision. Both liveness and readiness returned HTTP 200 through
the local endpoint and through a temporary HTTPS tunnel.

This result proves one temporary test runtime. It does not prove a registry
digest, durable hosting, stable DNS, managed TLS, backup restore, rollback,
traffic switching, staging, or production behavior.

## Browser observation

The private app configuration page was observed in the authorized sacrificial
workspace. The app remained pending installation. The OAuth consent and token
exchange did not complete. No OAuth response bytes were observed.

This observation does not prove the authenticated application UI, callback
delivery, event delivery, or workflow execution.

## Pending live proof

| Boundary | Status |
| --- | --- |
| OAuth installation and token exchange | Not proved |
| Browser onboarding after OAuth | Not proved |
| Signed Pumble callback delivery | Not proved |
| Live event or interaction handling | Not proved |
| Live workflow execution | Not proved |
| Pumble message, reply, direct-message, or reaction write | Not proved |
| Live cleanup after a Pumble write | Not applicable because no write ran |
| Reinstall, revocation, uninstall, and lifecycle delivery | Not proved |
| Durable deployment, restore, rollback, and traffic switching | Not proved |
| Marketplace review or publication | Not submitted; no submission started |

Do not use the successful read-only preflight or temporary runtime as evidence
for any pending row.
