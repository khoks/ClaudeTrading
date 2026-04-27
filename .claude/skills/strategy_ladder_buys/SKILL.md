---
name: strategy_ladder_buys
description: This skill should be used when invoked by master_trading with the ladder-buys strategy enabled, or when the user asks to "apply ladder buys", "check ladder rungs", "buy on the dip". For each stock in the buyable set, places a notional buy order when price has dropped at least drop_percent below the last buy price (or initial baseline), capped by user_preferences.max_per_trade_usd.
version: 0.1.0
---

# strategy_ladder_buys

Buys more of a stock as it drops. Each "rung" is a notional dollar buy at a price strictly below the previous rung. This is the inverse of trailing-stop: trailing-stop sells on a drop from the high; ladder-buys buys on a drop from the prior buy.

## Invocation contract

**STDIN** — same envelope shape as other strategies.

**STDOUT** — JSON array of placed orders.

## Per-stock logic

For each `symbol` in `buyable`:

1. **Resolve config:** `pool_strategy_config "$symbol" ladder_buys`. Defaults: `drop_percent=18`, `buy_amount_usd=1000`.
2. **Resolve baseline price** — the price the next rung must drop below:
   - If `pool[symbol].last_buy.price` exists → use it.
   - Else → no baseline yet. Place the **first rung** unconditionally at the current price (this is how a never-bought stock enters the position). Treat the current price as the baseline going forward.
3. **Get current price:** `price=$(alpaca_last_price "$symbol")`.
4. **Trigger condition:** if `current_price <= baseline * (1 - drop_percent/100)`, place a buy.
5. **Sizing:** notional = `min(buy_amount_usd, user_preferences.max_per_trade_usd, account.cash)`. Skip the buy entirely if notional ≤ 0.
6. **Place order:** `alpaca_place_order "$symbol" buy "\$$notional" market`.
7. **Update pool:** `pool_set_last_buy "$symbol" "$now" "$current_price" "$qty" "$notional"`. The qty Alpaca fills will arrive on the order fill; the optimistic estimate `notional / price` is fine for the snapshot — it'll be reconciled on the next tick by re-reading `alpaca_position`.

## First-rung handling

The very first time a stock appears in `buyable` with no prior `last_buy`, ladder_buys kicks off the position. This is intentional — without it, a freshly added pool stock would never get its first rung. To disable this behavior, set per-stock `strategy_config.ladder_buys.skip_initial = true` in pool.json.

## Implementation

Run:
```bash
bash "$REPO_ROOT/.claude/skills/strategy_ladder_buys/scripts/apply.sh"
```

## Reuse

`lib/alpaca.sh` for clock/positions/orders, `lib/pool.sh` for state, `persistence/config/user_preferences.json` for `max_per_trade_usd`.
