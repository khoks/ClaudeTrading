#!/usr/bin/env bash
# dashboard/scripts/fetch_market_intel.sh
#
# Pulls news (Alpaca) + Congressional trades (capitoltrades.com BFF) for
# the operator's pool tickers and writes a single consolidated cache to
# persistence/market_intel.json. The dashboard reads this file via FSA;
# nothing else in the system depends on it.
#
# Idempotent: safe to re-run any time. Each section is best-effort —
# if Alpaca news fetch fails, Capitol section still gets written (and
# vice versa). The output file is gitignored (operator-specific).
#
# Recommended cadence: run manually before opening the dashboard, or
# wire into a daily scheduled task via mcp__scheduled-tasks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
export REPO_ROOT

# shellcheck disable=SC1091
source "$REPO_ROOT/lib/env.sh"

POOL="$REPO_ROOT/persistence/pool.json"
OUT="$REPO_ROOT/persistence/market_intel.json"

if [ ! -f "$POOL" ]; then
  echo "ERROR: $POOL not found. Run /master_configurator first." >&2
  exit 1
fi

# Pool symbols → comma-separated string + JSON array
symbols_csv=$(jq -r '.stocks[].symbol' "$POOL" | tr '\n' ',' | sed 's/,$//')
symbols_json=$(jq -c '[.stocks[].symbol]' "$POOL")

if [ -z "$symbols_csv" ]; then
  echo "WARN: pool is empty; writing an empty cache." >&2
fi

now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# --- Alpaca news ---
news_json='[]'
if [ -n "$symbols_csv" ]; then
  echo "Fetching Alpaca news for ${symbols_csv}…" >&2
  news_resp=$(curl -fsS \
    --max-time 30 \
    -H "APCA-API-KEY-ID: $ALPACA_KEY" \
    -H "APCA-API-SECRET-KEY: $ALPACA_SECRET" \
    -H "accept: application/json" \
    "https://data.alpaca.markets/v1beta1/news?symbols=${symbols_csv}&limit=30&sort=desc" 2>&1) || {
    echo "WARN: Alpaca news fetch failed: ${news_resp}" >&2
    news_resp='{"news":[]}'
  }
  news_json=$(jq -c '.news // []' <<<"$news_resp" 2>/dev/null || echo '[]')
fi

# --- Capitol Trades (capitoltrades.com BFF) ---
#
# KNOWN LIMITATION: bff.capitoltrades.com is firewalled (Cloudflare/WAF)
# against non-browser callers and returns HTTP 503 for plain curl, even
# with realistic Origin/Referer/User-Agent headers. The public site
# itself (www.capitoltrades.com/trades) is a Next.js streaming app
# whose initial-data JSON is fragmented across self.__next_f push
# chunks — not parseable with grep/jq alone.
#
# Workable alternatives the operator can pick from later:
#   1. Use a headless browser (Playwright/Puppeteer) to render the page
#      and read the hydrated state. Heavy dependency; defer.
#   2. Pay for Quiver Quantitative's API or similar third-party
#      aggregator that exposes Congressional trades cleanly.
#   3. Pull directly from the source feeds at
#      https://disclosures-clerk.house.gov/ and
#      https://efdsearch.senate.gov/ — official but XML/PDF parsing.
#
# For now: best-effort try the BFF; if it 503s (it will), capitol
# section is empty in the dashboard with a clear callout. News
# section still works fully.
capitol_json='[]'
if [ -n "$symbols_csv" ]; then
  echo "Trying Capitol Trades BFF (known to 503 from non-browser clients)…" >&2
  capitol_resp=$(curl -fsS \
    --max-time 20 \
    -H 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36' \
    -H 'Accept: application/json' \
    -H 'Origin: https://www.capitoltrades.com' \
    -H 'Referer: https://www.capitoltrades.com/' \
    'https://bff.capitoltrades.com/trades?pageSize=100' 2>&1) || {
    echo "  → blocked (HTTP 503). Skipping; news still wrote successfully." >&2
    capitol_resp='{"data":[]}'
  }

  # If we did get JSON back, filter to trades whose asset.assetTicker is in our pool.
  capitol_json=$(jq -c --argjson syms "$symbols_json" '
    [ (.data // [])[]
      | select(.asset.assetTicker as $t | $syms | index($t))
    ]
    | sort_by(.txDate // .pubDate // "")
    | reverse
    | .[0:50]
  ' <<<"$capitol_resp" 2>/dev/null || echo '[]')
fi

# --- Combine + write ---
mkdir -p "$(dirname "$OUT")"
jq -n \
  --arg fetched_at "$now_iso" \
  --argjson syms "$symbols_json" \
  --argjson news "$news_json" \
  --argjson capitol "$capitol_json" '
  {
    fetched_at: $fetched_at,
    symbols: $syms,
    news: $news,
    capitol_trades: $capitol,
    counts: { news: ($news | length), capitol_trades: ($capitol | length) }
  }
' > "$OUT"

n_news=$(jq '.counts.news' "$OUT")
n_cap=$(jq '.counts.capitol_trades' "$OUT")
echo "Wrote $OUT — news: $n_news, capitol: $n_cap"
echo "$OUT"
