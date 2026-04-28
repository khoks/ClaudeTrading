#!/usr/bin/env bash
# lib/pool.sh — read/write persistence/pool.json with jq.
#
# pool.json schema:
# {
#   "stocks": [
#     {
#       "symbol": "AAPL",
#       "added_at": "ISO-8601",
#       "last_buy":  { "timestamp": null, "price": null, "qty": null, "amount_usd": null },
#       "last_sell": { "timestamp": null, "price": null, "qty": null, "amount_usd": null },
#       "high_watermark": null,
#       "stop_loss":   { "price": null, "trail_percent": null },
#       "strategy_config": {
#         "trailing_stop": {},
#         "ladder_buys": { "consecutive_buys": 0, "consecutive_invested_usd": 0 },
#         "wheel": {},
#         "mean_reversion": {},
#         "profit_take": { "fired_thresholds": [], "baseline_qty": null, "last_baseline_at": null }
#       },
#       "total_profit_usd": 0,
#       "total_invested_usd": 0
#     }
#   ],
#   "last_updated": "ISO-8601"
# }
#
# Per-stock strategy_config keys override values in
# persistence/config/strategy_defaults.json. Empty {} → use defaults.

if [ -z "${REPO_ROOT:-}" ]; then
  echo "pool.sh: source lib/env.sh first" >&2
  return 1 2>/dev/null || exit 1
fi

POOL_FILE="$REPO_ROOT/persistence/pool.json"

# pool_read — print pool.json. Auto-creates an empty pool on first call so
# fresh clones (where pool.json is gitignored) work without manual setup.
# The first writer / pool_add_stock call will populate it.
pool_read() {
  if [ ! -f "$POOL_FILE" ]; then
    mkdir -p "$(dirname "$POOL_FILE")"
    echo '{"stocks": [], "last_updated": null}' > "$POOL_FILE"
  fi
  cat "$POOL_FILE"
}

# pool_write <json> — atomically replaces pool.json.
# (CRLF stripping is handled by the jq shim in lib/env.sh.)
pool_write() {
  local tmp
  tmp="$(mktemp)"
  printf '%s' "$1" | jq '.last_updated = (now | todate)' > "$tmp"
  mv "$tmp" "$POOL_FILE"
}

pool_symbols() {
  pool_read | jq -r '.stocks[].symbol'
}

# pool_get_stock <symbol>
pool_get_stock() {
  pool_read | jq --arg s "$1" '.stocks[] | select(.symbol == $s)'
}

