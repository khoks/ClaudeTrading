#!/usr/bin/env bash
# lib/alpaca.sh — thin curl wrappers around the Alpaca REST API.
#
# Source AFTER lib/env.sh so ALPACA_* vars are set.
#
# All wrappers print raw JSON to stdout. Errors print to stderr and return
# non-zero. Use `jq` to extract fields in callers.
#
# Reference: https://docs.alpaca.markets/docs/trading-api

if [ -z "${ALPACA_KEY:-}" ]; then
  echo "alpaca.sh: source lib/env.sh first" >&2
  return 1 2>/dev/null || exit 1
fi

# --- low-level ---------------------------------------------------------------

# alpaca_curl <method> <url> [json_body]
alpaca_curl() {
  local method="$1" url="$2" body="${3:-}"
  local args=(
    -sS --fail-with-body
    -X "$method"
    -H "APCA-API-KEY-ID: $ALPACA_KEY"
    -H "APCA-API-SECRET-KEY: $ALPACA_SECRET"
    -H "accept: application/json"
  )
  if [ -n "$body" ]; then
    args+=(-H "content-type: application/json" --data "$body")
  fi
  curl "${args[@]}" "$url"
}

alpaca_get()    { alpaca_curl GET    "$ALPACA_BASE$1"; }
alpaca_post()   { alpaca_curl POST   "$ALPACA_BASE$1" "$2"; }
alpaca_delete() { alpaca_curl DELETE "$ALPACA_BASE$1"; }
alpaca_data_get() { alpaca_curl GET  "$ALPACA_DATA_BASE$1"; }

# --- account / clock / calendar ---------------------------------------------

alpaca_account() { alpaca_get "/account"; }
alpaca_clock()   { alpaca_get "/clock"; }

# alpaca_calendar [start_iso_date] [end_iso_date]
alpaca_calendar() {
  local start="${1:-}" end="${2:-}"
  local q=""
  [ -n "$start" ] && q="start=$start"
  [ -n "$end" ]   && q="${q:+$q&}end=$end"
  alpaca_get "/calendar${q:+?$q}"
}

# --- positions ---------------------------------------------------------------

alpaca_positions()         { alpaca_get "/positions"; }
alpaca_position()          { alpaca_get "/positions/$1"; }
alpaca_close_position()    { alpaca_delete "/positions/$1"; }
alpaca_close_all_positions() { alpaca_delete "/positions"; }

# --- orders ------------------------------------------------------------------

# alpaca_orders [status]   status: open | closed | all  (default: open)
alpaca_orders() { alpaca_get "/orders?status=${1:-open}&limit=100"; }
alpaca_order()  { alpaca_get "/orders/$1"; }
alpaca_cancel_order() { alpaca_delete "/orders/$1"; }

# alpaca_place_order <symbol> <side> <qty_or_notional> <type> [extra_json]
#   side:  buy | sell
#   type:  market | limit | stop | stop_limit | trailing_stop
#   third arg detected: integer/decimal → qty, else interpreted as notional via $-prefix
#   extra_json merged into the body (e.g. for limit_price, trail_percent, etc.)
#
# Examples:
#   alpaca_place_order AAPL buy  '$1000' market
#   alpaca_place_order AAPL sell 5      market
#   alpaca_place_order AAPL sell 5      trailing_stop '{"trail_percent":"5"}'
alpaca_place_order() {
  local symbol="$1" side="$2" amount="$3" type="$4" extra="${5:-{\}}"
  local qty_field
  if [[ "$amount" == \$* ]]; then
    qty_field="\"notional\":\"${amount#\$}\""
  else
    qty_field="\"qty\":\"$amount\""
  fi
  local body
  body=$(jq -nc \
    --arg symbol "$symbol" \
    --arg side "$side" \
    --arg type "$type" \
    --argjson qty_field "{$qty_field}" \
    --argjson extra "$extra" \
    '{symbol:$symbol, side:$side, type:$type, time_in_force:"day"} + $qty_field + $extra')
  alpaca_post "/orders" "$body"
}

# --- market data -------------------------------------------------------------

# alpaca_last_trade <symbol> — returns latest trade JSON for symbol.
alpaca_last_trade() { alpaca_data_get "/stocks/$1/trades/latest"; }

# alpaca_latest_quote <symbol>
alpaca_latest_quote() { alpaca_data_get "/stocks/$1/quotes/latest"; }

# alpaca_last_price <symbol> — extracts just the price as a bare number.
alpaca_last_price() {
  alpaca_last_trade "$1" | jq -r '.trade.p // empty'
}

# alpaca_bars <symbol> <timeframe> <start_iso> <end_iso>
#   timeframe examples: 1Min, 5Min, 15Min, 1Hour, 1Day
alpaca_bars() {
  local symbol="$1" tf="$2" start="$3" end="$4"
  alpaca_data_get "/stocks/$symbol/bars?timeframe=$tf&start=$start&end=$end&limit=1000"
}
