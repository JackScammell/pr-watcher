---
name: prwatch-eod
description: PR watcher session summary (run by /prwatch-tick once the 8-hour session is over) - one quiet notification with counts and a list in the window.
---

# /prwatch-eod

1. Run `/Users/jack/prwatch/bin/prwatch-state.sh eod-done`. It counts this session's lines in `events.jsonl` and prints `{"posted":<a>,"waiting":<b>,"not_started":<c>,"failed":<d>}` (you never count them yourself; a second run prints the same counts). Exit 64 → print the line the script printed (for example "session not over") and stop. Any other non-zero exit → print the script's output and stop. Exit 5 → superseded: print "This window was replaced by a newer watcher window — please close it." and stop.
2. `/Users/jack/prwatch/bin/prwatch-notify.sh eod posted-<a>.waiting-<b>.not-started-<c>.failed-<d>` (numbers only, from that JSON; this is a silent notification).
3. Print `Session summary: posted <a>, waiting <b>, not started <c>, failed <d>`, then a short list in the window from `/Users/jack/prwatch/state/state.json` (Read tool): one line per PR — key, status, recommendation, archive path. Say that waiting items can still be answered now with `d`, and that queued items are reviewed at the next launch.
4. `/Users/jack/prwatch/bin/prwatch-cleanup.sh --sweep`
Do not start any review. Do not delete the cron job (`/prwatch-tick` does that after this summary).