# pool_add_stock <symbol> — adds with empty trade history if not present.
pool_add_stock() {
  local symbol="$1" now updated
  now="$(date_now_iso)"
  updated=$(pool_read | jq --arg s "$symbol" --arg t "$now" '
    if (.stocks | map(.symbol) | index($s)) then .
    else .stocks += [{
      symbol: $s,
      added_at: $t,
      last_buy:  { timestamp: null, price: null, qty: null, amount_usd: null },
      last_sell: { timestamp: null, price: null, qty: null, amount_usd: null },
      high_watermark: null,
      stop_loss: { price: null, trail_percent: null },
      strategy_config: {
        trailing_stop: {},
        ladder_buys: { consecutive_buys: 0, consecutive_invested_usd: 0 },
        wheel: {},
        mean_reversion: {},
        profit_take: { fired_thresholds: [], baseline_qty: null, last_baseline_at: null }
      },
      total_profit_usd: 0,
      total_invested_usd: 0
    }] end')
  pool_write "$updated"
}

# pool_set_last_buy <symbol> <iso_ts> <price> <qty> <amount_usd>
pool_set_last_buy() {
  local s="$1" ts="$2" price="$3" qty="$4" amt="$5" updated
  updated=$(pool_read | jq \
    --arg s "$s" --arg ts "$ts" \
    --argjson price "$price" --argjson qty "$qty" --argjson amt "$amt" '
    .stocks |= map(
      if .symbol == $s then
        .last_buy = { timestamp: $ts, price: $price, qty: $qty, amount_usd: $amt }
        | .total_invested_usd += $amt
      else . end
    )')
  pool_write "$updated"
}

# pool_increment_ladder_consecutive <symbol> <amount_usd>
# Bumps the ladder_buys counters after a buy: rung count +1, invested notional
# += amount_usd. Treats missing fields as 0 so this is safe to call on stocks
# whose strategy_config.ladder_buys was previously {} (pre-counter pool).
pool_increment_ladder_consecutive() {
  local s="$1" amt="$2" updated
  updated=$(pool_read | jq --arg s "$s" --argjson amt "$amt" '
    .stocks |= map(
      if .symbol == $s then
        .strategy_config.ladder_buys.consecutive_buys =
          ((.strategy_config.ladder_buys.consecutive_buys // 0) + 1)
        | .strategy_config.ladder_buys.consecutive_invested_usd =
          ((.strategy_config.ladder_buys.consecutive_invested_usd // 0) + $amt)
      else . end
    )')
  pool_write "$updated"
}

# pool_set_last_sell <symbol> <iso_ts> <price> <qty> <amount_usd> <profit_delta>
# Also resets the ladder_buys consecutive counters so the next drawdown gets
# a fresh ladder budget. This applies to any sell — partial (profit_take) or
# full (trailing_stop) — because either way the operator has signalled the
# previous accumulation cycle is closing out.
pool_set_last_sell() {
  local s="$1" ts="$2" price="$3" qty="$4" amt="$5" profit="${6:-0}" updated
  updated=$(pool_read | jq \
    --arg s "$s" --arg ts "$ts" \
    --argjson price "$price" --argjson qty "$qty" \
    --argjson amt "$amt" --argjson profit "$profit" '
    .stocks |= map(
      if .symbol == $s then
        .last_sell = { timestamp: $ts, price: $price, qty: $qty, amount_usd: $amt }
        | .total_profit_usd += $profit
        | .strategy_config.ladder_buys.consecutive_buys = 0
        | .strategy_config.ladder_buys.consecutive_invested_usd = 0
      else . end
    )')
  pool_write "$updated"
}

# pool_set_watermark <symbol> <price>
pool_set_watermark() {
  local s="$1" price="$2" updated
  updated=$(pool_read | jq --arg s "$s" --argjson p "$price" '
    .stocks |= map(if .symbol == $s then .high_watermark = $p else . end)')
  pool_write "$updated"
}

# pool_set_stop_loss <symbol> <price> <trail_percent>
pool_set_stop_loss() {
  local s="$1" price="$2" trail="$3" updated
  updated=$(pool_read | jq --arg s "$s" --argjson p "$price" --argjson t "$trail" '
    .stocks |= map(if .symbol == $s then
      .stop_loss = { price: $p, trail_percent: $t } else . end)')
  pool_write "$updated"
}

# pool_set_profit_take_state <symbol> <fired_thresholds_json> <baseline_qty_or_null> <last_baseline_at_or_empty>
# Writes the full profit_take state. Pass "null" (literal) for baseline_qty to clear it,
# or an empty string for last_baseline_at to clear it.
pool_set_profit_take_state() {
  local s="$1" fired="$2" bq="$3" ba="$4" updated
  updated=$(pool_read | jq \
    --arg s "$s" --argjson f "$fired" \
    --argjson bq "$bq" --arg ba "$ba" '
    .stocks |= map(
      if .symbol == $s then
        .strategy_config.profit_take = {
          fired_thresholds: $f,
          baseline_qty: $bq,
          last_baseline_at: (if $ba == "" then null else $ba end)
        }
      else . end
    )')
  pool_write "$updated"
}

# pool_strategy_config <symbol> <strategy_name>
# Prints the merged JSON object: defaults <- per-stock overrides.
pool_strategy_config() {
  local s="$1" strat="$2"
  local defaults overrides
  defaults=$(jq --arg k "$strat" '.[$k] // {}' "$REPO_ROOT/persistence/config/strategy_defaults.json")
  overrides=$(pool_read | jq --arg s "$s" --arg k "$strat" \
    '.stocks[] | select(.symbol == $s) | .strategy_config[$k] // {}')
  jq -nc --argjson d "$defaults" --argjson o "$overrides" '$d * $o'
}
