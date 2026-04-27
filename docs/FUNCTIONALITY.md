# ClaudeTrading — Functionality Reference

What this system *does*, day to day. For *how it's built* and design rationale, see [ARCHITECTURE.md](./ARCHITECTURE.md).

---

## 1. What this system is

An autonomous Alpaca **paper-trading** system, driven entirely by Claude Code skills + Anthropic scheduled tasks. Shareable: anyone can clone, point it at their own paper account, and run their own bot on their machine.

- **Pool** — a curated list of tickers the operator builds during `/master_configurator`. There's no shipped default pool.
- **Cadence** — every N minutes during PT market hours; N is configurable (default 15) and stored in `persistence/config/activation.json`.
- **Strategies** — four cooperating policies (`profit_take`, `trailing_stop`, `mean_reversion`, `ladder_buys`); a fifth (`wheel`) is scaffolded but disabled. Defaults shipped in `strategy_defaults.json` (committed); per-stock overrides in `pool.json` (gitignored).
- **Safety floor** — every order runs through a configurable trading-day cooldown filter (`safe_trading`). Default: 2 trading days, designed to keep operators clear of pattern-day-trader and second-income classifications. Tunable via `SAFE_TRADING_THRESHOLD` env var. **Heuristic, not legal advice** — see disclaimer.
- **State** — pool, snapshots, configs, and reports are all JSON on disk and **local to the operator**. They are gitignored; trading history does not leave the machine.
- **Reports** — a single self-contained HTML file produced daily at 7am PT.

Hard rules are enumerated in [`CLAUDE.md`](../CLAUDE.md).

## 1.5. Mandatory first run

