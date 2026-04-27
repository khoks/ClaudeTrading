---
name: dashboard
description: This skill should be used when the user asks to "show my dashboard", "open the dashboard", "generate dashboard", "what's my portfolio look like", "show everything", "give me a status page", or runs `/dashboard`. Generates a self-contained HTML dashboard at persistence/dashboard.html — all data baked in at generation time so the operator can double-click the file in their OS file explorer and view it offline. Sections: account, equity sparkline, positions, recent activity, strategies, configuration, pool, schedule.
version: 0.1.0
---

# dashboard

A single-file HTML dashboard the operator can double-click to view. Snapshot of everything: portfolio, recent activity, strategy state, configuration, pool, schedule.

## Why a generated static file (and not a server)

Browsers block `file://` → `file://` fetches and most `file://` → `https://` fetches via CORS. To open a dashboard by double-clicking the HTML, all data has to be **baked in at generation time** — there are no live API calls from the page itself. This skill regenerates the file with fresh state on demand. The trade-off: the dashboard reflects state at the moment of generation, not "right now" in real-time. Re-run `/dashboard` to refresh.

## Invocation

- User: `/dashboard` or any of the trigger phrases above.
- The skill runs `bash scripts/generate_dashboard.sh` which writes `persistence/dashboard.html` and prints the absolute path to stdout.
- Tell the operator the path and instruct: open it by double-clicking from their file manager (works on macOS, Linux, Windows).

## Sections

1. **Header** — generated-at timestamp, account number (paper), equity headline.
2. **Account** — equity, cash, buying power, day change, daily P/L %.
3. **Equity sparkline** — last 30 tick snapshots' equity values as an inline SVG line chart. Green fill if up over the window, red if down.
4. **Open positions** — table sortable visually by largest unrealized P/L. Symbol, qty, avg cost, mark, market value, unrealized P/L (color-coded).
5. **Recent activity** — actions across the last 50 tick snapshots (most-recent first). Each row: time, strategy, symbol, side, qty/notional, status, reason. If no actions, show a friendly empty state.
6. **Strategies** — one card per strategy. Shows enabled/disabled, current tunables, and a one-line description of what it does. Disabled strategies grayed out.
7. **Configuration** — risk tolerance, max-per-trade, fractional-shares, cooldown threshold (from env or default), tick cadence, generated-at.
8. **Pool** — every stock in pool: last buy / last sell timestamps, watermark, stop-loss, total realized profit, total invested. Sortable visually by total profit.
9. **Schedule** — task IDs from activation.json, cron expressions (master tick + reporting), next/last run times pulled from `mcp__scheduled-tasks` if available *(this is a known gap — generate_dashboard.sh runs in bash and can't easily query the MCP; for now the section just prints the cron strings + `mcp__scheduled-tasks__list_scheduled_tasks` reminder)*.

## Visual style

Self-contained inline CSS (no external stylesheet, no fonts to download).
- Dark theme: `#0f172a` background, `#1e293b` cards, `#f1f5f9` text, `#94a3b8` muted.
- Accents: `#22c55e` (green / positive), `#ef4444` (red / negative), `#3b82f6` (info / blue), `#a855f7` (configuration / purple).
- CSS Grid responsive layout — cards stack on narrow screens.
- System fonts (`-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif`).
- File size target: under 50 KB even with full pool / 30 ticks.

## State the file path is local

The generated `persistence/dashboard.html` is **gitignored per-operator** — it contains the operator's portfolio, positions, and activity. It never goes to GitHub. Same data-handling story as snapshots and reports.

## Reuse

Sources `lib/env.sh` (for `$REPO_ROOT`, jq shim). Reads:
- `persistence/snapshots/tick/*.json` (last 30 for chart, last 50 for activity)
- `persistence/snapshots/daily/*.json` (most recent for prior-day P/L)
- `persistence/pool.json`
- `persistence/config/{activation,user_preferences,strategy_defaults}.json`

No Alpaca API calls — all data comes from the snapshots that state_persistence already wrote on the last tick. (If the operator wants a live live snapshot, they can run `/master_trading` first to fire a tick, then `/dashboard`.)

## Not auto-fired

The dashboard is on-demand only. It is **not** wired into master_trading's tick loop or any cron schedule, by design — refresh cadence is the operator's choice. If they want it auto-refreshed, the simplest path is to add a hook to state_persistence that calls `generate_dashboard.sh` after every tick.
