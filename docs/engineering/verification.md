# Offline verification

This is the mechanical stop/go gate for a release candidate **before** any
deployment or live Pumble mutation. Live certification is **P17** and is a
separate, named command path. It is not part of `./scripts/verify.sh`.

## One command

```bash
./scripts/verify.sh
```

A passing run prints:

```
verify.sh: all 19 gates passed
verify.sh: offline acceptance passed
live certification: excluded (P17)
```

The UI slice can be run alone:

```bash
./scripts/verify-ui.sh
```

That runner is `Phoenix.LiveViewTest` (`test/pumble_automation_web/live` and
`test/browser`). Wallaby and Playwright are not Mix dependencies.

CI (`.github/workflows/ci.yml`) runs the same `./scripts/verify.sh` from a
clean checkout and uploads `tmp/offline_acceptance_receipt.json`.

## Gates

| # | Gate | Failure |
|---|---|---|
| 1 | Clean-tree check | uncommitted or untracked candidate input |
| 2 | `mix format --check-formatted` | formatting drift |
| 3 | `MIX_ENV=test mix compile --warnings-as-errors` | warning |
| 4 | `scripts/forbid_skipped_tests.sh` | `@tag :skip` or `@tag :only` |
| 5 | Test DB drop/create/migrate twice | schema cannot replay from empty |
| 6 | `mix assets.build` | asset pipeline or missing browser assets |
| 7 | `mix test` | any test failure |
| 8 | `mix credo --strict` | Credo issue |
| 9 | `mix dialyzer` | Dialyzer issue |
| 10 | `mix sobelow --config` | Sobelow finding above configured exit |
| 11 | `mix hex.audit` | retired or advisory package |
| 12 | `git diff --check` | whitespace / conflict marker |
| 13 | `./scripts/verify-ui.sh` | LiveView/browser acceptance |
| 14 | `gitleaks detect --no-git --redact` | secret scan; missing `gitleaks` is failure |
| 15 | `mix assets.deploy` + `MIX_ENV=prod mix release` | release does not assemble |
| 16 | `scripts/release-migration-integration.sh` | assembled release cannot migrate safely |
| 17 | `scripts/container-smoke.sh` | image is not bound to `HEAD`, hardened, migratable, or healthy |
| 18 | Final clean-tree check | a gate changed candidate files |
| 19 | Receipt write | exact SHA, container revision, or test counts cannot be recorded |

A known flaky test blocks the candidate. Do not rerun until green as a substitute
for a fix. EXPLAIN fixtures assert an index-backed plan with sequential scans
disabled; named indexes are asserted from `pg_indexes`.

## Receipt

Path: `tmp/offline_acceptance_receipt.json` (gitignored via `/tmp/`).

Required keys (`schema_version` 2):

- `git_sha`
- `lockfile_sha256`
- `elixir`
- `otp`
- `recorded_at`
- `test_count`
- `doctest_count`
- `live_certification` (always `"excluded"`)
- `docker` (must be `"smoke_passed"`)
- `container_revision` (must equal `git_sha`)
- `working_tree` (must be `"clean"`)
- `gates_passed`

The receipt corresponds to a clean `HEAD`, its `mix.lock`, and the OCI revision
label that the hardened container smoke tested. It is not a Pumble live proof.

## Bounded read-only Pumble preflight

After the offline receipt passes, an operator with the authorized sacrificial
workspace API key already loaded as the private `SAC_WS_API_KEY` environment
variable can run:

```bash
mix run --no-start --no-compile --no-deps-check --no-listeners scripts/live_api_smoke.exs --preflight-only
```

The command does not compile, check dependencies, start Mix listeners, or start
the Phoenix application. The script blocks if `:pumble_automation` is already
started. It also blocks if a database, queue, web, or host-application runtime
is active before or after the minimal start. It starts only `:req` and its
declared dependencies.

Do not use the default `mix run` command. It can start the Phoenix application,
Repo, Oban queues and cron, and the web endpoint before the script guard runs.
The guard cannot undo those application-side effects.

The script then requires the exact reviewed public-contract hash. That public
request never contains the API key. The script binds `/myInfo` to literal
one fixed sacrificial workspace, selects one eligible sacrificial channel, and performs
bounded list/search shape reads. Its JSON receipt contains a safe timestamp;
fixed command and schema metadata; outcome and reason values; request counts
and caps; commit and contract hashes; and booleans and read counts. It excludes
provider IDs, message text, and credentials.

The API-key preflight and live-validation harness deliberately has no message
mutation mode. This harness limit does not disable the product's Pumble action
nodes. The documented API does not establish idempotent create, complete
bounded recovery after an uncertain create, retry-safe delete, or authoritative
absence. See the
[API-key live contract snapshot](../evidence/pumble_api_key_live_contract.md).
The API key does not prove OAuth, callback signatures, lifecycle delivery, a
deployment, or Marketplace readiness.

## Tools

Required locally: Elixir/OTP from `.tool-versions`, PostgreSQL 16, `gitleaks`,
Docker, Trivy, `jq`, and `curl`.

Unavailable required tools fail the script. They are not skipped.
