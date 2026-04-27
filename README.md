# ClaudeTrading

Autonomous Alpaca paper-trading system driven by Claude Code skills + Anthropic scheduled tasks. Clone it, point it at your own paper account, and it runs entirely on your machine.

> **Paper trading only.** Hard-coded to `https://paper-api.alpaca.markets/v2`. No live-money path exists in this repo. The shipped strategies are calibrated for an aggressive paper-trading profile and are intended as a starting point — retune via `/master_configurator` before relying on them.

## At a glance

```mermaid
flowchart LR
    You["👤 <b>You</b><br/>📋 Curated tickers<br/>⚖️ Risk + $/trade cap<br/>🔑 Alpaca paper key"]

    subgraph Engine["🤖 ClaudeTrading engine"]
      direction TB
      Tick["⏰ Tick every N min<br/>during market hours"]
      Safe["🛡️ Cooldown filter<br/>(N-trading-day floor)"]
      Strats["📐 4 strategies<br/>sells: profit_take · trailing_stop<br/>buys: mean_reversion · ladder_buys"]
      Tick --> Safe --> Strats
    end

    Trades["💱 Paper trades<br/>on Alpaca"]
    Report["📰 Daily HTML report<br/>7 AM local time"]

    You ==> Engine
    Engine ==> Trades
    Engine ==> Report
```

**What you get out:** strategies that scale into positions on the way down, scale out on the way up, and protect with trailing stops — all gated behind a configurable cooldown so you stay clear of pattern-day-trader and second-income classifications. Trading state stays on your machine; nothing leaves your laptop unless you decide to back it up.

## How it works

On a configured cadence during US market hours (Mon–Fri 6:30 AM – 1:00 PM PT), a scheduled Claude session fires `/master_trading`. The skill:

1. Checks the market is open via Alpaca's `/v2/clock`.
2. Runs `safe_trading` to filter the curated pool into a **sellable set** (last buy older than 2 trading days) and a **buyable set** (last sell older than 2 trading days, or never sold). This is a configurable cooldown floor designed to keep operators clear of pattern-day-trader and second-income classifications. It is a user-tunable heuristic, **not** legal or tax advice — see disclaimer.
3. Hands those sets to each enabled strategy. Four are shipped:
   - **`profit_take`** — eager partial exit on absolute gain (sells 25% at +10/20/35/50%).
   - **`trailing_stop`** — full exit on retracement from peak.
   - **`mean_reversion`** — buys the worst basket-relative laggard (with 50-day MA falling-knife guard).
   - **`ladder_buys`** — adds to a position when it drops past a configured threshold from the last buy.
   - (`wheel` is scaffolded but disabled until Alpaca options approval.)
4. Snapshots the result locally. Trading state is **gitignored per-operator** — your pool, snapshots, and reports stay on your machine.

A separate schedule fires `/reporting` daily at 7 AM PT, producing an HTML diagnostic in `persistence/reports/`.

## Setup

```mermaid
flowchart LR
    S1["1️⃣<br/><b>Clone</b><br/><code>git clone</code>"]
    S2["2️⃣<br/><b>Install</b><br/>jq · curl · gh"]
    S3["3️⃣<br/><b>Add creds</b><br/><code>cp .env.example .env</code><br/>paste Alpaca paper key"]
    S4["4️⃣<br/><b>Launch</b><br/><code>claude</code>"]
    S5["5️⃣<br/><b>Configure</b><br/><code>/master_configurator</code>"]
    Done(["✅<br/><b>Live</b><br/>schedule fires<br/>on next market open"])

    S1 --> S2 --> S3 --> S4 --> S5 --> Done
```

`/master_configurator` does the rest: bootstraps your gitignored config files from the shipped `.example` templates, walks you through pool / risk / caps / cadence, registers the cron schedule, discloses the permission allowlist it set up. After it finishes you're done — ticks fire automatically.

### Prerequisites

Runs unchanged on macOS, Linux, and Windows (Git Bash / MSYS).

- `bash` ≥ 3.2 (macOS default works; Git Bash on Windows works)
- `curl` (any recent version)
- `jq` ≥ 1.6 — install via `winget install jqlang.jq` / `brew install jq` / `apt install jq`
- `gh` (GitHub CLI), optional — useful for the initial clone if your remote is private
- **macOS only, optional but recommended:** `brew install coreutils` to get `gdate`. Without it the helpers fall back to BSD `date` with translated flags — both paths are tested.

