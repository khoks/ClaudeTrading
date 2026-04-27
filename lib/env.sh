#!/usr/bin/env bash
# lib/env.sh — load Alpaca credentials.
#
# Local dev:  reads .env at the repo root.
# Remote scheduled agent: .env will not exist; relies on env vars injected by
#                         mcp__scheduled-tasks at task creation time.
#
# Sourced by every skill script. Defines:
#   REPO_ROOT        — absolute path to the repo root
#   ALPACA_KEY       — paper API key
#   ALPACA_SECRET    — paper API secret
#   ALPACA_BASE      — trading API base URL (default: paper)
#   ALPACA_DATA_BASE — market data API base URL

# Resolve REPO_ROOT relative to this file (lib/env.sh → repo root is parent dir).
_env_self="${BASH_SOURCE[0]}"
_env_dir="$(cd "$(dirname "$_env_self")" && pwd)"
export REPO_ROOT="$(cd "$_env_dir/.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$REPO_ROOT/.env"
  set +a
fi

: "${ALPACA_KEY:?ALPACA_KEY missing — set it in .env or as an env var}"
: "${ALPACA_SECRET:?ALPACA_SECRET missing — set it in .env or as an env var}"
: "${ALPACA_BASE:=https://paper-api.alpaca.markets/v2}"
: "${ALPACA_DATA_BASE:=https://data.alpaca.markets/v2}"

export ALPACA_KEY ALPACA_SECRET ALPACA_BASE ALPACA_DATA_BASE
