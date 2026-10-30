---
name: prwatch-start
description: Start a PR watcher session - self-test, schedule the 15-minute checks, print the session banner, then run one check now.
---

# /prwatch-start

Run once, at launch. Keep output short.

## 1. Self-test (print one line per check, `OK` or `PROBLEM: …`)
1. **Sandbox on.** Run the sandboxed Bash command `/usr/bin/touch /Users/jack/prwatch/state/.sandbox-probe`. It must FAIL (operation not permitted / read-only: `state/` is write-denied by the sandbox; note `bin/` is no good as a probe because once Jack locks it with `chflags uchg` it fails even without a sandbox). If it succeeds, the sandbox is off: say `PROBLEM: sandbox is not active — do not use the watcher this session`, then stop (do not schedule anything).
2. **No network in the sandbox.** Run `/usr/bin/curl -sS --max-time 5 -o /dev/null https://example.com`. It must fail.
3. **Auto mode and model.** State the permission mode and the model you are running as.
4. **No MCP servers.** Confirm no `mcp__*` tools are available to you.
5. **No PermissionRequest hooks.** Read `/Users/jack/prwatch/config/settings.json` and confirm its `hooks` has no `PermissionRequest` key, and that `/Users/jack/prwatch/.claude/settings.json` and `/Users/jack/prwatch/.claude/settings.local.json` do not exist.
6. **Engine and skills.** Read `engine` from `/Users/jack/prwatch/state/session.lock` (Read tool) and print `Engine: <engine.engine>` (plus `engine.version` if set). Confirm `security-review`, `schedule` and `loop` are not in your available skills list, and that none of the Parliament commands `chaos:parliament-review`, `chaos:summon-council`, `chaos:implement-task-list`, `chaos:parliament-loop`, `chaos:parliament-monitor`, `chaos:debate-topic`, `chaos:ask-council` or `chaos:fast-track` is. Under `builtin`, `code-review` must be in the list.
7. **Foreground subagents.** Confirm your Bash tool has no `run_in_background` parameter. Then make one `Agent` call (`subagent_type: general-purpose`, `model: haiku`, `description: Foreground probe`, prompt `Reply with exactly PONG. Use no tools.`). In auto mode the reply normally arrives as a separate `[Subagent hand-back]` message, and the Agent result only says the report "was delivered to you as a message". That is expected: wait for that message before judging. **OK** when the call returned finished (no background-launch notice, no `PRWATCH HARNESS FAULT`) **and** the agent's report is `PONG`, either in the result or in its hand-back message. If the report is missing, withheld or flagged, say `PROBLEM: probe report not delivered (<what you saw>)`. If it says the agent was launched or is running in the background (the hook will also say `PRWATCH HARNESS FAULT`): `TaskStop` it ("not running" means it already finished — fine), say `PROBLEM: subagents run in the background (Claude Code update?) — do not use the watcher this session`. The hook has already stopped the watcher for this session and notified Jack.

7b. **Parliament probe** (only when the engine is `parliament`). Make one `Agent` call (`subagent_type: chaos:grumpy-code-reviewer`, `description: Parliament probe`, prompt `Reply with exactly PONG. Use no tools.`) and judge it exactly as test 7. Confirm `chaos:grumpy-security-nag` is one of the agent types you can dispatch. Then make one `Skill` call, skill `chaos:list-commands` with no args: it must be **refused** (by the hook, `prwatch skill gate`, or by a permission deny rule) and must not run. If anything here fails, say `PROBLEM: the Parliament engine is not usable (<what you saw>) — close this window and relaunch with PRWATCH_ENGINE=builtin`. Never switch engine yourself.
7c. **Built-in review probe** (only when the engine is `builtin`). Make one `Skill` call: skill `code-review`, args `low /Users/jack/prwatch/work/prwatch__selftest-pr1-0000000` (the launcher's one-line fixture). **OK** when its result arrives before you do anything else (no background-launch notice, no `PRWATCH HARNESS FAULT`) and you post nothing (ignore any offer to post or fix; the fixture's findings do not matter). Otherwise say `PROBLEM: the built-in review did not run in the foreground (<what you saw>)`; on a harness fault follow test 7.

8. **Angular test browser.** Check with the Glob tool that `/Users/jack/.cache/puppeteer/chrome-headless-shell/*/chrome-headless-shell-mac*/chrome-headless-shell` exists. If it's missing, say `PROBLEM: Angular tests can't run automatically (no chrome-headless-shell); Jack: npx @puppeteer/browsers install chrome-headless-shell`. This is a warning; the watcher still starts.

If any of 1, 4, 6, 7, 7b or 7c fails, tell Jack and do not schedule anything.

## 2. Schedule (session cron)
1. `CronList`. Delete any existing jobs (avoid duplicates).
2. `CronCreate` recurring `*/15 * * * *` with prompt `/prwatch-tick`.
A hook allows only this one job, exactly as written (recurring), and refuses every other way of scheduling a prompt. If it is refused, say `PROBLEM: could not schedule the checks (<hook message>)` and stop.

## 3. Banner
Run `/Users/jack/prwatch/bin/prwatch-tick.sh --window` and print, taking `started`, `starts_until` and `ends_at` from its JSON (never from your own sense of time):
- "Checking every 15 min for 8 hours from <started_hm>. New reviews start in the first 7½ hours (until <starts_until>); decisions until <ends_at>."
- "Engine: <engine> — <the one line for it>": `parliament` → "Parliament of Chaos reviewers"; `builtin` → "Claude Code's /code-review"; `builtin-agent` → "one general reviewer (/code-review cannot review a worktree on this Claude Code)". `<engine>` is the `engine` value from the same JSON.
- "Commands: `d` (drafts now), `status`, `pause 60`, `stop`, `allow <owner>/<repo>` or `block <owner>/<repo>` (for a first PR from a repo it has not seen). Esc stops a running review (it resumes at the next check)."
- "At permission prompts choose Yes — never 'Yes, and don't ask again'."
If `--window` prints `error`, print its `kind` instead of the first line and add "Close this window and double-click PR Watcher again." (`--window` sends no notification).

## 4. Housekeeping and first check
1. `/Users/jack/prwatch/bin/prwatch-cleanup.sh --sweep`
2. Run `/prwatch-tick` now.
