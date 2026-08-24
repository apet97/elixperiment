#!/usr/bin/env bash
#
# LiveView / browser acceptance gate (P15-T06).
#
# The approved runner is Phoenix.LiveViewTest. Wallaby and Playwright are not
# on the Mix dependency list: they would not add an assertion this harness
# cannot already make against isolated tenants and fake Pumble.
#
# Full offline acceptance (format, Dialyzer, release, secret scan, receipt)
# is `scripts/verify.sh`. This script is the UI slice that script also runs.

set -euo pipefail

cd "$(dirname "$0")/.."

step() {
  printf '\n==> %s\n' "$1"
}

step "LiveView suite (mix test test/pumble_automation_web/live --trace)"
mix test test/pumble_automation_web/live --trace

step "Browser acceptance (mix test test/browser --trace)"
mix test test/browser --trace

printf '\nverify-ui.sh: LiveView and browser gates passed\n'
