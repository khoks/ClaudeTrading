#!/usr/bin/env bash
# lib/calendar.sh — market hours and trading-day math via Alpaca's calendar API.
#
# Sources required: lib/env.sh (which auto-sources lib/date.sh), lib/alpaca.sh.

if [ -z "${ALPACA_KEY:-}" ]; then
  echo "calendar.sh: source lib/env.sh and lib/alpaca.sh first" >&2
  return 1 2>/dev/null || exit 1
fi

# is_market_open — exit 0 if market currently open, 1 otherwise.
is_market_open() {
  local open
  open=$(alpaca_clock | jq -r '.is_open')
  [ "$open" = "true" ]
}

# market_close_iso — prints today's market close timestamp (ISO-8601 with TZ).
market_close_iso() {
  alpaca_clock | jq -r '.next_close'
}

# is_last_tick_of_trading_day — true if (now + 5 min) >= today's market_close.
# Used by state_persistence to decide whether to also write a daily snapshot.
is_last_tick_of_trading_day() {
  local close_iso close_epoch now_epoch
  close_iso=$(alpaca_clock | jq -r '.next_close')
  close_epoch=$(date_iso_to_epoch "$close_iso") || return 1
  now_epoch=$(date_now_epoch)
  # Within 5 minutes (300s) of close → treat as last tick.
  [ $(( close_epoch - now_epoch )) -le 300 ]
}

# is_last_trading_day_of_week — true if today is the last trading day of the
# current ISO week (calendar API: next trading day's ISO week ≠ today's).
is_last_trading_day_of_week() {
  local today next today_week next_week end
  today=$(date_today_utc)
  end=$(date_offset_days "$today" "+7")
  next=$(alpaca_calendar "$today" "$end" \
    | jq -r --arg t "$today" '[.[] | select(.date > $t)] | first | .date // empty')
  [ -z "$next" ] && return 1
  today_week=$(date_iso_week "$today")
  next_week=$(date_iso_week "$next")
  [ "$today_week" != "$next_week" ]
}

# trading_days_ago <iso_timestamp> — prints the integer number of trading days
# strictly elapsed between <iso_timestamp> and now (US Eastern).
#
# Implementation:
#   1. Pull calendar between the date of <iso_timestamp> and today.
#   2. Count entries whose date is strictly greater than <iso_timestamp>'s date
#      and strictly less than today's date.
#   3. Both endpoint days are excluded — so a buy yesterday returns 0, a buy
#      two trading days ago returns 1, three trading days ago returns 2, etc.
#
# The safe_trading rule "older than 2 trading days" therefore checks ≥ 2.
trading_days_ago() {
  local iso="${1:-}"
  if [ -z "$iso" ]; then echo 0; return; fi
  local from to from_epoch
  from_epoch=$(date_iso_to_epoch "$iso") || { echo 0; return; }
  if [ "$_DATE_FLAVOR" = "gnu" ]; then
    from=$($_DATE -u -d "@$from_epoch" +%Y-%m-%d)
  else
    from=$($_DATE -u -r "$from_epoch" +%Y-%m-%d)
  fi
  to=$(date_today_utc)
  if [ "$from" = "$to" ]; then echo 0; return; fi
  alpaca_calendar "$from" "$to" \
    | jq --arg from "$from" --arg to "$to" \
        '[.[] | select(.date > $from and .date < $to)] | length'
}

# trading_days_old_enough <iso_timestamp> <threshold>
# Exit 0 if trading_days_ago >= threshold, else 1.
# Convention used by safe_trading: threshold = 2.
trading_days_old_enough() {
  local n
  n=$(trading_days_ago "$1")
  [ "$n" -ge "$2" ]
}
