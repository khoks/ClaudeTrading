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

3. **Strategy fan-out — two phases.** Read enabled strategies from `persistence/config/strategy_defaults.json`. Run them in the order below. Cross-strategy guards are enforced by master_trading at the set-membership level — strategies do not need to know about each other.

   **Phase A — sells (operate on `sets.sellable`):**
   1. `profit_take`  → skill `strategy_profit_take` (eager partial; absolute-gain rungs)
   2. `trailing_stop` → skill `strategy_trailing_stop` (full retracement exit)

   After Phase A, build `sold_this_tick = { symbol of every order placed in Phase A }`.

   **Phase B — buys (operate on a filtered subset of `sets.buyable`):**
   1. `mean_reversion` → skill `strategy_mean_reversion` (selective: ≤ `bottom_k` laggards per tick)
   2. `ladder_buys`   → skill `strategy_ladder_buys` (broad: any stock that broke its drop threshold)

   Before each Phase-B strategy, filter the buyable set:
   - Drop any symbol in `sold_this_tick` (sell-then-buy in the same tick is wash churn).
   - Drop any symbol already bought earlier in Phase B (no double-buy across strategies — first writer wins).

   Strategies receive their filtered buyable in the envelope's `buyable` field; they don't compute the filter themselves.

   `wheel` (and any user-added strategy) runs after these as appropriate. Wheel is currently disabled.

   **Envelope shape (same for every strategy):**
   ```json
   {
     "sellable": [...],
     "buyable":  [...],
     "defaults": { ... contents of strategy's entry in strategy_defaults.json ... },
     "now":      "<ISO-8601>"
   }
   ```
   Each strategy emits to stdout a JSON array of `{ strategy, symbol, side, qty|notional, type, alpaca_order_id, status, reason }` records. Aggregate across strategies into `$ACTIONS` preserving phase order.

   **Why sells before buys:** sells free cash. If both phases ran in parallel or buys-first, a strategic exit on AAPL might be preempted by a ladder buy on MSFT that drained the cash needed to actually market-sell AAPL.

   **Why selective-before-broad inside each phase:** the more selective strategy expresses higher per-stock conviction. Letting it run first ensures its picks aren't pre-empted by a broader strategy claiming the same cash or symbol.

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
