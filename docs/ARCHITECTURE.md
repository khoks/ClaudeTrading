# ClaudeTrading — Architecture & Design

How this system is built. For *what it does* day-to-day, see [FUNCTIONALITY.md](./FUNCTIONALITY.md).

---

## 1. System overview

```
                ┌─────────────────────────────────────────────┐
                │   mcp__scheduled-tasks (local cron)         │
                │                                             │
                │  claudetrading-master-tick   */15 6-12 * 1-5│
                │  claudetrading-daily-report  0 7 * * 1-5    │
                └────────────────┬────────────────────────────┘
                                 │ fires
                ┌────────────────▼────────────────────────────┐
                │   New Claude Code session per fire          │
                │     - cd D:/DEV/ClaudeProjects/ClaudeTrading│
                │     - source lib/env.sh (incl. .env)        │
                │     - invoke /master_trading or /reporting  │
                └────────────────┬────────────────────────────┘
                                 │ reads SKILL.md as code-by-prompt
                ┌────────────────▼────────────────────────────┐
                │   Skill layer  (.claude/skills/*/SKILL.md)  │
                │     master_trading orchestrates:            │
                │       safe_trading.filter_pool              │
                │       Phase A: profit_take, trailing_stop   │
                │       Phase B: mean_reversion, ladder_buys  │
                │       state_persistence                     │
                └────────────────┬────────────────────────────┘
                                 │ shells out
                ┌────────────────▼────────────────────────────┐
                │   Script layer  (.../scripts/*.sh, bash+jq) │
                │     concrete I/O: Alpaca calls, JSON edits  │
                └────────────────┬────────────────────────────┘
                                 │ sources
                ┌────────────────▼────────────────────────────┐
                │   Library layer  (lib/*.sh)                 │
                │     env, date (cross-platform shim),        │
                │     alpaca, calendar, pool                  │
                └────────────────┬────────────────────────────┘
                                 │ reads / writes
                ┌────────────────▼────────────────────────────┐
                │   Persistence layer  (persistence/*)        │
                │     pool.json, snapshots/, config/, reports/│
                └────────────────┬────────────────────────────┘
                                 │ HTTPS                       
                ┌────────────────▼────────────────────────────┐
                │   Alpaca paper API  (truth for orders/state)│
                └─────────────────────────────────────────────┘
```

Per-operator state (pool, snapshots, reports, activation, the local settings.json allowlist) is **gitignored**. The public repo holds code, strategy defaults, and `.example` templates only — trading data stays on the operator's machine.

---

## 2. Layer responsibilities

| Layer | Lives in | Owned by | Mutability |
|---|---|---|---|
| **Schedule** | `~/.claude/scheduled-tasks/<task_id>/SKILL.md` (out-of-repo) | `mcp__scheduled-tasks` MCP, registered by `/master_configurator` | Edit via MCP `update_scheduled_task` |
| **Skill** | `.claude/skills/<name>/SKILL.md` | Each skill is markdown that Claude reads as a prompt at runtime | Hand-edit; Claude can edit during user sessions |
| **Script** | `.claude/skills/<name>/scripts/*.sh` | Bash + jq, called from skill bodies | Hand-edit |
| **Library** | `lib/*.sh` | Shared helpers, sourced by every script | Hand-edit |
| **Persistence (mutable state)** | `persistence/pool.json` | Strategies during ticks; intakes during configuration | **Gitignored.** Bootstrapped from `pool.json.example` by master_configurator. |
| **Persistence (snapshots)** | `persistence/snapshots/{tick,daily,weekly}/*.json` | state_persistence | **Gitignored.** `tick/` pruned at 7 days. Directories preserved by `.gitkeep`. |
| **Persistence (config — operator-specific)** | `persistence/config/{activation,user_preferences}.json` | configurator + intake skills | **Gitignored.** Bootstrapped from `.example` templates by master_configurator. |
| **Persistence (config — committed baseline)** | `persistence/config/strategy_defaults.json` | prebuilt_strategy_configurator | **Committed.** Shipped with sensible defaults; new clones inherit. |
| **Persistence (reports)** | `persistence/reports/*.html` | reporting skill | **Gitignored.** Operator's daily diagnostics stay local. |
| **Claude permissions** | `.claude/settings.json` | master_configurator on first run | **Gitignored.** Bootstrapped from `settings.json.example` (recommended allowlist). |
| **Source of truth** | Alpaca paper API | n/a | Strategies place orders; positions/cash read fresh each tick |

