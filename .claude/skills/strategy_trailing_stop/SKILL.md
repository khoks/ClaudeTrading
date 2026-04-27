---
name: strategy_trailing_stop
description: This skill should be used when invoked by master_trading with the trailing-stop strategy enabled, or when the user asks to "apply trailing stop", "check stop losses", "evaluate trailing stops". For each stock in the sellable set, raises the high watermark when price runs up, and triggers a sell when price falls below the watermark by drop_percent.
version: 0.1.0
---

# strategy_trailing_stop

Floor-only trailing stop. Watermark goes up, never down. When price falls `drop_percent` below the watermark, the entire position sells at market.

## Invocation contract

**STDIN** — JSON envelope from master_trading:
```json
{
  "sellable": ["AAPL", "MSFT"],
  "buyable":  [...],
  "defaults": { "enabled": true, "drop_percent": 5, "raise_percent": 10 },
  "now":      "2026-04-26T18:00:00Z"
}
```

**STDOUT** — JSON array of placed orders:
```json
[
  { "strategy": "trailing_stop", "symbol": "AAPL", "side": "sell", "qty": 10, "type": "market",
    "alpaca_order_id": "abc-123", "status": "submitted",
    "reason": "price 175.00 fell below watermark 192.00 - 5% = 182.40" }
]
```

If no orders placed, emit `[]`.

## Per-stock logic

For each `symbol` in `sellable` (we never trail-stop a stock outside the sellable set — that would violate the H1B cooldown):

1. **Resolve config:** call `pool_strategy_config "$symbol" trailing_stop`. Returns merged defaults + per-stock overrides.
2. **Read state from pool:** `last_buy.price`, `high_watermark`, `stop_loss.price`.
3. **Get current price:** `price=$(alpaca_last_price "$symbol")`.
4. **Initialize watermark** if null. The initial watermark is `max(last_buy.price, current_price)`.
5. **Bump watermark** if `current_price >= watermark * (1 + raise_percent/100)`. Set `high_watermark = current_price` and recompute stop = `current_price * (1 - drop_percent/100)`. Persist via `pool_set_watermark` and `pool_set_stop_loss`.
6. **Trigger sell** if `current_price <= stop_loss.price`:
   - Look up actual position qty: `qty=$(alpaca_position "$symbol" | jq -r '.qty // empty')`.
   - If qty empty/zero, skip (no position to sell).
   - Place market sell: `alpaca_place_order "$symbol" sell "$qty" market`.
   - Compute realized profit estimate: `(current_price - last_buy.price) * qty`.
   - Update pool: `pool_set_last_sell "$symbol" "$now" "$current_price" "$qty" "$amt" "$profit"`.
   - Emit the order record.

## Implementation

Run:
```bash
bash "$REPO_ROOT/.claude/skills/strategy_trailing_stop/scripts/apply.sh"
```

## Reuse

Sources `lib/env.sh`, `lib/alpaca.sh`, `lib/pool.sh`. Reads `persistence/config/strategy_defaults.json`.

## Why we trail only on the sellable set

Watermark math is harmless to keep updated even on cooldown stocks, but pulling the trigger on a sell while inside cooldown would violate safe_trading. The cleanest contract is: only act on what safe_trading approves.

The watermark on cooldown stocks is updated implicitly the next time they enter the sellable set, by re-reading current price and last_buy.
