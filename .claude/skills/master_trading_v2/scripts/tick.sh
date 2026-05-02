#!/usr/bin/env bash
# master_trading_v2/scripts/tick.sh
#
# Mechanical orchestrator for one trading tick. The bash equivalent of
# everything v1's master_trading SKILL.md asks the LLM to do step-by-step.
#
# Why this exists:
#   v1 has the LLM walk the pipeline (market gate → safe_trading → Phase A
#   strategies → set-difference → Phase B strategies → state_persistence)
#   as a sequence of tool calls. Each step pays input-context cost.
#   Measured per-tick token spend: ~45k input, ~190 output.
#
#   None of those steps require LLM judgment — they're all deterministic.
#   This script does the same work in one Bash invocation. The v2 SKILL.md
#   then has the LLM observe the structured output and surface anomalies
#   (the only part that genuinely benefits from LLM intelligence).
#
# Output contract:
#   Single JSON object on stdout. The v2 SKILL.md tells the LLM how to
#   read it and what anomaly checks to run.
#
# Failure modes:
#   - Preconditions fail (not configured, .env missing) → exit 1, JSON error to stderr
#   - Market closed → exit 0 with status:"market_closed"
#   - Safe-trading fails → exit 1 (do not place orders blindly)
#   - Strategy fails → its action goes in actions[] with status:"error"; loop continues
#   - state_persistence fails → status:"persist_failed" but actions[] still emitted
#                               (orders already placed; LLM must see them to alert operator)

set -uo pipefail   # NOT -e: we want to keep going through strategy failures

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
export REPO_ROOT

# shellcheck disable=SC1091
source "$REPO_ROOT/lib/env.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/alpaca.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/calendar.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/pool.sh"

# ---------- Preconditions ----------
ACT="$REPO_ROOT/persistence/config/activation.json"
if [ ! -f "$ACT" ] || ! jq -e '.configured == true' "$ACT" >/dev/null 2>&1; then
  echo '{"status":"error","error":"not configured; run /master_configurator first"}' >&2
  exit 1
fi

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ---------- Market gate ----------
if ! is_market_open; then
  jq -nc --arg now "$NOW" \
    '{status:"market_closed", tick_at:$now, actions:[], sets:{sellable:[],buyable:[]}, summary:{action_count:0}}'
  exit 0
fi

# ---------- Safe trading filter (v2's own) ----------
if ! SETS=$(bash "$REPO_ROOT/.claude/skills/safe_trading_v2/scripts/filter_pool.sh" 2>&1); then
  jq -nc --arg now "$NOW" --arg err "$SETS" \
    '{status:"safe_trading_failed", tick_at:$now, error:$err, actions:[], sets:{sellable:[],buyable:[]}}'
  exit 1
fi
if ! jq -e '.sellable and .buyable' <<<"$SETS" >/dev/null 2>&1; then
  jq -nc --arg now "$NOW" --arg out "$SETS" \
    '{status:"safe_trading_bad_output", tick_at:$now, raw:$out}'
  exit 1
fi
SELLABLE=$(jq -c '.sellable' <<<"$SETS")
BUYABLE=$(jq -c  '.buyable'  <<<"$SETS")

# ---------- Strategy plumbing ----------
DEFAULTS_FILE="$REPO_ROOT/persistence/config/strategy_defaults.json"

is_enabled() {
  local name=$1
  jq -e --arg n "$name" '.[$n].enabled // false' "$DEFAULTS_FILE" >/dev/null 2>&1
}
get_defaults() {
  local name=$1
  jq -c --arg n "$name" '.[$n] // {}' "$DEFAULTS_FILE"
}

ACTIONS='[]'

# run_strategy <name> <buyable_override>
#   <name>            — strategy name without _v2 suffix (e.g. profit_take, ladder_buys)
#   <buyable_override>— JSON array; pass "$BUYABLE" for full buyable, or a filtered subset
#                       (Phase A strategies operate on sellable, but the envelope still
#                       carries buyable for symmetry with the v1 contract.)
run_strategy() {
  local name=$1
  local buyable_use=$2

  if ! is_enabled "$name"; then
    return 0
  fi

  local script="$REPO_ROOT/.claude/skills/strategy_${name}_v2/scripts/apply.sh"
  if [ ! -f "$script" ]; then
    ACTIONS=$(jq -nc --argjson a "$ACTIONS" --arg n "$name" \
      '$a + [{strategy:$n, status:"error", error:"v2 script not found"}]')
    return 0
  fi

  local envelope
  envelope=$(jq -nc \
    --argjson sel "$SELLABLE" \
    --argjson buy "$buyable_use" \
    --argjson def "$(get_defaults "$name")" \
    --arg now "$NOW" \
    '{sellable:$sel, buyable:$buy, defaults:$def, now:$now}')

  local out rc
  out=$(echo "$envelope" | bash "$script" 2>&1)
  rc=$?

  if [ $rc -ne 0 ]; then
    ACTIONS=$(jq -nc --argjson a "$ACTIONS" --arg n "$name" --arg e "$out" \
      '$a + [{strategy:$n, status:"error", error:$e}]')
    return 0
  fi

  if jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1; then
    ACTIONS=$(jq -nc --argjson a "$ACTIONS" --argjson b "$out" '$a + $b')
  else
    ACTIONS=$(jq -nc --argjson a "$ACTIONS" --arg n "$name" --arg o "$out" \
      '$a + [{strategy:$n, status:"error", error:"non-JSON output", raw:$o}]')
  fi
}

