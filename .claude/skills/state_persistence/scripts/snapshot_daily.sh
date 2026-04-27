#!/usr/bin/env bash
# state_persistence/scripts/snapshot_daily.sh
#
# Aggregates today's 5-min snapshots into a single daily file.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
export REPO_ROOT

# shellcheck disable=SC1091
source "$REPO_ROOT/lib/env.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/alpaca.sh"

today=$(date_today_utc)
out="$REPO_ROOT/persistence/snapshots/daily/${today}.json"

snaps_glob="$REPO_ROOT/persistence/snapshots/5min/${today}T*.json"
# Collect today's 5-min files; tolerate empty glob.
shopt -s nullglob
files=( $snaps_glob )
shopt -u nullglob

if [ ${#files[@]} -eq 0 ]; then
  echo "no 5-min snapshots for $today; aborting daily" >&2
  exit 0
fi

# Bash 3.2 (macOS default) doesn't support negative array indexing.
last_idx=$(( ${#files[@]} - 1 ))

opening_equity=$(jq -r '.account.equity' "${files[0]}")
closing_equity=$(jq -r '.account.equity' "${files[$last_idx]}")
day_pl=$(jq -nc --argjson c "$closing_equity" --argjson o "$opening_equity" '$c - $o')

# Aggregate every action across all 5-min snapshots into one array.
all_actions=$(jq -s '[ .[].actions[]? ]' "${files[@]}")

# Final positions snapshot.
final_positions=$(jq -c '.positions' "${files[$last_idx]}")

jq -n \
  --arg date "$today" \
  --argjson open "$opening_equity" \
  --argjson close "$closing_equity" \
  --argjson pl "$day_pl" \
  --argjson actions "$all_actions" \
  --argjson positions "$final_positions" \
  --argjson tick_count "${#files[@]}" \
  '{
    date: $date,
    opening_equity: $open,
    closing_equity: $close,
    day_pl_usd: $pl,
    tick_count: $tick_count,
    actions: $actions,
    final_positions: $positions
  }' > "$out"

echo "$out"
