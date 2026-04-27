---
name: master_configurator
description: This skill should be used when the user asks to "configure trading", "set up trading system", "initialize trading", "activate the trading bot", or runs `/master_configurator`. Walks the user through the one-time setup of pool, preferences, custom strategies, and prebuilt-strategy parameters, then activates the recurring schedule that drives master_trading and reporting.
version: 0.1.0
---

# master_configurator

Activates the ClaudeTrading system from cold. This is the single entry point a user runs the first time, and again any time they want to reconfigure.

## When to invoke

- First-time setup of the project.
- Re-configuration: pool changes, strategy tuning, schedule on/off.
- Verifying that the live schedule is registered.

## Preconditions

- `.env` (or runner-injected env vars) contains `ALPACA_KEY`, `ALPACA_SECRET`.
- `lib/env.sh` is sourceable from `$REPO_ROOT/lib/env.sh`.
- `gh auth status` succeeds (used by state_persistence to push commits).

## Workflow

1. **Read activation state.** Open `persistence/config/activation.json`.
   - If `.configured == true`, ask the user (AskUserQuestion) whether to RECONFIGURE or CANCEL. On cancel, exit.
2. **Sanity-check Alpaca creds.**
   ```bash
   source "$REPO_ROOT/lib/env.sh"
   source "$REPO_ROOT/lib/alpaca.sh"
   alpaca_account | jq -e '.status == "ACTIVE"' >/dev/null || {
     echo "Alpaca account is not ACTIVE. Aborting." >&2
     exit 1
   }
   ```
3. **Run the three intake sub-skills in order:**
   - Invoke skill `user_preferences_intake` — gathers tickers, risk, trade caps. Writes `persistence/config/user_preferences.json` and seeds `persistence/pool.json`.
   - Invoke skill `user_custom_strategy_intake` — optional, may scaffold new `strategy_<name>/` skills.
   - Invoke skill `prebuilt_strategy_configurator` — enables/disables/tunes trailing_stop, ladder_buys, wheel. Writes `persistence/config/strategy_defaults.json`.
4. **Pick the tick cadence.** Ask the user (AskUserQuestion) how often master_trading should fire during market hours. Sensible options: 5, 10, 15, 30 min. Store the chosen value as `$TICK_CADENCE_MIN` for use in steps 5 and 6.

5. **Activate schedules.** Use `mcp__scheduled-tasks__create_scheduled_task` to register two cron triggers, both timezone `America/Los_Angeles`:
   - `*/$TICK_CADENCE_MIN 6-12 * * 1-5` → runs `/master_trading`. Skips on holidays via `is_market_open` in the skill body.
   - `0 7 * * 1-5` → runs `/reporting`.
   For each task, pass these env vars so the remote agent can authenticate (if the chosen MCP supports env injection — `mcp__scheduled-tasks` currently does not, so the prompt itself sources `.env` from `$REPO_ROOT/lib/env.sh`):
   - `ALPACA_KEY`, `ALPACA_SECRET`, `ALPACA_BASE`, `ALPACA_DATA_BASE`
   (Reattach the values from the local `.env` at activation time. Verify the tool's parameter shape with ToolSearch before calling.)
6. **Persist activation.** Write `persistence/config/activation.json`. The `tick_cadence_minutes` field is what `lib/calendar.sh::is_last_tick_of_trading_day` reads — keep it in sync with the cron expression in step 5:
   ```json
   {
     "configured": true,
     "activated_at": "<ISO-8601 now>",
     "tick_cadence_minutes": <$TICK_CADENCE_MIN>,
     "schedule_ids": {
       "master_trading": "<task id from MCP>",
       "reporting":      "<task id from MCP>"
     }
   }
   ```
7. **Commit + push** the new config files (NOT `.env`):
   ```bash
   git add persistence/config/ persistence/pool.json
   git commit -m "config: master_configurator run on $(date -u +%FT%TZ)"
   git push
   ```
8. **Print a confirmation summary** to the user: number of stocks in pool, enabled strategies, chosen cadence, both schedule IDs, next expected trigger time.

## Reconfigure mode

If `.configured == true` and the user chose RECONFIGURE:
- Skip step 1's exit branch.
- In step 5, first `mcp__scheduled-tasks__delete_scheduled_task` for any existing task IDs in `activation.json` before re-creating, to avoid duplicate fires.
- For pure cadence changes, prefer `mcp__scheduled-tasks__update_scheduled_task` with a new `cronExpression` and update `tick_cadence_minutes` in activation.json — no need to delete and recreate.

## Refusal cases

- Refuse to activate the schedule if `pool.stocks` is empty after intake — empty pool means master_trading has nothing to do.
- Refuse to activate if `.env` is missing required keys (the sanity check in step 2 catches this).

## Why two separate scheduled tasks

`master_trading` fires on the configured tick cadence during market hours; `reporting` fires once daily before market open. Different cadences = different cron entries.
