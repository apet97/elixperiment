#!/usr/bin/env bash

# Bounded, local-only capacity evidence. This script never calls Pumble or any
# other external service, and it does not read or print application secrets.

set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"

sha256_stream() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

candidate_sha=$(git rev-parse --verify HEAD)

if [[ -n "$(git status --porcelain=v1 --untracked-files=all)" ]]; then
  worktree_dirty=true
else
  worktree_dirty=false
fi

source_fingerprint=$(
  {
    printf '%s\n' "$candidate_sha"
    git diff --binary HEAD -- config lib priv/repo/migrations test scripts docs/operations/capacity.md mix.exs mix.lock

    git ls-files --others --exclude-standard -- \
      config lib priv/repo/migrations test scripts docs/operations/capacity.md mix.exs mix.lock |
      LC_ALL=C sort |
      while IFS= read -r path; do
        printf '%s\0' "$path"
        sha256_stream <"$path"
      done
  } | sha256_stream
)

evidence_file=${CAPACITY_EVIDENCE_FILE:-tmp/capacity-local.log}
mkdir -p "$(dirname "$evidence_file")"

{
  printf 'CAPACITY_CONTEXT git_sha=%s worktree_dirty=%s source_fingerprint_sha256=%s\n' \
    "$candidate_sha" "$worktree_dirty" "$source_fingerprint"
  printf 'CAPACITY_CONTEXT os=%q\n' "$(uname -srm)"
  printf 'CAPACITY_CONTEXT elixir=%q\n' "$(elixir --version | tail -n 1)"
  printf 'CAPACITY_CONTEXT postgres_client=%q\n' "$(psql --version 2>/dev/null || printf unavailable)"
  printf 'CAPACITY_CONTEXT scope=local_only external_calls=0 latency_gate=disabled\n'

  env MIX_ENV=test mix test test/performance --max-cases 1 --seed 809943 --trace
} 2>&1 | tee "$evidence_file"

printf 'load-smoke: bounded local proof passed; evidence=%s\n' "$evidence_file"
