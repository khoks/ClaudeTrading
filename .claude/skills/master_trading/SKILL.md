---
name: master_trading
description: This skill should be used when fired by the recurring schedule (on the configured tick cadence during PT trading hours), or when the user manually runs `/master_trading` for a one-shot tick. Orchestrates one trading tick: checks market open, runs safe_trading filter, invokes each enabled strategy against the filtered pool, then calls state_persistence to snapshot the result.
version: 0.1.0
---

# master_trading

The heartbeat of ClaudeTrading. One invocation = one trading tick. Cadence is set by the cron expression on the `claudetrading-master-tick` scheduled task and mirrored in `persistence/config/activation.json` as `tick_cadence_minutes` (so libraries that need it — e.g. `is_last_tick_of_trading_day` — can stay correct when the schedule changes).

## Preconditions

- `master_configurator` has been run (`persistence/config/activation.json`.configured == true).
- `.env` or runner-injected env vars expose Alpaca creds.
- `persistence/pool.json` has at least one stock.

## Tick workflow (run in order, fail fast on errors)

```bash
set -euo pipefail
source "$REPO_ROOT/lib/env.sh"
source "$REPO_ROOT/lib/alpaca.sh"
source "$REPO_ROOT/lib/calendar.sh"
source "$REPO_ROOT/lib/pool.sh"
```

1. **Market gate.** If `! is_market_open`, log `"market closed at $(date -u +%FT%TZ), skipping"` and exit 0. Holidays and weekends fall through cleanly.

2. **Safe-trading filter.** Invoke skill `safe_trading` (it will run `bash .claude/skills/safe_trading/scripts/filter_pool.sh` and emit JSON to stdout):
   ```json
   { "sellable": ["AAPL", ...], "buyable": ["MSFT", ...] }
   ```
   Capture this as `$SETS`.

3. **Strategy fan-out.** Read `persistence/config/strategy_defaults.json`. For each key whose `.enabled == true`, invoke the matching skill:
   - `trailing_stop` → skill `strategy_trailing_stop`
   - `ladder_buys`   → skill `strategy_ladder_buys`
   - `wheel`         → skill `strategy_wheel`
   - any user-added strategy → skill `strategy_<name>`

   Each strategy receives a JSON envelope on stdin:
   ```json
   {
     "sellable": [...],
     "buyable":  [...],
     "defaults": { ... contents of strategy's entry in strategy_defaults.json ... },
     "now":      "<ISO-8601>"
   }
   ```
   And emits to stdout a JSON array of `{ symbol, side, qty|notional, type, alpaca_order_id, status }` records describing each placed order. Aggregate across strategies into `$ACTIONS`.

4. **State persistence.** Invoke skill `state_persistence` with envelope:
   ```json
   {
     "tick_at":  "<ISO-8601>",
     "actions":  [...$ACTIONS...],
     "sets":     $SETS
   }
   ```
   It owns the snapshot files, pool updates, daily/weekly rollups, and the git commit/push.

5. **Exit 0.** Print a one-line summary: `tick OK | actions=<N> | sellable=<N> | buyable=<N>`.

## Error handling

- Wrap each strategy invocation in its own try/catch. One strategy's failure should not block the others. Log the failure but continue, and include it in the actions array as `{ "strategy": "...", "status": "error", "error": "..." }`.
- If safe_trading fails, abort the tick (do not place any orders blindly).
- If state_persistence fails, the tick already placed real (paper) orders; log loudly and proceed — don't double-place orders.

## Why no orders are placed before safe_trading runs

The H1B safety constraint is the floor. Until safe_trading returns its filtered sets, master_trading has no idea which stocks are eligible. Trades must always pass through the filter.

## Reuse

- `lib/alpaca.sh` for the market clock and order placement.
- `lib/calendar.sh` for `is_market_open`.
- Sub-skills: `safe_trading`, `strategy_*`, `state_persistence`.
