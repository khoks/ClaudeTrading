---
name: state_persistence
description: This skill should be used when invoked by master_trading at the end of every tick, or when the user asks to "snapshot trading state", "save trading data". Writes a per-tick snapshot of the Alpaca account and pool. On the last tick of the trading day/week, also writes daily and weekly rollups. Prunes stale per-tick snapshots. All writes are local-only — snapshots and pool state are gitignored per-operator.
version: 0.2.0
---

# state_persistence

The disk layer of ClaudeTrading. Every other skill mutates `pool.json` in place; this skill is where the snapshots, rollups, and pruning happen.

## Invocation contract

**STDIN** — JSON envelope from master_trading:
```json
{
  "tick_at": "2026-04-26T18:35:00Z",
  "actions": [ { strategy, symbol, side, ... }, ... ],
  "sets":    { "sellable": [...], "buyable": [...] }
}
```

**STDOUT** — single line summarising what was written:
```json
{ "tick": "<path>", "daily": "<path>|null", "weekly": "<path>|null", "pruned": <int> }
```

## Workflow

The whole flow is a single script invocation — `persist.sh` is the orchestrator that mechanically applies the conditional daily/weekly logic so it never gets cut by an interpreting Claude session.

```bash
echo "$envelope" | bash "$REPO_ROOT/.claude/skills/state_persistence/scripts/persist.sh"
```

What `persist.sh` does, in order:

1. **Always: tick snapshot.** Calls `snapshot_tick.sh` with the envelope on stdin. Writes `persistence/snapshots/tick/<YYYY-MM-DDTHH-mm>.json` containing `tick_at`, full Alpaca account + positions response, the envelope's `actions` and `sets`, and `equity_delta_vs_prev_tick`.
2. **Conditional: daily rollup.** If `is_last_tick_of_trading_day` (from `lib/calendar.sh`, reads `tick_cadence_minutes` from `activation.json`), calls `snapshot_daily.sh`. Aggregates today's tick snapshots into `persistence/snapshots/daily/<YYYY-MM-DD>.json` (opening/closing equity, day P/L, all actions, final positions, tick_count).
3. **Conditional: weekly rollup.** If a daily snapshot was just written AND `is_last_trading_day_of_week`, calls `snapshot_weekly.sh`. Aggregates this week's daily snapshots into `persistence/snapshots/weekly/<YYYY-Www>.json`.
4. **Always: prune.** `prune_tick.sh` removes any `persistence/snapshots/tick/*.json` older than 7 days (configurable via `PRUNE_DAYS` env var). Daily and weekly snapshots are retained indefinitely.

`pool.json` mutations were already done by the strategies during the tick — `pool_write` bumps `last_updated` automatically, so nothing extra is needed here.

## No git commits — by design

Snapshots, reports, and `pool.json` are **gitignored per-operator** so trading history stays local. State_persistence does not commit or push. If you want cross-machine portability, set up your own backup mechanism (rsync, private mirror, etc.).

The repo is shareable publicly — anyone who clones it gets the code, the strategies, and the shipped baseline `strategy_defaults.json`, but not anyone else's trading data.

## Race conditions

Two simultaneous `master_trading` runs are unlikely but possible (manual trigger during a scheduled fire). The tick snapshot writes are atomic (temp + mv) but reads inside a tick are not transactional, so back-to-back ticks can interleave with surprising results. Avoid running `claude -p '/master_trading'` while a scheduled tick is active.

## Reuse

- `lib/env.sh`, `lib/alpaca.sh`, `lib/calendar.sh`, `lib/pool.sh`
- `scripts/persist.sh` (orchestrator)
- `scripts/snapshot_tick.sh`, `scripts/snapshot_daily.sh`, `scripts/snapshot_weekly.sh`, `scripts/prune_tick.sh`