Two separation principles drive the layout:

1. **Skill = prompt; script = action.** Skills (markdown) describe *intent and contract* — what the strategy decides, when it acts. Scripts execute the concrete I/O. This lets us tune behaviour by editing markdown (no compilation, no bash gymnastics) while keeping all primitive ops in well-tested bash.
2. **Persistence is human-readable.** Every state file is JSON, every doc is markdown, every report is HTML. `jq` is the universal manipulator. There is no database.

---

## 3. Tick data flow

End-to-end for one master_trading invocation:

```
1. cron fires at HH:MM
2. mcp__scheduled-tasks spawns a new Claude Code session
3. Session prompt: "cd <repo>, run /master_trading"
4. Claude cd's, reads .claude/skills/master_trading/SKILL.md, follows it.
5. master_trading sources lib/env.sh + lib/alpaca.sh + lib/calendar.sh + lib/pool.sh
6. Market gate: alpaca_clock → if !is_market_open, log + exit 0
7. safe_trading.filter_pool reads pool.json, calls trading_days_old_enough,
   emits { sellable, buyable }
8. Master_trading runs Phase A:
     a. profit_take/scripts/apply.sh ← envelope { sellable, defaults, now }
        - For each sym: pool_get_stock, alpaca_position, alpaca_last_price
        - Compute gain%; find first unfired threshold
        - If fire: alpaca_place_order, pool_set_profit_take_state, pool_set_last_sell
        - emit JSON array of orders to stdout
     b. trailing_stop/scripts/apply.sh ← envelope { sellable, defaults, now }
        - Similar pattern; sells full residual qty if stop hit
9. Build sold_this_tick = { symbols of all Phase A sells }
10. Master_trading runs Phase B (with filtered buyable):
      buyable_for_mr = original_buyable \ sold_this_tick
      a. mean_reversion/scripts/apply.sh ← envelope { ..., buyable: buyable_for_mr }
         - For each sym in buyable: alpaca_bars (75 days, 1Day timeframe)
         - Compute (return%, ma50, current_close); rank by underperformance
         - For each top-bottom_k: apply 4 filters, place buy if all pass
         - pool_set_last_buy on success
      buyable_for_lb = buyable_for_mr \ {symbols mean_reversion bought}
      b. ladder_buys/scripts/apply.sh ← envelope { ..., buyable: buyable_for_lb }
         - For each sym: pool_strategy_config, pool_get_stock
         - alpaca_last_price, threshold check OR cold-start
         - Place market buy, pool_set_last_buy, decrement running cash
11. Master_trading aggregates all order arrays into $ACTIONS
12. master_trading pipes the envelope { tick_at, actions, sets } to
    state_persistence/scripts/persist.sh
13. persist.sh runs MECHANICALLY (no Claude judgment in the loop):
      a. snapshot_tick.sh: pull live account/positions, write tick snapshot,
         compute equity_delta_vs_prev_tick
      b. If is_last_tick_of_trading_day (reads tick_cadence_minutes from
         activation.json to size the detection window): snapshot_daily.sh
         aggregates today's tick snapshots into one daily file
      c. If a daily was just written AND is_last_trading_day_of_week:
         snapshot_weekly.sh aggregates this week's daily snapshots
      d. prune_tick.sh removes tick/*.json older than 7 days
      No git push — all state is gitignored per-operator.
14. Master_trading prints one-line summary to stdout. Session ends.
```

---

## 4. Skill catalog