### Steps

```bash
# 1. Clone
git clone https://github.com/khoks/ClaudeTrading.git
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

`/master_configurator` is the **mandatory first run** before any tick or report fires. It:

- Bootstraps your local `pool.json`, `activation.json`, `user_preferences.json`, and `.claude/settings.json` from the shipped `.example` templates (all are gitignored — your data, your machine).
- Walks you through `user_preferences_intake` (pool tickers, risk, $/trade cap), optional `user_custom_strategy_intake`, and `prebuilt_strategy_configurator` (enable/tune the prebuilt strategies). Strategy defaults shipped in `persistence/config/strategy_defaults.json` are the starting baseline.
- Registers two cron tasks via `mcp__scheduled-tasks__create_scheduled_task` and stores their IDs + your chosen cadence in `activation.json`.
- Tells you exactly what permissions were granted to scheduled-tick sessions in `.claude/settings.json` so you can review them.

`master_trading` and `reporting` both check `activation.json.configured == true` at the top of every run and exit with a clear error if you skipped the configurator.

## Contributing

Changes to the repo's design, strategy skills, library code, or docs land via pull request — never directly on `main`. The `/change_management` skill (auto-nudged by a `PostToolUse` hook on tracked-file edits) creates a `change/*` branch, opens a PR, and routes the change for owner review. To check if your PR was approved, ask Claude `"is my PR approved?"` and the same skill in sync mode will fetch state and merge the branch back to `main` if the owner has merged it on GitHub.

Repo owner: run `bash .claude/skills/change_management/scripts/setup_branch_protection.sh` once to enforce the gate at the GitHub network layer.

## Documentation

- [`docs/FUNCTIONALITY.md`](docs/FUNCTIONALITY.md) — what the system does day-to-day: trading-day timeline, the cooldown safety floor, master_trading orchestration, the strategy cards, persistence, reporting, common operations.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — how it's built and why: layer responsibilities, tick data flow, skill catalog, state schemas, library API reference, cross-cutting concerns, design decisions.
- [`CLAUDE.md`](CLAUDE.md) — the hard rules (paper-only, must run configurator first, never commit `.env`, etc.). Loaded automatically by Claude Code.
- `.claude/skills/<name>/SKILL.md` — per-skill specs (Claude reads these as code-by-prompt at runtime).

## Repo layout

```
.claude/skills/      # 13 skills (configurator, tick, daily)
.claude/
  settings.json.example  # recommended permission allowlist for scheduled sessions
lib/                 # bash helpers: env, date (cross-platform), tz (TZ-aware cron),
                     #   alpaca, pool, calendar
persistence/
  config/
    strategy_defaults.json         # COMMITTED — shipped baseline tunables
    activation.json.example        # template; real file is gitignored
    user_preferences.json.example  # template; real file is gitignored
  pool.json.example  # template; real file is gitignored
  snapshots/         # tick (per-tick, 7-day TTL) | daily | weekly  (gitignored)
  reports/           # daily HTML reports  (gitignored)
docs/
  FUNCTIONALITY.md
  ARCHITECTURE.md
.env                 # GITIGNORED — Alpaca creds
CLAUDE.md            # rules loaded by Claude Code
```

## Security

- `.env` is gitignored. Verify with `git status` before any commit.
- Per-operator state (pool, snapshots, reports, activation, your tuned settings) is gitignored. Your trading data does not leave your machine.
- The `.claude/settings.json` allowlist that scheduled sessions use is gitignored too — `master_configurator` materialises it from `.example` on first run, scoped to the project. Review it.

## Disclaimer

The trading-day cooldown enforced by `safe_trading` is a user-defined safety margin. It is **not** legal, tax, or compliance advice and does not guarantee compliance with FINRA's pattern day trader rule, IRS classification of trading income, or any specific regulation that may apply to your visa, residency, or employment status. Consult a tax / legal advisor.

## License

MIT. Use at your own risk; no warranty. Paper-trading only — ClaudeTrading does not place live orders.
