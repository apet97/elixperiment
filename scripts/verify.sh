#!/usr/bin/env bash
#
# The single verification path for this repository.
#
# Continuous integration runs this exact script, so a local pass and a CI pass
# mean the same thing. Add a gate here first, never only in the workflow file.
#
# Nineteen steps, cheap-first. Live certification is P17 and is excluded.
#
#   1. clean candidate checkout
#   2. format
#   3. compile (warnings-as-errors, MIX_ENV=test)
#   4. forbid skip/only tags
#   5. migrate from empty (test database)
#   6. assets.build
#   7. tests
#   8. credo --strict
#   9. dialyzer
#  10. sobelow
#  11. hex.audit
#  12. git diff --check
#  13. LiveView/browser (`scripts/verify-ui.sh`)
#  14. secret scan (gitleaks)
#  15. production release build
#  16. assembled-release migration integration
#  17. candidate-bound hardened container smoke
#  18. final clean-tree check
#  19. machine-readable receipt
#
# The script stops at the first failure. Nothing here needs a Pumble or
# production secret. Dependency advisories, base-image pulls, and a fresh
# vulnerability database can require network access.

set -euo pipefail

cd "$(dirname "$0")/.."

mkdir -p tmp

step() {
  printf '\n==> %s\n' "$1"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'verify.sh: required tool missing: %s\n' "$1" >&2
    exit 1
  fi
}

require_clean_tree() {
  if [[ -n "$(git status --porcelain=v1 --untracked-files=all)" ]]; then
    printf 'verify.sh: release candidate working tree is not clean\n' >&2
    exit 1
  fi
}

candidate_sha=$(git rev-parse --verify HEAD)
container_image="pumble-automation:offline-${candidate_sha:0:12}"

step "1/19 clean candidate checkout"
require_clean_tree

step "2/19 format (mix format --check-formatted)"
mix format --check-formatted

step "3/19 compile without warnings (MIX_ENV=test mix compile --warnings-as-errors)"
env MIX_ENV=test mix compile --warnings-as-errors

step "4/19 forbid skipped tests (scripts/forbid_skipped_tests.sh)"
./scripts/forbid_skipped_tests.sh test

step "5/19 migrations from empty (MIX_ENV=test ecto.drop/create/migrate)"
env MIX_ENV=test mix ecto.drop --force
env MIX_ENV=test mix ecto.create
env MIX_ENV=test mix ecto.migrate
env MIX_ENV=test mix ecto.migrate

step "6/19 assets (mix assets.build)"
mix assets.build

step "7/19 tests (mix test)"
mix test | tee tmp/verify-test.log

step "8/19 credo (mix credo --strict)"
mix credo --strict

step "9/19 dialyzer (mix dialyzer)"
mix dialyzer

step "10/19 sobelow (mix sobelow --config)"
mix sobelow --config

step "11/19 dependency audit (mix hex.audit && mix deps.unlock --check-unused)"
mix hex.audit
mix deps.unlock --check-unused

step "12/19 whitespace and conflict markers (git diff --check)"
git diff --check
if git grep -nE '^(<<<<<<< |>>>>>>>)' -- ':!*.md' ':!*.lock'; then
  printf 'verify.sh: conflict markers found in tracked files\n' >&2
  exit 1
fi

step "13/19 LiveView/browser (./scripts/verify-ui.sh)"
./scripts/verify-ui.sh

step "14/19 secret scan (gitleaks detect --no-git --redact)"
require_cmd gitleaks
gitleaks detect --no-git --redact --source .

step "15/19 production release (mix assets.deploy && MIX_ENV=prod mix release)"
mix assets.deploy
MIX_ENV=prod mix release --overwrite
mix phx.digest.clean --all

step "16/19 assembled-release migration integration"
./scripts/release-migration-integration.sh

step "17/19 candidate-bound hardened container smoke"
require_cmd docker
./scripts/container-smoke.sh "$container_image"

step "18/19 final clean candidate checkout"
require_clean_tree

export VERIFY_TEST_LOG="${PWD}/tmp/verify-test.log"
export VERIFY_GATES="clean-tree,format,compile,forbid-skip,migrate-empty,assets,test,credo,dialyzer,sobelow,hex.audit,git-diff,verify-ui,gitleaks,release,release-migrations,container-smoke,final-clean-tree"
export VERIFY_WORKING_TREE_STATUS="clean"
export VERIFY_DOCKER_STATUS="smoke_passed"
export VERIFY_CONTAINER_REVISION="$candidate_sha"

step "19/19 offline receipt (tmp/offline_acceptance_receipt.json)"
mix run scripts/write_offline_receipt.exs

printf '\nverify.sh: all 19 gates passed\n'
printf 'verify.sh: offline acceptance passed\n'
printf 'live certification: excluded (P17)\n'
