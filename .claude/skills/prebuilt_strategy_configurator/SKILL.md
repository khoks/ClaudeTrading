---
name: prebuilt_strategy_configurator
description: This skill should be used when invoked by master_configurator, or when the user asks to "configure strategies", "tune trailing stop", "change ladder buy parameters", "enable wheel strategy". Lets the user enable/disable each prebuilt strategy (trailing_stop, ladder_buys, wheel) and set its default parameters; writes persistence/config/strategy_defaults.json.
version: 0.1.0
---

# prebuilt_strategy_configurator

Manages the global default config for the three prebuilt strategies. Per-stock overrides live on each entry in `persistence/pool.json` and take precedence; this skill only sets the global fallback.

## Workflow

1. **Read existing** `persistence/config/strategy_defaults.json` if present.
2. **For each strategy** (`trailing_stop`, `ladder_buys`, `wheel`), ask via AskUserQuestion:
   - Enabled? yes / no.
   - If enabled, ask the strategy's tunables (see below).
3. **Write the merged JSON** to `persistence/config/strategy_defaults.json`:
   ```json
   {
     "trailing_stop": {
       "enabled": true,
       "drop_percent": 5,
       "raise_percent": 10
     },
     "ladder_buys": {
       "enabled": true,
       "drop_percent": 18,
       "buy_amount_usd": 1000
     },
     "wheel": {
       "enabled": false,
       "comment": "requires Alpaca options approval"
     }
   }
   ```

## Tunables per strategy

### trailing_stop
- `drop_percent` (default 5): % below high_watermark that triggers a sell.
- `raise_percent` (default 10): % above current watermark required to bump it.

### ladder_buys
- `drop_percent` (default 18): % below `last_buy.price` that triggers a buy.
- `buy_amount_usd` (default 1000): notional size of each ladder rung.

### wheel
- `enabled` (default false). If user enables, warn that Alpaca requires options account approval.
- Tunables when enabled: `put_delta_target`, `call_delta_target`, `dte_min`, `dte_max`. Off-by-default until enrollment confirmed.

## Refusal cases

- Refuse to enable `wheel` without an explicit confirmation step asking the user to verify they have options approval enabled in their Alpaca dashboard.

## Reuse

Sources `lib/env.sh`. Uses `jq` for JSON edits. No Alpaca calls — pure config.