| Skill | Tier | Role | Invoked by | Invokes |
|---|---|---|---|---|
| `master_configurator` | Configurator | One-time / reconfigure entrypoint | User (`/master_configurator`) | `user_preferences_intake`, `user_custom_strategy_intake`, `prebuilt_strategy_configurator`; `mcp__scheduled-tasks__create_scheduled_task` |
| `user_preferences_intake` | Configurator | Pool tickers, risk, trade caps | master_configurator or standalone | Alpaca `/assets/<ticker>` for validation; `pool_add_stock` |
| `user_custom_strategy_intake` | Configurator | Scaffold a new `strategy_<name>/` skill | master_configurator (optional) or standalone | jq edits to strategy_defaults.json; mkdir + write SKILL.md/apply.sh stub |
| `prebuilt_strategy_configurator` | Configurator | Enable/disable + tune the prebuilt strategies | master_configurator or standalone | jq edits to strategy_defaults.json |
| `master_trading` | Tick | Orchestrates one tick | Schedule (`claudetrading-master-tick`) or user (`/master_trading`) | `safe_trading`, all enabled strategy skills, `state_persistence` |
| `safe_trading` | Tick | H1B-floor filter; emits sellable/buyable sets | master_trading | `lib/calendar.sh::trading_days_old_enough` |
| `strategy_profit_take` | Tick (sells) | Eager partial exit on absolute gain | master_trading Phase A.1 | `alpaca_position`, `alpaca_place_order`, `pool_set_profit_take_state`, `pool_set_last_sell` |
| `strategy_trailing_stop` | Tick (sells) | Full exit on retracement | master_trading Phase A.2 | `alpaca_position`, `alpaca_last_price`, `alpaca_place_order`, `pool_set_watermark`, `pool_set_stop_loss`, `pool_set_last_sell` |
| `strategy_mean_reversion` | Tick (buys) | Buy the basket-relative laggard | master_trading Phase B.1 | `alpaca_bars`, `alpaca_place_order`, `pool_set_last_buy` |
| `strategy_ladder_buys` | Tick (buys) | Buy the per-position dip; cold-start initial rung | master_trading Phase B.2 | `alpaca_last_price`, `alpaca_place_order`, `pool_set_last_buy` |
| `strategy_wheel` | Tick (disabled) | Cash-secured puts → covered calls (placeholder) | master_trading (skipped while disabled) | n/a |
| `state_persistence` | Tick | Snapshot + rollup + prune (local only — no git) | master_trading (last step) | `persist.sh` orchestrator → `snapshot_tick.sh`, `snapshot_daily.sh`, `snapshot_weekly.sh`, `prune_tick.sh` |
| `reporting` | Daily | Generate daily HTML diagnostic (local-only) | Schedule (`claudetrading-daily-report`) or user (`/reporting`) | `generate_report.sh` |

---

## 5. State schemas

### 5.1 `persistence/pool.json`

```json
{
  "stocks": [
    {
      "symbol": "AAPL",
      "added_at": "2026-04-27T07:54:41Z",
      "last_buy":  { "timestamp": "ISO|null", "price": 175.02, "qty": 2.857, "amount_usd": 500 },
      "last_sell": { "timestamp": "ISO|null", "price": null,    "qty": null,  "amount_usd": null },
      "high_watermark": null,
      "stop_loss":      { "price": null, "trail_percent": null },
      "strategy_config": {
        "trailing_stop":   {},
        "ladder_buys":     {},
        "wheel":           {},
        "mean_reversion":  {},
        "profit_take":     { "fired_thresholds": [], "baseline_qty": null, "last_baseline_at": null }
      },
      "total_profit_usd":   0,
      "total_invested_usd": 500
    }
  ],
  "last_updated": "ISO-8601"
}
```

Per-stock `strategy_config.<name>` overrides values from `strategy_defaults.json`. Empty `{}` means "use defaults". Merge order: `defaults * overrides` (jq union; overrides win).

### 5.2 `persistence/snapshots/tick/<YYYY-MM-DDTHH-mm>.json`

```json
{
  "tick_at": "ISO-8601",
  "account": { full Alpaca /v2/account response },
  "positions": [ full Alpaca /v2/positions response ],
  "actions":  [ { strategy, symbol, side, qty, notional?, price, type, alpaca_order_id, status, reason }, ... ],
  "sets":     { "sellable": [...], "buyable": [...] },
  "equity_delta_vs_prev_tick": <float|null>
}
```

`equity_delta_vs_prev_tick` is null on the first snapshot of a session (no prior to compare).

### 5.3 `persistence/snapshots/daily/<YYYY-MM-DD>.json`

```json
{
  "date": "YYYY-MM-DD",
  "opening_equity": <float>,
  "closing_equity": <float>,
  "day_pl_usd": <float>,
  "tick_count": <int>,
  "actions": [ all actions across all tick snapshots for this date ],
  "final_positions": [ positions from the last tick of the day ]
}
```

