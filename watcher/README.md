# PR Watcher — how to use it

The PR Watcher keeps an eye on GitHub for open pull requests, in any organisation your GitHub login can see, where someone has asked **you personally** to review. For each one it makes a private copy of the code, has a panel of AI reviewers look at it, and then asks you in the window what to post. **Nothing is ever posted unless you pick the action, approve the permission prompt, and click Post on a Mac dialog.**

## Daily use

**Start:** double-click **PR Watcher** on your Desktop (`~/Desktop/PR Watcher.command`). A Terminal window opens. The session runs for 8 hours from that moment, checking every 15 minutes; the banner shows when it ends.
- New reviews only **start** in the first 7½ hours. After that it still asks you about finished drafts until the 8 hours are up, then prints a session summary and finishes. Anything requested after the cut-off is reviewed at the next launch.
- Draft PRs are skipped.
- Laravel repos (attendance, auth) get a read-only review. Their tests are not run, and the screen says `Tests: NOT run (Laravel — Flux Pro credentials)`.

**While a review is running** (usually 25–45 minutes) the window is busy. Anything you type waits until the review finishes. Press **Esc** to stop that review; the next check starts it again.

**Commands you can type in the window:**
| Type | What happens |
|---|---|
| `d` | Ask me about waiting drafts now |
| `status` | One line per PR being tracked, then one line for the session: when it started, when new reviews stop starting, when it ends |
| `pause 60` | Skip checks for 60 minutes (1 to 480). Type it on its own; the window confirms with a `PRWATCH PAUSE:` line |
| `stop` | Finish the session early: no more checks or reviews. Type it on its own; the window confirms with a `PRWATCH STOP:` line. Then type `/exit` to close the window |
| `allow <owner>/<repo>` | Let the watcher review pull requests from a repo it has not seen before. The window confirms with a `PRWATCH REPO:` line; the repo's pull requests are picked up at the next check. Case does not matter (the repo is stored lower-cased; the reply echoes what you typed) |
| `block <owner>/<repo>` | Ignore that repo's pull requests. Any of its pull requests already being tracked is withdrawn at the next check. The window confirms with a `PRWATCH REPO:` line. Case does not matter |

**At every permission prompt choose "Yes". Never choose "Yes, and don't ask again".**

**Closing the window** is safe. Unfinished reviews carry on at the next launch.

**The first pull request from a repo the watcher has not seen** is not fetched. The check sends one `newrepo` notification per such repo ("First pull request from a repository the watcher has not seen. In Terminal, type allow or block, then owner/repo.") and prints `First PR from <owner>/<repo> by <author>: type allow <owner>/<repo> or block <owner>/<repo>` once per repo per check, even when several of its pull requests are waiting; the line repeats at every check until you type one of the two. A repo with no `repos` entry but a tracked pull request counts as allowed and is recorded as `allowed` the first time a new pull request of that repo is queued. Once blocked, that repo's pull requests are ignored and any already tracked is withdrawn at the next check; `allow` it later to change your mind. If a check's search comes back with exactly 100 pull requests it is treated as partial: nothing is withdrawn for being missing from the search that check (a pull request of a blocked repo that does appear in the search is still withdrawn), and the window prints `search truncated at 100; nothing withdrawn this check`. The search is sorted by most recently updated, so the newest requests survive truncation.

**If something goes wrong** you get a Mac notification: GitHub login expired, the watcher stopped before the end of its session, or nothing has happened for 30 minutes (usually a prompt or dialog waiting for you).

**Reviewer memory left frozen.** Under the Parliament engine the launcher freezes the memory folders of the ten Parliament reviewers the watcher can dispatch (`~/.claude/agent-memory/chaos-grumpy-<name>`, the names in `GRUMPS`; other `chaos-grumpy-*` folders are never touched) and the copy of the plugin it runs from (`~/prwatch/cache/parliament-<hash>`) for the session, and unfreezes them when the window closes. If the window was killed without closing properly, the next launch unfreezes the folders its lock lists and says so. To unfreeze without launching, close every watcher window and run `~/Documents/GitHub/pr-watcher/install.sh --thaw` in Terminal: it unfreezes the folders the last session's lock lists and the plugin copies, and refuses while a watcher window is still running. A folder it does not list (or with no lock left at all) can be unfrozen by hand: `chflags -R nouchg <folder>`.

