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
- **`mcp__scheduled-tasks` MCP is available.** Verify with a read-only call before doing real work:
  ```
  mcp__scheduled-tasks__list_scheduled_tasks  # must succeed (returns empty list on a fresh setup)
  ```
  If the tool errors with "not available" or similar, abort with a clear message: this Claude Code environment lacks the scheduled-tasks MCP, which the configurator needs to register the trading and reporting cron jobs. The operator needs to enable it (or upgrade their Claude Code version) before retrying.

## Workflow

0. **Bootstrap config files from `.example` templates if missing.** On a fresh clone of a public repo, the per-operator config files (and the `.claude/settings.json` allowlist) won't exist yet because they're gitignored. Copy them from the `.example` templates that ship with the repo:
   ```bash
   for path in \
     persistence/pool.json \
     persistence/config/activation.json \
     persistence/config/user_preferences.json \
     .claude/settings.json; do
     [ -f "$REPO_ROOT/$path" ] && continue
     [ -f "$REPO_ROOT/$path.example" ] || continue
     cp "$REPO_ROOT/$path.example" "$REPO_ROOT/$path"
     echo "bootstrapped $path from $path.example"
   done
   ```

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
4. **Pick the tick cadence.** Ask the user (AskUserQuestion) how often master_trading should fire during market hours. Sensible options: 5, 10, 15, 30 min. Store the chosen value as `$TICK_CADENCE_MIN` for use in steps 5–7.

5. **Pick the orchestration variant: v1 vs v2.** Ask the user (AskUserQuestion) which trading skill ecosystem to wire to the schedule. Both place real (paper) orders against the same pool with the same H1B cooldown — they only differ in *who* runs the tick orchestration:

   | Variant | What runs the tick | Per-tick token cost (measured) | When to pick it |
   |---|---|---|---|
   | **v1** (`master_trading`) | LLM walks each step (market gate → safe_trading → strategies → persistence) as separate tool calls | ~45k input / ~190 output | If you want LLM-mediated step-by-step audit-ability or plan to inject mid-tick judgment via SKILL.md edits. |
   | **v2** (`master_trading_v2`) | One `tick.sh` runs the entire pipeline mechanically; LLM observes the structured output and surfaces anomalies | ~30k input (target) / similar output | Default for most operators. ~⅓ less token spend per tick. Same trading semantics; same persistence layout. |

   Both ecosystems are fully isolated: v1's `safe_trading`, `strategy_*`, `state_persistence` skills serve only `master_trading`; v2's `_v2`-suffixed twins serve only `master_trading_v2`. `lib/`, `persistence/`, and `.env` are shared (infrastructure, not strategy logic). Switching between variants is reversible at any time by re-running the configurator.

   Store the chosen value as `$VARIANT` ∈ `{"v1","v2"}`. Default to `v2` if the user has no preference.

