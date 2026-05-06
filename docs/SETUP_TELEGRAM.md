# Setting up Telegram notifications

Five minutes start to finish. This is the recommended notification channel for ClaudeTrading — it's free, reliable, and the bot stays bound to your Telegram account so messages reach you on every device you're signed into.

## Why Telegram (not SMS)

Telegram **bots** can't message phone numbers directly — they message a `chat_id` that's bound to your Telegram account once you message the bot once. That's the security model: a bot can only reach people who've explicitly contacted it. So the setup is:

1. Make a bot.
2. Message your bot once.
3. Read your `chat_id` from the bot's `getUpdates` endpoint.
4. Drop the bot token + chat_id into `.env`.

## Step 1 — Create the bot

1. Open Telegram (mobile or desktop) and search for **@BotFather** (it's the official bot-creation bot, blue checkmark).
2. Send `/newbot`.
3. Pick a display name (e.g. "ClaudeTrading Notifier").
4. Pick a username ending in `bot` (e.g. `my_claudetrading_bot`). It must be globally unique on Telegram, so add a personal suffix.
5. BotFather replies with your **bot token** — a string like `1234567890:AAFzr...` Save it. **Treat it like a password** (anyone with the token can post as your bot).

## Step 2 — Message the bot once

1. In the BotFather reply, click the link to your new bot (or search Telegram for the username you picked).
2. Click **Start** (or send `/start`).
3. Send any message, e.g. "hi".

This is the gesture that authorizes the bot to message you back.

## Step 3 — Get your chat_id

In a terminal:

```bash
curl "https://api.telegram.org/bot<YOUR_BOT_TOKEN>/getUpdates"
```

Look for `"chat":{"id":123456789,...}` in the JSON response. That number is your `chat_id`. (For personal chats it's a positive integer; for group chats it's negative.)

If `getUpdates` returns an empty `result: []`, you skipped step 2 — go back and send a message to the bot first.

## Step 4 — Drop into `.env`

```bash
TELEGRAM_BOT_TOKEN=1234567890:AAFzr...your-real-token...
TELEGRAM_CHAT_ID=123456789
```

`.env` is gitignored, so the token stays on your machine.

## Step 5 — Verify

```bash
source lib/env.sh
source lib/notify.sh
notify_test
```

You should see a message in your Telegram chat within ~1 second. If not, look at stderr — the lib logs the API error description so you can debug.

## Common errors

- **`Unauthorized`** — bot token is wrong or revoked. Re-check, regenerate if needed via BotFather (`/revoke`).
- **`Bad Request: chat not found`** — chat_id is wrong, OR you never messaged the bot in step 2.
- **`Forbidden: bot was blocked by the user`** — you blocked your own bot. Unblock it in Telegram.
- **No message arrives but no error either** — Telegram's MarkdownV2 parser is fussy about `_*[]()~\`>#+-=|{}.!`. The `notify_test` message uses safe characters, so this shouldn't happen for the test. For your own messages, set `NOTIFY_NO_MARKDOWN=1` to send raw.

## What gets sent

Once the creds are in `.env`, `master_trading_v2`'s `tick.sh` automatically pings you whenever:

- **A tick places at least one order** — buy/sell summary with strategy, symbol, price, reason.
- **An anomaly fires** — concentration warning, equity drop > 2%, persist failure.
- **The daily report runs** — link / summary text after the morning report.

If you don't want any of these, set `NOTIFY_DEFAULT_CHANNEL=none` in `.env`.

## Privacy

The bot only sends to your own `chat_id`. The token + chat_id never leave your machine — they sit in `.env` (gitignored) and are sent only to `api.telegram.org`. Your messages don't pass through any server we control.

If you ever want to revoke access: send `/revoke` to `@BotFather`, pick your bot, get a new token. The old token is dead immediately.

## Why not SMS by default

SMS via paid services (Twilio, Vonage) works fine but adds a recurring cost and another vendor account to manage. SMS via free services (TextBelt, etc.) is unreliable for US numbers — TextBelt explicitly blocks US free-tier sends due to abuse history. Telegram is free, reliable, encrypted in transit, and works on every device you're signed into. SMS is supported via `NOTIFY_DEFAULT_CHANNEL=sms_textbelt` + `TEXTBELT_KEY=<paid-key>` if you want it, but it's opt-in.
