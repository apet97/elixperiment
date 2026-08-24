# Dependency and coding policy

The authoritative version sources are [`.tool-versions`](../../.tool-versions),
[`mix.exs`](../../mix.exs), and [`mix.lock`](../../mix.lock). The initial policy
was derived from Sections 8 and 9.2 of the
[historical implementation plan](../archive/planning/implementation-plan.md).

A runtime dependency must solve a concrete problem, pass compatibility and
maintenance review, and pass the complete verification gate.

---

## 1. Current toolchain and primary dependencies

Snapshot date: **2026-08-24**. Exact package resolutions remain in `mix.lock`.

| Component | Current repository value |
|---|---|
| Elixir | 1.20.3 on OTP 29 |
| Erlang/OTP | 29.0.5 |
| Phoenix | 1.8.11 |
| Phoenix LiveView | 1.2.9 |
| Ecto SQL | 3.14.0 |
| Postgrex | 0.22.4 |
| PostgreSQL | 16 deployment target |
| Oban | 2.23.1 |
| Req | 0.7.2 |
| Mint | 1.9.3 |
| Credo | 1.7.19 |
| Dialyxir | 1.4.7 |
| Sobelow | 0.15.0 |
| tzdata | 1.1.4 (IANA 2026b; autoupdate disabled). hackney overridden to 4.0.3 because tzdata requires it for unused IANA downloads and 1.x fails `mix hex.audit`. See ADR-0011. |

Credo, Dialyxir, and Sobelow are development and test tools, not runtime
dependencies.

### Version rules

- keep exact resolved versions in `mix.lock`;
- do not mix opportunistic upgrades with unrelated behavior changes;
- run dependency updates with changelog review, full tests, audit, and a
  release build;
- do not use a vulnerable or retired package release.

### Justification rule

For each direct dependency, record the problem it solves, why the standard library
is insufficient, its maintenance evidence, and its removal condition. No package is
added for trivial behavior.

### Transport rule

Req is the Pumble API client against a fixed configured base URL. Req is never
used to bypass the pinned-IP SSRF transport built on Mint (ADR-0010).

### Credential encryption

Credential encryption is implemented by
`PumbleAutomation.Crypto.EncryptedBinary` and
`PumbleAutomation.Crypto.Vault`. It uses AES-256-GCM through OTP crypto with
versioned key envelopes and authenticated context. No Cloak dependency is used.

### Supply-chain review

Review ownership, release recency, known advisories, and transitive dependency count
before approving any dependency.

---

## 2. Allowed domain dependencies

```text
Web        -> Installations, Workflows, Executions, Connections, Audit
Ingress    -> Installations, Workflows, Executions, Audit
Executions -> Workflows, Installations, Pumble, Connections, Audit
Workflows  -> Installations, Connections, Audit
Pumble     -> no domain context
Connections-> Installations, Audit
Audit      -> Installations identity references only
```

Forbidden:

- the Pumble adapter querying workflow tables;
- controllers issuing workflow SQL directly;
- LiveViews bypassing authorization contexts;
- jobs carrying raw credentials;
- Workflows executing side effects;
- Connections deciding workflow transitions.

---

## 3. Coding policy

### Conventions

- Define context boundaries and keep to the allowed dependency list above.
- Use consistent naming across contexts, schemas, and workers.
- Return typed error tuples or error structs, not bare strings.
- Place tests beside the context they prove; security tests live in `test/security`.
- No-warning policy: compilation warnings are build failures.
- No unused production code: dead production code is removed, not kept.

### Quality gates

The verification script `scripts/verify.sh` stops on the first failure and runs
the complete 19-gate candidate check. It includes format, compile with
warnings-as-errors, tests, Credo, Dialyzer, Sobelow, Hex audit, asset build,
secret scanning, release and container proof, and `git diff --check`.

Commands, as stated in the plan:

```bash
mix format --check-formatted
MIX_ENV=test mix compile --warnings-as-errors
mix credo --strict
mix sobelow --config
mix hex.audit
git diff --check
```

Configuration files: `.formatter.exs`, `.credo.exs`, and a Sobelow config.

Gate rules:

- a warning is an error; do not silence a warning to pass the gate;
- no high-confidence Sobelow issue may remain;
- Hex audit must show no vulnerable or retired release;
- prohibit web-layer `Repo` access through Credo or a custom check where practical.

### Failure behavior

Every failure must have a classification and a reproduction command.
