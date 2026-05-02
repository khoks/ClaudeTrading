#!/usr/bin/env bash
# strategy_profit_take/scripts/apply.sh
#
# Eager partial-exit on absolute gain thresholds. One rung fires per tick
# per stock at most. Reads/writes profit_take state in pool.json.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
export REPO_ROOT

# shellcheck disable=SC1091
source "$REPO_ROOT/lib/env.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/alpaca.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/pool.sh"

envelope="$(cat)"
now=$(jq -r '.now' <<<"$envelope")
sellable=$(jq -c '.sellable' <<<"$envelope")

orders='[]'

if [ "$(jq 'length' <<<"$sellable")" = "0" ]; then
  printf '%s\n' "$orders"
  exit 0
fi

for sym in $(jq -r '.[]' <<<"$sellable"); do
  cfg=$(pool_strategy_config "$sym" profit_take)
  thresholds=$(jq -c '.profit_thresholds_percent // [10,20,35,50]' <<<"$cfg")
  fraction=$(  jq -r '.sell_fraction_per_rung    // 0.25'          <<<"$cfg")

  stock=$(pool_get_stock "$sym")
  last_buy_ts=$(  jq -r '.last_buy.timestamp // empty'                              <<<"$stock")
  last_buy_price=$(jq -r '.last_buy.price    // empty'                              <<<"$stock")
  fired=$(        jq -c '.strategy_config.profit_take.fired_thresholds // []'       <<<"$stock")
  baseline_qty=$( jq -r '.strategy_config.profit_take.baseline_qty     // empty'    <<<"$stock")
  baseline_at=$(  jq -r '.strategy_config.profit_take.last_baseline_at // empty'    <<<"$stock")

  # Reset state if last_buy is fresher than the captured baseline.
  if [ -z "$baseline_at" ] || [ "$last_buy_ts" \> "$baseline_at" ]; then
    fired='[]'
    baseline_qty=""
    baseline_at=""
  fi

  # Read live position. Skip if no qty.
  position=$(alpaca_position "$sym" 2>/dev/null || echo '{}')
  cur_qty=$(jq -r '.qty // empty' <<<"$position")
  if [ -z "$cur_qty" ] || [ "$cur_qty" = "0" ]; then
    continue
  fi

  unrealized_plpc=$(jq -r '.unrealized_plpc // "0"' <<<"$position")
  gain_pct=$(jq -nc --argjson p "$unrealized_plpc" '$p * 100')

  # Find lowest threshold T s.t. T <= gain_pct AND T not in fired. At most one fires.
  triggered=$(jq -nc \
    --argjson thresh "$thresholds" \
    --argjson g "$gain_pct" \
    --argjson f "$fired" '
    [ $thresh[] | select(. <= $g and (. as $t | $f | index($t) | not)) ]
    | sort | first // null')

  if [ "$triggered" = "null" ]; then
    continue
  fi

  # First-fire: capture baseline_qty.
  if [ -z "$baseline_qty" ]; then
    baseline_qty="$cur_qty"
    baseline_at="$last_buy_ts"
  fi

  sell_qty=$(jq -nc \
    --argjson b "$baseline_qty" \
    --argjson f "$fraction" \
    --argjson c "$cur_qty" '
    [ ($b * $f), $c ] | min')

  too_small=$(jq -nc --argjson q "$sell_qty" '($q <= 0)')
  if [ "$too_small" = "true" ]; then
    continue
  fi

  cur_price=$(alpaca_last_price "$sym" || true)
  if [ -z "$cur_price" ]; then continue; fi

  order=$(alpaca_place_order "$sym" sell "$sell_qty" market 2>/dev/null) || {
    orders=$(jq -nc --argjson a "$orders" --arg s "$sym" --argjson t "$triggered" \
      '$a + [{strategy:"profit_take", symbol:$s, status:"error", error:"order failed", threshold:$t}]')
    continue
  }
  order_id=$(jq -r '.id'     <<<"$order")
  status=$(  jq -r '.status' <<<"$order")

  # Record state: fired += triggered, baseline_qty + baseline_at preserved.
  new_fired=$(jq -nc --argjson f "$fired" --argjson t "$triggered" '$f + [$t]')
  pool_set_profit_take_state "$sym" "$new_fired" "$baseline_qty" "$baseline_at"

  # Update last_sell + total_profit. The 2-trading-day buyable cooldown kicks
  # in for this stock — H1B safety floor applies to partials too.
  amt=$(jq -nc --argjson p "$cur_price" --argjson q "$sell_qty" '$p * $q')
  profit=$(jq -nc \
    --argjson p "$cur_price" \
    --argjson b "${last_buy_price:-0}" \
    --argjson q "$sell_qty" '($p - $b) * $q')
  pool_set_last_sell "$sym" "$now" "$cur_price" "$sell_qty" "$amt" "$profit"

  reason=$(printf 'gain %.2f%% hit rung %s%%; sell %.4f of baseline %.4f' \
    "$gain_pct" "$triggered" "$sell_qty" "$baseline_qty")

  orders=$(jq -nc --argjson a "$orders" \
    --arg s "$sym" --argjson q "$sell_qty" --argjson p "$cur_price" \
    --argjson t "$triggered" --argjson g "$gain_pct" \
    --arg id "$order_id" --arg st "$status" --arg r "$reason" '
    $a + [{
      strategy: "profit_take", symbol: $s, side: "sell",
      qty: $q, price: $p, type: "market",
      threshold: $t, gain_pct: $g,
      alpaca_order_id: $id, status: $st, reason: $r
    }]')
done

printf '%s\n' "$orders"
