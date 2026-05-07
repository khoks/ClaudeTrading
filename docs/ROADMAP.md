# ClaudeTrading — Intelligence Roadmap

A staged plan to evolve the system from "deterministic rules + paper orders" to "per-stock daily research → conviction-weighted decision → notified execution → measured learning loop".

**Audience**: the operator (who is also the architect); future contributors who fork this repo.

**Status**: draft. Phases 1–2 are concrete and PR-ready; phases 3–7 contain real design work but specific numbers (token budgets, schedules, scoring weights) will be tuned during implementation.

---

## Table of Contents

1. [Executive summary](#executive-summary)
2. [Design principles](#design-principles)
3. [Phase overview & dependencies](#phase-overview--dependencies)
4. [Phase 1 — Foundation hardening](#phase-1--foundation-hardening)
5. [Phase 2 — Free high-signal data ingestion](#phase-2--free-high-signal-data-ingestion)
6. [Phase 3 — Per-stock intel artifact system](#phase-3--per-stock-intel-artifact-system)
7. [Phase 4 — Conclusions + decision-maker pipeline](#phase-4--conclusions--decision-maker-pipeline)
8. [Phase 5 — Capitol trades & policy intelligence](#phase-5--capitol-trades--policy-intelligence)
9. [Phase 6 — IPO strategy](#phase-6--ipo-strategy)
10. [Phase 7 — Self-learning loop](#phase-7--self-learning-loop)
11. [Cost & token budget analysis](#cost--token-budget-analysis)
12. [Risk register](#risk-register)
13. [Work tracker](#work-tracker)
14. [Glossary](#glossary)

---

## Executive summary

**Today** (post-v2 ship): the system runs deterministic ticks every 15 min during market hours, applies four strategies (`profit_take`, `trailing_stop`, `mean_reversion`, `ladder_buys`) gated by a 2-trading-day H1B cooldown, and persists snapshots locally. The LLM observes the structured tick output but does no real synthesis.

**Goal (12-week horizon)**: layer in (a) **notifications** so the operator knows what fired without checking the dashboard, (b) **per-stock daily intel artifacts** that approximate a junior-analyst research note refreshed each morning, (c) a **decision-maker agent** that consumes the intel + ratings + news to set a daily bias for each pool stock at the first tick after market open, (d) **IPO handling** as a separate fast-cadence track, and (e) **capitol trades** + other contextual data feeding the same pipeline.

**Design philosophy**:
- **Scripts do the mechanics, LLM does the synthesis.** Same principle as v1→v2: anything deterministic gets bash; anything that needs reading-between-the-lines gets the LLM. Keeps tokens cheap, decisions auditable.
- **Tiered refresh.** Not every signal updates daily. Industry analyses change slowly; news changes hourly; ratings change with announcements. Each datum has its own freshness contract.
- **Cost-bounded.** Hedge-fund-quality research per-stock costs real money in tokens + API calls. Operating budget target: **< \$10/day** for the full 19-stock pool with daily intel + decisions, scaling sub-linearly as the pool grows.
- **Paper-only forever.** Nothing here changes that constraint.

---

## Design principles

1. **Every feature ships behind a flag in `strategy_defaults.json` or `user_preferences.json`.** Operators can run any subset.
2. **Persistence is local + gitignored.** Intel artifacts, conclusions, decisions all live under `persistence/` per the existing model.
3. **Failure modes are visible.** Silent fallback was the v0.1 dashboard mistake — every ingestion, every decision logs success/failure into a structured place the operator can see.
4. **No vendor lock-in beyond Alpaca.** Free public APIs preferred. Where a paid API materially improves signal (Quiver for capitol, Finnhub for analyst ratings), it's offered as opt-in with a graceful no-op fallback.
5. **Reversible.** Every phase is wire-compatible with prior phases. Switching off a feature shouldn't break the pipeline.

---

## Phase overview & dependencies

```
Phase 1: Foundation hardening
  ├─ Telegram notifications        (independent)
  ├─ Earnings calendar gate        (independent)
  └─ persistence/intel/ scaffolding ──────┐
                                          │
Phase 2: Free data ingestion              │
  ├─ Form 4 (insider trades)              ├──► consumed by Phase 4
  ├─ 8-K filings                          │
  ├─ 13F holdings                         │
  └─ VIX-aware sizing             ────────┘
                                          │
Phase 3: Per-stock intel artifacts ◄──────┘
  ├─ Daily intel collection
  ├─ Tiered refresh
  ├─ 30d archive
  └─ Rolling summaries (5d / 30d / 1y)
                            │
                            ▼
Phase 4: Conclusions + decision-maker
  ├─ Daily conclusion generator
  ├─ First-tick decision-maker agent
  ├─ Strategy bias consumption
  └─ Pre-trade LLM veto
                            │
            ┌───────────────┼───────────────┐
            ▼               ▼               ▼
Phase 5             Phase 6          Phase 7
Capitol trades      IPO strategy     Self-learning loop
```

Phases 1, 2, 3 build infrastructure. Phase 4 turns it into decisions. Phases 5–7 are independent enrichments that all consume the Phase 4 pipeline.

---

## Phase 1 — Foundation hardening

Three small, independent items. Buys notification surface, blocks an obvious risk class, and stands up the directory the rest of the plan writes into.

### 1.1 Telegram notifications

**Goal**: operator sees buy/sell decisions on their phone the moment a tick fires an order, without opening the dashboard or checking a transcript.

**Architecture**:
- Telegram Bot API is free, simple, and well-documented. Operator creates a bot via `@BotFather`, gets a token, sends `/start` to it, captures the chat_id from `getUpdates`.
- Two new env vars in `.env`: `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`.
- New library: `lib/notify.sh` exposing `notify_telegram <message>` and `notify <channel> <message>` (channel-agnostic dispatch — `telegram` is the first; `pushover`, `email`, `webhook` can drop in later without changing callers).
- Failure-soft: if env vars are missing or the API call fails, log to stderr and continue. Never block a tick on notification failure.

**File layout**:
```
lib/notify.sh                        # NEW
.claude/skills/master_trading_v2/scripts/tick.sh
                                     # MODIFIED: emit notify_telegram on actions
.claude/skills/reporting/scripts/    # MODIFIED: send daily report URL on completion
.env.example                         # MODIFIED: add TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID
docs/SETUP_TELEGRAM.md               # NEW: step-by-step bot creation guide
```

**Message shapes** (Telegram supports Markdown):
- **Per-tick action**: only fires if at least one order placed.
  ```
  📈 ClaudeTrading tick @ 06:15 PT
  
  BUY  KLAC  $500  ladder_buys (price 723.4 ≤ baseline 821.7 × 0.88)
  SELL AMAT  qty 0.31 (25% rung) profit_take @ +12.4%
  
  Equity: $103,452  (+$214 day)  Cash: $5,134
  ```
- **Anomaly alert**: separate channel-marker (🚨), only fires on the anomaly walk's findings (concentration, equity drop > 2%, persist failure, repeat-fire).
- **Daily report**: morning summary with link/summary text from the daily report.

**Open questions**:
- Two-way? (Operator replies "veto" to cancel before next tick?) → Phase 4 territory; for v1 just outbound notifications.
- Throttling? On a 15-min cadence, max 26 messages/day. Not a problem.

**Effort**: S (1 day). **Value**: high. Operator situational awareness ↑↑.

---

### 1.2 Earnings calendar gate

**Goal**: never place a buy on a stock 1–2 trading days before its earnings call. Earnings = volatility spike with random sign — exactly the wrong time to add risk.

**Architecture**:
- New library function `lib/earnings.sh::days_to_next_earnings <symbol>` returning an integer (or empty if unknown / >30 days out).
- Source: free Yahoo Finance earnings calendar JSON (or Finnhub free tier — same thing, more reliable). Cache responses in `persistence/intel/earnings_calendar.json`, refreshed daily.
- Hooks into both Phase B strategies (`mean_reversion`, `ladder_buys`):
  - If `days_to_next_earnings <= 2` → skip with reason `"earnings in N days; gate active"`.
- Phase A (sells: `profit_take`, `trailing_stop`) is *not* gated — if anything we want to be more eager to take profit before earnings risk.

**File layout**:
```
lib/earnings.sh                                        # NEW
.claude/skills/strategy_mean_reversion_v2/scripts/apply.sh   # MODIFIED: gate
.claude/skills/strategy_ladder_buys_v2/scripts/apply.sh      # MODIFIED: gate
persistence/intel/earnings_calendar.json               # NEW: nightly refresh
.claude/skills/intel_refresh_v2/                       # NEW: nightly cron skill
  SKILL.md
  scripts/refresh.sh
```

**Cron**: a new low-priority scheduled task, e.g. daily at 5:00 AM PT (before the master-tick fires at 6:00). Calls `intel_refresh_v2`'s refresh script, which is also where Phase 2's other ingestions hook in.

**Effort**: S (1 day). **Value**: high (eliminates a known volatility class).

---

### 1.3 `persistence/intel/` directory scaffolding

**Goal**: stand up the directory that Phases 2–7 all write into, with the bootstrap, gitignore, and `.gitkeep` already in place.

**Layout** (final shape — features will populate it incrementally):
```
persistence/intel/
  earnings_calendar.json              # Phase 1.2
  vix.json                            # Phase 2.4
  sec/
    form4/<symbol>/<date>.json        # Phase 2.1
    8k/<symbol>/<date>.json           # Phase 2.2
    13f/<filer-cik>.json              # Phase 2.3
  congress/
    trades.json                       # Phase 5
  per_stock/                          # Phase 3
    <symbol>/
      current.json
      conclusions/<date>.json
      summaries/{5d,30d,1y}.md
      intel/<date>/
        news.json
        leadership.md
        industry.md
        competitors.md
        regulatory.md
        ratings.json
      intel/archive/<YYYY-MM>.md
      meta.json
  decisions/<date>.json               # Phase 4
  ipo/
    watchlist.json                    # Phase 6
    research/<symbol>.md
```

**.gitignore** additions: `persistence/intel/**` (per-operator data, never committed). `.gitkeep` files for sub-dirs that need to exist on a fresh clone.

**Effort**: XS (a couple hours, mostly mkdir + gitignore tweaks).

---

## Phase 2 — Free high-signal data ingestion

All these come from free public sources, all run as nightly daemons (one cron task: `intel_refresh_v2`), all populate `persistence/intel/` for downstream phases to consume.

### 2.1 SEC Form 4 — insider trades

**Why it's the highest-signal-per-effort item in this whole plan**: cluster insider buying is one of the cleanest documented signals in finance. CEOs/CFOs buying with their own money beats most paid signals.

**Source**: SEC EDGAR JSON API. Endpoint: `https://data.sec.gov/submissions/CIK<padded>.json` then drill into Form 4 filings. Free, no auth, browser-friendly CORS.

**What we ingest per pool stock per day**:
- All Form 4 filings in the last 90 days
- Per filing: insider name, role, transaction type (P=purchase, S=sale, M=exercise), shares, price, total $ value
- Aggregate: net insider activity over 7d, 30d, 90d windows; cluster flag (≥3 distinct insiders buying within 14 days)

**Output**: `persistence/intel/sec/form4/<symbol>/<date>.json`
```json
{
  "asof": "2026-05-05",
  "filings_last_90d": [...],
  "summary": {
    "net_buys_7d_usd": 1240000,
    "net_buys_30d_usd": 3100000,
    "net_buys_90d_usd": 4200000,
    "distinct_insider_buyers_30d": 4,
    "cluster_buy_active": true,
    "cluster_buy_started": "2026-04-15"
  }
}
```

Consumed by: Phase 4 decision-maker (boost daily bias on cluster buys). Optionally a new strategy in Phase 7.

**Effort**: M (2–3 days). **Value**: high.

---

### 2.2 8-K material events

**Why**: 8-Ks are filed when something material happens that wasn't on the calendar — leadership change, M&A, material agreement, accounting issue. The narrative matters; the LLM is uniquely good at reading them.

**Source**: same EDGAR API.

**Pipeline**:
1. Cron pulls list of new 8-K filings for each pool ticker.
2. For each new filing, the LLM reads the cover page + Item summaries.
3. LLM emits a one-line classification (`leadership_change`, `m&a_announcement`, `legal_settlement`, `accounting`, `routine`) and a 2–3 sentence narrative.
4. Stored as `persistence/intel/sec/8k/<symbol>/<date>.json`.

Item types of high interest: 1.01 (material agreement), 1.02 (termination), 2.01 (M&A), 4.01/4.02 (auditor / accounting), 5.02 (officer/director changes).

**Cost**: ~5–20k tokens per 8-K reading, per stock per occurrence. Pool has maybe 0–3 8-Ks per week total. Negligible.

**Effort**: M (2 days). **Value**: high.

---

### 2.3 13F — institutional holdings

**Why**: identifies which big institutional funds are entering/exiting a name. 45-day delayed but useful for "who else is in this trade".

**Source**: EDGAR.

**Per-stock per-quarter**: list of top 50 holders, sorted by size, with delta vs. prior quarter.

Lower-frequency than other ingestions — quarterly refresh, not daily.

**Effort**: M (2 days). **Value**: medium. Mostly contextual, not directly actionable.

---

### 2.4 VIX-aware sizing

**Why**: when broad-market volatility spikes, position sizing should shrink. Same dollar trade in VIX 35 vs VIX 13 is a fundamentally different bet.

**Source**: free Yahoo or Finnhub for `^VIX`. Cache hourly during market hours; re-read once per tick.

**Implementation**: new field `user_preferences.vix_aware_sizing` with structure:
```json
{
  "enabled": true,
  "thresholds": [
    { "vix_above": 30, "size_multiplier": 0.5 },
    { "vix_above": 20, "size_multiplier": 0.75 },
    { "vix_above": 0,  "size_multiplier": 1.0 }
  ]
}
```

`tick.sh` reads VIX once at the top, computes the multiplier, passes it into each strategy's envelope as `defaults.vix_size_multiplier`. Strategies multiply their `notional` calc by it.

**Effort**: S (half-day). **Value**: high. One number, big risk impact.

---

## Phase 3 — Per-stock intel artifact system

This is the major architectural addition: a hedge-fund-style research note per pool stock, refreshed daily, with rolling summaries at multiple time horizons. Phases 4–7 consume what this builds.

### 3.1 Directory layout per stock

```
persistence/intel/per_stock/<SYMBOL>/
  meta.json                       # last-updated timestamps, version
  current.json                    # today's conclusions (machine-readable)
  conclusions/
    2026-05-05.json
    2026-05-04.json
    ...
  summaries/
    last_5_trading_days.md        # rolling 5-day synopsis
    last_30_days.md               # rolling 30-day synopsis
    last_year.md                  # rolling 12-month synopsis
  intel/
    2026-05-05/
      news.json                   # Alpaca news + scraped sources
      ratings.json                # analyst ratings snapshot
      leadership.md               # LLM digest of CEO/exec news
      industry.md                 # LLM digest of industry news
      competitors.md              # LLM digest of competitor moves
      regulatory.md               # LLM digest of policy / regulatory
      consortium.md               # LLM digest of consortia / unions / foreign-business
    2026-05-04/...
    archive/
      2026-04.md                  # monthly compaction of >30-day intel
      2026-03.md
```

### 3.2 Daily intel collection skill

New skill: `.claude/skills/intel_collect_v2/`. Runs as part of the pre-market 5:00 AM PT cron. Per pool stock:

1. **News pull** (cheap, automated): Alpaca news API, last 24h filtered to ticker.
2. **Ratings pull** (cheap): Finnhub free tier or Yahoo Finance scrape — current analyst rating distribution (strong buy / buy / hold / sell / strong sell).
3. **Leadership intel** (LLM-mediated, tiered): web search for recent news mentioning CEO/CFO/chair by name, last 7 days. LLM digest into `leadership.md`. Refresh **weekly** (not daily) unless a flag triggers.
4. **Industry intel** (LLM-mediated, tiered): web search for industry-level news (semiconductors, pharma, etc., based on stock's sector). LLM digest. Refresh **weekly**.
5. **Competitor intel** (LLM-mediated, tiered): web search for competitor news (top 3–5 named competitors, defined per-stock in `meta.json`). LLM digest. Refresh **weekly**.
6. **Regulatory intel** (LLM-mediated, tiered): congressional discussions / policy / regulatory filings affecting the company or sector. Refresh **weekly**, but flagged by Phase 5 capitol-trade hits for immediate refresh.
7. **Consortium / international intel** (LLM-mediated, tiered): foreign government / union / consortium / standards-body discussions. Refresh **weekly**.

Items 3–7 are the expensive ones (web searches + LLM synthesis). The tiered refresh is the cost-control lever.

### 3.3 Tiered refresh schedule

| Layer | Frequency | Cost per refresh per stock | Why this cadence |
|---|---|---|---|
| News + ratings | **Daily** | ~\$0.01 (API only) | News changes hourly; cheap to pull |
| Earnings + 8-K events | **As filed** | ~\$0.05 (LLM read) | Event-driven, rare |
| Leadership / industry / competitors / regulatory / consortium | **Weekly** | ~\$0.15–0.40 (web search + LLM) | These analyses change slowly |
| Yearly / strategic synthesis | **Monthly** | ~\$0.50 (deep LLM) | Big-picture refresh |

For 19 pool stocks: daily ~\$0.20, weekly ~\$5, monthly ~\$10. Operating run-rate: ~**\$10–15/day** at the current pool size.

### 3.4 30-day archive job

End-of-day cron: anything in `intel/<date>/` older than 30 days gets compacted. The LLM reads all daily files for a given calendar month, produces `intel/archive/<YYYY-MM>.md` (a 1–2 page synopsis), deletes the daily folders.

Keeps the per-stock directory size bounded at ~30 dailies + 12 monthly archives + 1 year of conclusions.

### 3.5 Rolling summary generators

Three separate skills, scheduled differently:
- `summary_5d_v2`: every trading day after market close. Reads last 5 daily conclusions, regenerates `summaries/last_5_trading_days.md`.
- `summary_30d_v2`: every Friday after market close. Reads last 30 daily conclusions, regenerates `summaries/last_30_days.md`.
- `summary_1y_v2`: first weekend of each month. Reads last 12 monthly archives + last 4 30-day summaries, regenerates `summaries/last_year.md`.

Each summary is a structured markdown doc with sections: bull case, bear case, narrative arc, key open questions.

---

## Phase 4 — Conclusions + decision-maker pipeline

The phase that turns intel into decisions.

### 4.1 Daily conclusion generator (per-stock, pre-market)

New skill: `intel_conclude_v2`. Runs at 5:30 AM PT (after intel_collect, before the first tick).

**Input** (assembled by the script that calls the LLM):
- Today's intel folder for the stock
- Yesterday's `current.json`
- `summaries/last_5_trading_days.md`
- `summaries/last_30_days.md`
- `summaries/last_year.md`
- Last 30 days of price action (from snapshots)

**LLM produces**: today's `current.json`:
```json
{
  "asof": "2026-05-05T05:30:00-07:00",
  "symbol": "AMAT",
  "bias": "BUY" | "STRONG_BUY" | "HOLD" | "SELL" | "STRONG_SELL" | "WAIT",
  "conviction": 0.0,         // [0..1]
  "bull_case": "Capex cycle for 3nm fabs accelerating; cluster insider buying...",
  "bear_case": "China export restrictions tightening; mgmt cautious on guidance...",
  "key_risks": ["earnings in 12 days", "DOJ investigation per 8-K 2026-05-02"],
  "narrative_change_vs_yesterday": "...",
  "drivers": [
    {"source": "form4", "weight": 0.3, "summary": "cluster buying detected"},
    {"source": "news",  "weight": 0.2, "summary": "TSMC capex up 18%"},
    ...
  ]
}
```

### 4.2 First-tick decision-maker agent

After conclusions land for all stocks, a single decision-maker pass aggregates:
- Per-stock conclusions
- Pool-wide context (VIX, sector returns, SPY level vs MA)
- Account state (equity, drawdown, sector concentration)

Produces `persistence/intel/decisions/<date>.json`:
```json
{
  "asof": "2026-05-05T06:00:00-07:00",
  "regime": "risk_on" | "neutral" | "risk_off",
  "pool_bias_distribution": {"buy": 7, "hold": 9, "sell": 3},
  "per_symbol": {
    "AMAT": {"bias": "BUY", "conviction": 0.7, "size_multiplier": 1.2, "stop_tightness": 1.0},
    "KLAC": {"bias": "WAIT", "conviction": 0.3, "size_multiplier": 0.0, "stop_tightness": 1.0},
    ...
  },
  "veto_list": ["TEM"],     // explicit do-not-trade today
  "narrative": "Risk-on regime; cluster insider buying across 5 names supports adds..."
}
```

### 4.3 Strategy bias consumption

Each `_v2` strategy reads the per-symbol decision in its envelope (under `defaults.daily_decision`):
- `mean_reversion` / `ladder_buys`: skip if `bias == WAIT` or symbol in `veto_list`; multiply notional by `size_multiplier`.
- `profit_take` / `trailing_stop`: tighten stops by `stop_tightness` factor. STRONG_SELL bias → trip stop early.
- All strategies log the `bias` they saw into the action record so the daily report can attribute outcomes back to the call.

### 4.4 Pre-trade LLM veto on $500+ orders

Before placing any order ≥ \$500, `tick.sh` invokes a small LLM check (separate from the orchestration to keep mainline cheap):

**Inputs**: symbol, side, notional, today's conclusions for that symbol, last hour of news.
**Output**: `{ "decision": "allow" | "veto", "reason": "..." }`.

Cost: ~5–10k tokens per check. Worst case: 19 stocks × 1 check each = ~150k tokens / day = ~\$0.20–0.50/day. Effort vs catastrophic-trade prevention: clear win.

---

## Phase 5 — Capitol trades & policy intelligence

### 5.1 Multi-source ingestion daemon

`lib/congress_trades.py` (Python because the parsing is XML + PDF — bash is the wrong tool). Daily nightly run:

1. **House**: pull XML index from `disclosures-clerk.house.gov/public_disc/financial-pdfs/<year>FD.xml`. Parse member list, fetch new PTR PDFs, extract trade rows (table inside the PDF).
2. **Senate**: scrape `efdsearch.senate.gov` (HTML, requires session-cookie ToS-accept). Parse the trade table.
3. **Optional paid**: Quiver Quantitative API if `QUIVER_API_KEY` is in `.env` — bypasses scraping headaches.
4. Normalize all sources to a common JSON schema:
   ```json
   {
     "trade_id": "house-12345",
     "member": "Pelosi, Nancy",
     "chamber": "house",
     "party": "D",
     "committees": ["financial_services", "intelligence"],
     "ticker": "NVDA",
     "side": "buy" | "sell",
     "amount_range_usd": [50000, 100000],
     "trade_date": "2026-04-22",
     "disclosed_date": "2026-05-04",
     "filing_url": "..."
   }
   ```
5. Append-only into `persistence/intel/congress/trades.json`.

### 5.2 Pool-aware capitol signals

Daily compute step (after ingestion, before market open):
- For each pool stock, compute: trades-by-pool-stock-this-week, cluster flag, committee-aligned flag, member-edge weight.
- Inject into Phase 4's decision-maker as another `driver` source.

### 5.3 Committee-context scoring

Defense committee members trading defense stocks > random. For each stock, predefine the relevant committees (in `per_stock/<SYMBOL>/meta.json::relevant_committees`). When scoring a capitol trade, weight by overlap.

### 5.4 Cluster trade detection

When ≥3 distinct legislators (esp. across both parties) trade the same ticker within a 14-day window before disclosure → strong signal. Surface as a high-priority anomaly.

### Honest signal disclosure

Congressional disclosure data is 45-day-delayed by law and only modestly predictive in academic studies. Don't oversell. Use it as a *bias adjuster*, never as a primary trigger.

---

## Phase 6 — IPO strategy

### 6.1 Pre-IPO watchlist + research

New file: `persistence/intel/ipo/watchlist.json`. Format:
```json
{
  "upcoming": [
    {
      "symbol": "RIVN",
      "expected_ipo_date": "2026-06-15",
      "expected_price_range": [50, 60],
      "underwriters": ["GS", "JPM"],
      "interest_level": "high",
      "added_at": "..."
    }
  ],
  "live_today": [
    {
      "symbol": "RIVN",
      "ipo_date": "2026-06-15",
      "open_price": 56.50,
      "first_print_at": "2026-06-15T13:31:00-04:00",
      "live_strategy_active": true,
      "live_strategy_expires_at": "2026-06-17T13:00:00-04:00"
    }
  ],
  "graduated": [...]      // post day-2, transitioned to normal pool
}
```

Operator (or Phase 4 decision-maker) populates `upcoming` from public IPO calendars (NASDAQ, NYSE, free).

For each upcoming IPO, a daily intel collection runs (same shape as Phase 3 per-pool-stock), producing a research dossier under `persistence/intel/ipo/research/<symbol>.md`. The operator decides whether to add the IPO to the live trading watchlist for IPO day.

### 6.2 `strategy_ipo_v2` — live IPO day mode

A new strategy skill, only activated for stocks in `live_today`.

**Activation trigger**: a separate scheduled task (`claudetrading-ipo-tick`) fires at a higher cadence — every 1–3 minutes — on IPO day, but ONLY if `live_today` is non-empty. Otherwise no-op exit.

**Behavior** for each IPO-day stock:
- **Bypass the 2-trading-day cooldown** — no prior history to cool down from. (Documented exception in CLAUDE.md.)
- **Tighter stops**: 5% trailing instead of the global default.
- **Smaller position sizing**: half the normal `max_per_trade_usd`.
- **More aggressive profit-taking**: 5/10/15/25% rungs instead of 10/20/35/50.
- **Hard cap**: total IPO-day notional per stock limited to operator-configured `ipo_day_max_total_usd`.

**Day-2 transition**: cadence stays elevated; risk parameters relax slightly.

**Day-3+**: stock graduates to normal pool, normal cadence, normal cooldown applies. The IPO entry establishes baseline for `last_buy.timestamp` so the standard 2-day cooldown kicks in for sells.

### 6.3 IPO-aware safe_trading bypass

`safe_trading_v2/scripts/filter_pool.sh` learns to read `ipo/watchlist.json`. Symbols in `live_today` get `bypass_cooldown: true` in the sets output. Strategies see this flag and adjust.

**Effort**: L (1–2 weeks, careful design + testing required since IPO behavior is high-volatility). **Value**: medium-high (one or two IPOs per quarter could meaningfully move portfolio P&L).

---

## Phase 7 — Self-learning loop

### 7.1 Per-strategy attribution P&L

Each action record already has `strategy` field. Daily snapshot already has `actions[]`. Add a post-tick computation:
- For each strategy, compute realized + unrealized P&L for the day's actions.
- Roll into `persistence/snapshots/daily/<date>.json::strategy_attribution`.
- 30/60/90-day rolling Sharpe per strategy in the daily report.

If a strategy has been negative for 60 days, the configurator surfaces this and prompts the operator to retune or disable.

### 7.2 Weekly post-mortem

Friday after market close, an LLM run reads:
- The 5 daily snapshots
- The decisions / conclusions for each pool stock
- The actions placed

Produces a 200–400 word narrative: what worked, what didn't, what to retune, what to watch next week. Saved as `persistence/reports/weekly/<YYYY-Www>.md` and pushed via Telegram.

### 7.3 Backtest replay harness

`lib/replay.sh` + `scripts/backtest.sh`: takes a strategy name, a parameter override JSON, and a date range. Replays historical price data through the same `apply.sh` (with stubbed Alpaca calls) and produces a hypothetical action stream. Lets you tune `drop_percent` etc. without burning paper trades.

### 7.4 Walk-forward optimizer

Sunday cron: replays last 60 days under 5 candidate parameter sets per strategy, picks the best Sharpe, proposes to the operator (Telegram message). Operator accepts/rejects with a reply or via a configurator step.

---

## Cost & token budget analysis

Estimated **steady-state daily cost** for the 19-stock pool, all phases shipped:

| Component | Tokens/day | API \$/day | Total \$/day |
|---|---|---|---|
| 26 ticks × ~30k input (v2) | 780k | — | ~\$2.30 |
| Daily intel collection (news + ratings) | ~10k | ~\$0.20 | ~\$0.40 |
| Weekly intel rotation (1/7 of leadership/industry/competitor/etc.) | ~150k | ~\$1 | ~\$1.50 |
| Daily conclusions × 19 stocks | ~400k | — | ~\$1.20 |
| Decision-maker (1/day) | ~50k | — | ~\$0.15 |
| Pre-trade vetoes (~5/day) | ~50k | — | ~\$0.15 |
| 8-K ingestions (occasional) | ~20k | — | ~\$0.06 |
| Capitol trades ingest (Quiver opt-in) | — | ~\$0.30 | ~\$0.30 |
| Earnings + VIX + Form4 (mostly free) | — | ~\$0.10 | ~\$0.10 |
| **Total** | ~1.5M | ~\$1.60 | **~\$6.20/day** |

Monthly: ~\$185. For a research stack approximating analyst-level coverage of 19 stocks every trading day, this is a serious-but-not-insane budget. The biggest lever is the tier of refresh on the deep intel (leadership / industry / competitor / regulatory / consortium): at weekly cadence the budget is bounded; at daily cadence it explodes ~5×.

**If budget is a concern**, the cost-staging order is:
1. Phase 1 + 2.1 + 2.4 (insiders + VIX) → highest signal-to-cost
2. Phase 3 with **all** deep intel layers at **monthly** refresh first → ~\$3/day total
3. Promote layers to weekly as you observe their value
4. Phase 4 vetoes are cheap and high-value; ship early
5. Phases 5–7 are independent; stage based on operator interest

---

## Risk register

Things that can go wrong, and the mitigation:

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Web-scraped sources break (Cloudflare, layout change) | High | Med | Free APIs first; scrapes always wrapped in try/catch with fallback; Phase 6 IPO watch list can be operator-maintained if scrapes fail |
| LLM hallucinates a "bull case" not supported by intel | Med | High | Conclusion generator is required to cite each driver with source; intel files are the only allowed source |
| Daily research budget runs away (forgotten loop) | Low | Med | Hard daily token cap in `lib/env.sh`; circuit breaker that halts further LLM calls past threshold |
| Decision-maker bias miscalibration biases all trades | Med | High | `size_multiplier` clamped to [0.0, 1.5]; `bias` is advisory, never overrides safe_trading cooldown |
| IPO strategy on day 1 over-trades into a flash crash | Med | High | Hard `ipo_day_max_total_usd` cap; tighter stops; small initial sizing; 1-min cadence has minimum-spacing |
| Telegram bot leaks Alpaca account info to wrong chat | Low | High | `chat_id` is a single hardcoded value per operator; no broadcast; no group support; messages contain no creds |
| Operator misinterprets "STRONG_BUY" as financial advice | Med | Reputational | Disclaimer in every Telegram daily summary: "paper trading only; not financial advice" |
| Intel summaries drift over months without operator review | Med | Med | Monthly audit step in Phase 7.2 weekly post-mortem; sample one stock's full intel chain for review |

---

## Work tracker

Item codes use `Px.y-shortname` format. Status: `todo` / `in_progress` / `done` / `blocked` / `dropped`.

### Phase 1 — Foundation hardening (target: 1 week)

| ID | Item | Status | Effort | Depends on | Notes |
|---|---|---|---|---|---|
| P1.1-telegram | `lib/notify.sh` + Telegram integration | **done** | S | — | Channel-agnostic dispatch; telegram + sms_textbelt channels; fail-soft |
| P1.1-tg-tick | Wire `tick.sh` to emit per-action notifications | **done** | S | P1.1-telegram | v2 tick.sh notifies after Phase B, before persistence (so operator sees order even if persist fails) |
| P1.1-tg-anom | Wire anomaly walk to emit alerts | todo | S | P1.1-telegram | Lives in v2 SKILL.md anomaly walk; deferred — not part of this PR |
| P1.1-tg-daily | Wire daily report to send summary | todo | S | P1.1-telegram | Touches reporting skill; separate PR |
| P1.1-setup-doc | `docs/SETUP_TELEGRAM.md` walkthrough | **done** | XS | P1.1-telegram | 5-min bot creation walkthrough + chat_id capture + verify |
| P1.1-configurator | Wire Telegram setup + dynamic variant discovery into `master_configurator` | **done** | S | P1.1-telegram | Step 5 (variant) discovers `master_trading_v*` skills dynamically (future-proof for v3+); step 6 (NEW, optional) walks operator through @BotFather + chat_id + writes `.env` + verifies via `notify_test`. Reconfigure mode supports notification-only or variant-only re-runs. |
| P1.2-earnings | `lib/earnings.sh` + earnings calendar fetcher | todo | S | — | |
| P1.2-gate | Hook gate into mean_reversion + ladder_buys | todo | S | P1.2-earnings | |
| P1.3-scaffold | `persistence/intel/` directory + .gitignore | todo | XS | — | |
| P1.3-cron | `intel_refresh_v2` skill + 5am PT cron | todo | XS | P1.3-scaffold | |

### Phase 2 — Free data ingestion (target: 2 weeks)

| ID | Item | Status | Effort | Depends on | Notes |
|---|---|---|---|---|---|
| P2.1-form4-fetch | Form 4 EDGAR fetcher | todo | M | P1.3-scaffold | |
| P2.1-form4-summary | Aggregate summary + cluster detection | todo | S | P2.1-form4-fetch | |
| P2.2-8k-fetch | 8-K filings fetcher | todo | M | P1.3-scaffold | |
| P2.2-8k-llm | LLM digest pipeline | todo | M | P2.2-8k-fetch | |
| P2.3-13f | 13F holdings fetcher (quarterly) | todo | M | P1.3-scaffold | Lower priority |
| P2.4-vix | VIX fetch + sizing multiplier | todo | S | — | |
| P2.4-vix-strategy | Wire multiplier into all strategies | todo | S | P2.4-vix | |

### Phase 3 — Per-stock intel artifact system (target: 3 weeks)

| ID | Item | Status | Effort | Depends on | Notes |
|---|---|---|---|---|---|
| P3.1-layout | Per-stock directory bootstrap | todo | XS | P1.3-scaffold | |
| P3.2-collect | `intel_collect_v2` skill (news + ratings) | todo | M | P3.1-layout | Daily cron |
| P3.2-leadership | Leadership intel digest (web search + LLM) | todo | M | P3.2-collect | Weekly tier |
| P3.2-industry | Industry intel digest | todo | M | P3.2-collect | Weekly tier |
| P3.2-competitors | Competitor intel digest | todo | M | P3.2-collect | Weekly tier |
| P3.2-regulatory | Regulatory / policy intel digest | todo | M | P3.2-collect | Weekly tier; flagged by P5 |
| P3.2-consortium | Consortium / international intel digest | todo | M | P3.2-collect | Weekly tier |
| P3.3-tiered-cron | Tiered refresh schedule wiring | todo | S | all P3.2-* | Cost-control critical |
| P3.4-archive | 30-day archive + monthly summarizer | todo | M | P3.2-* | |
| P3.5-summary-5d | Rolling 5-trading-day summary skill | todo | S | P3.2-* | |
| P3.5-summary-30d | Rolling 30-day summary skill | todo | S | P3.2-* | |
| P3.5-summary-1y | Rolling 1-year summary skill | todo | M | P3.4-archive | |

### Phase 4 — Conclusions + decision-maker (target: 2 weeks)

| ID | Item | Status | Effort | Depends on | Notes |
|---|---|---|---|---|---|
| P4.1-conclude | `intel_conclude_v2` (per-stock daily conclusion) | todo | M | P3.* | Pre-market 5:30am |
| P4.2-decide | First-tick decision-maker agent | todo | M | P4.1-conclude | |
| P4.3-bias-mr | mean_reversion_v2 reads daily bias | todo | S | P4.2-decide | |
| P4.3-bias-lb | ladder_buys_v2 reads daily bias | todo | S | P4.2-decide | |
| P4.3-bias-pt | profit_take_v2 reads daily bias | todo | S | P4.2-decide | |
| P4.3-bias-ts | trailing_stop_v2 reads daily bias | todo | S | P4.2-decide | |
| P4.4-veto | Pre-trade LLM veto on \$500+ orders | todo | M | P4.1-conclude | |

### Phase 5 — Capitol trades & policy intel (target: 2 weeks)

| ID | Item | Status | Effort | Depends on | Notes |
|---|---|---|---|---|---|
| P5.1-house | House XML+PDF ingestion | todo | L | P1.3-scaffold | Python; PDF parsing |
| P5.1-senate | Senate eFD scraper | todo | L | P1.3-scaffold | Cookie + ToS handling |
| P5.1-quiver | Quiver API opt-in | todo | S | P5.1-house | If `QUIVER_API_KEY` set |
| P5.2-pool-signals | Per-pool-stock daily signal aggregation | todo | M | P5.1-* | |
| P5.3-committees | Committee-context scoring | todo | S | P5.2-pool-signals | |
| P5.4-clusters | Cluster trade detection | todo | S | P5.2-pool-signals | |
| P5.5-decide | Wire capitol signals into P4.2-decide | todo | S | P5.2-* + P4.2-decide | |

### Phase 6 — IPO strategy (target: 2 weeks)

| ID | Item | Status | Effort | Depends on | Notes |
|---|---|---|---|---|---|
| P6.1-watchlist | `ipo/watchlist.json` schema + tooling | todo | S | P1.3-scaffold | |
| P6.1-research | Pre-IPO daily research dossier | todo | M | P3.* + P6.1-watchlist | |
| P6.2-strategy | `strategy_ipo_v2` skill | todo | L | P6.1-watchlist | |
| P6.2-cron | High-cadence IPO-day cron task | todo | S | P6.2-strategy | |
| P6.3-bypass | safe_trading_v2 IPO bypass | todo | S | P6.1-watchlist | |
| P6-test-paper | End-to-end test on a real upcoming IPO | todo | M | P6.* | Risky; do on sentinel stock |

### Phase 7 — Self-learning (target: 2 weeks)

| ID | Item | Status | Effort | Depends on | Notes |
|---|---|---|---|---|---|
| P7.1-attrib | Per-strategy P&L attribution | todo | M | — | |
| P7.1-rolling | Rolling Sharpe per strategy in daily report | todo | S | P7.1-attrib | |
| P7.2-postmortem | Weekly post-mortem generator | todo | M | P7.1-attrib | Friday cron |
| P7.3-replay | Backtest replay harness | todo | L | — | |
| P7.4-walkforward | Walk-forward optimizer | todo | L | P7.3-replay | |

### Cross-cutting

| ID | Item | Status | Effort | Depends on | Notes |
|---|---|---|---|---|---|
| X-budget-cap | Daily LLM token budget circuit breaker | todo | S | — | Risk-register mitigation |
| X-disclaimer | "Paper trading only" disclaimer in all Telegram daily messages | todo | XS | P1.1-telegram | |
| X-reconfig | `master_configurator` updates for new per-feature flags | ongoing | M | each phase | One configurator pass per phase |
| X-docs-functionality | Update `docs/FUNCTIONALITY.md` per phase | ongoing | S | each phase | |
| X-docs-architecture | Update `docs/ARCHITECTURE.md` per phase | ongoing | S | each phase | |

**Effort scale**: XS = <2 hrs · S = 0.5–1 day · M = 1–2 days · L = 3–7 days.

---

## Glossary

- **Tick**: one invocation of `master_trading_v2` (or v1). Default cadence: 15 min during market hours.
- **First-tick decision**: the bias decision made once per trading day, before the first tick of the day, by Phase 4's decision-maker.
- **Daily bias**: per-stock advisory rating (`STRONG_BUY` / `BUY` / `HOLD` / `SELL` / `STRONG_SELL` / `WAIT`) consumed by strategies as a sizing/stop-tightness modifier.
- **Conclusion**: the per-stock daily synthesized note: bull case, bear case, drivers, risks. Lives in `current.json`.
- **Intel**: the raw research artifacts collected: news, filings, web searches, digests. Lives under `intel/<date>/`.
- **Cluster trade**: ≥3 distinct legislators (or ≥3 distinct insiders) trading the same ticker in a 14-day window. Strong signal in academic studies.
- **IPO live mode**: special trading regime active for the first 2 trading days of a newly-public stock; bypasses cooldown, tighter risk params.
- **Veto list**: the explicit do-not-trade-today list emitted by the decision-maker, separate from the safe_trading filter.
- **Tiered refresh**: cost-control pattern where intel layers refresh at different frequencies (daily / weekly / monthly) based on signal volatility.

---

## Disclaimer

The trading-day cooldown enforced by `safe_trading` is a user-defined safety margin. The intel artifacts, conclusions, and decision-maker are research aids — they are **not** financial advice. They do not guarantee compliance with FINRA's pattern day trader rule, IRS classification of trading income, or any specific regulation. The system trades paper money against `paper-api.alpaca.markets` only. Consult a tax / legal advisor.
