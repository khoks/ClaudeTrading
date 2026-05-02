#!/usr/bin/env bash
# strategy_mean_reversion/scripts/apply.sh
#
# Reads JSON envelope on stdin (see SKILL.md). Emits JSON array of placed
# orders to stdout. One bar fetch per buyable candidate; one MA check per
# selected laggard.

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
defaults=$(jq -c '.defaults' <<<"$envelope")

orders='[]'

# Empty-buyable fast path.
if [ "$(jq 'length' <<<"$buyable")" = "0" ]; then
  printf '%s\n' "$orders"
  exit 0
fi

# Pull tunables (envelope.defaults wins; fall back to documented defaults).
lookback=$(    jq -r '.lookback_days                // 5'   <<<"$defaults")
bottom_k=$(    jq -r '.bottom_k                     // 1'   <<<"$defaults")
min_under=$(   jq -r '.min_underperformance_percent // 5'   <<<"$defaults")
buy_amt=$(     jq -r '.buy_amount_usd               // 100' <<<"$defaults")
ma_days=$(     jq -r '.ma_filter_days               // 50'  <<<"$defaults")
min_hrs=$(     jq -r '.min_hours_between_buys       // 2'   <<<"$defaults")

prefs="$REPO_ROOT/persistence/config/user_preferences.json"
max_per_trade=$(jq -r '.max_per_trade_usd // 1000' "$prefs" 2>/dev/null || echo 1000)

# Running cash balance: read once, decrement after each fired order.
cash=$(alpaca_account | jq -r '.cash // "0"')

now_epoch=$(date_iso_to_epoch "$now")
today=$(date_today_utc)
# Look-back window for the bars fetch — generous calendar buffer to span
# weekends + holidays for both the N-day return and the MA tail.
lookback_calendar=$(( ma_days * 2 + 14 ))
start_date=$(date_offset_days "$today" "-$lookback_calendar")

