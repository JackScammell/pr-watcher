# Raising the daily review cap for one day (`cap N`, 2026-09-30)

Jack can type `cap 8` in the watcher window to allow up to 8 councils today instead of the usual 6. The next day it
goes back to 6 by itself. Designed with a council (architecture, security, testing), built from its ruling, then
reviewed by the full Parliament panel (round 1 notes applied in round 2).

## What Jack sees
- Type `cap N` (N from 1 to 12) on its own. The window confirms it: "up to 8 reviews may start today (normally 6);
  3 started so far". A silent Mac notification says the same, and adds "If you didn't type cap 8, type stop". Every
  change notifies, with no throttle, because the notification is the alarm for a change Jack didn't make.
- `cap 13`, `cap 0` or `cap 08` change nothing: the hook replies "not changed (the cap must be 1 to 12)". Anything
  else that isn't exactly `cap <digits>` (such as `cap 8 please`) never reaches the hook's logic. The model sees no
  `PRWATCH CAP:` line and, as `CLAUDE.md` tells it, says the cap wasn't changed.
- `status` and the end-of-day summary show "Reviews today: 3 of 8", read from `prwatch-state.sh today`.
- Queued PRs start at the next check (within 15 minutes). A lower cap (for example `cap 3`) also works, and takes
  effect before the next council starts.

## Decisions
| Question | Ruling |
|---|---|
| One day or permanent? | One day only, stored as `cap_override[<date>]` in `state.json`. It lapses overnight, so nothing needs resetting. The numbers are defined once, as `CAP_DEFAULT` and `CAP_MAX` in `prwatch-state.sh`. The tick, skills, `CLAUDE.md` and the hook read them through `prwatch-state.sh today` or the tick JSON. To change the default, edit that line and also the prose Jack reads: the launcher banner, the start skill banner and `watcher/README.md` (each is marked). The harness fails if the prose disagrees. Harness fixtures derive the numbers from the constants. Then run `install.sh`. There's no config file, so only one place defines a cap. |
| `cap N` or `more N`? | `cap N`, an absolute number: repeating it changes nothing, whereas a repeated `more 2` would keep adding. |
| Ceiling | 12 (Jack, 2026-09-30). The start window is 08:00–15:29, and councils run 25–45 minutes one at a time. |
| `cap 0` | No (Jack): use `stop`. |
| Who may change it | Only Jack's own typed prompt. The model, PR text and reviewer hand-backs can't (see below). |
| Who enforces it | The scripts, not the model. |

## How it's enforced
1. **The prompt hook** (`bin/prwatch-prompthook.sh prompt`, UserPromptSubmit).
   - Claude Code runs it on every prompt before the model sees it.
   - If the whole prompt, trimmed, is `cap <digits>` and this window holds the session lock, the hook writes
     `state/cap/request.json` `{session, n}`, runs `prwatch-state.sh cap N` (reading stdout only), deletes the
     request, and prints one `PRWATCH CAP:` line, which is added to the model's context.
   - Any other prompt: nothing printed or written, exit 0.
2. **`prwatch-state.sh cap N`** refuses (exit 64) unless the cap is 1–12 **and** a request exists for this session
   and this N and is at most 60 seconds old.
   - The model can call the script, but it can't write `state/` (sandbox `denyWrite` plus a permission deny), so it
     can't create the request. A call from the model always fails, and the `cap_refused` event records the attempt.
   - The `CLAUDE.md` command table tells the model never to try.
   - When it succeeds it writes the override and logs a `cap` event. It then unlocks, notifies Jack and prints
     `today`'s JSON.
3. **The scheduling gate** (`bin/prwatch-prompthook.sh sched`, PreToolUse, matcher `.*(Cron|Schedule|Wakeup|Trigger).*`).
   - A prompt that the session schedules for itself might trigger UserPromptSubmit just as Jack's typing does. The
     docs don't say either way.
   - Only `/prwatch-tick` at `*/15 8-15 * * 1-5` and `/prwatch-eod` at `3 16 * * 1-5` (recurring) may be created,
     and `CronList` and `CronDelete` are allowed.
   - Anything else is denied (exit 2): `ScheduleWakeup`, `RemoteTrigger`, and a renamed or new scheduling tool that
     matches the pattern. `ScheduleWakeup` and `RemoteTrigger` are also in `permissions.deny`, as are the `/loop`
     and `/schedule` skills.
