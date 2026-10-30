# Security policy

The PR watcher reads pull requests, runs their tests in a sandbox and drafts reviews. Anything it posts goes out
under the user's own GitHub identity. That is why the rules below exist.

## What counts as a vulnerability

Report any of these:

- Content a pull request controls (code, commit messages, comments, PR text) causing the watcher to post anything.
- Anything running outside the sandbox it should be in.
- Any read of credentials: `~/.ssh`, `~/.config/gh`, `~/.netrc`, Keychains, `~/.composer`.
- Reaching the network from a review sandbox.
- Escaping the canonical-call rule (invariant 3 in `watcher/CLAUDE.md`): a watcher script called in any form other
  than `/Users/jack/prwatch/bin/prwatch-<name>.sh <plain args>`.
- Any way the model can call `gh`, `git push` or `osascript`.
- A scheduled prompt (a session cron, a hook, or text in a PR) posing as the user.
- The watcher loading a Parliament of Chaos install that differs from `watcher/config/parliament.lock`, running any
  `chaos:` command, dispatching a subagent other than `general-purpose` or the pinned grumpy reviewers, running
  `/code-review` with a posting or editing option, or a reviewer's memory changing while a session has it frozen.

These do not count:

- A wrong review. That is a quality problem, not a security one.
- A test the sandbox cannot run.
- The accepted risks listed in `docs/plan-v2.md` §8 ("Risks and accepted risks"), AR-1 to AR-10. There is no AR-4.

## How to report

This repository is private at the time of writing, so GitHub's "Report a vulnerability" button is not available
(GitHub offers private vulnerability reporting on public repositories only). Use one of these instead:

1. Email the address on [the maintainer's GitHub profile](https://github.com/JackScammell). Use this for anything
   that could be exploited.
2. Open an issue in this repository, using the bug report form, only for a report with no exploit detail in it.
   The repository is private, so an issue is seen only by its collaborators, but it is still not a private channel.

Include:

- the watcher commit you are running (`git rev-parse HEAD` in your checkout of this repository) and whether
  `install.sh` has been re-run since;
- `claude --version`;
- the `state/` entry for the PR concerned: its key and status only.

Never include PR contents, review text or credentials.

If this repository is ever made public, switch to GitHub's "Report a vulnerability" and add that link to
`.github/ISSUE_TEMPLATE/config.yml`.

## Supported versions

`main` only. There are no maintained release branches. The installed copy under `~/prwatch` must match `main`;
the offline harness (`watcher/test/harness/run.sh`) checks for drift between the two when `PRWATCH_REPO` points at
the repo's `watcher/` directory.

## What it does and does not do

- It never posts without the three steps: a choice typed in the console, the permission prompt, and the Mac dialog.
- The model never calls `gh`. All GitHub reads and the single write (`prwatch-post.sh`) live in `watcher/bin/*.sh`.
- Reviewers run in the foreground only. A reviewer found running in the background is treated as a harness fault
  and the review is abandoned (see `docs/fix-background-agents.md`).
- `state/` is written only by the watcher's own scripts and hooks, never by the model: `prwatch-state.sh`
  (`state.json`, `events.jsonl`), `prwatch-tick.sh` (seeds `state.json`, recreates `session.lock`), the launcher
  (`session.lock`), the hooks (`harness/` markers and log, `stopped-<session_id>`, `eod-done-<session_id>`, and the one-use request files under `stop/`, `pause/` and `repo/`),
  `prwatch-notify.sh` (`notify-throttle/`, `notify.log`), and the heartbeat `state/activity` touched by the hooks
  and the long-running scripts in `watcher/bin`. `state/` is in the sandbox `denyWrite` list and the Edit/Write
  deny rules.
- Hooks run with the user's permissions and run only scripts in this repository and `/usr/bin/touch`, except under
  the `parliament` engine: then the pinned Parliament of Chaos plugin's own hooks also run, outside the sandbox
  (accepted risk AR-1). That is why its whole install tree is pinned, its hooks get no webhook or data-directory
  variables, and the launcher refuses a plugin with a `.env` file beside its hooks.
- The watcher never updates itself, never installs or updates a plugin, and never fetches hook or reviewer code from
  elsewhere. A PR's own test run
  does restore packages inside the sandbox; that is accepted risk AR-5 in `docs/plan-v2.md`.
