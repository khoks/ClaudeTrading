#!/usr/bin/env bash
# strategy_trailing_stop/scripts/apply.sh
#
# Reads JSON envelope on stdin (see SKILL.md for shape).
# Emits JSON array of placed orders to stdout.

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

for sym in $(jq -r '.[]' <<<"$sellable"); do
  cfg=$(pool_strategy_config "$sym" trailing_stop)
  drop=$(jq -r '.drop_percent  // 5'  <<<"$cfg")
  raise=$(jq -r '.raise_percent // 10' <<<"$cfg")

  stock=$(pool_get_stock "$sym")
  last_buy_price=$(jq -r '.last_buy.price       // empty' <<<"$stock")
  watermark=$(     jq -r '.high_watermark        // empty' <<<"$stock")
  stop_price=$(    jq -r '.stop_loss.price       // empty' <<<"$stock")

  price=$(alpaca_last_price "$sym" || true)
  [ -z "$price" ] && continue

  # Initialize watermark on first observation.
  if [ -z "$watermark" ]; then
    if [ -n "$last_buy_price" ]; then
      watermark=$(jq -nc --argjson a "$last_buy_price" --argjson b "$price" '[$a,$b] | max')
    else
      watermark="$price"
    fi
  fi

  # Should we bump? new_watermark = max(current, watermark) but only commit if
  # current ≥ watermark * (1 + raise/100). Using jq for the float math.
  bump=$(jq -nc \
    --argjson p "$price" \
    --argjson w "$watermark" \
    --argjson r "$raise" \
    '($p >= ($w * (1 + $r/100)))')
  if [ "$bump" = "true" ]; then
    watermark="$price"
    new_stop=$(jq -nc --argjson p "$price" --argjson d "$drop" '$p * (1 - $d/100)')
    pool_set_watermark "$sym" "$watermark"
    pool_set_stop_loss "$sym" "$new_stop" "$drop"
    stop_price="$new_stop"
  fi

  # Compute the active stop price if we don't have one yet.
  if [ -z "$stop_price" ]; then
    stop_price=$(jq -nc --argjson w "$watermark" --argjson d "$drop" '$w * (1 - $d/100)')
    pool_set_stop_loss "$sym" "$stop_price" "$drop"
  fi

  # Trigger sell?
  trigger=$(jq -nc --argjson p "$price" --argjson s "$stop_price" '($p <= $s)')
  [ "$trigger" != "true" ] && continue

  position=$(alpaca_position "$sym" 2>/dev/null || echo '{}')
  qty=$(jq -r '.qty // empty' <<<"$position")
  if [ -z "$qty" ] || [ "$qty" = "0" ]; then
    continue
  fi

  order=$(alpaca_place_order "$sym" sell "$qty" market 2>/dev/null) || {
    orders=$(jq -nc --argjson a "$orders" --arg s "$sym" \
      '$a + [{strategy:"trailing_stop", symbol:$s, status:"error", error:"order failed"}]')
    continue
  }
  order_id=$(jq -r '.id'     <<<"$order")
  status=$(  jq -r '.status' <<<"$order")

  amt=$(jq -nc --argjson p "$price" --argjson q "$qty" '$p * $q')
  profit=$(jq -nc --argjson p "$price" --argjson b "${last_buy_price:-0}" --argjson q "$qty" \
    '($p - $b) * $q')
  pool_set_last_sell "$sym" "$now" "$price" "$qty" "$amt" "$profit"

  reason=$(printf 'price %.4f hit stop %.4f (watermark %.4f, drop %d%%)' \
    "$price" "$stop_price" "$watermark" "$drop")

  orders=$(jq -nc --argjson a "$orders" \
    --arg s "$sym" --argjson q "$qty" --argjson p "$price" \
    --arg id "$order_id" --arg st "$status" --arg r "$reason" '
    $a + [{
      strategy: "trailing_stop", symbol: $s, side: "sell",
      qty: $q, price: $p, type: "market",
      alpaca_order_id: $id, status: $st, reason: $r
    }]')
done

printf '%s\n' "$orders"
