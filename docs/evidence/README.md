# Evidence index

Evidence in this directory answers different questions. One proof type must not
be used as a substitute for another.

| Evidence | What it can prove | What it cannot prove |
| --- | --- | --- |
| Source matrix and fixtures | The reviewed client-side contract and offline behavior | Current server behavior |
| Automated test and release gate | The exact clean commit named by its receipt | Live API behavior or deployment |
| Read-only API-key preflight | Bounded reads allowed by one key in one sacrificial workspace | OAuth, callbacks, writes, or installation lifecycle |
| Deployment receipt | One exact artifact on one exact environment | Marketplace publication |

## Current references

- [Pumble source matrix](pumble_source_matrix.md)
- [Protocol probe register](pumble_probe_register.md)
- [Identity probe notes](identity_live_probes.md)
- [Read-only API-key contract snapshot](pumble_api_key_live_contract.md)
- [Runbook game day](runbook_game_day.md)

The initial greenfield inventory is retained in
[`../archive/evidence/initial-state-inventory.md`](../archive/evidence/initial-state-inventory.md).
It is historical and does not describe the current repository.

Candidate receipts under `tmp/` are intentionally ignored by Git. They are
local, redacted outputs bound to the exact commit that produced them.
