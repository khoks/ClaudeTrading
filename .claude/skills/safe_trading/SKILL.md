---
name: safe_trading
description: This skill should be used when invoked by master_trading at the start of every tick, or when the user asks "what's eligible to trade right now?", "show safe sellable list", "show safe buyable list". Filters persistence/pool.json into two sets — stocks safe to SELL (last_buy older than 2 trading days) and stocks safe to BUY (last_sell older than 2 trading days, or never sold) — to keep the user clear of pattern-day-trader and second-income classifications.
version: 0.1.0
---

# safe_trading

Implements the H1B safety filter. Never bypass — every order placed by ClaudeTrading must originate from a stock returned in one of these two sets.

> **Disclaimer.** The 2-trading-day cooldown is a user-defined safety margin, not legal or tax advice. It does not guarantee compliance with FINRA's pattern day trader rule, nor with IRS classification of trading income for H1B visa holders. Consult a tax advisor.

## Output contract

Print exactly one line of JSON to stdout:
```json
{ "sellable": ["AAPL", "MSFT"], "buyable": ["GOOGL"] }
```

## Filter rules

For each stock in `persistence/pool.json`:

- **sellable** ⇐ has a `last_buy.timestamp` AND `trading_days_ago(last_buy.timestamp) >= 2`. Rationale: a position bought today, yesterday, or the day before is still inside the 2-trading-day cooldown — selling it would be too close to a same-day round trip.
- **buyable** ⇐ `last_sell.timestamp` is null OR `trading_days_ago(last_sell.timestamp) >= 2`. Rationale: never-sold stocks are always re-buyable; recently-sold ones must wait out the cooldown.

A stock can appear in both sets (held position + last sale was long ago).
A stock can appear in neither (never bought, recently sold).

## Implementation

Run the bundled script:
```bash
bash "$REPO_ROOT/.claude/skills/safe_trading/scripts/filter_pool.sh"
```

The script sources `lib/env.sh`, `lib/alpaca.sh`, `lib/calendar.sh`, `lib/pool.sh`, then iterates over pool symbols and applies the rules above.

## Why trading days, not calendar days

Holidays and weekends do not count toward the cooldown. Using calendar days would let a Friday-buy → Monday-sell slip through with only 1 trading day of separation. Alpaca's `/v2/calendar` endpoint is the source of truth.

## Edge cases handled

- Stock newly added to pool with both `last_buy` and `last_sell` null: appears only in `buyable`.
- Stock with future-dated `last_buy.timestamp` (clock skew): treated as "today" → not sellable.
- Empty pool: emits `{ "sellable": [], "buyable": [] }` and exits 0.
