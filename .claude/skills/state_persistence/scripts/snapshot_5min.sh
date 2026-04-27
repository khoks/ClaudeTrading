#!/usr/bin/env bash
# state_persistence/scripts/snapshot_5min.sh
#
# Writes persistence/snapshots/5min/<YYYY-MM-DDTHH-mm>.json.
# Reads envelope JSON either from $1 (positional arg) or stdin.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
export REPO_ROOT

# shellcheck disable=SC1091
source "$REPO_ROOT/lib/env.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/alpaca.sh"

if [ $# -ge 1 ]; then envelope="$1"; else envelope="$(cat)"; fi

tick_at=$(jq -r '.tick_at' <<<"$envelope")
fname=$(date_iso_to_filename "$tick_at" 2>/dev/null) || fname=$(date_epoch_to_filename "$(date_now_epoch)")
out="$REPO_ROOT/persistence/snapshots/5min/${fname}.json"

# Pull live data.
account=$(alpaca_account)
positions=$(alpaca_positions)

# Find prior 5-min snapshot for delta calc.
prev=$(ls -1 "$REPO_ROOT/persistence/snapshots/5min/"*.json 2>/dev/null | { grep -v "$out" || true; } | sort | tail -1 || true)
prev_equity="null"
if [ -n "$prev" ]; then
  prev_equity=$(jq -r '.account.equity // "null"' "$prev")
fi
cur_equity=$(jq -r '.equity // "0"' <<<"$account")

delta="null"
if [ "$prev_equity" != "null" ] && [ "$prev_equity" != "" ]; then
  delta=$(jq -nc --argjson c "$cur_equity" --argjson p "$prev_equity" '$c - $p')
fi

jq -n \
  --arg tick "$tick_at" \
  --argjson account "$account" \
  --argjson positions "$positions" \
  --argjson actions "$(jq '.actions // []' <<<"$envelope")" \
  --argjson sets "$(jq '.sets // {}' <<<"$envelope")" \
  --argjson delta "${delta:-null}" \
  '{
    tick_at: $tick,
    account: $account,
    positions: $positions,
    actions: $actions,
    sets: $sets,
    equity_delta_5min: $delta
  }' > "$out"

echo "$out"
