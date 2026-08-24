# Rollback

Audience: internal operators. Do not copy this file into public support
articles.

Related:

- [Migrations](migrations.md)
- [Deployment](deployment.md)
- [Backup and restore](backup_restore.md)
- [Incidents](incidents.md)

## Result

A bad application release rolls back by running the previous image against
the already-expanded schema. Production does not run `mix ecto.rollback`.
A `down` that drops a column destroys data the newer release wrote.

The repository proves the expand-contract compatibility rule with an assembled
release fixture. It cannot prove image rollback in staging or production
because no deployment target, previous deployed digest, or traffic authority
was supplied.

## Symptom

The new instance fails ready, a migration fails, or a release misbehaves
after traffic shift.

## Checks

1. Confirm the previous instance still serves `/health/ready` HTTP 200.
2. Confirm the failed instance is out of rotation.
3. Confirm whether a migration applied. If it applied, treat schema as
   expanded and roll **forward** or keep the old image on that schema.

<!-- command-status: proven-local -->
```bash
MIX_ENV=test mix ecto.migrations
```

## Safe action

### Application rollback (environment procedure)

Keep the old image. Do not schema-downgrade.

Route traffic to the previously verified immutable image digest. Do not rebuild
that version, and do not run `mix ecto.rollback`. Confirm that the deployed
digest is the recorded previous digest and that `/health/ready` returns HTTP
200 before it receives traffic. This procedure needs environment-specific
deployment evidence; it is not proven by this repository alone.

The previous release must still run against the expanded schema (expand-contract
rules in [migrations.md](migrations.md)).

### Migration failure before ready

Leave the old instance in rotation. The new version must not become ready.
Fix with a new forward migration or a corrected release. Never edit a
migration that already applied anywhere except your own discarded local
database.

### Proven local: one-step rollback in the test database

Development and CI only. This is how we prove the newest migration is
reversible. It is not a production procedure.

<!-- command-status: proven-local -->
```bash
MIX_ENV=test mix ecto.rollback
MIX_ENV=test mix ecto.migrate
```

### Proven local: full test schema replay

<!-- command-status: proven-local -->
```bash
MIX_ENV=test mix ecto.drop
MIX_ENV=test mix ecto.create
MIX_ENV=test mix ecto.migrate
```

### Proven local: release migration and compatibility behavior

Build the production release, then run the assembled-release integration:

<!-- command-status: proven-local -->
```bash
mix assets.deploy
MIX_ENV=prod mix release --overwrite
./scripts/release-migration-integration.sh
```

The integration checks two simultaneous migrators, migration failure behavior,
and writes from both the old and expanded application shapes. It is schema
compatibility proof, not a traffic-switch or infrastructure rollback.

The workflow-version hash migration is an expand release. New rows continue to
store the source digest in the previous `definition_hash` column, and the
previous unique index stays in place. The new application also stores
`source_hash` and the complete immutable `identity_hash`. It reuses an exact
legacy snapshot even when a previous instance wrote it after the backfill.
If the compiler or resolved dependencies change without a source change, the
new application refuses activation during this rollback window. For a selected
historical version, it says that the version cannot be reactivated; update the
draft source and activate it as a new version instead. A later contract release
may remove the compatibility index and enable multiple snapshot identities for
one source after the previous image is no longer a rollback target.

Signature-required generic webhooks also fail closed across this rollback
boundary. Such a row stores `enabled=false` for the previous binary and uses
the new `signature_enabled` bit for this signature-aware release. The current
application accepts the endpoint only when that new bit is true and the HMAC is
valid. After rollback, the previous binary sees the endpoint as disabled; it
cannot accept a bearer-only request for a signature-required endpoint. This is
an availability limitation, not a silent authentication downgrade. Roll
forward and reactivate the workflow to restore that endpoint. Bearer-only
endpoints continue to use the previous `enabled` column.

## Stop / escalate

- Stop if you are about to run `mix ecto.rollback` on a shared or production
  database.
- Stop if you are about to drop a column, table, or index the previous
  release reads or writes.
- Stop if durable jobs, delays, or approvals are in flight and you have no
  rollback smoke plan. Those rows must survive process replacement. Forced
  `SIGKILL` recovers through leases and reconciliation; it may pause
  uncertain writes rather than lose them.
- Escalate production rollback to the production owner.