4. **Counting moved into prep.**
   - Before this change the model called `prwatch-state.sh daily-inc` itself (review step 1.4) and compared the
     count with the cap in its head, so it could skip the count.
   - Now `prwatch-prep.sh` calls `daily-inc` before doing anything else, and `daily-inc` refuses (exit 65) when
     today's count has reached today's cap. Prep then exits 24 without creating an archive or touching the network,
     and the review skill requeues the PR with no attempt charged.
   - A council's archive and worktrees come only from prep, so a council the skill starts is always counted.
   - **Not enforced:** a model ignoring its skill could re-run reviewers against an *earlier* archive without
     calling prep. That costs money but can't raise the cap or post anything (posting still needs Jack). The
     scripts don't try to stop it.
   - Unchanged: the PR is still marked `reviewing` just before prep. Exit 24 or 26 puts it back to `queued`, so it
     is never stranded.
5. **Lock.**
   - `prwatch-state.sh` takes an exclusive `zsystem flock` on `state/state.lock` before any `state.json` write.
     `daily-inc` holds it across its check and increment.
   - It is released before slow side effects: notifications (osascript) after `set` and `cap`. `harness-abort`
     kills PR processes and cleans up the worktrees first, and locks only for its final requeue and refund. It
     archives its fault markers only after that write succeeds. A busy lock (75) is re-run by the review skill
     (up to twice). A failed write (70) also keeps the markers, but the skill stops and tells Jack. The hook has
     already stopped the day. On this path today's slot is **not** refunded. If `state.json` was only
     unwritable, tomorrow's tick treats the PR like any orphaned review, and the sweep archives the old markers, as
     in `docs/fix-background-agents.md`. The PR is either:
     - requeued as `orphaned_requeue`, which charges one attempt (harness-tested);
     - sent to `needs_jack` after 3 attempts;
     - or, for a very large PR with no go-ahead, turned into the go-ahead question. If it is corrupt, the tick instead stops
     with `state_unreadable` (point 6) until it is repaired.
   - Without the lock, 10 parallel `daily-inc` calls left `state.json` **empty** (0 bytes) in 3 runs out of 3.
     With it, exactly 6 were counted and the file stayed valid.
   - A writer waits up to 10 seconds, then exits 75 ("state busy").
6. **Unreadable state is loud.** `today` uses `jq -e` and type checks.
   - An empty or corrupt `state.json` gives exit 70, never "0 of 0, cap reached".
   - Prep then fails visibly (exit 25, and after 3 attempts Jack is asked).
   - The tick stops with `error state_unreadable` and a notification.

When its write succeeds, `harness-abort` still refunds the slot it took (not on exit 70; see point 5), and the
refund never touches the cap.

## Exit codes
| Code | From | Meaning | What happens |
|---|---|---|---|
| 5 | state.sh | this window no longer holds the session lock | prep → 25 |
| 64 | state.sh | bad argument, or `cap` without a valid request; `harness-abort`: PR not `reviewing` | the hook tells Jack "not changed (…)"; `harness-abort` keeps its markers, so the session stays locked by design (review §4: relaunch tomorrow) |
| 65 | state.sh `daily-inc` | today's cap is used up | prep → 24 |
| 70 | state.sh `today` / `daily-inc` / `harness-abort` | `state.json` empty, corrupt or not writable | prep → 25; tick → `error state_unreadable`; `harness-abort` keeps its markers, no refund; not retried automatically (the skill stops and tells Jack) |
| 75 | state.sh | lock still held after 10 s | prep → 26; `harness-abort` keeps its markers and the review skill runs it again |
| 20–22, 64 | prep | clone, base lookup or fetch failed; bad arguments | review: `failed`, attempt +1 (unchanged) |
| 23 | prep | head moved | review: `queued` (unchanged) |
| 24 | prep | cap used up; nothing done | review: `queued`, no attempt; tick starts no more this turn |
| 25 | prep | the count failed (5 or 70) | review: `failed`, attempt +1 (visible) |
| 26 | prep | state busy; nothing done | review: `queued`, no attempt; tick starts no more this turn |

