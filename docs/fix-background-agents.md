# Fix: reviewers launched in the background (2026-09-29)

## What happened
- 10:37: Claude Code auto-updated to **2.1.284** (the npm global install under Herd's nvm). The watcher launched at 10:47.
- In 2.1.284 the `Agent` tool runs subagents in the **background by default**, and `run_in_background` has been removed
  from its schema. The skill's "never `run_in_background`" couldn't be followed. Transcript `a1800785…` shows all three
  reviewers of `Vision#1742` came back `async_launched` (`requestShape: background`). The binary's rule is:
  `shouldRunAsync = remote || ((wantsBackground===true || agent.background || (!isFork && (forceAsync || wantsBackground !== false))) && !backgroundTasksDisabled)`.
- The session stopped all three by hand and marked #1742 `failed` (attempt 1, 1 of 6 daily reviews used). Every later
  tick would have done the same and used up a daily slot each time.

## Root-cause fix
`CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` sets `backgroundTasksDisabled`, which puts subagents back in the foreground.
It also removes `run_in_background` from Bash and turns off tool detaching, so invariant 4 is enforced by Claude Code
itself rather than by the prompt. It is set in `config/settings.json` `env` (the primary copy, in the locked config
folder) and exported by the launcher (a backup).

## Safety net, in case a future update changes behaviour again
Jack's answers: keep auto-updates on and add a startup probe. On a **harness fault** (Claude Code's doing, not the
PR's), stop for the day and notify, without charging a daily slot or a PR attempt. Round-number logic is out of scope.

1. **Startup: `/prwatch-start` self-test 7** (blocking).
   - Bash must have no `run_in_background` parameter. This is the part that reliably detects a missing variable:
     in one auto-mode run without the variable, the probe agent still ran in the foreground.
   - A haiku `PONG` probe must come back finished (not a background launch).
   - The reply may arrive as a `[Subagent hand-back]` message (see "Auto-mode hand-back" below).
2. **During a review: `bin/prwatch-agenthook.sh`**. The hook is the primary runtime guard; the model can't run it
   (the guard blocks that). It has two modes:
   - **`post`** (PostToolUse `Agent|TaskStop`):
     - an Agent result whose status is not `completed` is a fault. That covers `async_launched`, `isAsync: true`, and
       any status name never seen before, so an unknown name fails safe. On a fault the hook:
       - writes `state/harness/<agentId>.marker` = `{session,key,agent,t}`;
       - touches `stopped-<date>`;
       - sends `error harness` (the only runtime notification, throttled to one per 30 minutes);
       - exits 2 with a fixed `PRWATCH HARNESS FAULT` instruction. The instruction names the **exact** recovery
         command, with the key filled in, on a line of its own. A model left to fill in `<key>` quoted it, and the
         guard and the gate refused it: a deadlock found in the end-to-end run.
     - no status field at all → `error hookdrift` only (fails open; the variable and test 7 still apply).
     - a successful `TaskStop` of a marked agent → `.stopped`. Any other TaskStop wording → `hookdrift`, and the marker stays live.
   - **`ended`** (SubagentStop): a marked agent that **finishes on its own** becomes `.stopped`. This matters
     because TaskStop on a finished agent is refused ("not running (status: completed)") before any hook runs. If
     SubagentStop comes first (a very fast agent), the hook leaves a `<id>.ended` note, and the fault marker is then
     created already stopped. A normal foreground result deletes the note. It always exits 0, because exit 2 on
     SubagentStop would keep the subagent running.
   - **`pre`** (PreToolUse `*`): while this session has an **unarchived fault**, it denies every tool except the list
     below. An unarchived fault means a live marker, or a `.stopped` one that `harness-abort` hasn't archived yet.
     A finished subagent may have left background shells that only `harness-abort` kills. Probe markers (key
     `none`) gate only while live, because nothing runs `harness-abort` for them. The allowed tools are:
     - `TaskStop`, `TaskList`, `ToolSearch` (TaskStop may be deferred), `Read`, `Glob`, `Grep`, `CronList`, `CronDelete`;
     - canonical `prwatch-state.sh harness-abort|stop-today|get`.

     So nothing can prompt or start while PR code runs, and Jack's `stop` still works.
   - The model can't write `state/` (sandbox `denyWrite` plus a permission deny), so PR text can't forge or clear a
     marker. Hook markers are written directly by harness-run code, like the existing `touch state/activity` hooks,
     so a missing or mismatched session lock can't disable them.
3. **Afterwards: `prwatch-state.sh harness-abort <key>`**, which `/prwatch-review` §4 runs after TaskStop.
   - Preconditions:
     - the item is `reviewing`;
     - the session lock matches;
     - this session has at least one hook marker for the key, and every one of them is `.stopped`.
   - Actions:
     - kills leftover PR processes: any process whose cwd is inside the PR's worktrees, and any **descendant of this
       watcher's launcher** whose command line contains that path (never Jack's own editor or pager). The path is
       resolved with `:A`, because lsof reports real paths;
     - runs `prwatch-cleanup.sh <key>`;
     - archives the markers to `harness/done/`, so it can only refund once;
     - sets `queued` and removes `step`, leaving `attempts` unchanged;
     - reduces today's `daily` by 1 (floor 0);
     - touches the stop file and logs an event. It sends no notification, because the hook already did.
