# Raising the daily review cap for one day (`cap N`, 2026-09-30)

Jack can type `cap 8` in the watcher window to allow up to 8 councils today instead of the usual 6. The next day it
goes back to 6 by itself. Designed with a council (architecture, security, testing) and built from its ruling.

## What Jack sees
- Type `cap N` (N from 1 to 12) on its own. The window confirms it: "up to 8 reviews may start today (normally 6);
  3 started so far". A silent Mac notification says the same, and adds "If you didn't type cap 8, type stop".
- Anything else that starts with "cap" (`cap 13`, `cap 0`, `cap 8 please`) changes nothing, and the window says so.
- `status` and the end-of-day summary show "Reviews today: 3 of 8".
- Queued PRs start at the next check (within 15 minutes). A lower cap (for example `cap 3`) also works, and takes
  effect before the next council starts.

## Decisions
| Question | Ruling |
|---|---|
| One day or permanent? | One day only, stored as `cap_override[<date>]` in `state.json`. It lapses overnight, so nothing needs resetting. Changing the default of 6 is a code change (`CAP_DEFAULT` in `prwatch-tick.sh` and `prwatch-state.sh`) plus `install.sh`. No config file, so there is only one place a cap can come from. |
| `cap N` or `more N`? | `cap N`, an absolute number: repeating it changes nothing, whereas a repeated `more 2` would keep adding. |
| Ceiling | 12 (Jack, 2026-09-30). The start window is 08:00–15:29, and councils run 25–45 minutes one at a time. |
| `cap 0` | No (Jack): use `stop`. |
| Who may change it | Only Jack's own typed prompt. The model, PR text and reviewer hand-backs can't (see below). |
| Who enforces it | The scripts, not the model. |

## How it's enforced
1. **The prompt hook** (`bin/prwatch-prompthook.sh prompt`, UserPromptSubmit). Claude Code runs it on every prompt
   before the model sees it. If the whole prompt, trimmed, is `cap <digits>`, the hook writes
   `state/cap/request.json` `{session, n}`, runs `prwatch-state.sh cap N`, deletes the request, and prints one
   `PRWATCH CAP:` line (added to the model's context). Any other prompt: nothing printed or written, exit 0.
2. **`prwatch-state.sh cap N`** refuses unless the cap is 1–12 **and** a request exists for this session and this N
   and is under 60 seconds old. The model can call the script, but it can't write `state/` (sandbox `denyWrite` plus
   a permission deny), so it can't create the request. A call from the model always fails, and the CLAUDE.md
   command table tells it never to try. When it succeeds it writes the override, logs a `cap` event and notifies Jack.
3. **The CronCreate gate** (`bin/prwatch-prompthook.sh cron`, PreToolUse `CronCreate`). A session cron job's
   prompt might trigger UserPromptSubmit just like Jack's typing (the docs don't say either way), and the model
   was free to schedule anything. Now only `/prwatch-tick` at `*/15 8-15 * * 1-5` and `/prwatch-eod` at
   `3 16 * * 1-5` (recurring) can be scheduled. Anything else gets exit 2.
4. **Counting moved into prep.** Before this change the model called `prwatch-state.sh daily-inc` itself (review
   step 1.4) and compared the count with the cap in its head. So it could skip the count, and PR text only had to
   persuade it to carry on. Now `prwatch-prep.sh` calls `daily-inc` before doing anything else. `daily-inc` refuses
   (exit 65) when today's count has reached today's cap, and prep then exits 24 without creating an archive or
   touching the network. Every council needs prep's archive and worktree, so a council can't start without being
   counted. The review skill requeues the PR on exit 24, with no attempt charged. This also fixes an ordering bug:
   the PR used to be marked `reviewing` before it was counted.
5. **Lock.** `prwatch-state.sh` takes an exclusive `zsystem flock` on `state/state.lock` for every subcommand except
   `get`, so the check and the increment happen as one step. Without it, 10 parallel `daily-inc` calls left
   `state.json` **empty** (0 bytes) in 3 runs out of 3. With it, exactly 6 were counted.

`harness-abort` still refunds the slot it took, and the refund never touches the cap.

## Checked
- `.prompt` is the UserPromptSubmit input field, and plain stdout with exit 0 is added to the model's context
  (Claude Code hooks guide).
- The guard rejects any model call to the hook (`prwatch-prompthook.sh` isn't one of its canonical names), and
  rejects env-prefixed watcher calls (its regex has to start at `/Users/…`).
- **Not checked:** whether cron-fired prompts trigger UserPromptSubmit. The CronCreate gate makes that irrelevant.
- **Not checked:** whether a prompt typed during a review triggers the hook when typed or when delivered. Either
  way the hook applies the cap when it runs. If the model sees `cap N` without a `PRWATCH CAP:` line, it says the
  cap wasn't changed.

## Tests
`test/harness/run.sh`, "daily cap" section (59 new checks):
- the hook: prompts it accepts and ignores, and the out-of-range messages;
- every refusal in `cap`: no request, wrong session, wrong N, stale, reused, over 12, bad argument;
- `daily-inc` at the default and raised caps, another day's cap ignored, 10 parallel calls;
- prep: exit 24 with nothing done, counts first, other session, T2 with no session;
- tick JSON: `cap`, `cap_default`, `councils_today`, `cap_left`;
- the CronCreate gate, the settings, the guard, the defaults matching, and the skill and CLAUDE.md wording.

In a scratch `HOME`, the branch passed every new check except the two settings checks, which need the real
`/Users/jack/prwatch` paths. Those passed against the real paths. The failures that don't depend on this change
were the same 23 as on `main` in the same scratch setup. Removing the lock (mutation) fails the parallel check.
