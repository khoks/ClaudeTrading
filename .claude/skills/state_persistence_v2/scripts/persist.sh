#!/usr/bin/env bash
# state_persistence/scripts/persist.sh
#
# One-shot orchestrator. Always writes the tick snapshot. Conditionally
# writes daily / weekly rollups based on calendar.sh predicates. Always
# prunes old tick snapshots.
#
# Reads the envelope JSON from stdin (or $1) and pipes it to snapshot_tick.sh.
# Emits a single line to stdout summarising what was written:
#   { "tick": "<path>", "daily": "<path>|null", "weekly": "<path>|null", "pruned": <int> }
#
# Why this lives in a script (and not in state_persistence/SKILL.md prose):
# the daily / weekly conditional was getting silently skipped when scheduled
# sessions cut corners while interpreting the SKILL.md. Making it mechanical
# guarantees the rollup fires whenever the predicate is true.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
export REPO_ROOT

# shellcheck disable=SC1091
source "$REPO_ROOT/lib/env.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/alpaca.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/calendar.sh"

# Read envelope from arg or stdin.
if [ $# -ge 1 ]; then envelope="$1"; else envelope="$(cat)"; fi

# 1. Always: tick snapshot.
tick_path=$(bash "$SCRIPT_DIR/snapshot_tick.sh" "$envelope")

# 2. Conditional: daily rollup at the last tick of the trading day.
daily_path="null"
if is_last_tick_of_trading_day; then
  daily_out=$(bash "$SCRIPT_DIR/snapshot_daily.sh" 2>/dev/null || true)
  if [ -n "$daily_out" ]; then
    daily_path="$daily_out"
  fi

  # 3. Conditional: weekly rollup, only if we just wrote a daily AND today
  #    is the last trading day of the ISO week.
  weekly_path="null"
  if [ "$daily_path" != "null" ] && is_last_trading_day_of_week; then
    weekly_out=$(bash "$SCRIPT_DIR/snapshot_weekly.sh" 2>/dev/null || true)
    if [ -n "$weekly_out" ]; then
      weekly_path="$weekly_out"
    fi
  fi
else
  weekly_path="null"
fi

# 4. Always: prune.
prune_msg=$(bash "$SCRIPT_DIR/prune_tick.sh" 2>&1 || true)
pruned=$(grep -oE '[0-9]+' <<<"$prune_msg" | head -1 || echo 0)
[ -z "$pruned" ] && pruned=0

jq -nc \
  --arg tick "$tick_path" \
  --arg daily "$daily_path" \
  --arg weekly "$weekly_path" \
  --argjson pruned "$pruned" '
  {
    tick: $tick,
    daily: (if $daily == "null" then null else $daily end),
    weekly: (if $weekly == "null" then null else $weekly end),
    pruned: $pruned
  }'