# Fetch bars + compute (return%, ma50, current_close) for one symbol.
# Stdout: single-line JSON object {ret, ma, close} or "null" if unusable.
compute_metrics() {
  local sym="$1" bars
  bars=$(alpaca_bars "$sym" 1Day "$start_date" "$today" 2>/dev/null) || { echo null; return; }
  jq -nc --argjson b "$bars" --argjson lb "$lookback" --argjson md "$ma_days" '
    ($b.bars // []) as $arr
    | ($arr | length) as $n
    | if $n < ($lb + 1) or $n < $md then null
      else
        ($arr[-1].c) as $cur
        | ($arr[-($lb + 1)].c) as $prior
        | (($cur - $prior) / $prior * 100) as $ret
        | ([$arr[-($md):][].c] | add / length) as $ma
        | { ret: $ret, ma: $ma, close: $cur }
      end'
}

# Phase 1: gather metrics for every candidate.
metrics='[]'
for sym in $(jq -r '.[]' <<<"$buyable"); do
  m=$(compute_metrics "$sym")
  if [ "$m" = "null" ] || [ -z "$m" ]; then
    continue
  fi
  metrics=$(jq -nc --argjson a "$metrics" --arg s "$sym" --argjson m "$m" \
    '$a + [{symbol: $s, ret: $m.ret, ma: $m.ma, close: $m.close}]')
done

# If too few candidates have data, nothing to compare against.
if [ "$(jq 'length' <<<"$metrics")" -lt 2 ]; then
  printf '%s\n' "$orders"
  exit 0
fi

# Compute median return across the surveyed candidates.
median=$(jq -nc --argjson a "$metrics" '
  [$a[].ret] | sort | (length / 2 | floor) as $i | .[$i]')

# Rank by underperformance descending, take top bottom_k.
ranked=$(jq -nc --argjson a "$metrics" --argjson med "$median" --argjson k "$bottom_k" '
  [ $a[] | . + { underperf: ($med - .ret) } ]
  | sort_by(-.underperf)
  | .[0:$k]')

# Apply per-candidate filters and place orders.
for row_idx in $(jq -r 'keys[]' <<<"$ranked"); do
  row=$(jq -c ".[$row_idx]" <<<"$ranked")
  sym=$( jq -r '.symbol'      <<<"$row")
  ret=$( jq -r '.ret'         <<<"$row")
  ma=$(  jq -r '.ma'          <<<"$row")
  close=$(jq -r '.close'      <<<"$row")
  underperf=$(jq -r '.underperf' <<<"$row")

  # Filter 1: minimum underperformance.
  qualifies=$(jq -nc --argjson u "$underperf" --argjson t "$min_under" '$u >= $t')
  if [ "$qualifies" != "true" ]; then
    continue
  fi

  # Filter 2: 50-day MA falling-knife guard.
  above_ma=$(jq -nc --argjson c "$close" --argjson m "$ma" '$c >= $m')
  if [ "$above_ma" != "true" ]; then
    orders=$(jq -nc --argjson a "$orders" --arg s "$sym" \
      --argjson u "$underperf" --argjson c "$close" --argjson m "$ma" '
      $a + [{
        strategy: "mean_reversion", symbol: $s, status: "skipped",
        reason: ("below \($m | tostring)-day MA: close=\($c) ma=\($m)"),
        underperformance: $u
      }]')
    continue
  fi

  # Filter 3: rebuy throttle on last_buy.timestamp.
  last_buy_ts=$(pool_get_stock "$sym" | jq -r '.last_buy.timestamp // empty')
  if [ -n "$last_buy_ts" ]; then
    buy_epoch=$(date_iso_to_epoch "$last_buy_ts")
    hours_since=$(( (now_epoch - buy_epoch) / 3600 ))
    if [ "$hours_since" -lt "$min_hrs" ]; then
      orders=$(jq -nc --argjson a "$orders" --arg s "$sym" --argjson h "$hours_since" --argjson m "$min_hrs" '
        $a + [{
          strategy: "mean_reversion", symbol: $s, status: "skipped",
          reason: ("rebuy throttle: last buy \($h)h ago, need \($m)h")
        }]')
      continue
    fi
  fi

  # Filter 4: cash availability.
  notional=$(jq -nc --argjson a "$buy_amt" --argjson m "$max_per_trade" --argjson c "$cash" \
    '[$a, $m, $c] | min')
  too_small=$(jq -nc --argjson n "$notional" '($n <= 0)')
  if [ "$too_small" = "true" ]; then
    orders=$(jq -nc --argjson a "$orders" --arg s "$sym" \
      '$a + [{strategy:"mean_reversion", symbol:$s, status:"skipped", reason:"insufficient cash"}]')
    continue
  fi

  # Place the buy.
  order=$(alpaca_place_order "$sym" buy "\$$notional" market 2>/dev/null) || {
    orders=$(jq -nc --argjson a "$orders" --arg s "$sym" \
      '$a + [{strategy:"mean_reversion", symbol:$s, status:"error", error:"order failed"}]')
    continue
  }
  order_id=$(jq -r '.id'     <<<"$order")
  status=$(  jq -r '.status' <<<"$order")

  qty=$(jq -nc --argjson n "$notional" --argjson p "$close" '$n / $p')
  pool_set_last_buy "$sym" "$now" "$close" "$qty" "$notional"

  # Decrement running cash.
  cash=$(jq -nc --argjson c "$cash" --argjson n "$notional" '$c - $n')

  reason=$(printf 'laggard: %s ret %.2f%% vs median %.2f%% (underperf %.2f%%)' \
    "$sym" "$ret" "$median" "$underperf")

  orders=$(jq -nc --argjson a "$orders" \
    --arg s "$sym" --argjson q "$qty" --argjson n "$notional" --argjson p "$close" \
    --arg id "$order_id" --arg st "$status" --arg r "$reason" '
    $a + [{
      strategy: "mean_reversion", symbol: $s, side: "buy",
      qty: $q, notional: $n, price: $p, type: "market",
      alpaca_order_id: $id, status: $st, reason: $r
    }]')
done

printf '%s\n' "$orders"
