---
name: reporting
description: This skill should be used when fired by the daily 7am PT schedule, or when the user asks to "generate trading report", "show me yesterday's report", "produce daily HTML report". Reads recent daily and per-tick snapshots, the pool, and live market context, then writes a single self-contained HTML file to persistence/reports/<YYYY-MM-DD>.html with positions, day/week P/L, per-strategy effectiveness, and market context.
version: 0.1.0
---

# reporting

Daily diagnostic for the user. Runs at 7am PT before market open, summarising the prior trading day plus week-to-date.

## Invocation

Schedule: cron `0 7 * * 1-5` America/Los_Angeles → runs `/reporting`.
Manual: user runs `/reporting` or asks for a report on a specific date.

## Output

Single self-contained HTML at `persistence/reports/<YYYY-MM-DD>.html`. Inline CSS only — no external assets, so it renders offline and on GitHub's HTML preview (limited) or after `git pull`.

## Sections to include

1. **Header** — date, week, account equity (open/close/delta).
2. **Positions table** — current positions with cost basis, market value, unrealized P/L.
3. **Day P/L** — total + per-stock breakdown from prior day's daily snapshot.
4. **Week-to-date P/L** — from the most recent weekly snapshot if present, else aggregated from this week's dailies.
5. **Per-strategy effectiveness** — count of orders + realized P/L per strategy across the past 30 days (read daily snapshots for the past 30 calendar days, group `actions[].strategy`).
6. **Pool table** — every stock in pool with last_buy, last_sell, watermark, stop_loss, total_profit_usd.
7. **Market context** — SPY change today (alpaca_last_trade SPY vs prior-day daily snapshot SPY), VIX latest if accessible.
8. **Schedule status** — read `persistence/config/activation.json` and confirm both schedules are active.

## Implementation

```bash
bash "$REPO_ROOT/.claude/skills/reporting/scripts/generate_report.sh"
```

After writing the HTML, the script also:
- Stages and commits via the same flow as state_persistence (the report is part of repo state).
- Prints the absolute report path to stdout.

## Tone

Plain, factual. No suggestions or trade calls in the report — those decisions belong to master_trading.

## Reuse

- All `lib/*.sh`.
- Reads `persistence/snapshots/daily/`, `persistence/snapshots/weekly/`, `persistence/snapshots/tick/`, `persistence/pool.json`, `persistence/config/activation.json`.