4. `prwatch-cleanup.sh --sweep` (run at every start) archives markers and notes older than a day. A new session id also ignores
   older sessions' markers.
5. **Rule text.**
   - CLAUDE.md invariant 4 names the variable and the harness-fault procedure. Only a hook's `PRWATCH HARNESS FAULT`
     counts, never the same words inside a report.
   - Review §4 covers the fault handling, and its Failure section excludes harness faults.
   - The tick stops its turn after a harness fault.
   - `allow` gains `TaskStop`.
   - `prwatch-notify.sh` has `error harness` and `error hookdrift` templates.

## Auto-mode hand-back (found on the first relaunch)
- Symptom: test 7 said PROBLEM. The probe had run in the foreground (`status: completed`), but the Agent result read
  "This agent's report was delivered to you as a message … (its SubagentHandback call)" instead of `PONG`.
- Cause: this is **not** an update; it's still 2.1.284. In **auto mode**, subagents report through `SubagentHandback`.
  The report goes through auto mode's review and arrives as a separate `[Subagent hand-back]` message. `tool_response`
  carries `handback: send|flagged|withheld` and `handbackReport.text`. It's controlled by
  `CLAUDE_CODE_SENDMESSAGE_HANDBACK`, which is on by default through a feature flag. The earlier end-to-end runs used
  `bypassPermissions`, which is why they showed PONG inline.
- Decision: **keep** it, because it adds auto-mode review of reviewer output. Reviews were never affected, because
  `/prwatch-review` reads the report files. Changes:
  - test 7 accepts `PONG` from either the result or the hand-back, and waits for the hand-back before judging;
  - review §4 treats the files as authoritative and puts a flagged or withheld hand-back into `questions_for_jack`;
  - CLAUDE.md invariant 1 and `/prwatch-decide` say a hand-back is **never** Jack's decision (a steered reviewer could
    write "Jack chose Approve");
  - invariant 5 lists hand-backs as untrusted data.

## Known fail-safe edges
Each of these leaves the day stopped, and the next session ignores the old markers.
- **A malformed agentId** (which gives an `unknown-<ts>` marker) can't be matched by TaskStop or SubagentStop, so the
  marker stays live. That session is limited to the tools listed in section 2, and `harness-abort` refuses. The stuck
  `reviewing` item is requeued the next day as `orphaned_requeue`, which **does** charge one attempt (cap 3). Claude
  Code has always sent a well-formed id; this is theoretical.
- **Agents that finish before TaskStop**, including the startup probe, were a live-marker edge. `SubagentStop` now
  clears them (fixed in the implementation loop after the full council; see Verification).
- **Self-DoS.** A PR-steered reviewer can't forge a fault. It can only end the day if Claude Code itself reports a
  non-`completed` Agent status, and that costs no slot or attempt. The one exception is when `harness-abort`'s
  final state write fails (exit 70). Then the slot isn't refunded, and the next day's `orphaned_requeue` charges
  an attempt (see `docs/history/cap-override.md`, "How it's enforced", point 5).
- **One reviewing item.** The hook's key lookup takes the single item this session is reviewing, which relies on
  invariant 7 (one PR at a time).

