---
name: dashboard
description: This skill should be used when the user asks to "show my dashboard", "open the dashboard", "show my portfolio", "show recent activity", "edit my configs in browser", "show market news", or runs `/dashboard`. Opens the committed dashboard.html (a single static page) in the operator's default browser. The page builds itself from local files (latest tick snapshot + configs + pool) on every load via the File System Access API — no Alpaca creds needed by default. Optional 🔑 Creds button enables Alpaca news fetching. Capitol-trades render as per-ticker deep-links (Cloudflare WAF blocks direct browser fetches). The Configuration tab lets the operator edit strategy tunables, preferences, and schedule cadence with browser-side writes back to persistence/config/*.json. No bash templating; no per-invocation regeneration.
version: 0.4.0
---

# dashboard

Opens an in-browser status page that builds itself from current state on every page load.

## Architecture

The dashboard is a **single committed HTML file** that builds itself from local state on every load:

- `.claude/skills/dashboard/dashboard.html` — committed static template, no operator data inlined.
- `.claude/skills/dashboard/scripts/open.sh` — one-line skill body that opens the HTML using the OS-appropriate command (`open` / `xdg-open` / `start`).
- **Default posture: zero credentials in the browser.** Account, positions, P/L, equity sparkline, activity, and pool all come from local files (the most recent tick snapshot + persistence configs) via the **File System Access API**. The operator grants the project root once; that single FSA handle covers reads + config writes.
- **Optional opt-in: Alpaca credentials.** A 🔑 Creds button in the header opens a small dialog where the operator can paste their paper key/secret. With creds present, tab 5 (Market intel) starts fetching news from `data.alpaca.markets`. Without creds, news is shown as "disabled" with a one-click prompt to enable. **Account/positions still come from snapshots** even when creds are present — there is no live-account path in the browser, by design.
- **Capitol trades** are *not* fetched. `bff.capitoltrades.com` is behind a Cloudflare WAF that blocks anything but a real browser TLS fingerprint (file:// origins return 503; even Python urllib with full browser headers returns 503), and there's no free CORS-friendly aggregator. The dashboard renders **per-ticker deep-links** (Capitol Trades + Quiver Senate + Quiver House) — one click per row opens the public site filtered to that ticker.
- **Edits to configs** — written through the same FSA handle. No bash, no PR, no skill round-trip; the files are gitignored so changes stay local.

Why this layout:
- **No browser-side secrets by default.** The operator's `.env` already has the Alpaca creds on disk; the dashboard does not need them re-entered just to display equity and positions, since `state_persistence` writes those into a tick snapshot every cadence-minutes anyway.
- **The page can stay open.** Operator hits Refresh and re-reads the latest snapshot. No periodic skill or cron job needed for the dashboard itself.
- **Trade-off acknowledged:** account/positions are *tick-cadence-fresh*, not real-time. With a 15-minute tick that's fine for a dashboard that's checked, not watched. If the operator wants real-time, they can opt into creds — but the architecture deliberately doesn't make this the default, because trading state on disk is already authoritative.
- **No bash for data prep.** Earlier designs had a `fetch_market_intel.sh` step; that's been removed — the browser does it itself.
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
5. **Market intel** — two sections:
   - **News** — `https://data.alpaca.markets/v1beta1/news?symbols=…` filtered to pool tickers, last 30 items, sort desc. **Requires creds.** When creds are absent (the default), the panel shows "News is disabled — click 🔑 Creds in the header to enable." When creds are present, the page fetches and renders the headlines.
   - **Congressional trades — pool deep-links.** The dashboard does *not* fetch congressional-trade JSON. `bff.capitoltrades.com` is behind a Cloudflare WAF that blocks anything but a real browser TLS fingerprint (file:// origins return 503; even Python urllib with full browser headers returns 503), and there's no free CORS-friendly aggregator. Instead, the page renders a small table — one row per pool ticker — with deep-links to **Capitol Trades**, **Quiver (Senate)**, and **Quiver (House)** filtered to that ticker. One click opens the public site in a new tab with real data. The trade-off: no in-page table, but no silent failure and no third-party rate-limit concerns either.

## First-run setup

When the dashboard is opened for the first time on a given browser, the page does **one** thing:

1. **Project root (FSA grant)** — page checks IndexedDB for a stored `FileSystemDirectoryHandle`. If absent, shows a "Pick directory…" button that opens the OS picker via `window.showDirectoryPicker({mode: 'readwrite'})`. Operator picks the repo's project root.

That's it. With FSA in place, the page reads `persistence/snapshots/tick/`, `persistence/config/`, and `persistence/pool.json` directly, attempts capitoltrades over the network, and renders all five tabs. **No credentials are required or requested at first run.**

**Optional later: enable news.** A 🔑 Creds button in the header opens a small dialog where the operator can paste `ALPACA_KEY` and `ALPACA_SECRET` (paper). Stored in `localStorage` only — same machine, same browser, never committed, never sent anywhere except to `data.alpaca.markets` for news fetching. Same security level as the `.env` on disk: anyone with filesystem access can already read both. Clear the creds any time via the same dialog.

Subsequent loads: re-uses the FSA handle (browser may re-prompt for permission once per session — one click). Re-uses creds if previously entered.

**Refresh** any time by hitting the Refresh button or reloading the tab — re-reads the latest tick snapshot, re-tries capitoltrades, re-fetches news (if creds present).

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

- **Default posture is zero credentials in the browser.** The dashboard runs purely from local files (snapshots, configs, pool) + an unauthenticated capitoltrades fetch. Nothing leaves the operator's machine in this mode except the capitoltrades request.
- **Optional creds**: when the operator clicks 🔑 Creds and saves a key/secret, the values live in `localStorage`, page-origin scoped. The dashboard sends them only to `data.alpaca.markets` (for news). Same security level as `.env` on disk: anyone with filesystem access can read both. Cleared via the same dialog or by deleting the localStorage key.
- The FSA handle is stored in IndexedDB, also page-origin scoped.
- The dashboard makes at most one outbound HTTP request, and only if the operator opts in: `data.alpaca.markets` (with creds, for news). It never calls `paper-api.alpaca.markets` (account/positions come from snapshots) and no longer calls `bff.capitoltrades.com` (deep-links instead). With no creds, the only outbound request when the page loads is fetching the dashboard.html itself.
- The dashboard.html itself contains no operator data — it's safe to commit publicly.

## Reuse

- `lib/env.sh` is sourced only by the open script (just to resolve `$REPO_ROOT`). The HTML/JS does not source any bash.
- No `lib/alpaca.sh` or `lib/pool.sh` from the browser — the JS reimplements the bits it needs (auth headers, pool path, snapshot path patterns).
