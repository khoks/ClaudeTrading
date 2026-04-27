#!/usr/bin/env bash
# reporting/scripts/generate_report.sh
#
# Builds a self-contained HTML report at persistence/reports/<YYYY-MM-DD>.html.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
export REPO_ROOT

# shellcheck disable=SC1091
source "$REPO_ROOT/lib/env.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/alpaca.sh"

today=$(date_today_utc)
out="$REPO_ROOT/persistence/reports/${today}.html"

# Live data
account=$(alpaca_account)
positions=$(alpaca_positions)
equity=$(  jq -r '.equity'        <<<"$account")
cash=$(    jq -r '.cash'          <<<"$account")
buying=$(  jq -r '.buying_power'  <<<"$account")

# Most recent daily snapshot for prior-day comparison.
prev_daily=$(ls -1 "$REPO_ROOT/persistence/snapshots/daily/"*.json 2>/dev/null | tail -1 || true)

# Pool
pool=$(cat "$REPO_ROOT/persistence/pool.json")

# Activation
activation_file="$REPO_ROOT/persistence/config/activation.json"
activation=$( [ -f "$activation_file" ] && cat "$activation_file" || echo '{}')

# Past 30 days of daily snapshots → strategy effectiveness.
shopt -s nullglob
all_dailies=( "$REPO_ROOT/persistence/snapshots/daily/"*.json )
shopt -u nullglob

# Take the last 30 entries (sorted by name = sorted by date).
n=${#all_dailies[@]}
recent_dailies=()
if [ "$n" -gt 0 ]; then
  start=$(( n > 30 ? n - 30 : 0 ))
  recent_dailies=( "${all_dailies[@]:$start}" )
fi

if [ ${#recent_dailies[@]} -gt 0 ]; then
  strat_counts=$(jq -s '
    [ .[].actions[]? | select(.strategy != null) ]
    | group_by(.strategy)
    | map({
        strategy: .[0].strategy,
        order_count: length,
        successful: ([ .[] | select(.status == "filled" or .status == "submitted" or .status == "accepted") ] | length)
      })' "${recent_dailies[@]}")
else
  strat_counts='[]'
fi

# Helper: HTML-escape JSON strings for safe inline display.
esc() { jq -Rr @html <<<"$1"; }

# Build the HTML inline.
{
cat <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<title>ClaudeTrading Report — $today</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
         background: #0d1117; color: #c9d1d9; margin: 0; padding: 2rem; }
  h1 { color: #58a6ff; margin-top: 0; }
  h2 { color: #58a6ff; border-bottom: 1px solid #30363d; padding-bottom: 0.3rem; }
  table { border-collapse: collapse; width: 100%; margin: 0.5rem 0 1.5rem; }
  th, td { border: 1px solid #30363d; padding: 0.4rem 0.6rem; text-align: left; }
  th { background: #161b22; }
  .pos { color: #56d364; }
  .neg { color: #f85149; }
  .small { color: #8b949e; font-size: 0.85em; }
  pre { background: #161b22; padding: 1rem; overflow-x: auto; border-radius: 4px; }
</style>
</head>
<body>

<h1>ClaudeTrading — $today</h1>
<p class="small">Generated $(date_now_iso)</p>

<h2>Account</h2>
<table>
  <tr><th>Equity</th><td>\$$equity</td></tr>
  <tr><th>Cash</th><td>\$$cash</td></tr>
  <tr><th>Buying power</th><td>\$$buying</td></tr>
</table>

<h2>Open positions</h2>
EOF

if [ "$(jq 'length' <<<"$positions")" = "0" ]; then
  echo "<p>No open positions.</p>"
else
  echo '<table><tr><th>Symbol</th><th>Qty</th><th>Avg cost</th><th>Mark</th><th>Market value</th><th>Unrealized P/L</th></tr>'
  jq -r '.[] |
    "<tr><td>\(.symbol)</td><td>\(.qty)</td><td>$\(.avg_entry_price)</td><td>$\(.current_price // "?")</td><td>$\(.market_value)</td><td class=\"\(if (.unrealized_pl|tonumber) >= 0 then "pos" else "neg" end)\">$\(.unrealized_pl)</td></tr>"
    ' <<<"$positions"
  echo "</table>"
fi

# Prior daily snapshot comparison.
if [ -n "$prev_daily" ]; then
  prev_date=$(jq -r '.date' "$prev_daily")
  prev_pl=$(  jq -r '.day_pl_usd' "$prev_daily")
  prev_close=$(jq -r '.closing_equity' "$prev_daily")
  cls=$( [ "${prev_pl%-*}" = "$prev_pl" ] && echo pos || echo neg )
  cat <<EOF
<h2>Prior trading day ($prev_date)</h2>
<table>
  <tr><th>Closing equity</th><td>\$$prev_close</td></tr>
  <tr><th>Day P/L</th><td class="$cls">\$$prev_pl</td></tr>
</table>
EOF
fi

# Strategy effectiveness.
cat <<EOF
<h2>Strategy effectiveness (past 30 days)</h2>
EOF
if [ "$(jq 'length' <<<"$strat_counts")" = "0" ]; then
  echo "<p>No strategy actions recorded yet.</p>"
else
  echo '<table><tr><th>Strategy</th><th>Orders</th><th>Successful</th></tr>'
  jq -r '.[] | "<tr><td>\(.strategy)</td><td>\(.order_count)</td><td>\(.successful)</td></tr>"' \
    <<<"$strat_counts"
  echo "</table>"
fi

# Pool table.
cat <<EOF
<h2>Pool</h2>
EOF
if [ "$(jq '.stocks | length' <<<"$pool")" = "0" ]; then
  echo "<p>Pool is empty.</p>"
else
  echo '<table><tr><th>Symbol</th><th>Last buy</th><th>Last sell</th><th>Watermark</th><th>Stop</th><th>Total P/L</th></tr>'
  jq -r '.stocks[] |
    "<tr><td>\(.symbol)</td><td>\(.last_buy.timestamp // "—") @ $\(.last_buy.price // "—")</td><td>\(.last_sell.timestamp // "—") @ $\(.last_sell.price // "—")</td><td>$\(.high_watermark // "—")</td><td>$\(.stop_loss.price // "—")</td><td>$\(.total_profit_usd)</td></tr>"
    ' <<<"$pool"
  echo "</table>"
fi

# Schedule status.
cat <<EOF
<h2>Schedule</h2>
<pre>$(jq . <<<"$activation" | jq -Rr @html)</pre>

<p class="small">Source: <code>persistence/config/activation.json</code>. To reconfigure, run <code>/master_configurator</code>.</p>

</body>
</html>
EOF
} > "$out"

# Reports are gitignored per-operator (private trading data). No auto-commit.
echo "$out"
