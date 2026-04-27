#!/usr/bin/env bash
# safe_trading/scripts/filter_pool.sh
#
# Reads persistence/pool.json and prints
#   { "sellable": [...], "buyable": [...] }
# to stdout, applying the 2-trading-day cooldown rule.

set -euo pipefail

# Resolve repo root from this script's location.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
export REPO_ROOT

# shellcheck disable=SC1091
source "$REPO_ROOT/lib/env.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/alpaca.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/calendar.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/pool.sh"

THRESHOLD="${SAFE_TRADING_THRESHOLD:-2}"

sellable=()
buyable=()

# Iterate symbols. Skip the loop entirely if pool is empty.
mapfile -t symbols < <(pool_symbols)
for sym in "${symbols[@]}"; do
  [ -z "$sym" ] && continue
  stock_json="$(pool_get_stock "$sym")"
  last_buy_ts=$(jq -r '.last_buy.timestamp // empty'  <<<"$stock_json")
  last_sell_ts=$(jq -r '.last_sell.timestamp // empty' <<<"$stock_json")

  # Sellable: must have been bought, and bought >= THRESHOLD trading days ago.
  if [ -n "$last_buy_ts" ]; then
    if trading_days_old_enough "$last_buy_ts" "$THRESHOLD"; then
      sellable+=("$sym")
    fi
  fi

  # Buyable: never-sold, OR last sell >= THRESHOLD trading days ago.
  if [ -z "$last_sell_ts" ]; then
    buyable+=("$sym")
  elif trading_days_old_enough "$last_sell_ts" "$THRESHOLD"; then
    buyable+=("$sym")
  fi
done

# Emit single-line JSON.
jq -nc \
  --argjson s "$(printf '%s\n' "${sellable[@]}" | jq -R . | jq -s .)" \
  --argjson b "$(printf '%s\n' "${buyable[@]}"  | jq -R . | jq -s .)" \
  '{ sellable: ($s // [] | map(select(. != ""))),
     buyable:  ($b // [] | map(select(. != ""))) }'