**"Reviewers ran in the background"** means Claude Code ran the reviewers in the background instead of the foreground, usually after a Claude Code update. It is a **harness fault**; nothing is wrong with the PR. The watcher stops the reviewers, puts the PR back in the queue, and stops for the rest of the session. Don't restart it straight away. Instead:
1. run `claude --version`;
2. check that `~/prwatch/config/settings.json` still has `"CLAUDE_CODE_DISABLE_BACKGROUND_TASKS": "1"` under `env`;
3. run `~/prwatch/test/harness/live-check.sh`.

If the live check passes, relaunch (the stop marker belongs to the old session; a new launch is a new session, and old markers are swept after two days). If it fails, ask Claude to look at it. The same applies if self-test 7 says `PROBLEM` at launch.

**"Claude Code changed how it reports subagents"** (hookdrift) means the background check may not recognise what Claude Code now sends back. The watcher keeps running. Run `~/prwatch/test/harness/live-check.sh` before relying on it.

**Tests run automatically.** The testing reviewer runs the PR's .NET, Python and Angular tests itself, in sandboxes. Angular uses `prwatch-ngtest.sh`, which needs Puppeteer's headless Chrome (`~/.cache/puppeteer/chrome-headless-shell`). If that folder is ever missing, install it once with `npx @puppeteer/browsers install chrome-headless-shell`. Test projects that would connect to a real local database are skipped and listed under "NOT run". See `BUILD-NOTES.md` → "Sandbox limits for PR tests".

**After every Claude Code update** run `~/prwatch/test/harness/live-check.sh` (5 to 10 minutes, about 15 model runs; the review-engine checks start reviewer subagents of their own). It checks the behaviour the watcher's safety checks depend on. Close every watcher window and unlock `~/prwatch` first (README "Lock"): it briefly freezes and then unfreezes the real reviewer memory folders, which would unfreeze a running window's, and it writes `config/engine-fallback.json`.

## Review engines

The panel that reads each pull request is chosen by the launcher **when you double-click it**, and printed as an `Engine:` line. The watcher never installs anything and never switches engine during a session: install or change something, then relaunch.

| Engine | When | Who reviews |
|---|---|---|
| `parliament` | The Parliament of Chaos plugin is installed **exactly** as pinned in `config/parliament.lock` (every file of its install folder hashes the same). The session runs from a locked copy of it in `~/prwatch/cache/`, checked again after copying | Parliament's grumpy reviewers, picked per pull request by size and what changed (security and correctness always), plus the watcher's `claims` and `testing-build` reviewers |
| `builtin` | Otherwise (not installed, not pinned, changed since the pin, or `PRWATCH_ENGINE=builtin`) | Claude Code's own `/code-review`, plus the watcher's security, backend-data, frontend, `claims` and `testing-build` reviewers |
| `builtin-agent` | Instead of `builtin`, when `live-check.sh` found that `/code-review` cannot review a worktree on this Claude Code version (`config/engine-fallback.json`) | One general reviewer (`angles/default-review.md`) in place of `/code-review`; the rest as `builtin` |

- **To use Parliament:** read the plugin's `SECURITY.md` first, then install it yourself and relaunch:
  ```
  claude plugin marketplace add https://github.com/JackScammell/Parliament-Of-Chaos.git
  claude plugin install chaos@chaos
  ```
  Then pin it: `~/Documents/GitHub/pr-watcher/install.sh --repin` (it writes `watcher/config/parliament.lock` and reinstalls; commit the lock). The launcher prints these lines whenever the plugin is not installed, unless you forced `builtin` with `PRWATCH_ENGINE`.
- **After a Parliament update** the launcher says `Parliament <new> is installed but the watcher is pinned to <old>` (or, when only files changed, `Parliament <version>'s files differ from the pin`) and uses `builtin` until you read the plugin's changes and run `~/Documents/GitHub/pr-watcher/install.sh --repin` again. Its hooks run outside the watcher's sandbox, which is why every file is pinned.
- **To force the built-in review** for one session: `PRWATCH_ENGINE=builtin ~/Desktop/PR\ Watcher.command` in Terminal. This always gives `builtin` (never `builtin-agent`). Do this if the start-up self-test says the Parliament engine is not usable.
- If `live-check.sh` finds Parliament writing where it should not, it records `parliament_blocked` in `config/engine-fallback.json`; the launcher then uses `builtin` until a later `live-check.sh` passes or you delete that file (unlock `~/prwatch/config` first) after re-reading and re-pinning the plugin.
- A `/code-review --comment` (or any `/chaos:` command) that **you type** at the prompt is your own act and bypasses the watcher's checks; the watcher itself only ever runs `/code-review` at low, medium or high effort on one of its worktrees, and never with a posting option.

