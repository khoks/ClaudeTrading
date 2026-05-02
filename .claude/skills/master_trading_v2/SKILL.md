---
name: master_trading_v2
description: This skill should be used when fired by the recurring schedule (on the configured tick cadence during PT trading hours), or when the user manually runs `/master_trading_v2` for a one-shot tick. Variant of master_trading where the per-tick orchestration runs as a single bash script (`tick.sh`) and the LLM is the observability layer (anomaly flags, narrative, recovery hints) on top of the structured output. Targets ~30k tokens/tick vs v1's ~45k by removing LLM round-trips for deterministic steps. Operators pick v1 vs v2 in /master_configurator.
version: 0.1.0
---

# master_trading_v2

The script-orchestrated variant of master_trading. Same trading semantics as v1 — same strategies, same H1B cooldown, same envelope shape, same persistence layer — but the per-tick pipeline runs as one Bash invocation instead of being walked step-by-step by the LLM.

## What changed vs v1, and why

v1's SKILL.md asks the LLM to:
1. Check market open
2. Run safe_trading
3. Run Phase A strategies (profit_take, trailing_stop)
4. Build sold_this_tick
5. Filter buyable, run Phase B strategies (mean_reversion, ladder_buys)
6. Pipe envelope to state_persistence

Each step is a separate tool call. The LLM exercises **no judgment** at any step — the order, the filters, the error handling are all deterministic. Measured cost: ~45k input tokens / ~190 output tokens per tick.

v2 collapses steps 1–6 into `scripts/tick.sh`. The LLM's job is now just:
1. Run the script.
2. Read the structured output.
3. Surface anomalies that only an LLM can spot.

Same trading behavior, ~⅓ less context per tick.

## Tick workflow

```bash
RESULT=$(bash "$REPO_ROOT/.claude/skills/master_trading_v2/scripts/tick.sh")
echo "$RESULT" | jq .
```

`tick.sh` emits a single JSON object on stdout:

```json
{
  "status": "ok" | "market_closed" | "safe_trading_failed" | "persist_failed",
  "tick_at": "<ISO-8601>",
  "actions": [ { "strategy", "symbol", "side", "qty"|"notional", "type", "alpaca_order_id", "status", "reason" }, ... ],
  "sets": { "sellable": [...], "buyable": [...] },
  "sold_this_tick":   [ "AAPL", ... ],
  "bought_this_tick": [ "MSFT", ... ],
  "persist": { "tick": "<path>", "daily": "<path>|null", "weekly": "<path>|null", "pruned": <int> },
  "summary": { "action_count", "sells", "buys", "errors", "sellable_count", "buyable_count" }
}
```

## Anomaly observation (the LLM's actual job)

After parsing the JSON, walk these checks and surface anything that fires. Keep it terse — one line per anomaly. If everything looks normal, just emit the summary line.

1. **Status check.** If `status != "ok"`:
   - `"market_closed"` → log `"market closed at <tick_at>, skipping"` and exit 0.
   - `"safe_trading_failed"` → emit a clear error citing the cause; exit 1. Do NOT pretend the tick succeeded.
   - `"persist_failed"` → orders DID fire but the snapshot didn't write. Surface loudly: which actions placed, what the persist error was, whether to investigate before next tick. Exit 0 (don't double-place on retry).

2. **Strategy errors.** `summary.errors > 0` → list which strategies errored and the error text. One-liner per failed strategy.

3. **Concentration.** If `bought_this_tick.length >= 0.6 * sets.buyable.length` AND `sets.buyable.length >= 5` → "ladder_buys/mean_reversion hit <N>/<M> buyable stocks — concentration warning, review baseline drift".

4. **Equity drop.** Read `persist.tick` (the snapshot path); look at `equity_delta_vs_prev_tick`. If absolute drop > 2% of previous-tick equity → flag as a single-tick volatility event.

5. **Repeat-fire.** If the same symbol appears in `actions` for the same strategy in the last 3 ticks (read `persistence/snapshots/tick/` last 3 files) → flag "<strategy> fired on <symbol> 3 ticks running — possible runaway, check params". This check is optional; skip if the snapshot dir is gappy.

Skip checks 4–5 entirely on `market_closed`.

## Output to terminal

After the anomaly walk, emit one line: `tick OK | actions=<N> | sellable=<N> | buyable=<N> | <anomalies-or-"clean">`. That's all the operator sees in the scheduled-task transcript.

## Why this is safe

- Same 2-trading-day H1B cooldown (`safe_trading_v2` runs identically to v1's filter).
- Same paper-only Alpaca base URL (`lib/env.sh` is unchanged).
- Same per-strategy `apply.sh` files (copied byte-for-byte to `_v2` dirs).
- Same persistence layout (`persist.sh` writes the same tick / daily / weekly snapshots).

The only behavioral difference is *who* runs the orchestration: a bash script vs the LLM walking it step by step. The orders placed for a given pool / market state should be identical between v1 and v2 ticks.

## Reuse

- `scripts/tick.sh` (this skill's only script — the orchestrator)
- `lib/{env,alpaca,calendar,pool}.sh` (shared with v1; not version-specific)
- `_v2` sub-skills: `safe_trading_v2`, `strategy_*_v2`, `state_persistence_v2`
- `persistence/config/strategy_defaults.json` (shared; same schema)
- `persistence/pool.json` (shared; same schema)

## Failure handling note

`tick.sh` uses `set -uo pipefail` (NOT `-e`) so a single strategy failure won't abort the whole tick. Each error becomes an entry in `actions[]` with `status:"error"`. The script always emits a JSON envelope so the LLM observability layer sees a complete picture.

## Switching back to v1

Re-run `/master_configurator` and pick variant `v1`. The configurator updates the existing scheduled task to invoke `/master_trading` instead of `/master_trading_v2`. The two versions are wire-compatible at the persistence level, so switching is reversible at any time.
