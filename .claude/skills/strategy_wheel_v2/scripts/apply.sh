#!/usr/bin/env bash
# strategy_wheel/scripts/apply.sh
#
# Currently a stub: emits a "disabled" record unless wheel.enabled = true in
# strategy_defaults.json AND the user has confirmed options approval.
#
# When enabled, this is where the put/call rotation state machine lives.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
export REPO_ROOT

# shellcheck disable=SC1091
source "$REPO_ROOT/lib/env.sh"

# Discard stdin (envelope) — we don't use it in disabled mode.
cat >/dev/null

defaults="$REPO_ROOT/persistence/config/strategy_defaults.json"
enabled=$(jq -r '.wheel.enabled // false' "$defaults" 2>/dev/null || echo false)

if [ "$enabled" != "true" ]; then
  jq -nc '[{strategy:"wheel", status:"disabled", reason:"wheel.enabled = false in strategy_defaults.json"}]'
  exit 0
fi

# TODO: when enabling, implement the four-phase state machine described in SKILL.md.
#       Until then, refuse to act even if mistakenly enabled.
jq -nc '[{strategy:"wheel", status:"not_implemented", reason:"wheel logic is not yet implemented; disable in strategy_defaults.json"}]'
