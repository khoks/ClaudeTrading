---
name: dashboard
description: This skill should be used when the user asks to "show my dashboard", "open the dashboard", "show my portfolio", "show recent activity", "edit my configs in browser", "show market news", or runs `/dashboard`. Opens the committed dashboard.html (a single static page) in the operator's default browser. The page itself fetches live data on load — Alpaca API for account/positions/news, File System Access API for local configs/snapshots — so it always reflects current state. The Configuration tab lets the operator edit strategy tunables, preferences, and schedule cadence with browser-side writes back to persistence/config/*.json. No bash templating; no per-invocation regeneration.
version: 0.2.0
---

# dashboard

Opens an in-browser status page that builds itself from current state on every page load.

## Architecture

The dashboard moved from a server-rendered, baked-at-generation static page (v0.1) to a **client-rendered live page** (v0.2):

- `.claude/skills/dashboard/dashboard.html` — committed static template, no operator data inlined.
- `.claude/skills/dashboard/scripts/open.sh` — one-line skill body that just opens the HTML in the operator's default browser using the OS-appropriate command (`open` / `xdg-open` / `start`).
- All data assembly happens **in the browser** at page-load time:
  - **Live values** (account, positions, current prices, news) — JS fetches directly from Alpaca's paper API. Alpaca supports browser CORS, so cross-origin from `file://` works.
  - **Local files** (`persistence/pool.json`, `persistence/config/*.json`, `persistence/snapshots/**/*.json`) — read via the File System Access API after the user grants directory access once.
  - **Edits to configs** — written through the same FSA handle. No bash, no PR, no skill round-trip; the files are gitignored so changes stay local.

Why this layout:
- The page is always live. Re-opening / reloading the tab regenerates content from current state automatically.
- The skill is trivial — just an "open file" command, cross-platform.
- Config editing fits naturally because the FSA handle is already there for reads.

## Tabs

1. **Portfolio** — account stats (equity / cash / buying power / day change), equity sparkline (computed from last 30 tick snapshots), positions table sorted by unrealized P/L.
2. **Activity** — actions across recent ticks + daily snapshots, with two filter dimensions: timeframe (last tick / today / week / month / all) and symbol (any pool ticker / all). Both filters compose.
3. **Configuration** — editable forms for:
   - **Strategies** — enabled toggle + tunables for each of the 5 strategies (`profit_take`, `trailing_stop`, `mean_reversion`, `ladder_buys`, `wheel`). Save writes `persistence/config/strategy_defaults.json`.
   - **User preferences** — risk tolerance, max-per-trade, fractional shares. Save writes `persistence/config/user_preferences.json`. (Curated tickers stay editable through `/user_preferences_intake` — too risky to edit silently.)
   - **Schedule** — `tick_cadence_minutes`. Save writes `persistence/config/activation.json`. **Caveat shown inline:** changing this field updates the operator's *configuration*, but the actual cron registered with `mcp__scheduled-tasks` does not change automatically. To apply the new cadence to the live schedule, the operator must run `/master_configurator` in reconfigure mode (or call `mcp__scheduled-tasks__update_scheduled_task` directly).
4. **Pool** — read-only table of every stock: last buy/sell, watermark, stop, total invested, realized P/L. To edit (add/remove tickers), the operator runs `/user_preferences_intake`.
5. **Market intel** — pool-ticker news fetched from Alpaca's `/v1beta1/news` endpoint. *(Congressional / insider trading section is a placeholder — needs the operator to confirm the upstream data source URL before wiring.)*

## First-run setup

When the dashboard is opened for the first time on a given browser, the page does:

1. **Credentials** — checks `localStorage['claudetrading.creds']`. If absent, shows a small modal asking for `ALPACA_KEY` and `ALPACA_SECRET` (paper). Stored in `localStorage` only — same machine, same browser, never committed, never sent anywhere except to Alpaca's API.
2. **Project root** — checks IndexedDB for a stored `FileSystemDirectoryHandle`. If absent, shows a "Pick repo root" button that opens the OS directory picker via `window.showDirectoryPicker({mode: 'readwrite'})`. Stored in IndexedDB.
3. With both in place, the page reads local configs/snapshots and fetches live Alpaca data, then renders all tabs.

Subsequent loads: re-uses both. The browser may re-prompt for FSA permission if it's been revoked between sessions; that's a one-click re-grant.

## Editing configs (Tab 3) — the save flow

Each form section has a "Save" button. On click:

1. JS reads the form values, builds the new JSON object.
2. Writes the file via the cached FSA handle: `await dirHandle.getFileHandle('persistence/config/strategy_defaults.json', { create: false }).getFile().createWritable()` (or the equivalent path-walking API).
3. Shows a green "Saved" toast.
4. Re-renders the affected tab with the new in-memory state.

If FSA isn't supported (Firefox / Safari today): each "Save" button becomes a "Download as JSON" link instead. Operator manually replaces the file. Read access falls back to a `<input type="file" multiple webkitdirectory>` picker — uglier but functional.

## Browser support summary

| Browser | Read live + local | Edit + save |
|---|---|---|
| Chrome / Edge / Opera (Chromium) | ✅ | ✅ |
| Firefox / Safari | ✅ (via input fallback) | ⚠️ download-and-replace |

## Security notes

- Alpaca creds live in `localStorage`. Same security level as `.env` on disk — anyone with filesystem access to the operator's machine can read both. The dashboard does not send creds anywhere except Alpaca's own API endpoints.
- The FSA handle is stored in IndexedDB, scoped to the page origin. The browser's origin-isolation prevents other tabs / pages from reading it.
- The dashboard.html itself contains no operator data — it's safe to commit publicly.

## Reuse

- `lib/env.sh` is sourced only by the open script (just to resolve `$REPO_ROOT`). The HTML/JS does not source any bash.
- No `lib/alpaca.sh` or `lib/pool.sh` from the browser — the JS reimplements the bits it needs (auth headers, pool path, snapshot path patterns).
