# Migration discipline

This document defines how the PumbleAutomation schema changes. It covers the
column conventions every migration must follow, the expand-contract rules that
keep a rollback safe, and the replay discipline used in development and CI.

PostgreSQL is the durable truth for every subsystem. The application never
creates or alters schema at runtime: all schema changes arrive through a
numbered migration in `priv/repo/migrations/`.

## 1. Repository configuration

`PumbleAutomation.Repo` uses the PostgreSQL adapter.

| Setting | dev | test | prod |
| --- | --- | --- | --- |
| `pool_size` | 10 | schedulers * 2 | `POOL_SIZE` (default 10) |
| `pool` | default | `Ecto.Adapters.SQL.Sandbox` | default |
| `timeout` | 15000 | 15000 | 15000 |
| `queue_target` | 50 | 50 | 50 |
| `queue_interval` | 1000 | 1000 | 1000 |
| `ssl` | off | off | `DATABASE_SSL` (default true) |

Tests run inside the SQL sandbox. `PumbleAutomation.DataCase` starts a sandbox
owner for each test and stops it on exit, so every test rolls back. Use
`use PumbleAutomation.DataCase, async: true` unless a test needs a shared
connection.

Production requires TLS to the database by default. Set `DATABASE_SSL=false`
only for a database that is unreachable from outside a private network and
cannot offer TLS.

## 2. Column conventions

These defaults are set once in `config/config.exs`, so a migration inherits them
without repeating them:

```elixir
config :pumble_automation, PumbleAutomation.Repo,
  migration_primary_key: [name: :id, type: :binary_id],
  migration_foreign_key: [column: :id, type: :binary_id],
  migration_timestamps: [type: :utc_datetime_usec]
```

### Primary keys

Every table has a UUID primary key named `id` of type `binary_id`. Ecto
generates the UUID in the application (`@primary_key {:id, :binary_id,
autogenerate: true}` through the schema defaults), so the database needs no
default expression.

**Decision: `pgcrypto` is not installed.** Application-side generation covers
every current need, and an unused extension is one more privileged object to
create, audit, and carry across environments. Install `pgcrypto` only when a
migration must generate UUIDs for rows it creates itself (for example a
backfill that runs entirely in SQL). If that day comes, add the extension in
its own migration and record the reason here.

### Timestamps

All timestamps are `:utc_datetime_usec`. Never store local time and never store
a naive timestamp. Domain timestamps (`authorized_at`, `revoked_at`,
`deleted_at`, and similar) follow the same type and the `_at` suffix.

### JSONB

Use `:map` (`jsonb`) for data whose shape is owned by a versioned document, such
as a workflow definition, a normalized event payload, or an execution context.
Do not use JSONB for a value that is filtered, joined, or sorted on in a hot
path; promote that value to its own column. Every JSONB column is `null: false`
with a `default: %{}` unless absence is meaningful. Index a JSONB column only
with a stated query in mind, and prefer an expression index on the extracted
key over a whole-document GIN index.

### Tenant key and indexes

Every tenant-owned table carries `installation_id` directly, or reaches an
installation through a mandatory parent. The column is `null: false` with a
foreign key to `installations`.

Every index on a tenant-owned table leads with the tenant key. A unique
constraint that is unique per workspace is `[:installation_id, :other_column]`,
never `[:other_column]` alone. A lookup index that supports a listing screen is
`[:installation_id, :inserted_at]` or similar. This makes a tenant-scoped query
index-only and makes a missing tenant filter visible in the query plan.

### Naming

| Object | Pattern | Example |
| --- | --- | --- |
| Index | `<table>_<columns>_index` (Ecto default) | `workflows_installation_id_name_index` |
| Unique index | `<table>_<columns>_index` | `installations_pumble_workspace_id_index` |
| Foreign key | `<table>_<column>_fkey` (Ecto default) | `workflows_installation_id_fkey` |
| Check constraint | `<table>_<rule>_check` | `executions_finished_after_started_check` |

Name every check constraint explicitly so that a changeset can map the database
error back to a field with `check_constraint/3`.

### Foreign keys and deletion

- Tenant-owned data rows use `on_delete: :delete_all` toward `installations`.
  The retention worker erases tenant data and marks the installation row
  `deleted`; it does not hard-delete the installation identity.
- A child that cannot exist without its parent (step executions under an
  execution, attempts under a step) uses `on_delete: :delete_all`.
