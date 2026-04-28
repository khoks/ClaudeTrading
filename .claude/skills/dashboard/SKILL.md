---
name: dashboard
description: This skill should be used when the user asks to "show my dashboard", "open the dashboard", "show my portfolio", "show recent activity", "edit my configs in browser", "show market news", or runs `/dashboard`. Opens the committed dashboard.html (a single static page) in the operator's default browser. The page itself fetches live data on load — Alpaca API for account/positions/news, File System Access API for local configs/snapshots — so it always reflects current state. The Configuration tab lets the operator edit strategy tunables, preferences, and schedule cadence with browser-side writes back to persistence/config/*.json. No bash templating; no per-invocation regeneration.
version: 0.2.0
---

# dashboard

Opens an in-browser status page that builds itself from current state on every page load.

## Architecture

The dashboard is a **single committed HTML file** that pulls live data on every load (or refresh):

- `.claude/skills/dashboard/dashboard.html` — committed static template, no operator data inlined.
- `.claude/skills/dashboard/scripts/open.sh` — one-line skill body that opens the HTML using the OS-appropriate command (`open` / `xdg-open` / `start`).
- All data assembly happens **in the browser**:
  - **Live API calls** — Alpaca paper API for account / positions / news (CORS-supported). capitoltrades.com for Congressional trades (best-effort; may CORS-fail from the `null`/`file://` origin — the page renders a clear error in that case and points at alternatives).
  - **Local files via the File System Access API** — pool, configs, snapshots. The page asks the operator to grant access to the project root once (handle stored in IndexedDB).
  - **Edits to configs** — written through the same FSA handle. No bash, no PR, no skill round-trip; the files are gitignored so changes stay local.

Why this layout:
- **The page can stay open.** Operator hits Refresh and gets fresh Alpaca + capitol data without touching the terminal. No periodic skill or cron job needed for the dashboard itself.
- **No bash for data prep.** Earlier designs had a `fetch_market_intel.sh` step; that's been removed — the browser does it itself.
- The page works offline gracefully: if Alpaca calls fail, it falls back to reading account/positions from the most recent tick snapshot (which `state_persistence` already wrote on disk). Capitol-trades failure is shown as an empty-state with the error reason.
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
5. **Market intel** — fetched live in the browser:
   - **News** — `https://data.alpaca.markets/v1beta1/news?symbols=…` filtered to pool tickers, last 30 items, sort desc. Alpaca supports browser CORS so this works directly.
   - **Congressional trades** (`https://bff.capitoltrades.com/trades`) — best-effort. A real browser sends realistic fingerprint headers and may bypass the Cloudflare WAF that blocks raw curl, but the BFF likely doesn't allow CORS for the `null` (file://) origin. Wrapped in `try/catch`; on failure the dashboard shows a clear error message naming the cause and listing alternatives (Quiver Quantitative API; House/Senate disclosure feeds; a small local relay that proxies the BFF). Refresh the browser tab to retry.

## First-run setup

When the dashboard is opened for the first time on a given browser, the page does:

1. **Credentials** — checks `localStorage['claudetrading.creds']`. If absent, shows a small modal asking for `ALPACA_KEY` and `ALPACA_SECRET` (paper). Stored in `localStorage` only — same machine, same browser, never committed, never sent anywhere except to Alpaca's API. Same security level as the `.env` on disk: anyone with filesystem access already can read both.
2. **Project root** — page checks IndexedDB for a stored `FileSystemDirectoryHandle`. If absent, shows a "Pick directory…" button that opens the OS picker via `window.showDirectoryPicker({mode: 'readwrite'})`. Operator picks the repo's project root.
3. With both in place, the page fetches Alpaca live + tries capitoltrades + reads local files, then renders all tabs.

Subsequent loads: re-uses both. Browser may re-prompt for FSA permission across sessions (one click).

**Refresh** any time by hitting the Refresh button or reloading the tab — re-fetches live data.

## Editing configs (Tab 3) — the save flow

Each form section has a "Save" button. On click:

1. JS reads the form values, builds the new JSON object.
2. Writes the file via the cached FSA handle: `await dirHandle.getFileHandle('persistence/config/strategy_defaults.json', { create: false }).getFile().createWritable()` (or the equivalent path-walking API).
3. Shows a green "Saved" toast.
4. Re-renders the affected tab with the new in-memory state.

If FSA isn't supported (Firefox / Safari today): each "Save" button becomes a "Download as JSON" link instead. Operator manually replaces the file. Read access falls back to a `<input type="file" multiple webkitdirectory>` picker — uglier but functional.

## Browser support summary

| Browser | Read live + local | Edit + save configs |
|---|---|---|
| Chrome / Edge / Opera (Chromium) | ✅ | ✅ |
| Firefox / Safari | ✅ (FSA via input fallback) | ⚠️ download-and-replace |

## Security notes

- Alpaca creds live in `localStorage`, page-origin scoped. The dashboard sends them only to `paper-api.alpaca.markets` and `data.alpaca.markets`. Same security level as `.env` on disk.
- The FSA handle is stored in IndexedDB, also page-origin scoped.
- The dashboard makes outbound HTTP requests to: Alpaca paper API (with creds), Alpaca data API (with creds), and `bff.capitoltrades.com` (no auth, public endpoint). Nothing else.
- The dashboard.html itself contains no operator data — it's safe to commit publicly.

## Reuse

- `lib/env.sh` is sourced only by the open script (just to resolve `$REPO_ROOT`). The HTML/JS does not source any bash.
- No `lib/alpaca.sh` or `lib/pool.sh` from the browser — the JS reimplements the bits it needs (auth headers, pool path, snapshot path patterns).
