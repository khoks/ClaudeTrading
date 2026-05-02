---
name: strategy_profit_take_v2
description: Internal sub-skill of master_trading_v2; called mechanically by tick.sh during Phase A. Same logic as v1 strategy_profit_take (eager partial-exit at absolute-gain rungs). Operators don't normally invoke this directly — use /master_trading_v2.
version: 0.1.0
---

# strategy_profit_take

Tier-out / scale-out strategy. Different from `trailing_stop` because it triggers on **absolute gain from cost basis**, not on **retracement from a peak**. The two strategies cooperate cleanly; together they realize gains both eagerly (on the way up) and lazily (on a real reversal).

## Invocation contract

**STDIN** — same envelope shape as other strategies.

```json
{
  "sellable": ["AAPL", ...],
  "buyable":  [...],
  "defaults": {
    "enabled": true,
    "profit_thresholds_percent": [10, 20, 35, 50],
    "sell_fraction_per_rung": 0.25
  },
  "now": "<ISO-8601>"
}
```

**STDOUT** — JSON array of placed orders.

## Per-stock logic

For each `symbol` in `sellable`:

1. **Resolve config:** `pool_strategy_config "$symbol" profit_take`. Defaults: `profit_thresholds_percent=[10,20,35,50]`, `sell_fraction_per_rung=0.25`.

2. **Read state from pool:**
   ```
   strategy_config.profit_take.fired_thresholds   // []
   strategy_config.profit_take.baseline_qty       // null
   strategy_config.profit_take.last_baseline_at   // null
   ```

3. **Reset on fresh buy.** If `last_buy.timestamp > last_baseline_at` (or `last_baseline_at` is null), clear `fired_thresholds = []`, `baseline_qty = null`, `last_baseline_at = null`. A new buy means a new cost basis; the threshold ladder is rebuilt from scratch.

4. **Read live position:** `qty=$(alpaca_position $sym | jq '.qty')`, `unrealized_plpc`. Skip if qty is empty / 0 (position was already fully closed by trailing_stop or manually).

5. **Compute current gain:** `gain_pct = unrealized_plpc * 100`. (Alpaca's `unrealized_plpc` is decimal, e.g. 0.10 = 10%.)

6. **Find the threshold to fire.** Walk `profit_thresholds_percent` ascending. The first threshold `T` such that `T <= gain_pct` AND `T not in fired_thresholds` is the trigger. **At most one rung fires per tick** — gains tend to overshoot; spreading rung fires across ticks gives the position room to keep running between sales.

7. **Capture baseline on first fire.** If `baseline_qty` is null (this is the first rung firing for this position), set `baseline_qty = current_qty` and `last_baseline_at = last_buy.timestamp`. This freezes the "100% size" reference for all future rungs of this same position.

8. **Compute sell qty.** `sell_qty = min(baseline_qty * sell_fraction_per_rung, current_qty)`. The `min` protects against overflowing if the position has already been partially sold below baseline since the rung was set.

9. **Place market sell.** `alpaca_place_order $sym sell "$sell_qty" market`. On success:
   - Append the fired threshold: `fired_thresholds += [T]`.
   - Persist via `pool_set_profit_take_state`.
   - Compute realized profit estimate: `(current_price - last_buy.price) * sell_qty`.
   - Update `last_sell` via `pool_set_last_sell` — yes, this triggers the 2-trading-day buyable cooldown for this stock. The cooldown is the H1B safety floor, applied uniformly regardless of whether the sell was full or partial.

## Pairing with trailing_stop (the footgun you flagged)

Both can fire on the same stock same tick. master_trading runs `profit_take` first:

- **profit_take** sells `min(baseline_qty * 0.25, current_qty)`.
- **trailing_stop** then re-fetches `alpaca_position` (qty is now smaller) and decides independently:
  - If `current_price > stop_price`: no further sell. profit_take's partial stands.
  - If `current_price <= stop_price`: sell the remaining qty. The position is fully closed.

Each action gets its own line in the tick's `actions[]` with the strategy name, so the daily rollup attributes correctly.

## Why thresholds are absolute, not retracement

Trailing-stop already covers the retracement case. The point of profit_take is to lock in gains **eagerly** — the moment you're up 10%, take some chips off the table regardless of whether the price is still climbing. Acceptance of giving up some upside (you stopped riding 25% of the position) is the explicit trade for guaranteed realization.

## Why fired_thresholds resets on fresh buy

If `ladder_buys` adds to a position at a lower price, the average cost drops. The +10% threshold from the new (lower) basis is a different price than the +10% from the original basis. Resetting the ladder lets profit_take re-evaluate from the new cost basis without double-firing on the same price level.

The reset is keyed on `last_buy.timestamp` advancing past `last_baseline_at`, so adding to position via any buy strategy triggers the rebuild.

## Implementation

```bash
bash "$REPO_ROOT/.claude/skills/strategy_profit_take/scripts/apply.sh"
```

## Reuse

`lib/alpaca.sh` for position + order placement, `lib/pool.sh` for state. Reads `persistence/config/strategy_defaults.json` via `pool_strategy_config`.
