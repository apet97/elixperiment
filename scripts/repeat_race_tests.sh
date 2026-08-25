#!/usr/bin/env bash
#
# Repeat the race tests until a timing-lucky pass cannot hide.
# Each iteration uses a distinct seed. A single failure stops the script.

set -euo pipefail

cd "$(dirname "$0")/.."

files=(
  test/integration/database/barrier_test.exs
  test/integration/database/engine_race_test.exs
  test/integration/database/workflow_race_test.exs
  test/integration/database/identity_lifecycle_race_test.exs
)

repeats="${1:-20}"

for i in $(seq 1 "${repeats}"); do
  printf '\n==> race repeat %s/%s (seed %s)\n' "${i}" "${repeats}" "${i}"
  mix test "${files[@]}" --trace --seed "${i}"
done

printf '\nrepeat_race_tests.sh: %s iterations passed\n' "${repeats}"
