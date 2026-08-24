# Data retention and deletion

This is the user-facing retention policy. The numbers are the ones
`PumbleAutomation.Retention.policy/0` enforces. Changing a window requires
changing that module and this document together.

There is **no legal hold** and **no support hold**. Due rows are deleted. The
product does not keep aggregate counters of deleted tenant data.

| Data | Retention | What happens |
|---|---|---|
| Raw/normalized receipt detail (`received_events`) | 30 days from receipt | The row is deleted. An execution that named it keeps running; the pointer is cleared. |
| Execution detail (run, steps, attempts, approvals) | 90 days after last write | Terminal runs (`completed`, `failed`, `cancelled`) are deleted in tenant-scoped batches. Queued, running, waiting, and paused runs are kept even if they are older. A parent run is kept until its descendants are gone. |
| Audit history | 365 days | Rows older than the window are deleted. Uninstall does not wipe audit early. |
| OAuth state | Promptly once consumed or expired | Unusable rows are deleted. |
| Browser sessions | Promptly once revoked, idle-expired, or absolutely expired | Unusable rows are deleted. |
| Uninstalled workspace | 30-day grace | Credentials are removed immediately on uninstall. Remaining workflow, execution, secret, connection, and membership rows are erased after the grace period. The installation row stays as `deleted` so later audit still names the workspace. |

Uninstall deletion is queryable: after the grace purge the tenant's operational
tables are empty and the installation status is `deleted`.