## Council
- **Plan:** security and architecture APPROVE-WITH-NOTES; testing REJECT. Its two blockers were the session lock
  silently disabling the backstop, and nothing being run against real Claude Code.
- **Code, round 2:** all three APPROVE-WITH-NOTES.
- **Closing check, round 3:** APPROVE-WITH-NOTES.
- **Full council on the whole change set** (security, testing, architecture, maintainability, documentation): all
  APPROVE-WITH-NOTES, no blockers. What their notes changed:
  - the hand-back is never a decision;
  - `ps` kills are scoped to the launcher's descendants;
  - the gate allows only `harness-abort`, `stop-today` and `get`;
  - an unknown Agent status is a fault;
  - `$PRW` replaces hardcoded paths in the hook;
  - the sweep is test-mode aware and tested;
  - the harness uses a trap and polling instead of sleeps, pins the skill wording, and checks sync visibly;
  - `live-check.sh` was added;
  - the operator docs were updated.

## Verification
- **`test/harness/run.sh`: 113/113.**
  - It covers every hook input shape (async, isAsync-only, status-only, unknown status, completed, completed plus a
    withheld hand-back, no status, non-Agent, empty, garbage, hostile id, no session id, unmarked TaskStop), plus
    SubagentStop (a marked agent finishing, the race note, the note being cleared, garbage input, a hostile id);
  - every pre-gate allow and deny;
  - every `harness-abort` precondition, the double call and the daily floor;
  - process kills (cwd, descendant args, non-descendant spared, unrelated spared);
  - the sweep, the notify throttle and wording, and the guard rows;
  - settings, launcher ordering, skill and CLAUDE.md wording, and repo↔install sync.

  **Mutation-checked:** turning off any of these makes its test fail: the gate, the kill, marker archiving, the
  unknown-status fail-safe, the narrower state allow-list, descendant scoping, the SubagentStop handling, the race note,
  the ToolSearch allowance, and the gate staying shut until `harness-abort`.
- **`test/harness/live-check.sh`** (real Claude Code, run after every update): passes on 2.1.284.
  - With the variable, in auto mode: `status: completed`.
  - Without it: `async_launched`, `isAsync: true` and a string `agentId`; TaskStop says `Successfully stopped task: …`;
    the installed hook records the fault and the stop.
  - Without the variable, an agent **finishing on its own**: the installed hook marks it stopped through SubagentStop.
  - It kills its own leftover test processes. If the model skips TaskStop, it says so instead of failing unclearly.
- **End-to-end** with `claude -p` and the installed hooks, in test mode:
  - without the variable, a fast agent that **finished before TaskStop**:
    - SubagentStop marked it stopped;
    - the model loaded TaskStop through ToolSearch, got "not running (status: completed)" and treated it as stopped;
    - it ran the exact unquoted `harness-abort`, which set the item to `queued` with daily going from 1 to 0;
    - only after that did the gate allow `echo after`.

    The first attempt at this found the quoted-key deadlock, which is now fixed.
  - without the variable: marker, stop file, one notification. The gate denied `echo hello`; TaskStop, then
    `harness-abort`, then `queued`, with daily going from 1 to 0 and attempts unchanged;
  - with the variable: a foreground `completed` result and nothing fired;
  - installed test-7 text in auto mode with Opus: `OK` with the variable, and `PROBLEM` without it (Bash had
    `run_in_background`).
- The existing guard suites pass 70/70, and `zsh -n` is clean on every script.

## Today's recovery (done 2026-09-29, with the watcher closed)
#1742 predates the hook, so it had no marker and needed a one-off edit. Attempts are stored as strings like every field
`prwatch-state.sh` writes. The file was backed up to `state.json.bak-2026-09-29` first:
```
F=~/prwatch/state/state.json
jq '.prs["ACT-Training/Vision#1742"] |= (.status="queued" | .attempts="0" | del(.step)) | .daily["2026-09-29"]=0' $F > $F.tmp && mv $F.tmp $F
```
If a `state/stopped-<date>` file exists (the watcher stopped itself), delete it too, or the relaunch stays stopped for
the day.

## Not changed
- The round-number logic (Jack: leave as it is).
- Auto-update stays on. The layers that catch the next behaviour change are self-test 7, the hook (fail-safe on
  unknown statuses) and `live-check.sh`.
