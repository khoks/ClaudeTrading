---
name: state_persistence
description: This skill should be used when invoked by master_trading at the end of every tick, or when the user asks to "snapshot trading state", "save trading data", "commit trading state". Writes a 5-min snapshot of the Alpaca account and pool, and on the last tick of the trading day/week also writes daily and weekly rollups. Prunes stale 5-min snapshots, then commits and pushes everything to GitHub so the next remote-agent run sees fresh state.
version: 0.1.0
---

# state_persistence

The disk + git layer of ClaudeTrading. Every other skill mutates pool.json in place; this skill is where the snapshots, rollups, pruning, and git push happen.

## Invocation contract

**STDIN** — JSON envelope from master_trading:
```json
{
  "tick_at": "2026-04-26T18:35:00Z",
  "actions": [ { strategy, symbol, side, ... }, ... ],
  "sets":    { "sellable": [...], "buyable": [...] }
}
```

**STDOUT** — single line confirming what was written:
```json
{ "snapshots": ["5min", "daily"], "committed": true, "commit_sha": "abc123" }
```

## Workflow

```bash
source "$REPO_ROOT/lib/env.sh"
source "$REPO_ROOT/lib/alpaca.sh"
source "$REPO_ROOT/lib/calendar.sh"
source "$REPO_ROOT/lib/pool.sh"
```

1. **Always: write 5-min snapshot.**
   `bash scripts/snapshot_5min.sh "<envelope>"` → writes `persistence/snapshots/5min/<YYYY-MM-DDTHH-mm>.json` with:
   - `tick_at`
   - `account` (cash, equity, buying_power, last_equity)
   - `positions` (full Alpaca positions response)
   - `actions` from envelope
   - `sets` from envelope
   - `equity_delta_5min` — equity now minus equity from previous 5-min snapshot

2. **Update pool.** The strategy scripts already mutated `last_buy`/`last_sell`/watermark/`stop_loss` in pool.json. Ensure `last_updated` is bumped (`pool_write` does this automatically).

3. **If `is_last_tick_of_trading_day`:** `bash scripts/snapshot_daily.sh` → writes `persistence/snapshots/daily/<YYYY-MM-DD>.json` consolidating the day's actions, opening/closing equity, per-stock day P/L.

4. **If also `is_last_trading_day_of_week`:** `bash scripts/snapshot_weekly.sh` → writes `persistence/snapshots/weekly/<YYYY-Www>.json` with week-over-week equity, top winners/losers.

5. **Prune.** `bash scripts/prune_5min.sh` removes any `persistence/snapshots/5min/*.json` older than 7 days. Daily/weekly are retained indefinitely.

6. **Git commit and push.**
   ```bash
   cd "$REPO_ROOT"
   git add persistence/
   if git diff --cached --quiet; then
     echo "no state changes"; exit 0
   fi
   git -c user.email=trading@claude.local -c user.name="ClaudeTrading bot" \
       commit -m "state: $(date -u +%FT%TZ)"
   git push
   ```

## Why the bot commits as a synthetic identity

Identifies bot commits in history at a glance. Replace with the user's preferred email if they want commits attributed to themselves.

## Race conditions

`master_trading` only fires every 5 min, so two simultaneous runs are very unlikely, but still possible (manual trigger during a scheduled fire). The git push will fail safely on a second concurrent run; the second run should `git pull --rebase` and retry once. If retry fails, log and exit non-zero — better to skip a commit than to corrupt state.

## Reuse

- All four `lib/*.sh`.
- `scripts/snapshot_5min.sh`, `scripts/snapshot_daily.sh`, `scripts/snapshot_weekly.sh`, `scripts/prune_5min.sh`.
