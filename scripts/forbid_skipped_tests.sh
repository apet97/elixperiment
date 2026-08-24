#!/usr/bin/env bash
#
# Fail if ExUnit skip/only tags are committed. A skipped test is not a passing
# gate. Pass a directory (default: test).

set -euo pipefail

cd "$(dirname "$0")/.."

root="${1:-test}"

matches="$(
  grep -R -n -E '^[[:space:]]*@(module)?tag[[:space:]]+:(skip|only)\b' \
    --include='*.exs' \
    "${root}" || true
)"

if [[ -n "${matches}" ]]; then
  printf 'forbid_skipped_tests: skip/only tags are forbidden:\n%s\n' "${matches}" >&2
  exit 1
fi
