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

1. **Resolve config:** `pool_strategy_config "$symbol" ladder_buys`. Defaults: `drop_percent=12`, `buy_amount_usd=500`, `max_rungs=4`, `max_position_usd=2000`.
2. **Resolve baseline price** — the price the next rung must drop below:
   - If `pool[symbol].last_buy.price` exists → use it.
   - Else → no baseline yet. Place the **first rung** unconditionally at the current price (this is how a never-bought stock enters the position). Treat the current price as the baseline going forward.
3. **Get current price:** `price=$(alpaca_last_price "$symbol")`.
4. **Trigger condition:** if `current_price <= baseline * (1 - drop_percent/100)`, the rung is *eligible*.
5. **Cap 1 — `max_rungs`:** if `strategy_config.ladder_buys.consecutive_buys >= max_rungs`, skip with a clear `status:"skipped"` order entry. The cold-start (first-ever) rung counts as rung 1, so `max_rungs=4` means entry + 3 dip adds.
6. **Cap 2 — `max_position_usd`:** if `strategy_config.ladder_buys.consecutive_invested_usd >= max_position_usd`, skip. Otherwise compute `remaining_pos = max_position_usd - consecutive_invested_usd` and use it to clamp the notional below.
7. **Sizing:** notional = `min(buy_amount_usd, user_preferences.max_per_trade_usd, account.cash, remaining_pos)`. Skip the buy entirely if notional ≤ 0. The `remaining_pos` clamp lets the final rung use a partial notional rather than overshooting the cap.
8. **Place order:** `alpaca_place_order "$symbol" buy "\$$notional" market`.
9. **Update pool:** call `pool_set_last_buy` (records the rung's price/qty/notional), then `pool_increment_ladder_consecutive "$symbol" "$notional"` (bumps `consecutive_buys` and `consecutive_invested_usd`). The qty Alpaca fills will arrive on the order fill; the optimistic estimate `notional / price` is fine for the snapshot — it'll be reconciled on the next tick by re-reading `alpaca_position`.

## Consecutive-rung cap

`max_rungs` and `max_position_usd` together bound how aggressively ladder_buys can ride a single drawdown. They use two counters stored in `pool.json`:

- `strategy_config.ladder_buys.consecutive_buys` — int, number of ladder rungs since the last sell of this stock.
- `strategy_config.ladder_buys.consecutive_invested_usd` — number, cumulative notional invested since the last sell.

Both reset to 0 inside `pool_set_last_sell`, so **any** sell — partial (`profit_take`) or full (`trailing_stop`) — gives the next drawdown a fresh ladder budget. This is intentional: a sell signals the previous accumulation cycle is closing out.

**Caveat — manual closes:** if you close a position in the Alpaca web UI without `pool_set_last_sell` being called, the counters do **not** reset. The stock will stay capped until either (a) the operator manually edits `pool.json` to zero them, or (b) the system places its own sell. This is the same divergence problem flagged generally for `pool.json` vs Alpaca's actual positions.

**Per-stock override:** to widen or tighten the caps for one stock, set `strategy_config.ladder_buys.max_rungs` and/or `.max_position_usd` in `pool.json`. `pool_strategy_config` merges defaults with overrides.

## First-rung handling

The very first time a stock appears in `buyable` with no prior `last_buy`, ladder_buys kicks off the position. This is intentional — without it, a freshly added pool stock would never get its first rung. To disable this behavior, set per-stock `strategy_config.ladder_buys.skip_initial = true` in `pool.json`. Note: the cold-start rung counts toward `max_rungs` (it's rung 1).

## Implementation

Run:
```bash
bash "$REPO_ROOT/.claude/skills/strategy_ladder_buys/scripts/apply.sh"
```

## Reuse

`lib/alpaca.sh` for clock/positions/orders, `lib/pool.sh` for state, `persistence/config/user_preferences.json` for `max_per_trade_usd`.
