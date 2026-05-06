#!/usr/bin/env bash
# lib/notify.sh — channel-agnostic notification dispatch
#
# This library is sourced by tick.sh and other skill scripts to send
# operator-facing notifications (per-tick action summaries, anomaly alerts,
# daily report links). It is designed to FAIL-SOFT — a notification failure
# never aborts a trading tick.
#
# Public interface
# ----------------
#   notify <message>                 — fire-and-forget to the default channel
#                                      (NOTIFY_DEFAULT_CHANNEL, default: telegram)
#   notify_telegram <message>        — direct Telegram send via Bot API
#   notify_sms_textbelt <phone> <msg>— direct SMS send via TextBelt free tier
#                                      (1 free SMS/day per IP; for testing only)
#   notify_test                      — send "hello from ClaudeTrading" via default
#
# All functions return 0 on success, non-zero on failure. They write success
# notes / failure reasons to stderr so the operator can grep tick logs to
# debug. They never write to stdout — important because tick.sh's stdout is
# the structured JSON envelope.
#
# Required env vars
# -----------------
#   TELEGRAM_BOT_TOKEN   — bot token from @BotFather (telegram channel)
#   TELEGRAM_CHAT_ID     — operator's chat_id (see docs/SETUP_TELEGRAM.md)
#   NOTIFY_DEFAULT_CHANNEL — optional: "telegram" (default) or "sms_textbelt"
#                            (sms_textbelt is for ad-hoc testing, not production)
#
# Failure modes
# -------------
#   - Missing creds: log to stderr, return 1, continue. tick.sh proceeds.
#   - Network failure: log to stderr, return 1, continue.
#   - API error from Telegram: log to stderr with API description, return 1.
#   - 4xx/5xx from TextBelt: log to stderr, return 1.

# Default channel — operators can override in .env
: "${NOTIFY_DEFAULT_CHANNEL:=telegram}"

# Internal: log a notify message to stderr with a tag prefix so it's easy
# to find in tick transcripts.
_notify_log() {
  echo "[notify] $*" >&2
}

# Send via Telegram Bot API.
# Uses MarkdownV2 parse mode by default; pass NOTIFY_NO_MARKDOWN=1 to send raw.
notify_telegram() {
  local msg=$1
  local token=${TELEGRAM_BOT_TOKEN:-}
  local chat_id=${TELEGRAM_CHAT_ID:-}

  if [ -z "$msg" ]; then
    _notify_log "telegram skipped: empty message"
    return 1
  fi
  if [ -z "$token" ] || [ -z "$chat_id" ]; then
    _notify_log "telegram skipped: TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not set in .env"
    _notify_log "  see docs/SETUP_TELEGRAM.md for the 5-minute bot creation walkthrough"
    return 1
  fi

  local parse_mode="Markdown"
  if [ "${NOTIFY_NO_MARKDOWN:-0}" = "1" ]; then
    parse_mode=""
  fi

  # Build curl args. --data-urlencode handles the message body safely; the
  # other fields are simple ASCII so plain -d is fine.
  local response http_code
  response=$(curl -s --max-time 10 -w "\n%{http_code}" \
    -X POST "https://api.telegram.org/bot${token}/sendMessage" \
    -d "chat_id=${chat_id}" \
    --data-urlencode "text=${msg}" \
    ${parse_mode:+-d "parse_mode=${parse_mode}"} 2>&1)
  http_code=$(printf '%s\n' "$response" | tail -n1)
  local body
  body=$(printf '%s\n' "$response" | sed '$d')

  if [ "$http_code" != "200" ]; then
    local err
    err=$(printf '%s' "$body" | jq -r '.description // empty' 2>/dev/null)
    _notify_log "telegram HTTP $http_code: ${err:-$body}"
    return 1
  fi

  if ! printf '%s' "$body" | jq -e '.ok == true' >/dev/null 2>&1; then
    local err
    err=$(printf '%s' "$body" | jq -r '.description // "unknown"' 2>/dev/null)
    _notify_log "telegram api error: $err"
    return 1
  fi

  return 0
}

# Send via TextBelt (free tier: 1 SMS/day per IP, no auth needed).
# Phone format: E.164 like +15734620375 (digits only with leading +). The
# function strips spaces, dashes, and parentheses for convenience.
#
# Warning: free tier is shared across all callers globally and may be
# exhausted on any given day. Production SMS should use Twilio / Vonage
# / AWS SNS with a paid account. This function exists for ad-hoc testing.
notify_sms_textbelt() {
  local phone=$1
  local msg=$2

  if [ -z "$phone" ] || [ -z "$msg" ]; then
    _notify_log "sms_textbelt skipped: phone or message empty"
    return 1
  fi

  # Sanitize phone: keep only + and digits.
  local clean_phone
  clean_phone=$(printf '%s' "$phone" | tr -dc '+0-9')

  # If TEXTBELT_KEY is set in env, use it (paid quota); else use the free
  # shared 'textbelt' key.
  local key="${TEXTBELT_KEY:-textbelt}"

  local response http_code
  response=$(curl -s --max-time 15 -w "\n%{http_code}" \
    -X POST https://textbelt.com/text \
    --data-urlencode "phone=${clean_phone}" \
    --data-urlencode "message=${msg}" \
    --data-urlencode "key=${key}" 2>&1)
  http_code=$(printf '%s\n' "$response" | tail -n1)
  local body
  body=$(printf '%s\n' "$response" | sed '$d')

  if [ "$http_code" != "200" ]; then
    _notify_log "textbelt HTTP $http_code: $body"
    return 1
  fi

  local ok
  ok=$(printf '%s' "$body" | jq -r '.success // false' 2>/dev/null)
  if [ "$ok" != "true" ]; then
    local err quota
    err=$(printf '%s' "$body" | jq -r '.error // "unknown"' 2>/dev/null)
    quota=$(printf '%s' "$body" | jq -r '.quotaRemaining // "?"' 2>/dev/null)
    _notify_log "textbelt failed: $err (quotaRemaining=$quota)"
    return 1
  fi

  local quota
  quota=$(printf '%s' "$body" | jq -r '.quotaRemaining // "?"' 2>/dev/null)
  _notify_log "textbelt sent OK (quotaRemaining=$quota)"
  return 0
}

# Dispatch to default channel.
notify() {
  local msg=$1
  case "$NOTIFY_DEFAULT_CHANNEL" in
    telegram)
      notify_telegram "$msg"
      ;;
    sms_textbelt)
      local phone="${NOTIFY_DEFAULT_PHONE:-}"
      if [ -z "$phone" ]; then
        _notify_log "sms_textbelt default channel requires NOTIFY_DEFAULT_PHONE in .env"
        return 1
      fi
      notify_sms_textbelt "$phone" "$msg"
      ;;
    none)
      # Operator explicitly disabled notifications.
      return 0
      ;;
    *)
      _notify_log "unknown channel: $NOTIFY_DEFAULT_CHANNEL"
      return 1
      ;;
  esac
}

# Quick connectivity test — useful for "did I set the creds right?" checks.
notify_test() {
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  notify "ClaudeTrading test message
Sent at $now
If you see this, notifications are working."
}