Reviews and drafts are kept in `~/Documents/vision-reviews/<date>-<owner>-<repo>-pr<N>-round<k>/` (owner and repo in lower case).

**Key format.** Every pull request is named by its key `<owner>/<repo>#<n>`, for example `ACT-Training/Vision#1803`: owner is 1–39 letters, digits or hyphens (no hyphen at either end), repo is 1–100 letters, digits, `.`, `_` or `-` (not starting with `.` or `-`), and `n` has no leading zero and at most 7 digits. Every script takes the whole key. Clones and private copies carry the owner too: `~/prwatch/repos/<owner>__<repo>` and `~/prwatch/work/<owner>__<repo>-pr<n>-<sha7>`, so two owners with a repo of the same name never collide.

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
chflags -R uchg ~/prwatch/bin ~/prwatch/shims ~/prwatch/config ~/prwatch/.claude ~/prwatch/angles ~/prwatch/CLAUDE.md
```

To change something later, unlock, edit, then lock again:

```
chflags -R nouchg ~/prwatch/bin ~/prwatch/shims ~/prwatch/config ~/prwatch/.claude ~/prwatch/angles ~/prwatch/CLAUDE.md
```

Because `.claude` is locked, "Yes, and don't ask again" at a permission prompt would fail anyway. That's another reason to always choose plain "Yes".

## Laravel repos and tests

Laravel repos (attendance, auth) are **read-only reviews for now**. Their packages include Flux Pro, which needs your licence key to download, and the watcher deliberately never sees it.

Running Laravel tests automatically would need the watcher to pass your Flux licence key into the dependency download. **Turning this on lets a PR's code see your Flux licence key during the dependency download.** The builder did **not** add this switch: the change was blocked as a security weakening during the build (see `BUILD-NOTES.md`). If you want it, it needs your explicit go-ahead and a separate change.

Your Flux key in `~/.composer` is blocked from the watcher's AI session and its sandboxed test runs.

## Day-1 test checklist

All tests use test mode so nothing touches your real state or `~/Documents/vision-reviews`. The test PR is `ACT-Training/Vision#1803` (already merged), head `7458ff7f6973c8a0bc988b88a1816abcd01068e8`. Posting in test mode is always a dry run: nothing is sent to GitHub.

The session window counts from the `started_epoch` the launcher writes into `session.lock`, so the tests can run at any time. `PRWATCH_NOW` (epoch seconds, or `YYYY-MM-DDTHH:MM` local time) moves only the scripts' clock, not the 15-minute timer or the watchdog.

The launcher takes your GitHub login from `gh api user` and passes it to the scripts as `PRWATCH_LOGIN`. If you run a check from a Terminal instead (`~/prwatch/bin/prwatch-tick.sh`, with or without `--dry-run`), put `PRWATCH_LOGIN=$(gh api user --jq .login)` in front of it; without it the tick prints `{"status":"error","kind":"no_login"}` and does nothing. `prwatch-tick.sh --window` does not need it. The launcher also prints a `Signed in as <login>. Organisations your login can see: …` line; that is information only, not a gate — what gets reviewed is decided by `allow`/`block` and the tracked keys.

Paste this first in any Terminal you use for tests:
```
export PRWATCH_TESTMODE=1 PRWATCH_STATE_DIR=~/prwatch/test/state PRWATCH_ARCHIVE_DIR=~/prwatch/test/archive
```

