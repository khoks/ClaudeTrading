#!/usr/bin/env bash
# lib/tz.sh — translate the PT-based market-hours cron to the operator's
# local timezone.
#
# US market hours: 9:30 AM – 4:00 PM ET = 6:30 AM – 1:00 PM PT.
# Our base tick window is hours 6–12 PT (covers pre-market through the
# last useful tick at 12:45 PT, 15 min before close).
#
# `mcp__scheduled-tasks` evaluates cron in the operator's local timezone,
# not UTC, so this helper computes the equivalent local hour range.

if [ -n "${_TZ_SH_LOADED:-}" ]; then return 0; fi
_TZ_SH_LOADED=1

# _tz_offset_minutes [<zone>] — UTC offset of <zone> (or system TZ if empty)
# in minutes. e.g. PT (PDT) → -420, ET (EDT) → -240, UTC → 0, IST → 330.
_tz_offset_minutes() {
  local tz="${1:-}"
  local raw sign h m val
  if [ -n "$tz" ]; then
    raw=$(TZ="$tz" date +%z 2>/dev/null) || { echo 0; return; }
  else
    raw=$(date +%z 2>/dev/null) || { echo 0; return; }
  fi
  # raw is "+HHMM" or "-HHMM"
  sign="${raw:0:1}"
  h="${raw:1:2}"
  m="${raw:3:2}"
  val=$((10#${h} * 60 + 10#${m}))
  [ "$sign" = "-" ] && val=$((0 - val))
  echo "$val"
}

# market_cron <cadence_minutes>
# Prints a 5-field cron expression that fires every <cadence_minutes>
# minutes during the local-TZ equivalent of 06:00–12:45 PT, Mon–Fri.
#
# Returns non-zero (and prints to stderr) if the operator's TZ has a
# half-hour offset relative to PT (e.g. IST, NPT) or if the equivalent
# window wraps past midnight — those need manual cron entry.
market_cron() {
  local cadence="${1:-15}"
  local local_off pt_off shift_min shift_h shift_m start_h end_h

  local_off=$(_tz_offset_minutes)
  # Use POSIX TZ string (PST8PDT) instead of IANA name. Git Bash on
  # Windows ships with mingw `date` which does not resolve IANA zones
  # like "America/Los_Angeles" — it returns +0000. POSIX TZ format
  # works on Linux, macOS, and Windows Git Bash.
  pt_off=$(_tz_offset_minutes "PST8PDT")
  shift_min=$(( local_off - pt_off ))
  shift_h=$(( shift_min / 60 ))
  shift_m=$(( shift_min % 60 ))

  if [ "$shift_m" != 0 ]; then
    echo "tz.sh: local TZ has a non-integer-hour offset from PT (${shift_min}min); cannot auto-compute cron. Set your machine TZ to a US zone or pass a cron expression manually." >&2
    return 1
  fi

  start_h=$(( 6 + shift_h ))
  end_h=$(( 12 + shift_h ))

  if [ "$start_h" -lt 0 ] || [ "$start_h" -gt 23 ] || [ "$end_h" -lt 0 ] || [ "$end_h" -gt 23 ]; then
    echo "tz.sh: equivalent local window wraps past midnight (${start_h}-${end_h}); cron 5-field syntax can't express this cleanly. Set your machine TZ to a US zone or pass a cron expression manually." >&2
    return 1
  fi

  echo "*/${cadence} ${start_h}-${end_h} * * 1-5"
}

# market_cron_describe <cadence_minutes>
# Human-readable description of where ticks will fire and what that maps
# to in PT. Useful for the configurator's confirmation summary.
market_cron_describe() {
  local cadence="${1:-15}"
  local cron local_tz pt_tz local_off_h pt_off_h
  cron=$(market_cron "$cadence") || { echo "(could not auto-compute)"; return; }

  local_tz=$(date +%Z 2>/dev/null || echo "?")
  pt_tz=$(TZ=PST8PDT date +%Z 2>/dev/null || echo "PT")

  # Extract hour range from the cron we just generated.
  local hr_range
  hr_range=$(echo "$cron" | awk '{print $2}')

  printf 'cadence=%dm  cron="%s"  local_tz=%s  fires=hours %s local  equiv=06:00-12:45 %s' \
    "$cadence" "$cron" "$local_tz" "$hr_range" "$pt_tz"
}
