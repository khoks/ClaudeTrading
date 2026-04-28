---
name: dashboard
description: This skill should be used when the user asks to "show my dashboard", "open the dashboard", "show my portfolio", "show recent activity", "edit my configs in browser", "show market news", or runs `/dashboard`. Opens the committed dashboard.html (a single static page) in the operator's default browser. The page itself fetches live data on load — Alpaca API for account/positions/news, File System Access API for local configs/snapshots — so it always reflects current state. The Configuration tab lets the operator edit strategy tunables, preferences, and schedule cadence with browser-side writes back to persistence/config/*.json. No bash templating; no per-invocation regeneration.
version: 0.2.0
---

# dashboard

Opens an in-browser status page that builds itself from current state on every page load.

## Architecture

The dashboard is a **single committed HTML file** that builds itself from local files at load time:

- `.claude/skills/dashboard/dashboard.html` — committed static template, no operator data inlined.
- `.claude/skills/dashboard/scripts/open.sh` — one-line skill body that opens the HTML using the OS-appropriate command (`open` / `xdg-open` / `start`).
- `.claude/skills/dashboard/scripts/fetch_market_intel.sh` — separate one-off fetcher that pulls Alpaca news + (best-effort) Congressional trades into `persistence/market_intel.json`. Run before opening the dashboard, or wire into a daily scheduled task.
- All data assembly happens **in the browser** at page-load time:
  - **Local files via the File System Access API** — pool, configs, snapshots, market-intel cache. The page asks the operator to grant access to the project root once (handle stored in IndexedDB).
  - **Account / positions** — read from the most recent tick snapshot (state_persistence already wrote them). Up to one tick-cadence-minutes stale; refresh by reloading the browser tab.
  - **News + Congressional trades** — read from the local cache file populated by `fetch_market_intel.sh`.
  - **Edits to configs** — written through the same FSA handle. No bash, no PR, no skill round-trip; the files are gitignored so changes stay local.

Why this layout:
- **No browser-side API keys.** The dashboard never talks to Alpaca directly; the cache fetch script (which has access to `.env` via `lib/env.sh`) does. Browsers' file:// sandbox would otherwise force creds into `localStorage`, which adds surface area unnecessarily.
- **No outbound HTTP from the page.** The dashboard works offline once the cache is populated.
- The page is always fresh on reload — pulls current snapshot data and the latest cache contents on every open.
- Config editing fits naturally because the FSA handle is already there for reads.

Why browsers can't just `fetch('../../persistence/pool.json')` even though the files are siblings: the `file://` scheme blocks cross-file fetches as a deliberate security feature (a malicious HTML opened from disk could otherwise read arbitrary local files). FSA is the official escape hatch — the operator *explicitly* grants access via picker.

## Tabs

1. **Portfolio** — account stats (equity / cash / buying power / day change), equity sparkline (computed from last 30 tick snapshots), positions table sorted by unrealized P/L.
2. **Activity** — actions across recent ticks + daily snapshots, with two filter dimensions: timeframe (last tick / today / week / month / all) and symbol (any pool ticker / all). Both filters compose.
3. **Configuration** — editable forms for:
   - **Strategies** — enabled toggle + tunables for each of the 5 strategies (`profit_take`, `trailing_stop`, `mean_reversion`, `ladder_buys`, `wheel`). Save writes `persistence/config/strategy_defaults.json`.
   - **User preferences** — risk tolerance, max-per-trade, fractional shares. Save writes `persistence/config/user_preferences.json`. (Curated tickers stay editable through `/user_preferences_intake` — too risky to edit silently.)
   - **Schedule** — `tick_cadence_minutes`. Save writes `persistence/config/activation.json`. **Caveat shown inline:** changing this field updates the operator's *configuration*, but the actual cron registered with `mcp__scheduled-tasks` does not change automatically. To apply the new cadence to the live schedule, the operator must run `/master_configurator` in reconfigure mode (or call `mcp__scheduled-tasks__update_scheduled_task` directly).
4. **Pool** — read-only table of every stock: last buy/sell, watermark, stop, total invested, realized P/L. To edit (add/remove tickers), the operator runs `/user_preferences_intake`.
5. **Market intel** — reads `persistence/market_intel.json` (a local cache populated by `scripts/fetch_market_intel.sh`). The cache contains:
   - **News** — Alpaca's `/v1beta1/news` endpoint, filtered to pool tickers, last 30 items. Fully working.
   - **Congressional trades** (capitoltrades.com) — best-effort. The BFF endpoint is firewalled against non-browser callers (HTTP 503), and the public Next.js page uses streaming hydration that's not easily curl-parseable. The fetch script tries it but typically returns empty; the dashboard renders a clear empty-state with the known limitation noted. Alternatives (Quiver Quantitative API, House/Senate disclosure feeds, headless-browser fetcher) are deferred for a follow-up PR.

## First-run setup

When the dashboard is opened for the first time on a given browser:

1. **Project root** — page checks IndexedDB for a stored `FileSystemDirectoryHandle`. If absent, shows a "Pick directory…" button that opens the OS picker via `window.showDirectoryPicker({mode: 'readwrite'})`. Operator picks the repo's project root (the directory containing `persistence/`, `lib/`, `.claude/` etc.). Handle stored in IndexedDB.
2. With access granted, the page reads local configs / snapshots / market-intel cache and renders all tabs.

That's it — one grant, no API keys, no `localStorage` setup. Subsequent loads reuse the handle (with a quick permission re-prompt if the browser has revoked it between sessions).

To get news + Congressional data populated in tab 5, run **once before opening the dashboard** (or as part of a daily scheduled task):

```bash
bash .claude/skills/dashboard/scripts/fetch_market_intel.sh
```

This pulls from Alpaca + capitoltrades.com (best-effort) and writes `persistence/market_intel.json`.

## Editing configs (Tab 3) — the save flow

Each form section has a "Save" button. On click:

1. JS reads the form values, builds the new JSON object.
2. Writes the file via the cached FSA handle: `await dirHandle.getFileHandle('persistence/config/strategy_defaults.json', { create: false }).getFile().createWritable()` (or the equivalent path-walking API).
3. Shows a green "Saved" toast.
4. Re-renders the affected tab with the new in-memory state.

If FSA isn't supported (Firefox / Safari today): each "Save" button becomes a "Download as JSON" link instead. Operator manually replaces the file. Read access falls back to a `<input type="file" multiple webkitdirectory>` picker — uglier but functional.

## Browser support summary

| Browser | Read local | Edit + save configs |
|---|---|---|
| Chrome / Edge / Opera (Chromium) | ✅ | ✅ |
| Firefox / Safari | ✅ (via input fallback) | ⚠️ download-and-replace |

## Security notes

- The dashboard makes **no outbound HTTP requests**. Everything it reads is local (FSA-mediated), everything it writes is local (FSA-mediated). It cannot leak data even if the page were modified, because there's nowhere for it to send anything.
- The FSA handle is stored in IndexedDB, scoped to the page origin. The browser's origin-isolation prevents other tabs / pages from reading it.
- `fetch_market_intel.sh` runs in your shell and uses `.env` for Alpaca auth. Same security level as any other skill that hits Alpaca. It writes only to `persistence/market_intel.json` (gitignored).
- The dashboard.html itself contains no operator data — it's safe to commit publicly.

## Reuse

- `lib/env.sh` is sourced only by the open script (just to resolve `$REPO_ROOT`). The HTML/JS does not source any bash.
- No `lib/alpaca.sh` or `lib/pool.sh` from the browser — the JS reimplements the bits it needs (auth headers, pool path, snapshot path patterns).
