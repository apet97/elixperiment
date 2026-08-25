# Backup and restore

This runbook defines the verified backup and restore boundary.

Related:

- [Migrations](migrations.md)
- [Rollback](rollback.md)
- [Deployment](deployment.md)
- [Retention](../product/retention.md)

## Result

PostgreSQL is the durable truth: schema, executions, Oban jobs, schedules,
approvals, audit, and ciphertext. Encryption keys are not in the database.
A restore without the matching `ENCRYPTION_KEY` / legacy keys fails closed.

Automated provider backups, point-in-time recovery (PITR), and
`scripts/restore-verify.sh` are **planned but not executed or verified**.

## Symptom

You need a copy of schema or data, or a restore drill after data loss.

## Checks

1. Confirm you are on a non-production database (`pumble_automation_dev` or
   `pumble_automation_test`).
2. Confirm encryption keys for that environment are available in a secret
   store, not in git.
3. Confirm the restore target cannot reach production Pumble or customer
   HTTP endpoints.

## Safe action

### Proven local: schema dump

Dump schema only. Schema SQL does not contain tokens. Write it to a private
temp file. Do not commit it.

<!-- command-status: proven-local -->
```bash
MIX_ENV=test mix ecto.dump -d /tmp/pumble_automation_structure.sql
```

Equivalent `pg_dump` (role from `config/test.exs`; do not put a password on
the command line):

<!-- command-status: proven-local -->
```bash
pg_dump --schema-only -h localhost -U postgres -d pumble_automation_test
```

### Proven local: empty-database replay

This rebuilds schema from migrations. It is the CI replay, not a data
restore.

<!-- command-status: proven-local -->
```bash
MIX_ENV=test mix ecto.drop
MIX_ENV=test mix ecto.create
MIX_ENV=test mix ecto.migrate
MIX_ENV=test mix ecto.migrations
```

Every migration must read `up`. A second `mix ecto.migrate` must be a no-op.

### Planned: production backup and isolated restore

<!-- command-status: planned-not-executed -->
```bash
# planned — not executed or verified
# Enable encrypted provider backups / PITR.
# Restore into an isolated database.
# Point the exact image at it with the same encryption read keys.
# ./scripts/restore-verify.sh <isolated-db>
# Destroy the restore environment.
```

Integrity checks must be boolean (row counts, foreign keys, version hashes,
job presence, decrypt-success). The receipt must not contain plaintext.

## Stop conditions

- Stop if you are about to download an unencrypted production backup onto a
  laptop.
- Stop if the restore environment can send real Pumble or HTTP actions.
- Stop if decrypt checks fail. Do not print the failing ciphertext.
- Stop before production backup or restore work. This repository does not prove
  a production backup target, restore target, or recovery procedure.
