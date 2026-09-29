---
name: prwatch-start
description: Start today's PR watcher session - self-test, schedule the 15-minute ticks and the end-of-day summary, then run one tick now.
---

# /prwatch-start

Run once, at launch. Keep output short.

## 1. Self-test (print one line per check, `OK` or `PROBLEM: …`)
1. **Sandbox on.** Run the sandboxed Bash command `/usr/bin/touch /Users/jack/prwatch/state/.sandbox-probe`. It must FAIL (operation not permitted / read-only: `state/` is write-denied by the sandbox; note `bin/` is no good as a probe because once Jack locks it with `chflags uchg` it fails even without a sandbox). If it succeeds, the sandbox is off: say `PROBLEM: sandbox is not active — do not use the watcher today`, then stop (do not schedule anything).
2. **No network in the sandbox.** Run `/usr/bin/curl -sS --max-time 5 -o /dev/null https://example.com`. It must fail.
3. **Auto mode and model.** State the permission mode and the model you are running as.
4. **No MCP servers.** Confirm no `mcp__*` tools are available to you.
5. **No PermissionRequest hooks.** Read `/Users/jack/prwatch/config/settings.json` and confirm its `hooks` has no `PermissionRequest` key, and that `/Users/jack/prwatch/.claude/settings.json` and `/Users/jack/prwatch/.claude/settings.local.json` do not exist.
6. **Blocked skills absent.** Confirm `code-review`, `review`, `security-review`, `schedule` and `loop` are not in your available skills list.

If any of 1, 4 or 6 fails, tell Jack and do not schedule anything.

## 2. Schedule (session cron, local time)
1. `CronList`. Delete any existing `/prwatch-tick` or `/prwatch-eod` jobs (avoid duplicates).
2. `CronCreate` recurring `*/15 8-15 * * 1-5` with prompt `/prwatch-tick`.
3. `CronCreate` recurring `3 16 * * 1-5` with prompt `/prwatch-eod`.

## 3. Housekeeping and first tick
1. `/Users/jack/prwatch/bin/prwatch-cleanup.sh --sweep`
2. Run `/prwatch-tick` now (it is a no-op outside the window).

## 4. Banner
Print:
- "Checking every 15 min, Mon–Fri. New reviews start 08:00–15:30; decisions until 16:00."
- "Commands: `d` (drafts now), `status`, `pause 60`, `stop`. Esc stops a running review (it resumes at the next check)."
- "At permission prompts choose Yes — never 'Yes, and don't ask again'."
