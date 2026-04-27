#!/usr/bin/env bash
# lib/date.sh — cross-platform date helpers.
#
# Abstracts over GNU coreutils `date` (Linux, Git Bash on Windows, macOS+gdate)
# and BSD `date` (default on macOS). All callers should use these helpers
# instead of `date -d ...` directly so the codebase runs unchanged on any host.
#
# OS detection picks the binary at source-time:
#   Linux / Windows Git Bash → GNU date
#   macOS with `gdate` (brew install coreutils) → GNU date via gdate
#   macOS without gdate     → BSD date with translated flags
#
# Sourced by every helper that does date math.

if [ -n "${_DATE_SH_LOADED:-}" ]; then return 0; fi
_DATE_SH_LOADED=1

_DATE_OS="$(uname -s 2>/dev/null || echo unknown)"

if [ "$_DATE_OS" = "Darwin" ] && command -v gdate >/dev/null 2>&1; then
  _DATE="gdate"
  _DATE_FLAVOR="gnu"
elif [ "$_DATE_OS" = "Darwin" ]; then
  _DATE="date"
  _DATE_FLAVOR="bsd"
else
  # Linux, Windows Git Bash, MSYS, Cygwin — all GNU.
  _DATE="date"
  _DATE_FLAVOR="gnu"
fi

export _DATE _DATE_FLAVOR

# --- now / today helpers ------------------------------------------------------

# date_now_iso → 2026-04-26T18:35:00Z (UTC, second precision)
date_now_iso() {
  $_DATE -u +%Y-%m-%dT%H:%M:%SZ
}

# date_today_utc → 2026-04-26
date_today_utc() {
  $_DATE -u +%Y-%m-%d
}

# date_now_epoch → epoch seconds (UTC)
date_now_epoch() {
  $_DATE -u +%s
}

# --- ISO ↔ epoch --------------------------------------------------------------

# date_iso_to_epoch <iso> — accepts:
#   2026-04-27T16:00:00-04:00  (RFC 3339 with offset)
#   2026-04-27T16:00:00Z       (UTC)
#   2026-04-27T16:00:00        (assume UTC)
#   2026-04-27                 (assume UTC midnight)
# Prints epoch seconds (UTC). Empty/error → empty + non-zero exit.
date_iso_to_epoch() {
  local iso="$1"
  [ -z "$iso" ] && return 1

  if [ "$_DATE_FLAVOR" = "gnu" ]; then
    # If the string has no explicit TZ marker (Z or ±HH[:MM]), force UTC so
    # bare dates and naive timestamps don't get reinterpreted as local time.
    if [[ "$iso" == *Z ]] || [[ "$iso" =~ [+-][0-9]{2}:?[0-9]{2}$ ]]; then
      $_DATE -d "$iso" +%s 2>/dev/null
    else
      TZ=UTC $_DATE -d "$iso" +%s 2>/dev/null
    fi
    return
  fi

  # BSD path: parse manually because BSD `date -j -f` does not understand
  # offsets like "-04:00".
  local base="$iso" tz_secs=0

  if [[ "$iso" == *Z ]]; then
    base="${iso%Z}"
  elif [[ "$iso" =~ ^(.+)([+-])([0-9]{2}):?([0-9]{2})$ ]]; then
    base="${BASH_REMATCH[1]}"
    local sign="${BASH_REMATCH[2]}"
    local tz_h="${BASH_REMATCH[3]}"
    local tz_m="${BASH_REMATCH[4]}"
    tz_secs=$(( 10#${tz_h} * 3600 + 10#${tz_m} * 60 ))
    [ "$sign" = "-" ] && tz_secs=$(( 0 - tz_secs ))
  fi

  local fmt="%Y-%m-%dT%H:%M:%S"
  [[ "$base" != *T* ]] && fmt="%Y-%m-%d"

  local face_epoch
  face_epoch=$($_DATE -j -u -f "$fmt" "$base" +%s 2>/dev/null) || return 1
  # Convert face-value (interpreted as UTC) back to true UTC by removing the
  # offset that was attached to the original string.
  echo $(( face_epoch - tz_secs ))
}

# date_epoch_to_iso <epoch> → 2026-04-26T18:35:00Z (UTC)
date_epoch_to_iso() {
  if [ "$_DATE_FLAVOR" = "gnu" ]; then
    $_DATE -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
  else
    $_DATE -u -r "$1" +%Y-%m-%dT%H:%M:%SZ
  fi
}

# date_epoch_to_filename <epoch> → 2026-04-26T18-35 (filesystem-safe)
date_epoch_to_filename() {
  if [ "$_DATE_FLAVOR" = "gnu" ]; then
    $_DATE -u -d "@$1" +%Y-%m-%dT%H-%M
  else
    $_DATE -u -r "$1" +%Y-%m-%dT%H-%M
  fi
}

# date_iso_to_filename <iso> → 2026-04-26T18-35
date_iso_to_filename() {
  local epoch
  epoch=$(date_iso_to_epoch "$1") || {
    # Last-resort fallback: substitute colons and truncate.
    local s="${1//:/-}"
    echo "${s:0:16}"
    return
  }
  date_epoch_to_filename "$epoch"
}

# --- date arithmetic ----------------------------------------------------------

# date_offset_days <from_yyyy_mm_dd|now> <±N> → YYYY-MM-DD shifted by N days.
# Examples:
#   date_offset_days now -7
#   date_offset_days 2026-04-26 +3
date_offset_days() {
  local from="$1" days="$2"

  if [ "$_DATE_FLAVOR" = "gnu" ]; then
    if [ "$from" = "now" ] || [ -z "$from" ]; then
      $_DATE -u -d "$days days" +%Y-%m-%d
    else
      $_DATE -u -d "$from $days days" +%Y-%m-%d
    fi
    return
  fi

  # BSD: -v flag, sign embedded.
  local sign="+"
  case "$days" in
    -*) sign="-"; days="${days:1}" ;;
    +*) days="${days:1}" ;;
  esac
  if [ "$from" = "now" ] || [ -z "$from" ]; then
    $_DATE -u -v"${sign}${days}d" +%Y-%m-%d
  else
    $_DATE -j -u -v"${sign}${days}d" -f "%Y-%m-%d" "$from" +%Y-%m-%d 2>/dev/null
  fi
}

# date_iso_week <yyyy_mm_dd> → "YYYY-Www" (ISO 8601)
date_iso_week() {
  local d="$1"
  if [ "$_DATE_FLAVOR" = "gnu" ]; then
    $_DATE -d "$d" +%G-W%V
  else
    $_DATE -j -f "%Y-%m-%d" "$d" +%G-W%V 2>/dev/null
  fi
}