| # | Test | What to do | Expected |
|---|---|---|---|
| T0 | First launch | Double-click **PR Watcher** on the Desktop (install steps are done). | The window prints `claude: … (2.1.x …)`. A one-time "trust this folder" prompt. The self-test lines say: sandbox on, auto mode, opus, no MCP servers, no PermissionRequest hooks, security-review/schedule/loop absent, an `Engine:` line (and in the window banner the same engine), and (test 7) foreground subagents OK: Bash has no `run_in_background`, and the `PONG` probe replied, usually through a `[Subagent hand-back]` message; then 7b (Parliament: the grumpy probe replied `PONG` and `chaos:list-commands` was refused) or 7c (builtin: `/code-review low` on the self-test worktree returned in the foreground and posted nothing). Then type `stop`, then `/exit`. |
| T1 | Notifications (run twice: Alerts, then Banners) | `~/prwatch/bin/prwatch-notify.sh test x` (in a Terminal **without** the test-mode export) | A notification with the Glass sound. `tail -1 ~/prwatch/state/notify.log` shows `test x :: Test notification…`. Keep the style you prefer. |
| T2 | Prep on the test PR (already run by the builder, see BUILD-NOTES) | Prep refuses with `repo not allowed` (exit 25) unless the test state allows the repo, so seed `repos` first: run `~/prwatch/bin/prwatch-state.sh check` (it creates `state.json` if it does not exist), then `jq '.repos["ACT-Training/Vision"]="allowed"' ~/prwatch/test/state/state.json > ~/prwatch/test/state/s.tmp && mv ~/prwatch/test/state/s.tmp ~/prwatch/test/state/state.json` (the same shape as the T16 command). A bare Terminal dry run in test mode has no session id, so prep is not gated by the window: `~/prwatch/bin/prwatch-prep.sh ACT-Training/Vision#1803 7458ff7f6973c8a0bc988b88a1816abcd01068e8 1`. For T3 (and any `--window` call) create the lock the launcher would write: `jq -n --argjson e $(date +%s) '{session_id:"terminal",pid:1,started_epoch:$e}' > ~/prwatch/test/state/session.lock` | Prints an archive folder under `~/prwatch/test/archive`. `prebuild.log` there shows `Restored …api/…csproj` and `added N packages`, and no `MSB1025`/`MSB1003`/`command not found`. Under a real session, prep refuses with `window closed for new reviews` (exit 27) once 7½ hours have passed, and with `no session start` (exit 25) if the lock has no `started_epoch`; under a session it also refuses with `no login` (exit 25) if `PRWATCH_LOGIN` is missing, and in any mode with `repo not allowed` (exit 25) if the repo is blocked or has neither an `allowed` entry nor a tracked key. |
| T3 | Window times (builder ran it) | With the T2 lock in place: `e=$(jq -r .started_epoch ~/prwatch/test/state/session.lock); for o in 0 26999 27000 28799 28800; do PRWATCH_NOW=$((e+o)) ~/prwatch/bin/prwatch-tick.sh --window; done` | `in_window`, `in_window`, `start_closed`, `start_closed`, `session_over` — the cut-offs are 7½ hours (27000 s) and 8 hours (28800 s) after `started_epoch`. Each line also shows `started`, `starts_until` and `ends_at`. |
| T4 | Design check (builder ran it) | `(cd ~/prwatch/test/sim2 && zsh tick-sim2.sh)` | 22 lines, matching `~/prwatch/test/sim2/expected.txt` (the last two are the `new_repo` row and the second owner's `#10`). |
| T5 | Guard (builder ran it) | Run the **T5 command** below the table. | Just `done`. Any `MISMATCH` line is a failure. |
| T5b | Session lock-down (once per engine: a normal launch, then `PRWATCH_ENGINE=builtin`) | In the watcher window, ask it to: edit `bin/prwatch-tick.sh`; edit `config/settings.json`; run a subagent that fetches `https://api.github.com` with Python `urllib`; `cat ~/.ssh/id_ed25519.pub`; run `code-review --comment` on a worktree, `code-review high ~/prwatch/bin`, and `security-review` (ask it to call them, do not type them yourself); run `chaos:parliament-loop`; start a `chaos:senior-council` agent; run `claude plugin list`. | Edits denied. Network error from the sandbox. The key read denied. Every skill and agent refused (`prwatch skill gate`, `prwatch:` or a permission deny), and `claude plugin` refused by the guard. If anything offers to post, stop and tell the builder. |
| T6 | Full dry run | `PRWATCH_ONLY_PR='ACT-Training/Vision#1803' ~/Desktop/PR\ Watcher.command` (with the test-mode export; no `PRWATCH_NOW` — the window counts from the launch) | On a fresh test state the first check prints `First PR from ACT-Training/Vision by stub: type allow ACT-Training/Vision or block ACT-Training/Vision` and reviews nothing (the author shows as `stub` unless `PRWATCH_ONLY_AUTHOR` is set); type `allow ACT-Training/Vision` first. Then: council runs → notification when the question appears → choose **Comment only** → permission prompt (Yes) → "A Mac dialog … is opening" → dialog says "PR is MERGED - dry run" → **Post** → `dry-run.txt` in the archive's `post/`, state `skipped dry_run=1`, and no re-ask at later checks. |
| T7 | Question timeout | During a T6-style run, leave the question for 10 minutes. | State `awaiting_decision`; asked again at the next check. |
| T8 | Two windows | Launch twice (test mode), then look at the old window. | The old one notifies "please close" and stops. The new one carries on. |
| T9 | Close mid-review | Close the window while reviewers are running; relaunch. | The PR is re-queued with attempts +1. |
| T10 | First real PR | Normal launch on a day with a real request. | Exactly one review on GitHub, after your three steps. |
| T11 | Edited draft | After the question appears, edit `draft/review-body.md`, then answer without typing `edited`. | Post refuses (exit 8); the draft is re-frozen and you are asked again. |
| T12 | Dialog left open | At the post dialog, do nothing. | It closes itself after 14 minutes ("Timeout") → `awaiting_decision`. A permission prompt left 30 minutes → "Waiting on you" notification. |
| T12b | Slow Post | Leave the dialog 3 minutes, then click **Post**. | It posts (dry run). |
| T13 | Stopped early | First `rm -f ~/prwatch/test/state/notify-throttle/error-session*`, then launch in test mode and, a few minutes in, type `/exit` without typing `stop` first. | "Stopped before the end of its session" notification; no more watchdog notifications. (Typing `stop` first gives no notification: that is a deliberate stop.) |
| T14 | Two PRs | As T6 but `PRWATCH_ONLY_PR='ACT-Training/Vision#1803,ACT-Training/Vision#1792'`. Then once more with two owners, e.g. `PRWATCH_ONLY_PR='ACT-Training/Vision#1803,JackScammell/pr-watcher#1'` (`JackScammell/pr-watcher#1` stands for any pull request in a repo of another owner: `PRWATCH_ONLY_PR` feeds the key straight to the check, so it does not have to be open or request you; the author shows as `stub` unless `PRWATCH_ONLY_AUTHOR=<login>` is set). On a fresh test state `allow ACT-Training/Vision` first, as in T6. | PR A's notification arrives when A's question is on screen, before B's review starts. With two owners: the first check prints `First PR from JackScammell/pr-watcher by <author>: type allow JackScammell/pr-watcher or block JackScammell/pr-watcher` (`<author>` is `stub` or your `PRWATCH_ONLY_AUTHOR`) and asks nothing; type `allow JackScammell/pr-watcher` (any case), the window replies `PRWATCH REPO: JackScammell/pr-watcher allowed - its pull requests will be picked up at the next check.`, and the next check reviews it in its own `work/JackScammell__pr-watcher-pr1-<sha7>` folder (`<owner>__<repo>`), with an archive folder `<date>-jackscammell-pr-watcher-pr1-round1`. |
| T15 | Sandboxed tests (before the first live day) | After T2, run T6 and let the testing-build reviewer run. Then at the question type `run tests`. | `dotnet test` runs in the sandbox under both time zones; ng test runs or is recorded as could-not-run; `run tests` shows the "run outside the sandbox?" dialog. **If the sandboxed dotnet test can't run, tell the builder: automatic tests switch to "only when you type run tests".** |
| T16 | Title injection (builder ran the stub version) | Run the **T16 commands** below the table. | The notification shows the cleaned title as plain text; nothing runs. |
| T17 | Engine choice | (a) With Parliament installed and pinned, launch normally. (b) Launch with `PRWATCH_ENGINE=builtin ~/Desktop/PR\ Watcher.command`. (c) Change one byte in any file under the plugin's install folder (or install a newer version) and launch. Each time, `stop` then `/exit`. | (a) `Engine: parliament <pinned version> (Parliament of Chaos reviewers)`, self-test 7b OK; `ls -lO ~/.claude/agent-memory/` shows `uchg` on the ten reviewers' `chaos-grumpy-*` folders while it runs and not after it closes. (b) `Engine: builtin (Claude Code's /code-review). Why: forced by PRWATCH_ENGINE=builtin.`, self-test 7c OK, no freeze. (c) `Parliament <pinned version>'s files differ from the pin. … then run: ~/Documents/GitHub/pr-watcher/install.sh --repin` (or, for a newer version, `… is installed but the watcher is pinned to <pinned version>`) and `Engine: builtin`. Undo the byte (or run `--repin`) afterwards. |
| T-CGEvent | Synthetic clicks | See the plan (§10). Only at a throwaway dialog and a throwaway permission prompt, never the real post dialog. | Both attempts fail. |

**Background-agent safety checks:** `~/prwatch/test/harness/run.sh` (offline, about 10 seconds, prints `N/N passed`), and `~/prwatch/test/harness/live-check.sh` (real Claude Code, 5 to 10 minutes; run it after every Claude Code update, with every watcher window closed and `~/prwatch` unlocked). See `docs/fix-background-agents.md` in the repo.

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
