# PR Watcher — how to use it

The PR Watcher keeps an eye on GitHub for pull requests where someone has asked **you personally** to review, in ACT-Training. For each one it makes a private copy of the code, has a panel of AI reviewers look at it, and then asks you in the window what to post. **Nothing is ever posted unless you pick the action, approve the permission prompt, and click Post on a Mac dialog.**

## Daily use

**Start:** double-click **PR Watcher** on your Desktop (`~/Desktop/PR Watcher.command`). A Terminal window opens. It checks every 15 minutes, Monday to Friday.
- New reviews only **start** between 08:00 and 15:30. After 15:30 it still asks you about finished drafts until 16:00. Anything requested after 15:30 is reviewed from 08:00 the next working day.
- Draft PRs are skipped.
- Laravel repos (attendance, auth) get a read-only review. Their tests are not run, and the screen says `Tests: NOT run (Laravel — Flux Pro credentials)`.

**While a review is running** (usually 25–45 minutes) the window is busy. Anything you type waits until the review finishes. Press **Esc** to stop that review; the next check starts it again.

**Commands you can type in the window:**
| Type | What happens |
|---|---|
| `d` | Ask me about waiting drafts now |
| `status` | One line per PR being tracked |
| `pause 60` | Skip checks for 60 minutes (any number of minutes) |
| `stop` | Finish for the day. Then type `/exit` to close the window |

**At every permission prompt choose "Yes". Never choose "Yes, and don't ask again".**

**Closing the window** is safe. Unfinished reviews carry on at the next launch.

**If something goes wrong** you get a Mac notification: GitHub login expired, the watcher stopped before 16:00, or nothing has happened for 30 minutes (usually a prompt or dialog waiting for you).

**"Reviewers ran in the background"** means Claude Code ran the reviewers in the background instead of the foreground, usually after a Claude Code update. It is a **harness fault**; nothing is wrong with the PR. The watcher stops the reviewers, puts the PR back in the queue, gives back the day's review slot, and stops for the rest of the day. Don't restart it straight away. Instead:
1. run `claude --version`;
2. check that `~/prwatch/config/settings.json` still has `"CLAUDE_CODE_DISABLE_BACKGROUND_TASKS": "1"` under `env`;
3. run `~/prwatch/test/harness/live-check.sh`.

If the live check passes, delete `~/prwatch/state/stopped-<today>` and relaunch. If it fails, ask Claude to look at it. The same applies if self-test 7 says `PROBLEM` at launch.

**"Claude Code changed how it reports subagents"** (hookdrift) means the background check may not recognise what Claude Code now sends back. The watcher keeps running. Run `~/prwatch/test/harness/live-check.sh` before relying on it.

**After every Claude Code update** run `~/prwatch/test/harness/live-check.sh` (about 3 minutes, a few cheap model calls). It checks the behaviour the watcher's safety checks depend on.

Reviews and drafts are kept in `~/Documents/vision-reviews/<date>-pr<N>-round<k>/`.

## One-time setup: notifications (do this before test T1)

