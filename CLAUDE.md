# CLAUDE.md — repo-wide rules

Loaded automatically by Claude Code. These rules override anything in chat.

## What this repo is

Autonomous Alpaca **paper-trading** system, driven entirely by Claude Code skills + Anthropic scheduled tasks.

ClaudeTrading is shareable — anyone can clone this repo and run their own paper-trading bot on their machine with their own Alpaca creds. The repo contains the strategy code, orchestration, and shipped baseline tunables; per-operator state (pool, snapshots, schedule IDs, Claude permissions) is gitignored and lives only on the operator's machine.

The shipped strategies enforce a **2-trading-day cooldown** between opposite-direction trades on the same stock (configurable, default 2). This is a user-tunable safety floor designed to keep operators clear of pattern-day-trader and second-income classifications. It is not a guarantee of compliance with any specific rule — see disclaimer below.

## Hard rules

1. **Paper API only.** Never call `https://api.alpaca.markets`. The base URL must always be `https://paper-api.alpaca.markets/v2` (default in `lib/env.sh`; `.env` can override). If a future task requires live trading, STOP and ask the operator.
2. **Never commit `.env`.** It contains the Alpaca key and secret. `.gitignore` excludes it; verify with `git status` before every commit.
3. **Per-operator state is local-only.** `persistence/pool.json`, `persistence/config/{activation,user_preferences}.json`, `persistence/snapshots/**/*.json`, `persistence/reports/*.html`, and `.claude/settings.json` are all gitignored. They never go to GitHub. The repo ships `.example` templates for the JSON ones — `master_configurator` bootstraps the real files from those examples on first run.
4. **`master_configurator` must be run before `master_trading` or `reporting`.** Both check `persistence/config/activation.json.configured == true` and exit with an error otherwise. A fresh clone has no `activation.json` (it's gitignored), so this is automatic.
5. **Always go through `safe_trading`.** Every order placed must originate from a stock returned by the safe_trading filter. Never bypass the trading-day cooldown — it's the operator's safety floor.
6. **No legal or tax advice.** The cooldown is a user-defined heuristic, not a guarantee. Never tell the operator it makes them compliant with FINRA's pattern day trader rule, IRS classification of trading income, or any specific regulation that may apply to their visa, residency, or employment status. Consult a tax / legal advisor.
7. **`master_configurator` is the only place that activates schedules.** Ad-hoc skill scripts must not call `mcp__scheduled-tasks__create_scheduled_task` directly.
8. **`wheel` is disabled by default.** Enabling it requires confirmed Alpaca options approval.

## Operator profile (for the current operator running this clone)

The operator is on H1B and is using the 2-trading-day cooldown to stay below pattern-day-trader and second-income heuristics. Strategy defaults shipped in `strategy_defaults.json` are tuned for an aggressive risk profile (drop=7% trailing, drop=12% ladder, $500/trade cap when configured). New operators cloning the repo will see these as the starting baseline; running `/master_configurator` lets them adjust.

This profile section is **not normative for future contributors** — it's context for Claude Code so it understands the constraints behind certain choices. Anyone adapting this repo for a different profile (long-term hold, day-trader, options-enabled, etc.) is free to retune via `/prebuilt_strategy_configurator`.

## Repo map (quick)

- `lib/` — shared bash helpers (`env.sh`, `date.sh`, `alpaca.sh`, `pool.sh`, `calendar.sh`). `lib/date.sh` is the cross-platform `date` shim — Linux/Git Bash/macOS-with-`gdate` use GNU; macOS without `gdate` uses BSD with translated flags. Always go through the `date_*` helpers, never call `date -d` directly.
- `.claude/skills/` — 13 skills (see catalog below).
- `persistence/` — runtime state. Most files are gitignored per-operator; `strategy_defaults.json` is the committed baseline.
- `.env` (local-only) — Alpaca creds.
- `docs/FUNCTIONALITY.md` and `docs/ARCHITECTURE.md` — comprehensive operator and developer docs.

## Skill catalog

**Configurator tier (operator-invoked, one-time + reconfigure):**
- `master_configurator` — entry point. Bootstraps config from `.example`, runs intakes, activates schedules, discloses settings allowlist.
- `user_preferences_intake` — collects pool tickers, risk, trade caps.
- `user_custom_strategy_intake` — scaffolds new strategy skills.
- `prebuilt_strategy_configurator` — enables/tunes the prebuilt strategies.

**Tick tier (schedule-invoked on the configured tick cadence during PT trading hours; cadence in `persistence/config/activation.json`.tick_cadence_minutes):**
- `master_trading` — orchestrates one tick (Phase A sells → Phase B buys → state_persistence).
- `safe_trading` — filters pool into sellable + buyable sets per the cooldown rule.
- `strategy_profit_take`, `strategy_trailing_stop` (Phase A); `strategy_mean_reversion`, `strategy_ladder_buys` (Phase B); `strategy_wheel` (disabled).
- `state_persistence` — tick / daily / weekly snapshots, prune. No git push (state is local).

**Daily tier (schedule-invoked at 7am PT):**
- `reporting` — generates an HTML report under `persistence/reports/`.

## Recurring tasks etiquette

- Never run `master_trading` outside its schedule unless the operator explicitly asks for a manual tick.
- When debugging, prefer reading recent snapshots from `persistence/snapshots/tick/` over hitting Alpaca repeatedly.
- Code changes go in normal commits. State changes (pool.json, snapshots, etc.) stay local — don't try to commit them; they're gitignored.

## Helpful one-liners

```bash
# First time: bootstrap + configure
claude
> /master_configurator

# Sanity-check creds
source lib/env.sh && source lib/alpaca.sh && alpaca_account | jq .status

# Is the market open?
source lib/env.sh && source lib/alpaca.sh && alpaca_clock | jq .is_open

# Manual tick (only inside market hours)
claude -p '/master_trading'

# Inspect today's report
open     persistence/reports/$(date -u +%F).html  # macOS
xdg-open persistence/reports/$(date -u +%F).html  # Linux
start    persistence/reports/$(date -u +%F).html  # Windows / Git Bash
```
