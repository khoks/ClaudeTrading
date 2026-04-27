---
name: user_custom_strategy_intake
description: This skill should be used when invoked by master_configurator, or when the user asks to "add a custom strategy", "scaffold a new strategy", "register a trading rule". Lets the user describe a custom strategy in plain English, then scaffolds a new `.claude/skills/strategy_<name>/` skill skeleton and registers it in strategy_defaults.json so master_trading will invoke it.
version: 0.1.0
---

# user_custom_strategy_intake

Optional sub-skill of master_configurator. Skipped by default unless the user explicitly wants extra strategies beyond `trailing_stop`, `ladder_buys`, `wheel`.

## Workflow

1. **Ask** (AskUserQuestion): "Add a custom strategy?" → yes / no. If no, exit with no changes.
2. **Collect strategy spec** (free-text via AskUserQuestion):
   - Strategy name (snake_case, e.g. `breakout_buy`).
   - One-paragraph plain-English description of when to BUY and when to SELL.
   - Whether it operates on `sellable`, `buyable`, or both sets.
   - Any tunable parameters (name → default value, comma-separated).
3. **Scaffold the skill directory:**
   ```bash
   mkdir -p ".claude/skills/strategy_$NAME/scripts"
   ```
4. **Write SKILL.md.** Use `.claude/skills/strategy_trailing_stop/SKILL.md` as the structural template — copy frontmatter shape, section headings, invocation contract, then fill the body with the user's described logic.
5. **Write `scripts/apply.sh`** stub. Read STDIN as a JSON envelope with `{ sellable, buyable, defaults, overrides }`. Emit a JSON array of placed orders to STDOUT. Leave the strategy logic as a TODO marker — the user (or a follow-up Claude session) will flesh it out.
6. **Register in `persistence/config/strategy_defaults.json`:**
   ```bash
   jq --arg k "$NAME" --argjson v "$DEFAULT_PARAMS" \
      '.[$k] = ({ enabled: true } + $v)' strategy_defaults.json > tmp && mv tmp strategy_defaults.json
   ```
7. **Loop:** ask "Add another strategy?" until user says no.
8. **Echo** the list of newly-scaffolded strategies and remind the user to fill in `apply.sh` before relying on them.

## Why this skill is intentionally minimal

Custom strategies are user-specific and need code review before going live. This skill scaffolds the structure but does not autogenerate trading logic — that step is deliberate human input.

## Reuse

References `strategy_trailing_stop/SKILL.md` as a template. Writes JSON via jq.
