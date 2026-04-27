---
name: user_preferences_intake
description: This skill should be used when invoked by master_configurator, or when the user asks to "update trading preferences", "change my pool", "add stocks to pool", "set trade limits". Collects the curated stock pool, risk tolerance, max-per-trade dollar cap, and fractional-share preference, then writes the results to persistence/config/user_preferences.json and seeds persistence/pool.json.
version: 0.1.0
---

# user_preferences_intake

Gathers the user's trading preferences and the initial curated stock list.

## When invoked standalone

User can run this alone (e.g. `/user_preferences_intake`) to add stocks or adjust caps without re-running the full configurator.

## Workflow

1. **Read current state** if any:
   - `persistence/config/user_preferences.json`
   - `persistence/pool.json`
2. **Ask the user** (one AskUserQuestion call, batched questions):
   - Curated stock tickers (free text, comma-separated). Default: keep existing.
   - Risk tolerance: `conservative` | `moderate` | `aggressive`.
   - Max per-trade dollar cap (USD integer). Default: `$1000`.
   - Allow fractional shares: yes/no. Default: yes.
3. **Validate tickers.** For each ticker entered, call `alpaca_get "/assets/$TICKER"` and check `.tradable == true`. Drop and warn on any that fail.
4. **Write `persistence/config/user_preferences.json`:**
   ```json
   {
     "risk_tolerance": "moderate",
     "max_per_trade_usd": 1000,
     "fractional_shares": true,
     "curated_tickers": ["AAPL", "MSFT", "GOOGL"],
     "updated_at": "<ISO-8601>"
   }
   ```
5. **Seed `persistence/pool.json`.** For each ticker in `curated_tickers`, call `pool_add_stock <symbol>` (idempotent — skips existing). Do NOT remove tickers that the user dropped — instead, ask explicitly: "Remove these <N> tickers from pool?" with AskUserQuestion. If yes, edit the pool JSON to filter them out.
6. **Echo summary** back to user: tickers added, tickers removed, validation failures, current cap.

## Trigger phrases for AskUserQuestion answers

- For ticker input: header "Tickers", free-text via "Other".
- For risk: 3 options.
- For cap: 4 options (`$500`, `$1000`, `$2500`, "Other").
- For fractional: 2 options (yes/no).

## Reuse

Sources `lib/env.sh`, `lib/alpaca.sh`, `lib/pool.sh`. Uses `pool_add_stock` for idempotent inserts.
