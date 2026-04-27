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
#       "strategy_config": { "trailing_stop": {}, "ladder_buys": {}, "wheel": {} },
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

pool_read() {
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
      strategy_config: { trailing_stop: {}, ladder_buys: {}, wheel: {} },
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

# pool_set_last_sell <symbol> <iso_ts> <price> <qty> <amount_usd> <profit_delta>
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
