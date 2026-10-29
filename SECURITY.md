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

These do not count:

- A wrong review. That is a quality problem, not a security one.
- A test the sandbox cannot run.
- The accepted risks listed in `docs/plan-v2.md` §8 ("Risks and accepted risks"), AR-1 to AR-10.

## How to report

This repository is private at the time of writing, so GitHub's "Report a vulnerability" button is not available
(GitHub offers private vulnerability reporting on public repositories only). Use one of these instead:

1. Open an issue in this repository.
2. Email the address on the maintainer's GitHub profile: https://github.com/JackScammell.

Include:

- the watcher commit you are running (`git -C ~/Documents/GitHub/pr-watcher rev-parse HEAD`) and whether
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
- `state/` is written only by `prwatch-state.sh`, the launcher (`session.lock`), the hooks' `harness/` markers and
  the prompt hook's one-use request files.
- Hooks run with the user's permissions and only run scripts in this repository.
- Nothing is downloaded or executed from elsewhere.
