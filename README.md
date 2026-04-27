# ClaudeTrading

Autonomous Alpaca paper-trading system driven by Claude Code skills + Anthropic scheduled tasks.

> **Paper trading only.** Hardcoded to `https://paper-api.alpaca.markets/v2`. No live-money path exists in this repo.

## How it works

Every 5 minutes during US market hours (Mon–Fri 6:30am–1:00pm PT), a scheduled remote Claude agent fires `/master_trading`. The skill:

1. Checks the market is open via Alpaca's `/v2/clock`.
2. Runs `safe_trading` to filter the curated pool into a **sellable set** (last buy older than 2 trading days) and a **buyable set** (last sell older than 2 trading days, or never sold). This is the H1B-safety filter — the user must not be classified as a pattern day trader, so positions must rest at least 2 trading days between opposite-direction trades.
3. Hands those sets to each enabled strategy:
   - **`trailing_stop`** — floor-only watermark; sells when price drops 5% below the high.
   - **`ladder_buys`** — buys $1000 notional when price drops 18% below the last buy.
   - **`wheel`** — disabled until options approval is granted.
4. Snapshots the result and commits to GitHub so the next agent sees fresh state.

A separate schedule fires `/reporting` daily at 7am PT, producing an HTML diagnostic.

## Setup

### Prerequisites

Runs unchanged on macOS, Linux, and Windows (Git Bash / MSYS).

- `bash` ≥ 3.2 (macOS default works; Git Bash on Windows works)
- `curl` (any recent version)
- `jq` ≥ 1.6 — install via `winget install jqlang.jq` / `brew install jq` / `apt install jq`
- `gh` (GitHub CLI) authenticated with the repo's owner account
- **macOS only, optional but recommended:** `brew install coreutils` to get `gdate`. Without it the helpers fall back to BSD `date` with translated flags — both paths are tested.

### Steps

```bash
# 1. Clone
gh repo clone khoks/ClaudeTrading
cd ClaudeTrading

# 2. Drop creds in .env (never committed)
cp .env.example .env
$EDITOR .env   # paste ALPACA_KEY and ALPACA_SECRET

# 3. Smoke-test
source lib/env.sh && source lib/alpaca.sh && alpaca_account | jq .status   # → "ACTIVE"

# 4. From inside Claude Code, configure & activate
claude
> /master_configurator
```

`/master_configurator` walks through:
- `user_preferences_intake` (pool tickers, risk, $/trade cap)
- `user_custom_strategy_intake` (optional)
- `prebuilt_strategy_configurator` (enable/tune trailing_stop, ladder_buys, wheel)
- Registers two cron tasks via `mcp__scheduled-tasks__create_scheduled_task`.

## Repo layout

```
.claude/skills/    # 11 skills (configurator, tick, daily)
lib/               # bash helpers: env, date (cross-platform), alpaca, pool, calendar
persistence/
  pool.json        # curated stocks + last buy/sell + per-stock strategy overrides
  config/          # user prefs, strategy defaults, activation state
  snapshots/       # 5min (7-day TTL) | daily | weekly
  reports/         # daily HTML reports
.env               # GITIGNORED — Alpaca creds
CLAUDE.md          # rules loaded by Claude Code
```

## Security

- `.env` is gitignored.
- The remote scheduled agent gets the keys via the `mcp__scheduled-tasks` env map at activation time, not from the repo.
- **If you can read this repo, rotate the Alpaca keys before going live.** Paste exposure during initial setup is a known risk.

## Disclaimer

The 2-trading-day cooldown is a user-defined safety margin. It is **not** legal, tax, or compliance advice and does not guarantee compliance with FINRA's pattern day trader rule or with IRS classification of trading income for H1B visa holders. Consult a tax advisor.

## License

Private, personal use. Not redistributed.
