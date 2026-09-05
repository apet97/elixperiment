# Evidence index

Evidence in this directory answers different questions. One proof type must not
be used as a substitute for another.

| Evidence | What it can prove | What it cannot prove |
| --- | --- | --- |
| Source matrix and fixtures | The reviewed client-side contract and offline behavior | Current server behavior |
| Automated test and release gate | The exact clean commit named by its receipt | Live API behavior or deployment |
| Read-only API-key preflight | Bounded reads allowed by one key in one sacrificial workspace | OAuth, callbacks, writes, or installation lifecycle |
| Temporary runtime check | One local image migrated and probed over local HTTP; prior-candidate public tunnel attempts were separately recorded as HTTP 530 | A registry image, durable environment, restore, rollback, or production behavior |
| Durable deployment receipt | One registry artifact on one durable environment | Marketplace publication |

## Current references

- [Pumble source matrix](pumble_source_matrix.md)
- [Protocol probe register](pumble_probe_register.md)
- [Identity probe notes](identity_live_probes.md)
- [Read-only API-key contract snapshot](pumble_api_key_live_contract.md)
- [Current live validation record](live_validation.md)
- [Runbook game day](runbook_game_day.md)

Candidate receipts under `tmp/` are intentionally ignored by Git. They are
local, redacted outputs bound to the exact commit that produced them.