A fresh clone has none of the per-operator config files (they're gitignored). Both `/master_trading` and `/reporting` check for `persistence/config/activation.json`.configured == true and exit with an error if missing. **Run `/master_configurator` first** — it bootstraps the config files from shipped `.example` templates, walks you through preferences, and registers the schedule.

---

## 2. The trading day

A typical Mon–Fri timeline (all times Pacific):

```
 06:00 ────  cron fires (master-tick), market still closed →
             /master_trading checks Alpaca clock → exits cleanly.
 06:15 ────  same.
 06:30 ────  market opens.
 06:33 ────  first market-hours tick (jitter from scheduler).
 06:45,
 07:00, …    every 15 min, all the way to 12:45.
 07:03 ────  daily-report cron fires → /reporting writes
             persistence/reports/<today>.html (summarises *yesterday*).
 12:45 ────  last scheduled tick of the day. is_last_tick_of_trading_day
             is true (window = tick_cadence_minutes × 60s); state_persistence
             additionally writes the daily snapshot.
 13:00 ────  market closes. No more ticks fire today.
 Friday 12:45  also writes the weekly snapshot.
```

Holidays and weekends: the cron still fires Mon–Fri 06:00–12:45, but `is_market_open` (Alpaca `/v2/clock`) returns false on holidays, so master_trading exits cleanly with no orders placed.

---

## 3. The trading-day cooldown — `safe_trading`

This is the first thing every tick does. It runs once and produces two sets:

| Set | Rule |
|---|---|
| `sellable` | Stock has a non-null `last_buy.timestamp` AND that timestamp is **≥2 trading days old** |
| `buyable`  | Stock has never been sold (`last_sell.timestamp` is null), OR `last_sell.timestamp` is **≥2 trading days old** |

A stock can be in **both** sets (held position whose last sell was long ago). It can be in **neither** (never bought, recently sold).

**Trading days, not calendar days.** Holidays and weekends do not count toward the cooldown — Alpaca's `/v2/calendar` is the source of truth. A Friday-buy + Monday-sell cannot slip through with only one trading day of separation.

**Strategies operate exclusively on these sets.** No strategy can place an order on a stock outside its respective set. This is the systemic guardrail; every strategy inherits it.

The threshold (default 2 trading days) is the operator's safety margin. Configure via `SAFE_TRADING_THRESHOLD` env var if you want a different value. The shipped default of 2 is calibrated for operators avoiding pattern-day-trader and second-income heuristics (e.g., H1B visa holders), but the system is policy-neutral — anyone can retune.

> **Disclaimer.** The cooldown window is a user-defined heuristic. It is **not** legal, tax, or compliance advice and does not guarantee compliance with FINRA's PDT rule, IRS classification of trading income, or any specific regulation that may apply to the operator's visa, residency, or employment status. Consult a tax / legal advisor.

---

## 4. Master-trading orchestration

`master_trading` is the heartbeat. One invocation = one tick. It runs strategies in **two phases** with explicit cross-strategy guards:

```
  ┌─────────────────────────────────┐
  │  safe_trading.filter            │  → sellable, buyable
  └─────────────────────────────────┘
                │
  ┌─────────────▼───────────────────┐
  │  Phase A: Sells                 │  on `sellable`
  │   1. profit_take                │  partial, eager
  │   2. trailing_stop              │  full, lazy
  └─────────────────────────────────┘
                │
                ├─►  sold_this_tick = {symbols of all sells}
                │
  ┌─────────────▼───────────────────┐
  │  Phase B: Buys                  │  on filtered buyable:
  │   1. mean_reversion             │   buyable \ sold_this_tick
  │   2. ladder_buys                │     \ already_bought_this_tick
  └─────────────────────────────────┘
                │
  ┌─────────────▼───────────────────┐
  │  state_persistence              │  snapshot, prune, git commit + push
  └─────────────────────────────────┘
```

### Why this order

- **Sells before buys.** Selling frees cash. If buys ran first, a strategic exit on a position might be preempted by a ladder buy on a different stock that drained the cash needed to market-sell.
- **Selective before broad in each phase.** The more selective strategy gets first claim. Inside Phase A, `profit_take` only fires one rung per stock; `trailing_stop` can sell the full residual. Inside Phase B, `mean_reversion` picks at most one stock per tick; `ladder_buys` can fire on many.

### Cross-strategy guards (master_trading enforces)

| Guard | Rule | Why |
|---|---|---|
| **No buy after sell, same tick, same stock** | A symbol that received a sell in Phase A is dropped from the buyable set passed to Phase B. | Sell-then-buy in one tick is wash churn. |
| **No double-buy across strategies** | After `mean_reversion` runs, its bought symbols are dropped from the buyable set passed to `ladder_buys`. First-writer-wins. | Avoids stacking $100 + $500 = $600 in one tick on the same stock. |
| **Position re-fetch between strategies** | `profit_take` and `trailing_stop` each call `alpaca_position` fresh inside their per-stock loop. | If `profit_take` sells 25%, `trailing_stop` sees the reduced qty. |
| **Cash decrement within a strategy** | Each buy strategy reads `account.cash` once at start, decrements after each placed order. | Prevents over-commitment when the buy loop iterates many candidates with limited cash. |

### Error policy

- A failed strategy invocation is logged and recorded as `{ strategy, status: "error", error }` in `actions[]`. It does **not** halt the tick — other strategies still run.
- A failed `safe_trading` call **does** halt the tick (no orders placed blindly).
- A failed `state_persistence` after orders were placed is logged loudly; the tick does NOT retry orders to avoid double-placement.

---

## 5. Strategy cards

### 5.1 `profit_take` — eager partial exit on absolute gain

| | |
|---|---|
| **Phase** | A (sells) |
| **Acts on** | `sellable` |
| **Concept** | Lock in gains in tier-out chunks as a position runs up |
| **Trigger** | `unrealized_pl_pct ≥ T` for the lowest unfired threshold T in the ladder |
| **Action** | Market-sell `min(baseline_qty × sell_fraction_per_rung, current_qty)`. **At most one rung fires per tick per stock.** |
| **State read** | `last_buy.{timestamp, price}`, `strategy_config.profit_take.{fired_thresholds, baseline_qty, last_baseline_at}`, Alpaca position |
| **State written** | `strategy_config.profit_take.fired_thresholds += [T]`, `baseline_qty` set on first fire, `last_baseline_at`, `last_sell` (triggers H1B cooldown) |
| **Tunables** (current values in `strategy_defaults.json`) | `profit_thresholds_percent: [10, 20, 35, 50]`, `sell_fraction_per_rung: 0.25` |
| **Reset rule** | `fired_thresholds`, `baseline_qty`, `last_baseline_at` clear when `last_buy.timestamp` advances past `last_baseline_at` (a fresh buy redefines cost basis) |
| **Guards** | Skip if no position (qty empty/0); skip if `sell_qty ≤ 0` after min-clamp |
| **Pairs with** | `trailing_stop` — both can fire same stock same tick. profit_take partial first, then trailing_stop sees reduced qty and decides independently. |
| **Footguns** | The 2-trading-day cooldown is triggered for the stock on every fire (because `last_sell` updates). Subsequent buys via any buy strategy are blocked for 2 days. This is intentional — partial vs full sell is irrelevant to the H1B safety floor. |

### 5.2 `trailing_stop` — full exit on retracement from peak

| | |
|---|---|
| **Phase** | A (sells) |
| **Acts on** | `sellable` |
| **Concept** | Floor-only watermark; sell when price drops `drop_percent` below the high |
| **Trigger** | `current_price ≤ stop_loss.price` where `stop_loss.price = high_watermark × (1 − drop_percent/100)` |
| **Action** | Market-sell **the entire position** (fetched fresh from Alpaca) |
| **State read** | `last_buy.price`, `high_watermark`, `stop_loss.price`, Alpaca position |
| **State written** | `high_watermark` (bumped when current ≥ watermark × (1 + raise_percent/100)), `stop_loss` (recomputed on bump), `last_sell` on fire |
| **Tunables** (current values) | `drop_percent: 7`, `raise_percent: 10` |
| **Watermark init** | On first observation: `high_watermark = max(last_buy.price, current_price)` |
| **Guards** | Skip if no position |
| **Pairs with** | `profit_take` (see above). Also see "missed peak during cooldown" footgun — watermarks aren't tracked while a stock is in 2-day cooldown, so if the stock spikes during that window the watermark is never recorded, and trailing_stop initializes from `max(buy_price, current_price)` when the stock re-enters the sellable set. Acceptable since selling during cooldown is forbidden anyway. |

### 5.3 `mean_reversion` — buy the laggard

| | |
|---|---|
| **Phase** | B (buys) |
| **Acts on** | `buyable` (after Phase B filtering) |
| **Concept** | Cross-sectional contrarian — buy the worst basket-relative performer |
| **Trigger** | Stock is in the bottom `bottom_k` of `(median_5d_return − this_5d_return)` AND that gap ≥ `min_underperformance_percent` |
| **Action** | Market-buy `notional = min(buy_amount_usd, max_per_trade_usd, available_cash)` |
| **State read** | Alpaca daily bars (≈75 calendar days), `last_buy.timestamp` (for throttle), `pool` |
| **State written** | `last_buy` |
| **Tunables** (current values) | `lookback_days: 5`, `bottom_k: 1`, `min_underperformance_percent: 5`, `buy_amount_usd: 100`, `ma_filter_days: 50`, `min_hours_between_buys: 2` |
| **Guards (in order)** | (1) Min underperformance gap. (2) **50-day MA falling-knife guard** — current_price must be ≥ 50-day moving average. (3) **Rebuy throttle** — no buy on this stock by *any* strategy in the last `min_hours_between_buys` hours (reads `last_buy.timestamp`). (4) Cash ≥ `buy_amount_usd`. |
| **Pairs with** | `ladder_buys` — first-writer-wins. mean_reversion runs first; if it bought AMAT, ladder_buys skips AMAT this tick. |
| **Footguns** | Insufficient bar history for a fresh-IPO stock → silently dropped from ranking. Empty `buyable` (everything just got sold) → exit immediately, no API calls. |

### 5.4 `ladder_buys` — buy the dip

| | |
|---|---|
| **Phase** | B (buys) |
| **Acts on** | `buyable` (after Phase B filtering, including any symbol mean_reversion bought this tick) |
| **Concept** | Per-position dip-add — buy more as the price falls below the last buy |
| **Trigger** | `current_price ≤ last_buy.price × (1 − drop_percent/100)`, OR `last_buy.price` is null and `skip_initial != true` (the **cold-start initial rung**) |
| **Action** | Market-buy `notional = min(buy_amount_usd, max_per_trade_usd, available_cash)` |
| **State read** | `last_buy.price`, Alpaca live price + cash |
| **State written** | `last_buy` |
| **Tunables** (current values) | `drop_percent: 12`, `buy_amount_usd: 500`. Per-stock override `skip_initial: true` available. |
| **Cold-start behavior** | First time a stock with no `last_buy.price` enters `buyable`, ladder_buys places the initial rung at the current market price. This is the bootstrap mechanism — without it, a freshly added pool stock would never get its first position. **This is what placed your 19 starting positions on the first market-hours tick after activation.** |
| **Guards** | Cash availability; running cash decremented after each placed order |
| **Pairs with** | `mean_reversion` (above). |
| **Footguns** | None known. (Previously: cash wasn't decremented across the loop → over-commitment. Fixed in commit `ce78c62`.) |

### 5.5 `wheel` — disabled

| | |
|---|---|
| **Phase** | A (would be sells of options premium) |
| **Concept** | Sell cash-secured puts → if assigned, hold underlying and sell covered calls → if called away, restart |
| **Status** | **Disabled.** Requires Alpaca options account approval. The skill exists as a no-op placeholder. |
| **Hard rule** | `CLAUDE.md` requires confirmed options approval before enabling. |

---

## 6. State persistence

`state_persistence` runs at the end of every tick (after all strategies). It owns the disk + git layer.

### What gets written, when

| File | Cadence | Contents |
|---|---|---|
| `persistence/snapshots/tick/<YYYY-MM-DDTHH-mm>.json` | Every tick | account snapshot, full positions list, actions[], sellable/buyable sets, equity_delta_vs_prev_tick |
| `persistence/snapshots/daily/<YYYY-MM-DD>.json` | Last tick of trading day | opening/closing equity, day P/L, all actions for the day, final positions, tick_count |
| `persistence/snapshots/weekly/<YYYY-Www>.json` | Last tick of trading week (typically Friday) | opening/closing equity, week P/L, all actions for the week, trading_days |
| `persistence/pool.json` | Updated in-place by strategies during the tick | per-stock state — see ARCHITECTURE.md schema section |
| `persistence/reports/<YYYY-MM-DD>.html` | 7am PT (separate schedule, not tick-driven) | self-contained HTML diagnostic |

### Pruning

`prune_tick.sh` removes any `persistence/snapshots/tick/*.json` older than 7 days (configurable via `PRUNE_DAYS` env var). Daily and weekly snapshots are retained indefinitely.

### No git commit — by design

Snapshots, reports, `pool.json`, and per-operator config files are gitignored. State_persistence does **not** commit or push. Trading history stays on the operator's machine. If you want cross-machine portability or an audit log, set up your own backup mechanism (private mirror, rsync to NAS, encrypted cloud bucket, etc.) — the public repo is for code, not data.

---

## 7. Daily report

Fires once daily at 7am PT (Mon–Fri) via the `claudetrading-daily-report` scheduled task. Produces a single self-contained HTML file at `persistence/reports/<YYYY-MM-DD>.html` (inline CSS, no external assets — renders offline and on GitHub HTML preview).

### Sections

1. **Header** — date, account equity, cash, buying power.
2. **Open positions table** — symbol, qty, avg cost, mark, market value, unrealized P/L (color-coded).
3. **Prior trading day** — closing equity and day P/L (read from the most recent daily snapshot).
4. **Strategy effectiveness (past 30 days)** — order count and successful fills per strategy, aggregated from the last 30 daily snapshots.
5. **Pool table** — every stock in the pool: last buy, last sell, watermark, stop, total realized profit.
6. **Schedule status** — current `activation.json` (configured? activated_at? schedule IDs?).

### Local-only

The HTML report is gitignored — your daily diagnostics stay on your machine. `generate_report.sh` writes the file and prints the absolute path; nothing more.

---

## 8. Configuration files

All of these live under `persistence/config/`. **Most are gitignored** — only `strategy_defaults.json` is committed (as the shipped baseline that new operators inherit). The repo ships `.example` templates for the gitignored ones; `master_configurator` bootstraps the real files from those examples on first run.

### `activation.json` *(gitignored — created by master_configurator)*

Single source of truth for the schedule.

```json
{
  "configured": true,
  "activated_at": "<ISO-8601>",
  "tick_cadence_minutes": 15,
  "schedule_ids": {
    "master_trading": "claudetrading-master-tick",
    "reporting": "claudetrading-daily-report"
  }
}
```

`tick_cadence_minutes` is read by `lib/calendar.sh::is_last_tick_of_trading_day` to compute the "is this the last tick" window, so it self-corrects when you change cadence. Keep it in sync with the cron expression on the scheduled task.

### `user_preferences.json` *(gitignored — created by user_preferences_intake)*

Operator-level preferences from `user_preferences_intake`.

```json
{
  "risk_tolerance": "aggressive",
  "max_per_trade_usd": 500,
  "fractional_shares": true,
  "curated_tickers": ["AMAT", "ASX", ...],
  "updated_at": "<ISO-8601>"
}
```

`max_per_trade_usd` is enforced by every buy strategy as `notional = min(strategy.buy_amount_usd, max_per_trade_usd, available_cash)`.

### `strategy_defaults.json` *(committed — shipped repo baseline)*

Per-strategy defaults. New operators inherit the shipped values; `prebuilt_strategy_configurator` lets them retune for their account. Per-stock overrides live in `pool.json[stock].strategy_config.<name>` (gitignored) and take precedence over these defaults (merged via `pool_strategy_config <symbol> <strategy_name>`).

```json
{
  "profit_take":     { "enabled": true,  "profit_thresholds_percent": [10,20,35,50], "sell_fraction_per_rung": 0.25 },
  "trailing_stop":   { "enabled": true,  "drop_percent": 7, "raise_percent": 10 },
  "mean_reversion":  { "enabled": true,  "lookback_days": 5, "bottom_k": 1, "min_underperformance_percent": 5, "buy_amount_usd": 100, "ma_filter_days": 50, "min_hours_between_buys": 2 },
  "ladder_buys":     { "enabled": true,  "drop_percent": 12, "buy_amount_usd": 500 },
  "wheel":           { "enabled": false, "comment": "requires Alpaca options account approval before enabling" }
}
```

### `pool.json` *(gitignored — managed by user_preferences_intake + strategies during ticks)*

Per-stock state including last buy/sell, watermarks, stop losses, per-strategy state. See [ARCHITECTURE.md §5](./ARCHITECTURE.md#5-state-schemas) for the full schema.

---

## 9. Scheduling

Two scheduled tasks, both evaluated in the operator's **local timezone** by `mcp__scheduled-tasks`. `master_configurator` auto-computes the cron expression for the operator's local TZ via `lib/tz.sh::market_cron`, so a non-PT operator gets the equivalent local hour range (e.g., ET operators get `*/15 9-15 * * 1-5` covering 09:00–15:45 ET = 06:00–12:45 PT).

| Task ID | Cron (PT example) | Cadence | Purpose |
|---|---|---|---|
| `claudetrading-master-tick` | `*/15 6-12 * * 1-5` | Every 15 min, 06:00–12:45 local (= US market hours minus last 15 min) | Runs `/master_trading` |
| `claudetrading-daily-report` | `0 7 * * 1-5` | 07:00 local time, Mon–Fri | Runs `/reporting` |

Both registered via `mcp__scheduled-tasks__create_scheduled_task` during `/master_configurator`. The task IDs are recorded in `activation.json.schedule_ids`.

**Half-hour offset TZs** (IST, NPT, etc.) and **TZs that wrap past midnight** are not auto-handled — `market_cron` errors and the configurator falls back to asking the operator for a manual cron expression.

> **Cadence-only changes** can be made via `mcp__scheduled-tasks__update_scheduled_task` with a new `cronExpression`. Remember to also update `activation.json.tick_cadence_minutes` so `is_last_tick_of_trading_day` stays correct.

---

## 10. Common operations

### Add a ticker
Run `/user_preferences_intake` (standalone). Validates against Alpaca `/v2/assets/<ticker>` (`tradable: true`), then `pool_add_stock` (idempotent — skips existing).

### Remove a ticker
Run `/user_preferences_intake` and explicitly drop. The skill will confirm before pruning. Existing positions are NOT auto-closed — you'll need to close them manually via Alpaca.

### Change cadence (e.g. 15 → 30 min)
1. `mcp__scheduled-tasks__update_scheduled_task` with `cronExpression: "*/30 6-12 * * 1-5"`.
2. Update `persistence/config/activation.json` → `tick_cadence_minutes: 30`. (Local-only edit; not committed.)

### Disable a strategy temporarily
Edit `persistence/config/strategy_defaults.json` → set `<name>.enabled: false`. master_trading will skip it on the next tick. (This file is committed, so the change is part of repo history if you push.)

### Disable trading entirely (pause the schedule)
`mcp__scheduled-tasks__update_scheduled_task` with `enabled: false` for `claudetrading-master-tick`. Reports continue. To resume: `enabled: true`.

### Manual one-off tick (debugging)
From the project root: `claude -p '/master_trading'`. Skill checks `is_market_open` first, so you can only force-tick during market hours.

### Inspect why a tick did nothing
1. Read `persistence/snapshots/tick/<latest>.json`.
2. Look at `actions[]`. If empty: probably `sellable` was empty AND no `buyable` candidate met any buy strategy's trigger.
3. Look at `sets.sellable.length` and `sets.buyable.length` — if both 19 (or matching pool size), `sellable` likely empty because all positions are <2 trading days old.
4. For mean_reversion silence specifically: the per-stock `last_buy.timestamp` may be within 2 hours of `now` (rebuy throttle), or current price below the 50-day MA (falling-knife guard).

### Reconfigure from scratch
`/master_configurator`. It detects whether `activation.json` exists and is configured; if yes, it asks whether to RECONFIGURE or CANCEL. RECONFIGURE re-runs the three intake skills in order.

### Fresh-clone setup
On a brand-new clone, `activation.json` doesn't exist (it's gitignored). Just `cp .env.example .env`, paste creds, then run `/master_configurator` — it bootstraps all the gitignored config files from `.example` templates and walks you through setup.

---

## 11. Files you might want to read

| File | What it is |
|---|---|
| [`README.md`](../README.md) | Quick start and prerequisites |
| [`CLAUDE.md`](../CLAUDE.md) | Hard rules for the project (loaded by Claude Code on every session) |
| [`docs/ARCHITECTURE.md`](./ARCHITECTURE.md) | Companion to this doc — design rationale, schemas, library API |
| `.claude/skills/<name>/SKILL.md` | Per-skill spec; Claude reads these as code-by-prompt at runtime |
| `lib/*.sh` | Shared bash helpers — see ARCHITECTURE.md §6 |
