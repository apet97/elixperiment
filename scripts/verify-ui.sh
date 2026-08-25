#!/usr/bin/env bash
#
# Server-rendered LiveView acceptance gate.
#
# This gate uses Phoenix.LiveViewTest against isolated tenants and fake Pumble.
# Real-browser checks remain a separate manual boundary in
# docs/product/ui_acceptance.md.
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
