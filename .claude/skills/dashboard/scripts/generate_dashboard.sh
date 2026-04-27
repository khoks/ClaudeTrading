#!/usr/bin/env bash
# dashboard/scripts/generate_dashboard.sh
#
# Generates a self-contained HTML dashboard at persistence/dashboard.html.
# All data is baked into the HTML at generation time — the page makes no
# fetches when opened (browsers block file:// → file:// and file:// → https
# anyway). To refresh, re-run this script.
#
# Sources state from:
#   persistence/snapshots/tick/*.json   (last 30 for chart, last 50 for activity)
#   persistence/snapshots/daily/*.json  (most recent for prior-day comparison)
#   persistence/pool.json
#   persistence/config/{activation,user_preferences,strategy_defaults}.json
#
# No Alpaca API calls — uses the snapshots state_persistence wrote on the
# last tick. Re-run /master_trading first if you want fresher live values.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
export REPO_ROOT

# shellcheck disable=SC1091
source "$REPO_ROOT/lib/env.sh"

out="$REPO_ROOT/persistence/dashboard.html"
mkdir -p "$(dirname "$out")"

gen_time=$(date_now_iso)
cooldown="${SAFE_TRADING_THRESHOLD:-2}"

# --- Gather snapshots ---
shopt -s nullglob
tick_dir="$REPO_ROOT/persistence/snapshots/tick"
all_ticks=()
if [ -d "$tick_dir" ]; then
  while IFS= read -r line; do all_ticks+=( "$line" ); done < <(ls -1 "$tick_dir"/*.json 2>/dev/null | sort)
fi
n=${#all_ticks[@]}

recent_30=()
recent_50=()
if [ "$n" -gt 0 ]; then
  s30=$(( n > 30 ? n - 30 : 0 ))
  s50=$(( n > 50 ? n - 50 : 0 ))
  for ((i=s30; i<n; i++)); do recent_30+=( "${all_ticks[$i]}" ); done
  for ((i=s50; i<n; i++)); do recent_50+=( "${all_ticks[$i]}" ); done
fi

latest_tick=""
[ "$n" -gt 0 ] && latest_tick="${all_ticks[$((n-1))]}"

latest_daily=$(ls -1 "$REPO_ROOT/persistence/snapshots/daily"/*.json 2>/dev/null | tail -1 || true)

# --- Read config files (graceful fallbacks for fresh clone) ---
pool=$(cat "$REPO_ROOT/persistence/pool.json" 2>/dev/null || echo '{"stocks":[]}')
prefs=$(cat "$REPO_ROOT/persistence/config/user_preferences.json" 2>/dev/null || echo '{}')
activation=$(cat "$REPO_ROOT/persistence/config/activation.json" 2>/dev/null || echo '{"configured":false}')
defaults=$(cat "$REPO_ROOT/persistence/config/strategy_defaults.json" 2>/dev/null || echo '{}')

configured=$(jq -r '.configured // false' <<<"$activation")

# --- Pull current account/positions from latest tick (or empty) ---
if [ -n "$latest_tick" ]; then
  account=$(jq '.account'   "$latest_tick")
  positions=$(jq '.positions' "$latest_tick")
  tick_at=$(jq -r '.tick_at' "$latest_tick")
else
  account='{}'; positions='[]'; tick_at='—'
fi

equity_now=$(jq -r '.equity        // "0"' <<<"$account")
cash=$(      jq -r '.cash          // "0"' <<<"$account")
bp=$(        jq -r '.buying_power  // "0"' <<<"$account")
last_equity=$(jq -r '.last_equity  // .equity // "0"' <<<"$account")

day_change=$(    jq -nc --argjson n "$equity_now" --argjson p "$last_equity" '$n - $p')
day_change_pct=$(jq -nc --argjson n "$equity_now" --argjson p "$last_equity" 'if ($p|tonumber) == 0 then 0 else (($n - $p) / $p) * 100 end')

# --- Equity sparkline points ---
if [ "${#recent_30[@]}" -gt 1 ]; then
  equity_series=$(jq -s '[.[] | (.account.equity | tonumber)]' "${recent_30[@]}")
else
  equity_series='[]'
fi
sparkline_svg=$(jq -nc --argjson e "$equity_series" '
  if ($e | length) < 2 then ""
  else
    ($e | min) as $mn |
    ($e | max) as $mx |
    (if $mx == $mn then 1 else $mx - $mn end) as $range |
    ($e | length) as $n |
    [ $e | to_entries[] |
      ((.key * 600) / (($n - 1))) as $x |
      (70 - ((.value - $mn) / $range * 60)) as $y |
      "\($x|round),\($y|round)"
    ] | join(" ")
  end
')

# Sparkline color: green if last > first, red otherwise
if [ "$sparkline_svg" != '""' ] && [ "${#recent_30[@]}" -gt 1 ]; then
  trend=$(jq -nc --argjson e "$equity_series" 'if .[-1] >= .[0] then "up" else "down" end' <<<"$equity_series" 2>/dev/null || echo "up")
  trend=$(jq -nc --argjson e "$equity_series" 'if ($e[-1] // 0) >= ($e[0] // 0) then "up" else "down" end')
else
  trend="up"
fi
[ "$trend" = "up" ] && trend_color="#22c55e" || trend_color="#ef4444"

# --- Recent actions across last 50 ticks ---
if [ "${#recent_50[@]}" -gt 0 ]; then
  recent_actions=$(jq -s '
    [ .[] | (.tick_at as $t | (.actions // []) | map(. + {tick_at: $t})) ]
    | flatten | reverse | .[0:50]
  ' "${recent_50[@]}")
else
  recent_actions='[]'
fi
actions_count=$(jq 'length' <<<"$recent_actions")

# --- Helpers ---
fmt_money()   { awk -v v="$1" 'BEGIN{printf "%.2f", v+0}'; }
fmt_signed()  { awk -v v="$1" 'BEGIN{printf "%+.2f", v+0}'; }
fmt_pct()     { awk -v v="$1" 'BEGIN{printf "%+.2f%%", v+0}'; }
sign_class()  { awk -v v="$1" 'BEGIN{print (v+0 >= 0) ? "pos" : "neg"}'; }
esc_html()    { jq -Rsr '.' <<<"$1" | sed 's/^"//; s/"$//'; }   # not great; we'll use jq @html

# ============================================================
# Begin HTML output
# ============================================================
cat > "$out" <<'HTMLHEAD'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>ClaudeTrading Dashboard</title>
<style>
  *{box-sizing:border-box}
  body{margin:0;padding:24px;background:#0f172a;color:#f1f5f9;
       font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;
       font-size:14px;line-height:1.5}
  header{margin-bottom:24px}
  h1{margin:0 0 4px;font-size:24px;color:#f1f5f9}
  .subtitle{color:#94a3b8;font-size:13px}
  .banner{background:#7f1d1d;color:#fca5a5;padding:14px 18px;border-radius:8px;
          margin-bottom:18px;font-size:13px}
  .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(380px,1fr));gap:16px}
  .card{background:#1e293b;border:1px solid #334155;border-radius:10px;padding:18px}
  .card h2{margin:0 0 14px;font-size:11px;font-weight:700;
           text-transform:uppercase;letter-spacing:1.4px;color:#94a3b8}
  .card.account h2{color:#22c55e}
  .card.chart h2{color:#3b82f6}
  .card.positions h2{color:#22c55e}
  .card.activity h2{color:#a855f7}
  .card.strategies h2{color:#3b82f6}
  .card.config h2{color:#a855f7}
  .card.pool h2{color:#22c55e}
  .card.schedule h2{color:#3b82f6}
  .card.full{grid-column:1/-1}
  table{width:100%;border-collapse:collapse;font-size:13px}
  th{text-align:left;color:#94a3b8;font-weight:600;border-bottom:1px solid #334155;
     padding:8px 6px;text-transform:uppercase;font-size:10px;letter-spacing:0.6px}
  td{padding:8px 6px;border-bottom:1px solid #1e293b;color:#cbd5e1}
  tr:last-child td{border-bottom:0}
  td.num{font-variant-numeric:tabular-nums;text-align:right}
  td.sym{font-weight:600;color:#f1f5f9}
  .pos{color:#22c55e}
  .neg{color:#ef4444}
  .muted{color:#64748b}
  .pill{display:inline-block;padding:2px 8px;border-radius:12px;font-size:10px;
        font-weight:700;text-transform:uppercase;letter-spacing:0.5px}
  .pill.green{background:#064e3b;color:#4ade80}
  .pill.red{background:#7f1d1d;color:#fca5a5}
  .pill.gray{background:#334155;color:#94a3b8}
  .pill.blue{background:#1e3a8a;color:#93c5fd}
  .stat-grid{display:grid;grid-template-columns:repeat(2,1fr);gap:14px}
  .stat .label{color:#64748b;font-size:10px;text-transform:uppercase;letter-spacing:0.6px}
  .stat .value{font-size:22px;font-weight:600;color:#f1f5f9;font-variant-numeric:tabular-nums}
  .strategy-card{border:1px solid #334155;border-radius:8px;padding:12px;margin-bottom:10px}
  .strategy-card:last-child{margin-bottom:0}
  .strategy-card.disabled{opacity:0.5}
  .strategy-card .head{display:flex;justify-content:space-between;align-items:center;margin-bottom:6px}
  .strategy-card .name{font-weight:600;color:#f1f5f9;font-size:14px}
  .strategy-card .desc{color:#94a3b8;font-size:12px;margin-bottom:8px}
  .strategy-card .tunables{color:#cbd5e1;font-size:11px;font-family:ui-monospace,Consolas,monospace;
                            background:#0f172a;padding:6px 8px;border-radius:4px}
  footer{margin-top:24px;padding-top:16px;border-top:1px solid #334155;color:#64748b;
         font-size:11px;text-align:center}
  .sparkline{width:100%;height:80px}
  .empty{color:#64748b;font-style:italic;padding:14px 6px;font-size:13px}
  code{background:#0f172a;padding:2px 5px;border-radius:3px;font-size:12px;color:#cbd5e1}
  .config-row{display:flex;justify-content:space-between;padding:6px 0;
              border-bottom:1px solid #1e293b;font-size:13px}
  .config-row:last-child{border-bottom:0}
  .config-row .k{color:#94a3b8}
  .config-row .v{color:#f1f5f9;font-variant-numeric:tabular-nums}
</style>
</head>
<body>
HTMLHEAD

# Header
cat >> "$out" <<EOF
<header>
  <h1>ClaudeTrading Dashboard</h1>
  <div class="subtitle">Generated $gen_time · last tick $tick_at · paper account</div>
</header>
EOF

# Banner if not configured
if [ "$configured" != "true" ]; then
  cat >> "$out" <<'EOF'
<div class="banner">
  ⚠ This clone has not been initialized yet. Run <code>/master_configurator</code> from inside Claude Code to set up your pool, preferences, and schedule. The dashboard below shows whatever's available, but most cards will be empty until configuration is complete.
</div>
EOF
fi

cat >> "$out" <<'EOF'
<main class="grid">
EOF

# === Account ===
cat >> "$out" <<EOF
<section class="card account">
  <h2>Account</h2>
  <div class="stat-grid">
    <div class="stat"><div class="label">Equity</div>
      <div class="value">\$$(fmt_money "$equity_now")</div></div>
    <div class="stat"><div class="label">Cash</div>
      <div class="value">\$$(fmt_money "$cash")</div></div>
    <div class="stat"><div class="label">Buying Power</div>
      <div class="value">\$$(fmt_money "$bp")</div></div>
    <div class="stat"><div class="label">Day Change</div>
      <div class="value $(sign_class "$day_change")">$(fmt_signed "$day_change")
        <span style="font-size:13px">($(fmt_pct "$day_change_pct"))</span></div></div>
  </div>
</section>
EOF

# === Equity sparkline ===
cat >> "$out" <<EOF
<section class="card chart">
  <h2>Equity (last ${#recent_30[@]} ticks)</h2>
EOF
if [ "${#recent_30[@]}" -gt 1 ]; then
  pts=$(jq -r '.' <<<"$sparkline_svg")
  cat >> "$out" <<EOF
  <svg class="sparkline" viewBox="0 0 600 80" preserveAspectRatio="none">
    <polyline points="$pts" stroke="$trend_color" stroke-width="2" fill="none"/>
    <polyline points="0,80 $pts 600,80" fill="${trend_color}22" stroke="none"/>
  </svg>
  <div style="display:flex;justify-content:space-between;color:#64748b;font-size:11px;margin-top:6px">
    <span>$(jq -r '.[0].tick_at' <<<"$(jq -s '[.[] | {tick_at}]' "${recent_30[@]}")")</span>
    <span>$(jq -r '.[-1].tick_at' <<<"$(jq -s '[.[] | {tick_at}]' "${recent_30[@]}")")</span>
  </div>
EOF
else
  cat >> "$out" <<'EOF'
  <div class="empty">Need at least 2 tick snapshots to draw a chart. Run more ticks (or wait through market hours).</div>
EOF
fi
echo '</section>' >> "$out"

# === Open positions ===
positions_count=$(jq 'length' <<<"$positions")
cat >> "$out" <<EOF
<section class="card positions full">
  <h2>Open positions ($positions_count)</h2>
EOF
if [ "$positions_count" = "0" ]; then
  echo '<div class="empty">No open positions.</div>' >> "$out"
else
  cat >> "$out" <<'EOF'
  <table>
    <thead><tr><th>Symbol</th><th class="num">Qty</th><th class="num">Avg cost</th><th class="num">Mark</th><th class="num">Mkt value</th><th class="num">Unrealized P/L</th></tr></thead>
    <tbody>
EOF
  jq -r '
    sort_by(-(.unrealized_pl | tonumber))
    | .[]
    | "<tr><td class=\"sym\">\(.symbol)</td>"
      + "<td class=\"num\">\((.qty | tonumber) | (. * 10000 | round) / 10000)</td>"
      + "<td class=\"num\">$\((.avg_entry_price | tonumber) | (. * 100 | round) / 100)</td>"
      + "<td class=\"num\">$\((.current_price // "0" | tonumber) | (. * 100 | round) / 100)</td>"
      + "<td class=\"num\">$\((.market_value | tonumber) | (. * 100 | round) / 100)</td>"
      + "<td class=\"num \(if (.unrealized_pl|tonumber) >= 0 then "pos" else "neg" end)\">\(if (.unrealized_pl|tonumber) >= 0 then "+" else "" end)$\((.unrealized_pl | tonumber) | (. * 100 | round) / 100)</td></tr>"
  ' <<<"$positions" >> "$out"
  echo '</tbody></table>' >> "$out"
fi
echo '</section>' >> "$out"

# === Recent activity ===
cat >> "$out" <<EOF
<section class="card activity full">
  <h2>Recent activity (last 50 ticks · $actions_count actions)</h2>
EOF
if [ "$actions_count" = "0" ]; then
  echo '<div class="empty">No actions in recent ticks. Strategies are armed; triggers just haven&rsquo;t fired yet.</div>' >> "$out"
else
  cat >> "$out" <<'EOF'
  <table>
    <thead><tr><th>Time</th><th>Strategy</th><th>Symbol</th><th>Side</th><th class="num">Qty / $</th><th>Status</th><th>Reason</th></tr></thead>
    <tbody>
EOF
  jq -r '
    .[] |
    (.tick_at | sub("T"; " ") | sub("Z"; "")) as $t |
    "<tr><td class=\"muted\">\($t)</td>"
      + "<td>\(.strategy // "?")</td>"
      + "<td class=\"sym\">\(.symbol // "?")</td>"
      + "<td>\(.side // "—")</td>"
      + "<td class=\"num\">\(if .qty then ((.qty|tonumber) | (. * 10000 | round) / 10000 | tostring) elif .notional then ("$" + (.notional|tostring)) else "—" end)</td>"
      + "<td><span class=\"pill \(if .status == "filled" or .status == "submitted" or .status == "accepted" or .status == "pending_new" then "green" elif .status == "error" then "red" else "gray" end)\">\(.status // "?")</span></td>"
      + "<td class=\"muted\" style=\"max-width:300px\">\(.reason // "—")</td></tr>"
  ' <<<"$recent_actions" >> "$out"
  echo '</tbody></table>' >> "$out"
fi
echo '</section>' >> "$out"

# === Strategies ===
cat >> "$out" <<'EOF'
<section class="card strategies">
  <h2>Strategies</h2>
EOF

# Map of strategy → description
declare_descs() {
  case "$1" in
    profit_take)    echo "Eager partial exit on absolute gain (sells, Phase A)" ;;
    trailing_stop)  echo "Floor-only watermark; full exit on retracement (sells, Phase A)" ;;
    mean_reversion) echo "Buy the basket-relative laggard (buys, Phase B)" ;;
    ladder_buys)    echo "Buy more when a position drops below last buy (buys, Phase B)" ;;
    wheel)          echo "Cash-secured puts → covered calls — requires Alpaca options approval" ;;
    *)              echo "User-defined strategy" ;;
  esac
}

for strat in profit_take trailing_stop mean_reversion ladder_buys wheel; do
  cfg=$(jq -c --arg k "$strat" '.[$k] // {"enabled":false}' <<<"$defaults")
  enabled=$(jq -r '.enabled // false' <<<"$cfg")
  desc=$(declare_descs "$strat")
  # Format tunables (strip enabled and comment for display)
  tuns=$(jq -r 'del(.enabled, .comment) | to_entries | map("\(.key): \(.value)") | join(" · ")' <<<"$cfg")
  [ -z "$tuns" ] || [ "$tuns" = "null" ] && tuns="(no tunables)"

  pill_class=$([ "$enabled" = "true" ] && echo "green" || echo "gray")
  pill_text=$([ "$enabled" = "true" ] && echo "ENABLED" || echo "DISABLED")
  card_class=$([ "$enabled" = "true" ] && echo "" || echo "disabled")

  cat >> "$out" <<EOF
  <div class="strategy-card $card_class">
    <div class="head">
      <span class="name">$strat</span>
      <span class="pill $pill_class">$pill_text</span>
    </div>
    <div class="desc">$desc</div>
    <div class="tunables">$tuns</div>
  </div>
EOF
done

echo '</section>' >> "$out"

# === Configuration ===
risk=$(    jq -r '.risk_tolerance     // "—"' <<<"$prefs")
cap=$(     jq -r '.max_per_trade_usd  // "—"' <<<"$prefs")
frac=$(    jq -r 'if .fractional_shares then "yes" elif .fractional_shares == false then "no" else "—" end' <<<"$prefs")
n_tickers=$(jq '.curated_tickers // [] | length' <<<"$prefs")
cadence=$(jq -r '.tick_cadence_minutes // "—"' <<<"$activation")
activated_at=$(jq -r '.activated_at // "—"' <<<"$activation")

cat >> "$out" <<EOF
<section class="card config">
  <h2>Configuration</h2>
  <div class="config-row"><span class="k">Risk tolerance</span><span class="v">$risk</span></div>
  <div class="config-row"><span class="k">Max per-trade</span><span class="v">\$$cap</span></div>
  <div class="config-row"><span class="k">Fractional shares</span><span class="v">$frac</span></div>
  <div class="config-row"><span class="k">Tick cadence</span><span class="v">$cadence min</span></div>
  <div class="config-row"><span class="k">Cooldown threshold</span><span class="v">$cooldown trading days</span></div>
  <div class="config-row"><span class="k">Curated tickers</span><span class="v">$n_tickers</span></div>
  <div class="config-row"><span class="k">Configured at</span><span class="v muted">$activated_at</span></div>
</section>
EOF

# === Pool ===
n_stocks=$(jq '.stocks | length' <<<"$pool")
cat >> "$out" <<EOF
<section class="card pool full">
  <h2>Pool ($n_stocks tickers)</h2>
EOF
if [ "$n_stocks" = "0" ]; then
  echo '<div class="empty">Pool is empty. Run <code>/user_preferences_intake</code> to add tickers.</div>' >> "$out"
else
  cat >> "$out" <<'EOF'
  <table>
    <thead><tr><th>Symbol</th><th>Last buy</th><th>Last sell</th><th class="num">Watermark</th><th class="num">Stop</th><th class="num">Total invested</th><th class="num">Realized P/L</th></tr></thead>
    <tbody>
EOF
  jq -r '
    .stocks
    | sort_by(-(.total_profit_usd // 0))
    | .[]
    | "<tr><td class=\"sym\">\(.symbol)</td>"
      + "<td class=\"muted\">\(.last_buy.timestamp // "—") @ $\(.last_buy.price // "—")</td>"
      + "<td class=\"muted\">\(.last_sell.timestamp // "—") @ $\(.last_sell.price // "—")</td>"
      + "<td class=\"num\">\(if .high_watermark then "$" + (.high_watermark | tostring) else "—" end)</td>"
      + "<td class=\"num\">\(if .stop_loss.price then "$" + (.stop_loss.price | tostring) else "—" end)</td>"
      + "<td class=\"num\">$\(.total_invested_usd // 0)</td>"
      + "<td class=\"num \(if (.total_profit_usd // 0) >= 0 then "pos" else "neg" end)\">\(if (.total_profit_usd // 0) >= 0 then "+" else "" end)$\(.total_profit_usd // 0)</td></tr>"
  ' <<<"$pool" >> "$out"
  echo '</tbody></table>' >> "$out"
fi
echo '</section>' >> "$out"

# === Schedule ===
master_id=$(jq -r '.schedule_ids.master_trading // "—"' <<<"$activation")
report_id=$(jq -r '.schedule_ids.reporting       // "—"' <<<"$activation")

cat >> "$out" <<EOF
<section class="card schedule">
  <h2>Schedule</h2>
  <div class="config-row"><span class="k">Master tick</span><span class="v"><code>$master_id</code></span></div>
  <div class="config-row"><span class="k">Cadence</span><span class="v">every $cadence min, market hours, Mon–Fri</span></div>
  <div class="config-row"><span class="k">Daily report</span><span class="v"><code>$report_id</code></span></div>
  <div class="config-row"><span class="k">Report time</span><span class="v">7:00 AM local, Mon–Fri</span></div>
  <div style="margin-top:10px;font-size:11px;color:#64748b">
    For live next/last-run times, run
    <code>mcp__scheduled-tasks__list_scheduled_tasks</code> from inside Claude Code.
  </div>
</section>
EOF

# === Footer ===
cat >> "$out" <<'HTMLFOOT'
</main>

<footer>
  Paper trading only · No live-money path · All data is local to your machine ·
  Refresh this dashboard by re-running <code>/dashboard</code>
</footer>
</body>
</html>
HTMLFOOT

echo "$out"
