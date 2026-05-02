---
name: strategy_wheel_v2
description: Internal sub-skill of master_trading_v2; placeholder for the options wheel (cash-secured puts → assignment → covered calls → repeat). Disabled by default, no-op until Alpaca options approval. Called mechanically by tick.sh when enabled. Operators don't normally invoke this directly.
version: 0.1.0
---

# strategy_wheel

Implements the classic wheel: rotate between cash-secured puts and covered calls on the same underlying.

## Status: DISABLED by default

`persistence/config/strategy_defaults.json` ships with `wheel.enabled = false`. To enable:
1. Apply for and receive options-trading approval on Alpaca (paper account: https://app.alpaca.markets/paper/dashboard/overview).
2. Run `prebuilt_strategy_configurator` and confirm "yes I have options approval" when prompted.

Until enabled, `apply.sh` exits 0 with `[]` and a `disabled` reason record.

## Invocation contract (when enabled)

**STDIN** — same envelope shape as other strategies.

**STDOUT** — JSON array of placed orders. Each order has additional `option_contract` field with the OCC symbol.

## Per-stock logic (when enabled)

State machine per stock:

- **Phase A — `no_position`:** sell a cash-secured put.
  - Find a put expiring `dte_min` to `dte_max` days out, with delta closest to `put_delta_target` (default 0.30).
  - Strike = the chosen contract's strike.
  - Order: STO (sell-to-open) 1 put, limit at the bid+0.05 or mark.
  - On fill, transition state to `short_put` and record contract details in `pool[stock].wheel_state`.

- **Phase B — `short_put`:** wait for expiry/assignment.
  - If put expires worthless: collect premium → reset to `no_position`.
  - If put is assigned (Alpaca delivers the underlying): transition to `long_underlying`.

- **Phase C — `long_underlying`:** sell a covered call.
  - Find a call expiring `dte_min` to `dte_max` days out, delta closest to `call_delta_target` (default 0.30), strike at-or-above cost basis.
  - Order: STO 1 call, limit at bid+0.05 or mark.
  - On fill, transition state to `short_call`.

- **Phase D — `short_call`:** wait for expiry/assignment.
  - If call expires worthless: keep underlying → next tick re-runs Phase C.
  - If call is assigned (shares called away): reset to `no_position`.

## Tunables

- `dte_min`, `dte_max` — days-to-expiration window for option selection.
- `put_delta_target`, `call_delta_target` — delta the option chain search optimizes for.
- `put_strike_floor_pct` — refuse puts whose strike is more than X% below current price.
- `roll_at_dte` — auto-roll a short option when its DTE drops below this value.

## Why the safe_trading filter still applies

When the wheel results in shares being assigned (we go long the underlying), the underlying's `last_buy.timestamp` is set to assignment time. The next sell — whether by trailing_stop or by wheel's own mechanics — must respect the 2-trading-day cooldown like any other position.

Likewise, when shares are called away, set `last_sell.timestamp` to the call's expiration date.

## Implementation

```bash
bash "$REPO_ROOT/.claude/skills/strategy_wheel/scripts/apply.sh"
```

When disabled, `apply.sh` emits `[{ "strategy": "wheel", "status": "disabled" }]`.

## Reuse

`lib/alpaca.sh` (with options endpoints — `/v2/options/contracts`, `/v2/positions`, `/v2/orders` with `legs` for multi-leg orders).
