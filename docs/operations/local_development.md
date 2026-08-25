# Local development

Audience: developers. This file is safe to share. It does not name production
hosts or credentials.

Related:

- [Migrations](migrations.md)
- [Maintenance](maintenance.md)
- [Incidents](incidents.md)
- [Deployment boundary](deployment.md)

## Symptom

`mix phx.server` fails, `/health/ready` is not HTTP 200, or
`./scripts/verify.sh` stops before `verify.sh: offline acceptance passed`.

## Result

A local Phoenix node runs against PostgreSQL 16 on this machine. It uses the
placeholders in `config/dev.exs`. It does not read `.env`.

## Toolchain

| Tool | Proven local value |
|---|---|
| Elixir | 1.20.3 |
| OTP | 29 |
| PostgreSQL | 16 (`brew services` name `postgresql@16`) |
| Mix project | `pumble_automation` 0.1.0 |

## Checks

1. Confirm Elixir and OTP.

<!-- command-status: proven-local -->
```bash
elixir --version
```

2. Confirm PostgreSQL 16 is started.

<!-- command-status: proven-local -->
```bash
brew services list | grep postgresql@16
```

The line must include `started`. If it does not, start the service:

<!-- command-status: proven-local -->
```bash
brew services start postgresql@16
```

3. Fetch dependencies.

<!-- command-status: proven-local -->
```bash
mix deps.get
```

4. Create the development schema once.

<!-- command-status: proven-local -->
```bash
mix setup
```

`mix setup` runs `deps.get`, `ecto.create`, `ecto.migrate`, seeds, and asset
setup. Development database name is `pumble_automation_dev`. Test database
name is `pumble_automation_test`. Both use role `postgres` on `localhost`.
Do not print that role's password.

## Safe action

Start the development endpoint:

<!-- command-status: proven-local -->
```bash
mix phx.server
```

Open `http://localhost:4000`. Public liveness and readiness:

<!-- command-status: proven-local -->
```bash
curl -sS http://localhost:4000/health/live
curl -sS http://localhost:4000/health/ready
```

`/health/live` must return JSON `status` `ok` and HTTP 200. `/health/ready`
must return HTTP 200 with checks `database`, `migrations`, and `queues` equal
to `ok` when PostgreSQL and Oban are up.

Run the complete 19-step candidate gate before treating a commit as a release
candidate:

<!-- command-status: proven-local -->
```bash
./scripts/verify.sh
```

The result must include `verify.sh: all 19 gates passed` and
`verify.sh: offline acceptance passed`.
The Mix alias `mix precommit` runs compile, unused-deps unlock, format, and
tests. Use `./scripts/verify.sh` for a release candidate because it also proves
security scans, static assets, the assembled release, release migrations, and
the hardened container.

Owner diagnostics for one workspace live at `/settings/operations`. Public
ready does not run those checks.

## Configuration

- Development and test use `config/dev.exs` and `config/test.exs`.
- `.env.example` documents production variables only. Copy it only when you
  prepare a production-like release. Never commit a filled `.env`.
- `LOG_LEVEL` is a production runtime setting. Dev keeps the text formatter.

## Stop conditions

- Stop if a command would print `SECRET_KEY_BASE`, `ENCRYPTION_KEY`,
  `PUMBLE_CLIENT_SECRET`, `PUMBLE_APP_KEY`, or `PUMBLE_SIGNING_SECRET`.
- Stop if you are about to point this checkout at a production database.
- Stop before a production deploy. [deployment.md](deployment.md) defines the
  verified deployment boundary; this local guide does not prove durable
  production hosting.