## Checked
- `.prompt` is the UserPromptSubmit input field, and plain stdout with exit 0 is added to the model's context
  (Claude Code hooks guide).
- The `CronCreate` input fields (`cron`, `prompt`, `recurring`, `durable`) are taken from the tool's schema in
  Claude Code 2.1.x. They haven't been seen in a live hook payload yet. If they differed, the gate would refuse the
  real jobs (it fails closed), and `/prwatch-start` would print `PROBLEM: could not schedule the checks`. T0/T17
  catch that before a live day.
- The guard rejects any model call to the hook (`prwatch-prompthook.sh` isn't one of its canonical names). It also
  rejects env-prefixed watcher calls, because its regex has to start at `/Users/…`.
- **Not checked:** whether scheduled prompts trigger UserPromptSubmit. The scheduling gate makes that irrelevant for
  every tool it matches.
- **Not checked:** whether a prompt typed during a review triggers the hook when typed or when delivered. Either way
  the hook applies the cap when it runs.

## Deferred and deliberate limits
- A slot is spent when prep fails after counting (head moved, clone error). `daily-inc` ran before prep before this
  change too. A refund would need a new "un-count" subcommand, and the model could call that to lift its own limit.
  So it is left out deliberately.
- `test/guard-cases.txt` and `test/sec/guard-cases.tsv` are identical copies. Both get the new cases.
- `daily` and `cap_override` gain one small key a day. That is negligible for years.
- Refused `cap` calls each add a `cap_refused` line to `events.jsonl`. They are not coalesced, because that line is
  the audit trail for exactly the behaviour (the model trying to raise its own cap) that should stand out.
- Prep's heartbeat stays in `~/prwatch/state/activity` in test mode, because the launcher's watchdog reads it there
  during T6-style runs. Harness runs therefore refresh the live heartbeat. That is harmless: it only postpones a
  "stuck" notification.
- The scheduling gate matches tool names containing Cron, Schedule, Wakeup or Trigger. A future scheduling tool
  with none of those words would need adding to the matcher (check the Claude Code release notes when updating).

## Tests
`test/harness/run.sh`, "daily cap" section:
- the hook: prompts it accepts and ignores (including whitespace-only, non-string and garbage input), exit 0 with
  no output for each, the out-of-range messages, and the wrong-window refusal;
- every refusal in `cap`, each with its exact exit code: no request, other session's request, other session's
  caller, wrong N, 2 minutes old (a 30-second-old request is accepted), reused, above the max, bad argument;
- the `cap_refused` event, and notification on every change;
- `daily-inc` at the default and raised caps, another day's cap ignored, parallel calls (default + 4) with a valid
  file afterwards, lock held elsewhere (75), a short wait, and empty or corrupt state (70);
- `today`, and `today` without a session;
- `harness-abort`: a busy lock (75) and a failed write (70) both keep the markers, and a retry then succeeds;
- prep's exits 24, 25 (other session, unreadable state) and 26, counting first, and T2 with no session;
- tick JSON (`cap`, `cap_default`, `cap_max`, `councils_today`, `cap_left`), the unreadable-state error, and
  `stop-today` on the test day;
- the scheduling gate, including the two jobs parsed from the start skill;
- settings, the guard, one definition of the numbers (read and range-checked before any cap test), the prose
  matching them, and no literal cap in model-facing text. Test numbers derive from `CAP_DEFAULT` and `CAP_MAX`.

In a scratch `HOME`, every new check passes except the two settings checks, which need the real
`/Users/jack/prwatch` paths. Those pass against the real paths. The only other failures are the same 23 as on
`main` in that setup. Removing the lock (mutation) fails the parallel check.
