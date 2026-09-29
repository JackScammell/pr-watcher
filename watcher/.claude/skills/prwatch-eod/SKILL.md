---
name: prwatch-eod
description: PR watcher end-of-day summary (fired once after 16:00 by session cron) - one quiet notification with counts and a list in the window.
---

# /prwatch-eod

1. Read `/Users/jack/prwatch/state/state.json` and `/Users/jack/prwatch/state/events.jsonl` (today's lines only).
2. Count today: `posted`, `skipped`, waiting for Jack (`ready`/`asking`/`awaiting_decision`/`go_ahead_pending`), not started (`queued` — they were requested after the 15:30 start cut-off or over the cap), `failed`.
3. `/Users/jack/prwatch/bin/prwatch-notify.sh eod posted-<a>.waiting-<b>.not-started-<c>.failed-<d>` (numbers only; this is a silent notification).
4. Print a short list in the window: one line per PR — key, status, recommendation, archive path. Say that waiting items can still be answered now with `d`, and that queued items will be reviewed from 08:00 tomorrow.
5. `/Users/jack/prwatch/bin/prwatch-cleanup.sh --sweep`
Do not start any review. Do not delete the cron jobs.
