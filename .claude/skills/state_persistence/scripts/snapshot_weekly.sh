#!/usr/bin/env bash
# state_persistence/scripts/snapshot_weekly.sh
#
# Aggregates this week's daily snapshots into a single weekly file.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
export REPO_ROOT

# shellcheck disable=SC1091
source "$REPO_ROOT/lib/env.sh"   # provides date helpers via lib/date.sh

today=$(date_today_utc)
week=$(date_iso_week "$today")
out="$REPO_ROOT/persistence/snapshots/weekly/${week}.json"

# Find this week's daily files (last 7 dates). Use a portable while-read loop
# instead of `mapfile` (bash 4+) so the script runs on macOS bash 3.2.
daily_files=()
for i in 6 5 4 3 2 1 0; do
  d=$(date_offset_days "$today" "-$i") || continue
  [ -z "$d" ] && continue
  f="$REPO_ROOT/persistence/snapshots/daily/${d}.json"
  if [ -f "$f" ] && [ "$(date_iso_week "$d")" = "$week" ]; then
    daily_files+=( "$f" )
  fi
done

if [ ${#daily_files[@]} -eq 0 ]; then
  echo "no daily snapshots for week $week; aborting weekly" >&2
  exit 0
fi

# Bash 3.2 lacks negative array indexing.
last_idx=$(( ${#daily_files[@]} - 1 ))

opening=$(jq -r '.opening_equity' "${daily_files[0]}")
closing=$(jq -r '.closing_equity' "${daily_files[$last_idx]}")
week_pl=$(jq -nc --argjson c "$closing" --argjson o "$opening" '$c - $o')

# Top movers: aggregate per-symbol P/L from action records.
all_actions=$(jq -s '[ .[].actions[]? ]' "${daily_files[@]}")

jq -n \
  --arg week "$week" \
  --argjson open "$opening" \
  --argjson close "$closing" \
  --argjson pl "$week_pl" \
  --argjson actions "$all_actions" \
  --argjson days "${#daily_files[@]}" \
  '{
    week: $week,
    opening_equity: $open,
    closing_equity: $close,
    week_pl_usd: $pl,
    trading_days: $days,
    actions: $actions
  }' > "$out"

echo "$out"