# ---------- Phase A: sells ----------
# profit_take first (eager partial); trailing_stop second (residual exit).
run_strategy profit_take    "$BUYABLE"
run_strategy trailing_stop  "$BUYABLE"

# Build sold_this_tick: symbols where a Phase-A sell order was actually placed.
# Exclude error/skipped — those didn't reduce the position.
SOLD_THIS_TICK=$(jq -c '
  [.[] | select(.side == "sell" and (.status != "error") and (.status != "skipped")) | .symbol]
  | unique
' <<<"$ACTIONS")

# ---------- Phase B: buys, with set-difference filtering ----------
# Drop sold_this_tick (avoid wash churn) and bought_this_tick (first-writer wins
# across Phase-B strategies).
BOUGHT_THIS_TICK='[]'

filter_buyable() {
  jq -nc --argjson b "$BUYABLE" --argjson s "$SOLD_THIS_TICK" --argjson bought "$BOUGHT_THIS_TICK" \
    '$b - $s - $bought'
}

run_phase_b_strategy() {
  local name=$1
  local filtered_buyable
  filtered_buyable=$(filter_buyable)
  run_strategy "$name" "$filtered_buyable"

  # After running, update bought_this_tick with this strategy's successful buys.
  local new_buys
  new_buys=$(jq -c --arg n "$name" '
    [.[] | select(.strategy == $n and .side == "buy" and (.status != "error") and (.status != "skipped")) | .symbol]
  ' <<<"$ACTIONS")
  BOUGHT_THIS_TICK=$(jq -nc --argjson a "$BOUGHT_THIS_TICK" --argjson b "$new_buys" \
    '$a + $b | unique')
}

run_phase_b_strategy mean_reversion   # selective first
run_phase_b_strategy ladder_buys      # broad second
run_phase_b_strategy wheel            # disabled by default; no-op when so

# ---------- State persistence ----------
ENVELOPE=$(jq -nc \
  --arg now "$NOW" \
  --argjson actions "$ACTIONS" \
  --argjson sets "$SETS" \
  '{tick_at:$now, actions:$actions, sets:$sets}')

PERSIST_OUT=$(echo "$ENVELOPE" | bash "$REPO_ROOT/.claude/skills/state_persistence_v2/scripts/persist.sh" 2>&1)
PERSIST_RC=$?

if [ $PERSIST_RC -ne 0 ]; then
  # Orders already fired. Surface to the LLM observability layer instead of
  # exiting non-zero — non-zero would mask the actions list.
  jq -nc \
    --arg now "$NOW" \
    --argjson actions "$ACTIONS" \
    --argjson sets "$SETS" \
    --arg err "$PERSIST_OUT" \
    --argjson sold "$SOLD_THIS_TICK" \
    --argjson bought "$BOUGHT_THIS_TICK" \
    '{
      status: "persist_failed",
      tick_at: $now,
      actions: $actions,
      sets: $sets,
      sold_this_tick: $sold,
      bought_this_tick: $bought,
      persist_error: $err,
      summary: {
        action_count:    ($actions | length),
        sells:           ($actions | map(select(.side == "sell")) | length),
        buys:            ($actions | map(select(.side == "buy"))  | length),
        errors:          ($actions | map(select(.status == "error")) | length),
        sellable_count:  ($sets.sellable | length),
        buyable_count:   ($sets.buyable  | length)
      }
    }'
  exit 0
fi

# ---------- Final structured output ----------
PERSIST_JSON=$(jq -c '.' <<<"$PERSIST_OUT" 2>/dev/null || echo '{}')

jq -nc \
  --arg now "$NOW" \
  --argjson actions "$ACTIONS" \
  --argjson sets "$SETS" \
  --argjson persist "$PERSIST_JSON" \
  --argjson sold "$SOLD_THIS_TICK" \
  --argjson bought "$BOUGHT_THIS_TICK" \
  '{
    status: "ok",
    tick_at: $now,
    actions: $actions,
    sets: $sets,
    sold_this_tick: $sold,
    bought_this_tick: $bought,
    persist: $persist,
    summary: {
      action_count:    ($actions | length),
      sells:           ($actions | map(select(.side == "sell")) | length),
      buys:            ($actions | map(select(.side == "buy"))  | length),
      errors:          ($actions | map(select(.status == "error")) | length),
      sellable_count:  ($sets.sellable | length),
      buyable_count:   ($sets.buyable  | length)
    }
  }'