Notifications come from **Script Editor** (that's how macOS shows notifications sent by scripts).
1. Open **Script Editor** (Applications → Utilities), create a new document, type `display notification "hello"` and press ▶ Run. Allow notifications when macOS asks.
2. Open **System Settings → Notifications → Script Editor**. Turn on **Allow notifications**, then pick a style:
   - **Alerts** stay on screen until you dismiss them (recommended).
   - **Banners** disappear after a few seconds.
   T1 below is run once with each style, so you can pick.
3. Turn **Play sound for notifications** on.
4. If you use Focus modes, allow Script Editor in the Focus you use at work (System Settings → Focus → your Focus → Allowed apps).

Clicking a notification opens Script Editor, not Terminal. Switch to the Terminal "PR watcher" window yourself.

## Locking the watcher's own files (after the day-1 tests pass)

This makes the watcher's scripts and settings read-only, so nothing (including the AI) can change them:

```
chflags -R uchg ~/prwatch/bin ~/prwatch/config ~/prwatch/.claude ~/prwatch/angles ~/prwatch/CLAUDE.md
```

To change something later, unlock, edit, then lock again:

```
chflags -R nouchg ~/prwatch/bin ~/prwatch/config ~/prwatch/.claude ~/prwatch/angles ~/prwatch/CLAUDE.md
```

Because `.claude` is locked, "Yes, and don't ask again" at a permission prompt would fail anyway. That's another reason to always choose plain "Yes".

## Laravel repos and tests

Laravel repos (attendance, auth) are **read-only reviews for now**. Their packages include Flux Pro, which needs your licence key to download, and the watcher deliberately never sees it.

Running Laravel tests automatically would need the watcher to pass your Flux licence key into the dependency download. **Turning this on lets a PR's code see your Flux licence key during the dependency download.** The builder did **not** add this switch: the change was blocked as a security weakening during the build (see `BUILD-NOTES.md`). If you want it, it needs your explicit go-ahead and a separate change.

Your Flux key in `~/.composer` is blocked from the watcher's AI session and its sandboxed test runs.

## Day-1 test checklist

All tests use test mode so nothing touches your real state or `~/Documents/vision-reviews`. The test PR is `ACT-Training/Vision#1803` (already merged), head `7458ff7f6973c8a0bc988b88a1816abcd01068e8`. Posting in test mode is always a dry run: nothing is sent to GitHub.

**Do T6, T7 and T11–T14 on a weekday between 09:00 and 15:00.** `PRWATCH_NOW` moves only the tick script's clock, not the 15-minute timer or the watchdog.

Paste this first in any Terminal you use for tests:
```
export PRWATCH_TESTMODE=1 PRWATCH_STATE_DIR=~/prwatch/test/state PRWATCH_ARCHIVE_DIR=~/prwatch/test/archive
```

| # | Test | What to do | Expected |
|---|---|---|---|
| T0 | First launch | Double-click **PR Watcher** on the Desktop (install steps are done). | The window prints `claude: … (2.1.x …)`. A one-time "trust this folder" prompt. The self-test lines say: sandbox on, auto mode, opus, no MCP servers, no PermissionRequest hooks, code-review/security-review/schedule/loop absent, and (test 7) foreground subagents OK: Bash has no `run_in_background`, and the `PONG` probe replied, usually through a `[Subagent hand-back]` message. Then type `stop`, then `/exit`. |
| T1 | Notifications (run twice: Alerts, then Banners) | `~/prwatch/bin/prwatch-notify.sh test x` (in a Terminal **without** the test-mode export) | A notification with the Glass sound. `tail -1 ~/prwatch/state/notify.log` shows `test x :: Test notification…`. Keep the style you prefer. |
| T2 | Prep on the test PR (already run by the builder, see BUILD-NOTES) | `~/prwatch/bin/prwatch-prep.sh Vision 1803 7458ff7f6973c8a0bc988b88a1816abcd01068e8 1` | Prints an archive folder under `~/prwatch/test/archive`. `prebuild.log` there shows `Restored …api/…csproj` and `added N packages`, and no `MSB1025`/`MSB1003`/`command not found`. |
| T3 | Window times (builder ran it) | `for t in 07:59 08:00 15:29 15:30 15:59 16:00; do PRWATCH_NOW=2026-09-29T$t ~/prwatch/bin/prwatch-tick.sh --window; done` | outside, in, in, start_closed, start_closed, outside. |
| T4 | Design check (builder ran it) | `(cd ~/prwatch/test/sim2 && zsh tick-sim2.sh)` | 20 lines, as in the plan's Checks table. |
| T5 | Guard (builder ran it) | Run the **T5 command** below the table. | Just `done`. Any `MISMATCH` line is a failure. |
| T5b | Session lock-down | In the watcher window, ask it to: edit `bin/prwatch-tick.sh`; edit `config/settings.json`; run a subagent that fetches `https://api.github.com` with Python `urllib`; `cat ~/.ssh/id_ed25519.pub`; run `/code-review --post` and `/security-review` on the test PR. | Edits denied. Network error from the sandbox. The key read denied. Both skills refused or "unknown skill". If either review offers to post, stop and tell the builder. |
| T6 | Full dry run | `PRWATCH_ONLY_PR='ACT-Training/Vision#1803' PRWATCH_NOW=2026-09-29T10:00 ~/Desktop/PR\ Watcher.command` (with the test-mode export) | Council runs → notification when the question appears → choose **Comment only** → permission prompt (Yes) → "A Mac dialog … is opening" → dialog says "PR is MERGED - dry run" → **Post** → `dry-run.txt` in the archive's `post/`, state `skipped dry_run=1`, and no re-ask at later checks. |
| T7 | Question timeout | During a T6-style run, leave the question for 10 minutes. | State `awaiting_decision`; asked again at the next check. |
| T8 | Two windows | Launch twice (test mode), then look at the old window. | The old one notifies "please close" and stops. The new one carries on. |
| T9 | Close mid-review | Close the window while reviewers are running; relaunch. | The PR is re-queued with attempts +1. |
| T10 | First real PR | Normal launch on a day with a real request. | Exactly one review on GitHub, after your three steps. |
| T11 | Edited draft | After the question appears, edit `draft/review-body.md`, then answer without typing `edited`. | Post refuses (exit 8); the draft is re-frozen and you are asked again. |
| T12 | Dialog left open | At the post dialog, do nothing. | It closes itself after 14 minutes ("Timeout") → `awaiting_decision`. A permission prompt left 30 minutes → "Waiting on you" notification. |
| T12b | Slow Post | Leave the dialog 3 minutes, then click **Post**. | It posts (dry run). |
| T13 | Stopped early | First `rm -f ~/prwatch/test/state/stopped-* ~/prwatch/test/state/notify-throttle/error-session*`, then launch in test mode and type `/exit` around 13:00. | "Stopped before 16:00" notification; no more watchdog notifications. |
| T14 | Two PRs | As T6 but `PRWATCH_ONLY_PR='ACT-Training/Vision#1803,ACT-Training/Vision#1792'`. | PR A's notification arrives when A's question is on screen, before B's review starts. |
| T15 | Sandboxed tests (before the first live day) | After T2, run T6 and let the testing-build reviewer run. Then at the question type `run tests`. | `dotnet test` runs in the sandbox under both time zones; ng test runs or is recorded as could-not-run; `run tests` shows the "run outside the sandbox?" dialog. **If the sandboxed dotnet test can't run, tell the builder: automatic tests switch to "only when you type run tests".** |
| T16 | Title injection (builder ran the stub version) | Run the **T16 commands** below the table. | The notification shows the cleaned title as plain text; nothing runs. |
| T-CGEvent | Synthetic clicks | See the plan (§10). Only at a throwaway dialog and a throwaway permission prompt, never the real post dialog. | Both attempts fail. |

**Background-agent safety checks:** `~/prwatch/test/harness/run.sh` (offline, about 10 seconds, prints `N/N passed`), and `~/prwatch/test/harness/live-check.sh` (real Claude Code, about 3 minutes; run it after every Claude Code update). See `docs/fix-background-agents.md` in the repo.

**T5 command:**
```
while IFS=$'\t' read -r want c; do got=$(/usr/bin/jq -nc --arg c "$c" '{tool_input:{command:$c}}' | ~/prwatch/bin/prwatch-guard.sh >/dev/null 2>&1; print $?); [[ $got == $want ]] || print "MISMATCH ($got≠$want): $c"; done < ~/prwatch/test/guard-cases.txt; print done
```

**T16 commands** (with the test-mode export):
```
mkdir -p ~/prwatch/test/archive/x/input
print -r -- '{"title":"x\" & (do shell script \"id\") --"}' > ~/prwatch/test/archive/x/input/pr.json
jq --arg a ~/prwatch/test/archive/x '.prs["ACT-Training/Vision#1"]={status:"asking",archive:$a,recommendation:"comment",blockers:"0"}' ~/prwatch/test/state/state.json > ~/prwatch/test/state/s.tmp && mv ~/prwatch/test/state/s.tmp ~/prwatch/test/state/state.json
~/prwatch/bin/prwatch-notify.sh decision 'ACT-Training/Vision#1'
```

## Old Claude install (hygiene)
Remove the old root-owned Claude Code 1.0.128: `sudo /usr/local/bin/npm uninstall -g @anthropic-ai/claude-code`. The launcher already ignores it.
