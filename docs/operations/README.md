# Operations index

These runbooks describe the application artifact and its operating boundaries.
They do not claim that a public or production deployment exists.

| Need | Runbook |
| --- | --- |
| Start and troubleshoot locally | [Local development](local_development.md) |
| Configure an independently authorized environment | [Deployment](deployment.md) |
| Apply release migrations | [Migrations](migrations.md) |
| Reverse a failed release | [Rollback](rollback.md) |
| Verify backup recovery | [Backup and restore](backup_restore.md) |
| Respond to an incident | [Incidents](incidents.md) |
| Resolve an ambiguous external effect | [Uncertain effects](uncertain_effects.md) |
| Inspect or control queues | [Queues](queues.md) |
| Rotate or revoke OAuth credentials | [OAuth revocation](oauth_revocation.md) |
| Run maintenance tasks | [Maintenance](maintenance.md) |
| Review logs and metrics | [Logging](logging.md) · [Metrics](metrics.md) |
| Review measured limits | [Capacity](capacity.md) |

Run `./scripts/verify.sh` from a clean commit before treating an artifact as an
offline candidate. Deployment requires separate infrastructure and evidence.
