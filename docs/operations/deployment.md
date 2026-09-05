# Deployment

Audience: people who deploy this application. This file names application
settings and probes. It does not name production hosts.

Related:

- [Local development](local_development.md)
- [Migrations](migrations.md)
- [Rollback](rollback.md)
- [Backup and restore](backup_restore.md)
- [Incidents](incidents.md)
- Runtime variables: `../../.env.example`

## Result

A production-like node must boot from `config/runtime.exs`, serve HTTPS, and
fail ready when the database, schema, or Oban supervisor cannot accept durable
work.

A temporary test runtime was exercised for the clean candidate named by the
latest offline receipt. A staging or production target
is **not** configured in this repository. The exact-candidate gate built and
tested one local hardened OCI image from digest-pinned base images. The
repository also contains an explicit release migrator and candidate-bound local
smoke tests. It does not provide a published registry artifact. Registry
publication, durable platform deployment, stable DNS, managed TLS, restore,
rollback, traffic switching, and environment smoke tests remain unverified.

## Current temporary runtime evidence

| Item | Result |
| --- | --- |
| Candidate | Exact SHA in `tmp/offline_acceptance_receipt.json` |
| Local image ID | Exact local image ID in `tmp/offline_acceptance_receipt.json` |
| OCI revision | Exact candidate commit |
| Running container | Disposable local runtime (removed after validation) |
| Local liveness and readiness | HTTP 200 and HTTP 200 |
| Temporary HTTPS tunnel liveness and readiness | **Not proved:** two account-less tunnel attempts returned HTTP 530 |

The image value is a local Docker image ID. It is not a registry digest. The
local container proves one temporary test runtime only. The failed public tunnel
attempts add no public reachability proof. Neither result proves a durable
deployment or production behavior.

## What this release already implements

- Strict runtime config. Missing required variables refuse boot in production.
- `PUMBLE_BOT_SCOPES` is a required, nonempty comma-separated least-privilege
  scope request. `PUMBLE_USER_SCOPES` is optional and empty by default. Both
  reject blank entries, duplicates, and names outside the closed Pumble scope
  catalog; changing either set requires reinstalling the app. Stored values
  record the request and do not prove which scopes Pumble granted.
- `PUBLIC_BASE_URL` is the canonical host. It is the base of OAuth redirects
  and the Pumble callback URL.
- Pumble callbacks enter `POST /pumble/callbacks` only. The reverse proxy must
  not change body bytes (HMAC is over the raw body).
- Inbound webhooks enter `POST /hooks/:public_id` with a bearer or
  `x-webhook-token` header. Query credentials are refused.
- Public probes: `GET /health/live` (process up) and `GET /health/ready`
  (database ping, migrations, Oban). Bodies are `ok` or `error` only.
- Owner diagnostics: `/settings/operations`. They are not part of ready.
- Production `force_ssl` excludes the health paths so an orchestrator can probe
  HTTP locally if the platform requires it.
- One BEAM node runs the web endpoint and Oban. Do not split workers until
  evidence says you must.
- The OCI build uses digest-pinned build and runtime images and a strict
  allowlist build context. Runtime secrets are not image build arguments or
  image environment values.
- The runtime process is numeric UID/GID `10001:10001` behind `tini`. The local
  smoke runs it with all capabilities dropped, `no-new-privileges`, a read-only
  root filesystem, and a bounded writable `/tmp`.
- `/app/bin/migrate` applies the assembled release's migrations under a
  PostgreSQL advisory lock. It is a one-shot command, not a web boot child.

## Symptom

The new instance never becomes ready, or traffic still hits the previous
instance after a deploy attempt.

## Checks

1. Read `/health/live`. HTTP 200 means the process runs. A restart loop here
   is almost always a bad liveness dependency; this application's liveness
   does not query the database.
2. Read `/health/ready`. HTTP 503 means the node must not receive traffic.
3. Confirm required runtime variables exist in the platform secret store.
   Names are in `.env.example`. Do not print values.
4. Confirm `PUBLIC_BASE_URL` matches the Pumble app callback host.
5. Confirm the proxy preserves raw bodies for `/pumble/callbacks`.

Proven local shape of the probes (development port 4000; test ConnCase uses
the endpoint without starting a daemon):

<!-- command-status: proven-local -->
```bash
curl -sS -o /tmp/pumble-live.json -w "%{http_code}\n" http://localhost:4000/health/live
curl -sS -o /tmp/pumble-ready.json -w "%{http_code}\n" http://localhost:4000/health/ready
```

Do not `cat` those files in a ticket if a misconfigured probe ever grew extra
keys. The implemented bodies contain only `status` and, for ready, `checks`.

## Safe action

Local run (not a production deploy):

<!-- command-status: proven-local -->
```bash
mix phx.server
```

Candidate-bound local image build, scan, migration, and smoke:

<!-- command-status: proven-local -->
```bash
./scripts/container-smoke.sh
```

This command builds with `--pull --no-cache`, checks the exact `HEAD` revision
label, scans high and critical vulnerabilities, runs the release migrator
against a disposable database, and requires both health probes to return HTTP
200. Run it through `./scripts/verify.sh` for release evidence because that
path also requires a clean tree. A standalone dirty-tree run is developer proof
only.

Production or staging apply is not implemented as a generic command. To deploy,
publish the tested image by immutable registry digest. Run `/app/bin/migrate`
from that same digest. Start the instance with the documented runtime variables.
Keep it out of rotation until readiness returns HTTP 200. Record the registry
digest, deployed digest, migration result, and probe result for that environment.

Mark the instance ready only after `/health/ready` is HTTP 200. Migrations
must finish before the new instance receives traffic. See [migrations.md](migrations.md).

## Stop conditions

- Stop if `/health/ready` is 503 and you are about to force the load balancer
  to send traffic anyway.
- Stop if you are about to run `mix ecto.rollback` against a shared database.
  That is not a production rollback. See [rollback.md](rollback.md).
- Stop if a command would print a secret value.
- Stop if the registry, platform, DNS, or TLS target is not explicitly
  configured. Do not invent a host or claim that the local container smoke is a
  durable deployment.
