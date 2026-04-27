---
name: strategy_mean_reversion
description: This skill should be used when invoked by master_trading with the mean_reversion strategy enabled, or when the user asks to "buy the laggard", "find the worst performer", "apply mean reversion". Cross-sectional, contrarian. Compares each buyable stock's N-day return against the pool's median return; the worst k laggards (those falling at least min_underperformance_percent below the median) get a small buy. Falling-knife guard via 50-day moving average; rebuy throttle via min_hours_between_buys on top of the 2-trading-day H1B floor.
version: 0.1.0
---

# strategy_mean_reversion

Buy-the-laggard contrarian strategy. The thesis: among a basket of correlated names, the underperformer over a short window tends to snap back toward the basket's median return.

## Invocation contract

**STDIN** — same envelope shape as other strategies. The `buyable` set is already filtered by `master_trading` to exclude stocks sold or bought earlier in the same tick.

```json
{
  "sellable": [...],
  "buyable":  ["AAPL", "MSFT", ...],
  "defaults": {
    "enabled": true,
    "lookback_days": 5,
    "bottom_k": 1,
    "min_underperformance_percent": 5,
    "buy_amount_usd": 100,
    "ma_filter_days": 50,
    "min_hours_between_buys": 2
  },
  "now": "<ISO-8601>"
}
```

**STDOUT** — JSON array of placed orders (or `[]` if nothing fired).

## Decision logic

1. **Compute N-day return per candidate.** For each `symbol` in `buyable`, fetch ~75 calendar days of daily bars from Alpaca and compute:
   - `ret = (latest_close - close_N_trading_days_ago) / close_N_trading_days_ago * 100`
   - `ma50 = mean(last 50 daily closes)`

   Skip silently if Alpaca returns insufficient bars (e.g., a freshly-IPO'd stock with less history than `lookback_days + 1` or `ma_filter_days`).

2. **Compute pool median.** Median of `ret` across all candidates with valid data.

3. **Rank.** For each candidate compute `underperformance = median_return - this_stock_return`. Positive = lagging. Sort descending (worst laggards first). Take the top `bottom_k`.

4. **Per-candidate filters (apply in order, skip on first failure):**
   - **Min underperformance:** `underperformance >= min_underperformance_percent`. Otherwise the laggard isn't lagging enough to act on.
   - **50-day MA falling-knife:** `current_price >= ma50`. Stocks below their 50-day MA are in a confirmed downtrend; mean-reversion fights trend, so we abstain.
   - **Rebuy throttle:** `(now - last_buy.timestamp) >= min_hours_between_buys`. Prevents stacking buys across consecutive ticks via different strategies. Reuses `pool.last_buy.timestamp` as the "any buy" timestamp — if `ladder_buys` bought this stock 90 min ago, this strategy waits.
   - **Cash:** running cash balance must be `>= buy_amount_usd`. Decrements as orders fire within this tick.

5. **Place buy.** `notional = min(buy_amount_usd, max_per_trade_usd, available_cash)`. `alpaca_place_order $sym buy "$$notional" market`. Then `pool_set_last_buy` so subsequent ticks see the updated baseline (and other buy strategies' throttles activate).

## Implementation

```bash
bash "$REPO_ROOT/.claude/skills/strategy_mean_reversion/scripts/apply.sh"
```

## Why "vs median" instead of "absolute drop"

Two signals are conflated in a market move: the basket-wide drift (e.g., SPY down 3%) and the stock-specific component. Comparing to the basket median strips out the systematic component. A stock down 4% on a day the median is also down 4% isn't a laggard — it's tracking the basket. A stock down 4% when the median is +1% really is being abandoned, and is a higher-conviction reversion candidate.

## Why the 50-day MA guard

Mean-reversion assumes the prior trend continues. A stock in a confirmed downtrend (closing below its 50-day MA) violates that assumption — buying it is "catching a falling knife." The guard isn't a perfect signal but it cheaply removes the worst regime mismatches.

For fast-moving AI / semiconductor names where the user has tilted the pool, 50-day MA is a reasonable trend filter — long enough to ignore intraweek noise, short enough to react when a real downtrend establishes.

## Footguns we've already addressed

- **Insufficient history:** `compute_return` returns null when bars < `lookback+1`; the candidate is silently dropped from ranking.
- **Empty buyable:** If `buyable` is `[]` (everything was just sold or bought earlier in the tick), exit with `[]` immediately. No API calls.
- **Cash exhaustion mid-loop:** `available_cash` is decremented after each placed order. If it falls below `buy_amount_usd`, remaining candidates skip with a `status: "skipped"` action recorded.

## Reuse

Sources `lib/env.sh`, `lib/alpaca.sh`, `lib/pool.sh`. Reads `persistence/config/user_preferences.json` for `max_per_trade_usd`. Reads `persistence/config/strategy_defaults.json` via `pool_strategy_config`.