6. **Activate schedules.** Compute the master-tick cron expression from the operator's local timezone — `mcp__scheduled-tasks` evaluates cron in local time, not UTC, so a non-PT operator needs the cron's hour range shifted to their local equivalent of US market hours.
   ```bash
   source "$REPO_ROOT/lib/tz.sh"
   MASTER_CRON=$(market_cron "$TICK_CADENCE_MIN")     # e.g. "*/15 9-15 * * 1-5" for ET
   ```
   If `market_cron` errors (operator's TZ has a half-hour offset from PT, e.g. IST, or wraps past midnight), fall back to AskUserQuestion offering: (a) "I'll set my machine TZ to a US zone and re-run", or (b) "Let me type a cron expression manually".

   Pick the slash command name from `$VARIANT`:
   ```bash
   if [ "$VARIANT" = "v2" ]; then
     MASTER_CMD="/master_trading_v2"
   else
     MASTER_CMD="/master_trading"
   fi
   ```

   Then register two cron triggers via `mcp__scheduled-tasks__create_scheduled_task`:
   - `$MASTER_CRON` → runs `$MASTER_CMD`. Skips on holidays via `is_market_open` in the skill / script.
   - `0 7 * * 1-5` → runs `/reporting`. **Note:** the report cron is also local-time. For non-PT operators, 7 AM local time is fine (it's a personal-diagnostic schedule, not market-aligned).
   The scheduled task prompt itself should `cd $REPO_ROOT` then invoke the slash command, since `mcp__scheduled-tasks` does not support env-var injection — `lib/env.sh` will source `.env` from the local repo at fire time.
7. **Persist activation.** Write `persistence/config/activation.json`. The `tick_cadence_minutes` field is what `lib/calendar.sh::is_last_tick_of_trading_day` reads — keep it in sync with the cron expression in step 6. The `master_trading_variant` field records which ecosystem the live cron task targets (so reconfigure mode and the dashboard can show it):
   ```json
   {
     "configured": true,
     "activated_at": "<ISO-8601 now>",
     "tick_cadence_minutes": <$TICK_CADENCE_MIN>,
     "master_trading_variant": "<$VARIANT>",
     "schedule_ids": {
       "master_trading": "<task id from MCP>",
       "reporting":      "<task id from MCP>"
     }
   }
   ```
8. **No commit.** Per-operator config files (`pool.json`, `activation.json`, `user_preferences.json`, `.claude/settings.json`) are gitignored — they stay local. `strategy_defaults.json` is the only config file that's committed; if you changed it during this run (via `prebuilt_strategy_configurator`), commit + push that change manually. The shipped baseline of `strategy_defaults.json` is what new clones inherit.

9. **Print a confirmation summary** to the user. Include:
   - Number of stocks in pool, enabled strategies, chosen cadence, **chosen orchestration variant (v1 or v2)**, both schedule IDs, next expected trigger time.
   - **Resolved cron expression and timezone**, e.g.: "Local TZ detected as `EDT`. Master tick will fire `*/15 9-15 * * 1-5` (every 15 min, 09:00–15:45 your local time, equivalent to 06:00–12:45 PT — covering US market hours from pre-market through 15 min before close). Slash command: `/master_trading_v2` (script-orchestrated; ~30k tokens/tick)."
   - **Disclose the `.claude/settings.json` allowlist** that was bootstrapped (or is currently active) — the user should know what permissions are pre-granted to scheduled-tick sessions:
     - `Bash` (any command — needed because scheduled sessions run compound `&&` chains the granular allowlist can't pre-match)
     - `Bash(<cmd>:*)` granular entries documenting intent (curl, jq, git, gh, bash, source, etc.)
     - `Read`, `Write`, `Edit`, `Glob`, `Grep` — file operations
     - `mcp__scheduled-tasks__list_scheduled_tasks` — read-only schedule inspection
   - Plus `ask` rules retained as safety guards: `Bash(gh repo create:*)`, `Bash(gh repo delete:*)`, `mcp__scheduled-tasks__create_scheduled_task`, `mcp__scheduled-tasks__update_scheduled_task`. The user is asked before any of these run, even from scheduled sessions.
   - Tell the user they can review or tighten this in `.claude/settings.json` (their local copy, not committed).

## Reconfigure mode

If `.configured == true` and the user chose RECONFIGURE:
- Skip step 1's exit branch.
- Show the operator the current `master_trading_variant` from `activation.json` so they know what they're switching from.
- In step 6, first `mcp__scheduled-tasks__delete_scheduled_task` for any existing task IDs in `activation.json` before re-creating, to avoid duplicate fires.
- **For pure cadence changes (no variant switch)**, prefer `mcp__scheduled-tasks__update_scheduled_task` with a new `cronExpression` and update `tick_cadence_minutes` in activation.json — no need to delete and recreate.
- **For variant switch (v1 ↔ v2)**, the slash command in the cron task body changes (`/master_trading` ↔ `/master_trading_v2`), so use `mcp__scheduled-tasks__update_scheduled_task` to rewrite both the prompt and (optionally) the cron, OR delete + recreate. Either works; the dashboard reads the new `master_trading_variant` from `activation.json` regardless.

## Refusal cases

- Refuse to activate the schedule if `pool.stocks` is empty after intake — empty pool means master_trading has nothing to do.
- Refuse to activate if `.env` is missing required keys (the sanity check in step 2 catches this).

## Why two separate scheduled tasks

`master_trading` fires on the configured tick cadence during market hours; `reporting` fires once daily before market open. Different cadences = different cron entries.
