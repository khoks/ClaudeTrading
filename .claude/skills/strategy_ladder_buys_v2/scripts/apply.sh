#!/usr/bin/env bash
# strategy_ladder_buys/scripts/apply.sh

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
buyable=$(jq -c '.buyable' <<<"$envelope")

prefs="$REPO_ROOT/persistence/config/user_preferences.json"
max_per_trade=$(jq -r '.max_per_trade_usd // 1000' "$prefs" 2>/dev/null || echo 1000)
cash=$(alpaca_account | jq -r '.cash // "0"')

orders='[]'

for sym in $(jq -r '.[]' <<<"$buyable"); do
  cfg=$(pool_strategy_config "$sym" ladder_buys)
  drop=$(jq -r       '.drop_percent     // 18'   <<<"$cfg")
  amount=$(jq -r     '.buy_amount_usd   // 1000' <<<"$cfg")
  skip_init=$(jq -r  '.skip_initial     // false' <<<"$cfg")

  stock=$(pool_get_stock "$sym")
  baseline=$(jq -r '.last_buy.price // empty' <<<"$stock")

  price=$(alpaca_last_price "$sym" || true)
  [ -z "$price" ] && continue

  trigger="false"
  reason=""
  if [ -z "$baseline" ]; then
    if [ "$skip_init" != "true" ]; then
      trigger="true"
      reason="initial rung at $price (no prior baseline)"
    fi
  else
    threshold=$(jq -nc --argjson b "$baseline" --argjson d "$drop" '$b * (1 - $d/100)')
    trig=$(jq -nc --argjson p "$price" --argjson t "$threshold" '($p <= $t)')
    if [ "$trig" = "true" ]; then
      trigger="true"
      reason=$(printf 'price %s ≤ baseline %s × (1 - %s%%) = %s' "$price" "$baseline" "$drop" "$threshold")
    fi
  fi

  [ "$trigger" != "true" ] && continue

  # Sizing
  notional=$(jq -nc --argjson a "$amount" --argjson m "$max_per_trade" --argjson c "$cash" \
    '[$a, $m, $c] | min')
  too_small=$(jq -nc --argjson n "$notional" '($n <= 0)')
  if [ "$too_small" = "true" ]; then
    orders=$(jq -nc --argjson a "$orders" --arg s "$sym" \
      '$a + [{strategy:"ladder_buys", symbol:$s, status:"skipped", reason:"insufficient cash or cap"}]')
    continue
  fi

  order=$(alpaca_place_order "$sym" buy "\$$notional" market 2>/dev/null) || {
    orders=$(jq -nc --argjson a "$orders" --arg s "$sym" \
      '$a + [{strategy:"ladder_buys", symbol:$s, status:"error", error:"order failed"}]')
    continue
  }
  order_id=$(jq -r '.id'     <<<"$order")
  status=$(  jq -r '.status' <<<"$order")

  qty=$(jq -nc --argjson n "$notional" --argjson p "$price" '$n / $p')
  pool_set_last_buy "$sym" "$now" "$price" "$qty" "$notional"

  # Decrement running cash so subsequent loop iterations see the reduced
  # balance. Without this, N candidates each compute notional against the
  # original cash → over-commitment on a low-cash account.
  cash=$(jq -nc --argjson c "$cash" --argjson n "$notional" '$c - $n')

  orders=$(jq -nc --argjson a "$orders" \
    --arg s "$sym" --argjson q "$qty" --argjson n "$notional" --argjson p "$price" \
    --arg id "$order_id" --arg st "$status" --arg r "$reason" '
    $a + [{
      strategy: "ladder_buys", symbol: $s, side: "buy",
      qty: $q, notional: $n, price: $p, type: "market",
      alpaca_order_id: $id, status: $st, reason: $r
    }]')
done

printf '%s\n' "$orders"