### 5.4 `persistence/snapshots/weekly/<YYYY-Www>.json`

```json
{
  "week": "YYYY-Www",
  "opening_equity": <float>,
  "closing_equity": <float>,
  "week_pl_usd": <float>,
  "trading_days": <int>,
  "actions": [ all actions across all daily snapshots for this week ]
}
```

### 5.5 `persistence/config/activation.json`

```json
{
  "configured": true,
  "activated_at": "ISO-8601",
  "tick_cadence_minutes": 15,
  "schedule_ids": {
    "master_trading": "claudetrading-master-tick",
    "reporting":      "claudetrading-daily-report"
  }
}
```

Single source of truth for cadence. `lib/calendar.sh::is_last_tick_of_trading_day` reads `tick_cadence_minutes` to compute the detection window (`window_seconds = cadence × 60`).

### 5.6 `persistence/config/user_preferences.json`

```json
{
  "risk_tolerance": "conservative" | "moderate" | "aggressive",
  "max_per_trade_usd": <int>,
  "fractional_shares": true | false,
  "curated_tickers": ["AMAT", ...],
  "updated_at": "ISO-8601"
}
```

### 5.7 `persistence/config/strategy_defaults.json`

See [FUNCTIONALITY.md §8](./FUNCTIONALITY.md#83-strategy_defaultsjson) for full shape.

---

## 6. Library API reference

All under `lib/`. Sourced by every script via `source "$REPO_ROOT/lib/env.sh"` (which auto-sources `date.sh`); other libs sourced explicitly per need.

### 6.1 `lib/env.sh`

| Function / variable | Purpose |
|---|---|
| `REPO_ROOT` (exported) | Absolute path to repo root. Resolved relative to `lib/env.sh` itself. |
| `ALPACA_KEY` / `ALPACA_SECRET` (exported) | Loaded from `.env` if present; otherwise expected from runner-injected env. |
| `ALPACA_BASE` | Defaults to `https://paper-api.alpaca.markets/v2`. **Hard-coded paper.** |
| `ALPACA_DATA_BASE` | Defaults to `https://data.alpaca.markets/v2`. |
| `jq()` (function shim) | Wraps `command jq` and pipes through `tr -d '\r'` to strip CRLF that Windows `winget`-installed jq emits. Idempotent on Linux/macOS. |

### 6.2 `lib/date.sh`

Cross-platform `date` shim. Detects host (Linux / Git Bash / macOS-with-gdate / macOS-without-gdate) at source time and picks the right binary + flag flavor. Loaded once via guard variable `_DATE_SH_LOADED`.

| Function | Purpose |
|---|---|
| `date_now_iso` | UTC ISO-8601, second precision (e.g., `2026-04-26T18:35:00Z`) |
| `date_today_utc` | UTC `YYYY-MM-DD` |
| `date_now_epoch` | UTC epoch seconds |
| `date_iso_to_epoch <iso>` | Accepts `Z`-suffixed, `±HH:MM`-suffixed, naive (treated as UTC), or bare-date inputs |
| `date_epoch_to_iso <epoch>` | Inverse of above |
| `date_epoch_to_filename <epoch>` | `YYYY-MM-DDTHH-MM` (filesystem-safe — colons replaced) |
| `date_iso_to_filename <iso>` | Convenience wrapper |
| `date_offset_days <from\|now> <±N>` | `YYYY-MM-DD` shifted by N days. Use `now` as `from` for "today ± N". |
| `date_iso_week <yyyy-mm-dd>` | ISO 8601 week label `YYYY-Www` |

### 6.3 `lib/alpaca.sh`

Thin curl wrappers. All functions print raw JSON to stdout; errors print to stderr and return non-zero. Use `jq` to extract fields.

| Function | Endpoint / purpose |
|---|---|
| `alpaca_curl <method> <url> [body]` | Low-level curl with key headers |
| `alpaca_get`, `alpaca_post`, `alpaca_delete` | Trading API base |
| `alpaca_data_get` | Market data API base |
| `alpaca_account` | `/v2/account` |
| `alpaca_clock` | `/v2/clock` |
| `alpaca_calendar [start] [end]` | `/v2/calendar` |
| `alpaca_positions` | `/v2/positions` |
| `alpaca_position <symbol>` | `/v2/positions/<symbol>` |
| `alpaca_close_position <symbol>` | `DELETE /v2/positions/<symbol>` |
| `alpaca_close_all_positions` | `DELETE /v2/positions` |
| `alpaca_orders [status]` | `/v2/orders?status=...` |
| `alpaca_order <id>` | `/v2/orders/<id>` |
| `alpaca_cancel_order <id>` | `DELETE /v2/orders/<id>` |
| `alpaca_place_order <sym> <buy\|sell> <qty\|$notional> <type> [extra_json]` | Auto-detects notional vs qty; merges extras |
| `alpaca_last_trade <sym>` | `/v2/stocks/<sym>/trades/latest` |
| `alpaca_latest_quote <sym>` | `/v2/stocks/<sym>/quotes/latest` |
| `alpaca_last_price <sym>` | Convenience: extracts the trade price as a bare number |
| `alpaca_bars <sym> <tf> <start> <end>` | `/v2/stocks/<sym>/bars` (e.g. `1Min`, `5Min`, `1Day`) |

### 6.4 `lib/calendar.sh`

Market hours and trading-day math. Sources `lib/env.sh` + `lib/alpaca.sh` first.

| Function | Purpose |
|---|---|
| `is_market_open` | Exit 0 if Alpaca clock says open, 1 otherwise |
| `market_close_iso` | Today's `next_close` from Alpaca clock |
| `is_last_tick_of_trading_day` | Reads `activation.json.tick_cadence_minutes`; returns true if `(close - now) ≤ cadence × 60s` |
| `is_last_trading_day_of_week` | True if next trading day in Alpaca calendar is in a different ISO week |
| `trading_days_ago <iso_ts>` | Integer count of trading days strictly between the date of `<iso_ts>` and today (excluding both endpoints) |
| `trading_days_old_enough <iso_ts> <threshold>` | Exit 0 if `trading_days_ago ≥ threshold`. Convention: `threshold=2` for the H1B floor. |

### 6.5 `lib/tz.sh`

Translates the PT-based market-hours cron to the operator's local timezone, since `mcp__scheduled-tasks` evaluates cron in local time. Uses POSIX TZ format (`PST8PDT`) for portability — IANA names like `America/Los_Angeles` don't resolve on Git Bash's mingw `date`.

| Function | Purpose |
|---|---|
| `_tz_offset_minutes [<zone>]` | UTC offset of `<zone>` (or system if empty) in minutes |
| `market_cron <cadence_minutes>` | Prints a 5-field cron expression that fires every `<cadence>` minutes during the local-TZ equivalent of 06:00–12:45 PT, Mon–Fri. Returns non-zero with a stderr message for half-hour-offset TZs (IST etc.) or windows that wrap past midnight. |
| `market_cron_describe <cadence_minutes>` | Human-readable summary for the configurator's confirmation output |

### 6.6 `lib/pool.sh`

Read/write `persistence/pool.json` via jq. All writes are atomic (write-temp + mv).

| Function | Purpose |
|---|---|
| `pool_read` | Print pool.json |
| `pool_write <json>` | Replace pool.json (sets `last_updated` automatically) |
| `pool_symbols` | List ticker symbols, one per line |
| `pool_get_stock <sym>` | Print the stock object |
| `pool_add_stock <sym>` | Idempotent — adds with empty trade history if not present (seeds full `strategy_config` shape) |
| `pool_set_last_buy <sym> <ts> <price> <qty> <amount>` | Updates `last_buy` and increments `total_invested_usd` |
| `pool_set_last_sell <sym> <ts> <price> <qty> <amount> <profit>` | Updates `last_sell` and increments `total_profit_usd` |
| `pool_set_watermark <sym> <price>` | Updates `high_watermark` |
| `pool_set_stop_loss <sym> <price> <trail_percent>` | Updates `stop_loss` |
| `pool_set_profit_take_state <sym> <fired_json> <baseline_qty> <baseline_at>` | Updates `strategy_config.profit_take` (pass `null` for baseline_qty / empty string for baseline_at to clear) |
| `pool_strategy_config <sym> <strategy_name>` | Returns merged JSON of defaults `*` per-stock overrides |

---

## 7. Cross-cutting concerns

### 7.1 Cadence as single source of truth

`activation.json.tick_cadence_minutes` is the canonical cadence. Two consumers:
- **Cron string** — set on the scheduled task (e.g., `*/15 6-12 * * 1-5`). Operator must keep them in sync; `master_configurator` does this on activation/reconfigure.
- **`is_last_tick_of_trading_day`** — reads cadence from `activation.json` to set the detection window, so daily rollups fire on the correct tick regardless of cadence.

### 7.2 The trading-day cooldown floor

Implemented entirely in `safe_trading.filter_pool.sh` via `trading_days_old_enough <ts> $THRESHOLD` where `THRESHOLD` is `${SAFE_TRADING_THRESHOLD:-2}`. **Every** strategy operates on `safe_trading`'s output sets — they never read `pool.json` directly to decide eligibility. This is the systemic guardrail; no individual strategy can bypass it.

Default threshold is 2 trading days — calibrated for operators avoiding pattern-day-trader and second-income heuristics. Override via env var if a different policy fits.

Trading-days math uses Alpaca `/v2/calendar` (weekends + holidays automatically excluded).

### 7.3 Cross-strategy guards

Master_trading itself maintains `sold_this_tick` and `bought_this_tick` sets, and filters the buyable set passed to each Phase B strategy. Strategies don't know about each other; only master_trading does.

This is implemented in master_trading's SKILL.md prose (since master_trading is markdown that Claude follows at runtime, not a script). Each tick's Claude session re-reads the SKILL.md, so changes to orchestration rules take effect on the next tick after a commit lands.

### 7.4 Permissions

`.claude/settings.json` carries an allowlist for the bash commands scheduled sessions will run. The file is **gitignored** — `.claude/settings.json.example` ships with the repo as the recommended baseline, and `master_configurator` copies it to the real path on first run.

The recommended baseline includes a plain `Bash` allow rule (necessary because scheduled sessions construct compound `&&` chains the granular allowlist can't match), plus granular `Bash(<cmd>:*)` entries for documentation. Retained `ask` rules: `Bash(gh repo create:*)`, `Bash(gh repo delete:*)`, `mcp__scheduled-tasks__create_scheduled_task`, `mcp__scheduled-tasks__update_scheduled_task`.

The scheduled session reads project settings after `cd $REPO_ROOT`, which is why the prompt explicitly cd's first.

### 7.5 Cross-platform shell

The repo runs unchanged on Linux, macOS (with or without gdate), and Windows Git Bash:
- `lib/date.sh` translates between GNU and BSD `date` flag conventions.
- `lib/env.sh` ships a `jq()` shim that strips CRLF (Windows `winget install jqlang.jq` emits CRLF on stdout).
- All scripts use `bash -n`-validated syntax compatible with bash 3.2 (macOS default).

### 7.6 Idempotency and retry

- **Order placement**: not idempotent. If `persist.sh` fails after orders have been placed, master_trading does NOT retry orders to avoid double-placement; it logs and exits non-zero.
- **Snapshot writes**: write-temp + mv = atomic on POSIX. Re-running the same tick (same minute) overwrites the snapshot, which is fine — Alpaca state is the same so the snapshot content is the same.
- **No git push to worry about**: state is local-only, so concurrent ticks don't cause non-fast-forward push failures. They can still race on `pool.json` if you trigger a manual tick during a scheduled fire — avoid this.

### 7.7 Cache freshness

- `alpaca_account` is fetched fresh per strategy invocation (cash availability could change mid-tick).
- `alpaca_position` is fetched fresh per per-stock iteration inside profit_take and trailing_stop (so trailing_stop sees post-profit_take qty).
- `alpaca_clock` is fetched once at the top of the tick (market gate).
- `alpaca_calendar` is fetched on demand (safe_trading per stock; calendar.sh helpers).

---

## 8. Extension points

### 8.1 Add a new strategy

Run `/user_custom_strategy_intake`. It scaffolds:

1. `.claude/skills/strategy_<name>/SKILL.md` (template based on `strategy_trailing_stop`).
2. `.claude/skills/strategy_<name>/scripts/apply.sh` (stub with the JSON envelope contract pre-wired).
3. Adds an entry under `strategy_defaults.json[<name>]` with `enabled: true` plus the user-described tunables.

Then hand-edit `apply.sh` with the actual decision logic. **Important contract** for any new strategy:

- Read envelope from stdin: `{ sellable, buyable, defaults, now }`.
- Operate **only** on the appropriate set (sellable for sells, buyable for buys).
- Emit a JSON array of order records to stdout (or `[]`).
- For sells: call `pool_set_last_sell` to honor the H1B cooldown.
- For buys: call `pool_set_last_buy` and decrement running `cash` after each fire.
- For first-fire-only state: define a per-stock `strategy_config.<name>` shape and persist via a new pool.sh helper.

If the new strategy needs to slot into the orchestration order: **edit `master_trading/SKILL.md`** to add it to Phase A or Phase B explicitly. Without that, master_trading falls back to "any user-added strategy" handling, which runs after the prebuilt phases without specific cross-strategy guards.

### 8.2 Change a strategy's defaults

Edit `persistence/config/strategy_defaults.json`. Or: set per-stock overrides in `pool.json[stock].strategy_config.<name>` (these win over global defaults).

### 8.3 Add a new lib helper

Add to the appropriate `lib/*.sh`. Two conventions:
- New helpers that need `REPO_ROOT` go in libs that already require it (pool.sh, calendar.sh).
- Helpers that don't (pure date math, jq utilities) go in date.sh or alpaca.sh.

### 8.4 Tune the cron

`mcp__scheduled-tasks__update_scheduled_task` with new `cronExpression`. Remember to update `activation.json.tick_cadence_minutes` and commit.

---

## 9. Operational concerns

### 9.1 Race conditions

`master_trading` only fires every N min, so two simultaneous runs are rare but possible (manual trigger during a scheduled fire). Mitigations:

- Alpaca order placement is **not** idempotent; double-firing master_trading would double-place orders. Avoid manual triggers during the cadence window.
- `pool.json` writes are atomic (temp + mv), so a concurrent reader sees consistent state — but the `read → modify → write` sequence inside a strategy is not transactional, so a concurrent write between two strategies' invocations could clobber updates. Same advice: don't manually fire during scheduled ticks.

### 9.2 Permission prompts in scheduled sessions

Scheduled-task Claude sessions cannot answer prompts (nobody's at the keyboard). Project settings.json allowlist + the user's "loose" preference (plain `Bash` allow) prevents this. Newly-introduced command shapes will still prompt the first time — surface them in the operator's interactive session and update settings.

### 9.3 Local runner caveat

`mcp__scheduled-tasks` runs the task on the **operator's local machine** (not a remote ephemeral agent). Practical implications:
- The machine must be online and Claude Code must be reachable when the cron fires.
- The scheduled prompt sources `.env` directly from the local repo (no env-injection path on this MCP).
- The git auto-commit-and-push is belt-and-suspenders for backup/visibility; state would survive without it on a local-only setup, but the cross-machine portability story is git-based.

`CLAUDE.md` was originally drafted assuming a remote ephemeral agent; the on-disk persistence design (commits-as-state-backup) survives both topologies.

### 9.4 Observability

For debugging:
- `persistence/snapshots/tick/<latest>.json` — live state at the last tick (account, positions, actions, sets). Gitignored — viewable locally only.
- `persistence/snapshots/daily/<date>.json` — end-of-day rollup once `is_last_tick_of_trading_day` fires.
- `persistence/reports/<today>.html` — human-readable view if the daily report has fired.
- `mcp__scheduled-tasks__list_scheduled_tasks` — schedule status, next/last run.

State is no longer in `git log` — set up your own backup mechanism if you want a history. For deep debugging, `claude -p '/master_trading'` runs an ad-hoc tick from the operator's interactive session (still gated by `is_market_open`, so closed-market debugging requires inspecting existing snapshots).

---

## 10. Design decisions (the "why")

| Decision | Rationale |
|---|---|
| **Skill markdown over rigid scripts for orchestration** | Each tick re-reads SKILL.md; behavior changes take effect via commits, no compilation. Claude can also reason about edge cases (e.g., partial Alpaca outages) per tick rather than baking every branch into bash. |
| **Bash + jq over Python** | Zero external runtime; works identically on Linux / macOS / Git Bash; jq's pipeline is a clean fit for shell-out from a markdown-driven harness. |
| **JSON on disk over a database** | Human-readable, jq-manipulable, git-trackable. Diffs in PRs are reviewable. No server to run. |
| **Trading-day cooldown floor enforced systemically by safe_trading** | Centralizes the cooldown heuristic. No individual strategy can bypass it; even a user-added strategy inherits the guardrail by virtue of operating on safe_trading's output. Threshold defaults to 2 trading days but is overridable via `SAFE_TRADING_THRESHOLD`. |
| **Two-phase orchestration (sells before buys)** | Sells free cash. Selective-before-broad ordering inside each phase routes high-conviction picks ahead of broad strategies competing for the same cash. |
| **First-writer-wins for cross-strategy buy conflicts** | Simpler than priority/scoring for v1. Determinism > optimality at this stage; if two strategies want the same stock the same tick, the more-selective one (mean_reversion at $100) wins over the broader one ($500 ladder add). |
| **profit_take resets `fired_thresholds` on fresh buy** | A new buy at a different price changes the cost basis. Without reset, the +10% threshold from the original basis would be a different price than +10% from the new basis. Reset ensures the rung ladder always references the current cost basis. |
| **`tick` naming (cadence-agnostic)** | The 5-min name was hardcoded across the codebase originally, broke when cadence moved to 15 min, and would keep drifting any time the schedule changes. "tick" decouples the data unit from any specific cadence. |
| **`tick_cadence_minutes` in activation.json (not derived from cron)** | The cron string lives in the scheduled-tasks MCP store (out-of-repo). Storing cadence in activation.json keeps it in-repo and queryable by libs that need it. The two are kept in sync by master_configurator on activation/reconfigure. |
| **Per-operator state is local-only (gitignored)** | Earlier design auto-committed every tick. Reversed once the repo became publicly shareable: trading history is private to the operator, and a public repo with strangers' trade timelines committed to `main` is the wrong default. Operators wanting cross-machine portability or an audit log set up their own backup (private mirror, encrypted bucket, etc.). |
| **Mechanical persist.sh orchestrator (vs markdown-driven state_persistence)** | The earlier design had state_persistence's daily-rollup conditional in SKILL.md prose, which Claude in scheduled sessions sometimes silently skipped. Moving the conditional into a shell script (`persist.sh`) makes daily/weekly rollups happen reliably whenever `is_last_tick_of_trading_day` returns true. |
| **First-run gate (configurator must run before tick / report)** | Both master_trading and reporting check `activation.json.configured == true` and fail fast otherwise. Combined with the gitignore, a fresh clone has no `activation.json` and the gate forces operators through the configurator (which bootstraps the gitignored config files from `.example` templates). |
| **Cold-start initial rung in `ladder_buys`** | Without it, a freshly added pool stock with no `last_buy.price` would never have its first position opened. The cold-start branch (line 41-45 of apply.sh) places one initial rung at current market price the first time the stock enters `buyable`. This is what placed the operator's 19 starting positions. |
| **Wheel scaffolded but disabled** | Options trading on Alpaca requires explicit account approval. Hard-coded `enabled: false` until the operator confirms approval. The skill exists as a no-op placeholder so master_trading doesn't error on a missing strategy reference. |

---

## 11. Hard rules (excerpts from CLAUDE.md)

These are repo-wide invariants enforced by convention; they should be respected by every change:

1. **Paper API only.** Never call `https://api.alpaca.markets`. Base URL is `https://paper-api.alpaca.markets/v2`.
2. **Never commit `.env`.** Gitignored; verify with `git status` before every commit.
3. **Per-operator state is local-only.** `persistence/{pool.json, config/{activation,user_preferences}.json, snapshots/**, reports/**}` and `.claude/settings.json` are gitignored. `.example` templates ship with the repo; `master_configurator` materialises the real files on first run.
4. **`master_configurator` must be run before `master_trading` or `reporting`.** Both check `activation.json.configured == true` at startup and exit on failure.
5. **Always go through safe_trading.** Every order originates from a stock returned by the safe_trading filter.
6. **No legal or tax advice.** The cooldown is a heuristic, not a guarantee of compliance with FINRA / IRS / visa rules.
7. **`master_configurator` is the only place that activates schedules.** Ad-hoc skills must not call `mcp__scheduled-tasks__create_scheduled_task` directly.
8. **`wheel` is disabled by default.** Enabling requires confirmed Alpaca options approval.

See [`CLAUDE.md`](../CLAUDE.md) for the canonical list.
