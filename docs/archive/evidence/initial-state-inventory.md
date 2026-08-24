# Initial repository inventory and baseline

> [!WARNING]
> Historical snapshot from before the Phoenix application was scaffolded. It is
> not a description of the current repository. See the
> [current documentation](../../README.md).

Date: 2026-08-15. Recorded by orchestrator session.

## P0-T01 — Repository inventory

- Repository path: the repository root.
- Branch: `main`. Baseline HEAD: `087446c` (planning package import).
- Contents at baseline: planning documents only. No `mix.exs`, no `lib/`,
  no `config/`, no `priv/repo/migrations/`, no `test/`, no CI, no Dockerfile.
- Conclusion: greenfield. Every implementation task starts at `implement`,
  none at `remediate` or `verify`.
- Toolchain evidence:
  - `elixir --version` → Elixir 1.20.3 (compiled with Erlang/OTP 29)
  - `mix --version` → Mix 1.20.3
  - Erlang/OTP 29 [erts-17.0.5]
  - PostgreSQL 16.13 (Homebrew), running as service `postgresql@16`
  - `phx_new` archive 1.8.9 installed
- Source corpus: five supplied Pumble guide snapshots, identified as G01–G05
  in the source matrix. The snapshots are not stored in this repository.
- Protocol cross-check: the public
  [Pumble Node SDK at commit `36bb7ed`](https://github.com/CAKE-com/pumble-node-sdk/tree/36bb7edf091b9d24b39d6e70302ebbb3a1759fe3).

## P0-T02 — Reproducible baseline

- No project commands exist at baseline HEAD `087446c`.
- Result: `NOT APPLICABLE — scaffold required by P2-T01`.
- `git status --short` after inventory: clean except intended docs additions.
- `git diff --check`: clean.

## Environment variable names available for live phases (values not recorded)

- A sacrificial-workspace API key was available only as a private runtime
  variable. Its value was not recorded. It applies to the API-key surface, not
  the OAuth application surface used by the product.
- OAuth app credentials for live P17: NOT YET VERIFIED — see probe register.
