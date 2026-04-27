# CLAUDE.md — repo-wide rules

Loaded automatically by Claude Code. These rules override anything in chat.

## What this repo is

Autonomous Alpaca **paper-trading** system, driven entirely by Claude Code skills + Anthropic scheduled tasks. The user is on H1B and cannot operate as a pattern day trader, so a 2-trading-day cooldown is enforced.

## Hard rules

1. **Paper API only.** Never call `https://api.alpaca.markets`. The base URL must always be `https://paper-api.alpaca.markets/v2` (set in `.env` as `ALPACA_BASE`). If a future task requires live trading, STOP and ask the user.
2. **Never commit `.env`.** It contains the Alpaca key and secret. `.gitignore` excludes it; verify with `git status` before every commit.
3. **Snapshots ARE committed.** `persistence/snapshots/`, `persistence/pool.json`, `persistence/config/`, and `persistence/reports/` all live in the repo because the scheduled remote agent has ephemeral storage and would otherwise lose state.
4. **Always go through `safe_trading`.** Every order placed by ClaudeTrading must originate from a stock returned by the safe_trading filter. Never bypass the 2-trading-day cooldown — it's the H1B safety floor.
5. **No legal or tax advice.** The cooldown is a user-defined heuristic, not a guarantee. Never tell the user it makes them compliant.
6. **`master_configurator` is the only place that activates schedules.** Ad-hoc skill scripts must not call `mcp__scheduled-tasks__create_scheduled_task` directly.
7. **`wheel` is disabled by default.** Enabling it requires confirmed Alpaca options approval.

## Repo map (quick)

- `lib/` — shared bash helpers (`env.sh`, `date.sh`, `alpaca.sh`, `pool.sh`, `calendar.sh`). `lib/date.sh` is the cross-platform `date` shim — Linux/Git Bash/macOS-with-`gdate` use GNU; macOS without `gdate` uses BSD with translated flags. Always go through the `date_*` helpers, never call `date -d` directly.
- `.claude/skills/` — 11 skills (see catalog below).
- `persistence/` — all state. The remote agent reads/writes here.
- `.env` (local-only) — Alpaca creds. Mirrored as runtime env vars on the scheduled-task side.

## Skill catalog

**Configurator tier (user-invoked, one-time):**
- `master_configurator` — entry point. Runs intakes, then activates schedules.
- `user_preferences_intake` — collects pool tickers, risk, trade caps.
- `user_custom_strategy_intake` — scaffolds new strategy skills.
- `prebuilt_strategy_configurator` — enables/tunes trailing_stop, ladder_buys, wheel.

**Tick tier (schedule-invoked every 5 min during PT trading hours):**
- `master_trading` — orchestrates one tick.
- `safe_trading` — filters pool into sellable + buyable sets.
- `strategy_trailing_stop`, `strategy_ladder_buys`, `strategy_wheel` — strategy implementations.
- `state_persistence` — snapshots, rollups, git push.

**Daily tier (schedule-invoked at 7am PT):**
- `reporting` — generates HTML report.

## Recurring tasks etiquette

- Never run `master_trading` outside its schedule unless the user explicitly asks for a manual tick.
- When debugging, prefer reading recent snapshots from `persistence/snapshots/5min/` over hitting Alpaca repeatedly.

## Helpful one-liners

```bash
# Sanity-check creds
source lib/env.sh && source lib/alpaca.sh && alpaca_account | jq .status

# Is the market open?
source lib/env.sh && source lib/alpaca.sh && alpaca_clock | jq .is_open

# Manual tick
claude -p '/master_trading'

# Inspect today's report
open     persistence/reports/$(date -u +%F).html  # macOS
xdg-open persistence/reports/$(date -u +%F).html  # Linux
start    persistence/reports/$(date -u +%F).html  # Windows / Git Bash
```