- A reference kept for history (an audit event pointing at a workflow, a member
  who created a secret) uses `on_delete: :nilify_all` and a nullable column, so
  the history survives the referenced row.
- `audit_events.installation_id` is the documented exception. It uses
  `on_delete: :nothing` so an audit row keeps its tenant identity after data
  erasure. A hard delete of an installation is forbidden until an ADR defines
  what happens to that audit trail.
- Retention and soft deletion are application concerns. A `deleted_at` column
  never replaces a real foreign-key rule.

## 3. Constraints enforce invariants

A changeset validation is a user-facing message. A database constraint is the
guarantee. Any invariant that would corrupt execution if broken gets both:

- uniqueness that defines identity (workspace per installation, dedup key per
  installation) is a unique index, not only a changeset check;
- a state field constrained to a fixed set is a check constraint;
- an ordering rule between two timestamps is a check constraint;
- a counter that must not go negative is a check constraint.

## 4. Expand-contract rules

Every schema change is deployed so that the previous release and the new release
can both run against the schema at the same time. This is what makes a rollback
possible without data loss.

**Expand (release N):**

1. Add the new column as nullable, or with a default that is safe for old code.
2. Add the new table or index concurrently.
3. Write to both the old and new shape in application code.
4. Backfill in batches, outside the migration when the table is large.

**Migrate reads (release N+1):**

5. Read from the new shape. Keep writing both.

**Contract (release N+2, after the rollback window has passed):**

6. Stop writing the old shape.
7. Drop the old column, index, or table in its own migration.

Each of the three steps is a separate deploy with its own migration file. Never
combine an expand and a contract in one release.

## 5. Prohibited during the rollback window

The rollback window is the period in which the previous release may be restored.
Until it closes, a migration must not:

- drop a column, table, or index that the previous release reads or writes;
- rename a column or table (rename is a drop plus an add; use expand-contract);
- change a column type in place when the old type is not readable by the
  previous release;
- add a `NOT NULL` constraint to a column the previous release leaves null;
- add a `NOT NULL` column without a default to a populated table;
- add a foreign key or check constraint that existing rows violate;
- take a long `ACCESS EXCLUSIVE` lock on a hot table during traffic;
- run an unbounded `UPDATE` over a large table inside the migration transaction.

A migration that would do any of these is split into an expand step now and a
contract step in a later release.

## 6. Reversibility

- Prefer `change/0` with reversible operations (`create table`, `add`,
  `create index`).
- When an operation is not automatically reversible, write `up/0` and `down/0`.
  Never leave a migration that cannot be rolled back one step in development.
- A data backfill is idempotent: running it twice produces the same rows.
- `mix ecto.rollback` is a development and staging tool. In production a bad
  release is rolled forward with a new migration, because a `down` that drops a
  column destroys data written by the newer release.

## 7. Release and failure behavior

Migrations run before the new release accepts traffic. The assembled release
provides `/app/bin/migrate`, which starts only the repository and applies all
pending migrations. A PostgreSQL advisory lock serializes the complete release
operation, including first-time creation of `schema_migrations`. The Repo also
uses Ecto's PostgreSQL advisory migration lock.

A migration failure exits non-zero. The new version must not become ready, and
the previous version must keep serving. A transactional migration rolls back
its own work. A migration with `@disable_ddl_transaction true`, such as a
concurrent index build, can leave partial DDL, but its version is not marked as
applied. Inspect and repair that exact boundary before a retry. Never mark a
deploy healthy while a migration is partially applied.

The local integration proof runs two migration processes against one empty
database, verifies a third no-op run, injects transactional and
non-transactional failures, and checks old/new application-shape compatibility:

```bash
./scripts/release-migration-integration.sh
```

Build the production release first. The complete `./scripts/verify.sh` path
does both in the required order.

## 8. Replay discipline

A fresh database must reach the current schema by running every migration in
order. Verify this whenever a migration is added:

```bash
MIX_ENV=test mix ecto.drop
MIX_ENV=test mix ecto.create
MIX_ENV=test mix ecto.migrate
MIX_ENV=test mix ecto.migrations   # every entry reads "up"
MIX_ENV=test mix test
```

Run `MIX_ENV=test mix ecto.migrate` a second time to confirm it is a no-op, and
`MIX_ENV=test mix ecto.rollback` followed by `mix ecto.migrate` to confirm the
newest migration is reversible.

Never edit a migration that has been applied anywhere outside your machine.
Correct it with a new migration instead: an edited migration produces two
different schemas that share one version number.
