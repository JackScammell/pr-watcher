# Contributing

This is a small zsh tool with one maintainer. It runs on macOS today; a Windows port is planned in
`docs/windows-port.md`. The rules below exist because anything the watcher posts
goes out under the user's own GitHub identity, so a careless change has real consequences. Read `SECURITY.md`
and the "This Project" paragraph in `CODE_OF_CONDUCT.md` first.

## Where things live

| Path | What |
|---|---|
| `launcher/PR Watcher.command` | The double-click launcher. `install.sh` copies it to the Desktop. |
| `watcher/bin/` | The scripts. Every window, key and path check lives here. `prwatch-common.zsh` is sourced, not run: the window constants, the clock and the human time format. |
| `watcher/.claude/skills/` | The five skills the session runs (`prwatch-start`, `prwatch-tick`, `prwatch-review`, `prwatch-decide`, `prwatch-eod`). |
| `watcher/angles/` | The reviewer briefs, one per angle. |
| `watcher/config/` | `settings.json` (permissions, sandbox, hooks) and `gitconfig`. |
| `watcher/CLAUDE.md` | The standing rules the session reads: the invariants and Jack's commands. |
| `watcher/test/harness/` | `run.sh` (offline tests of the installed copy) and `live-check.sh` (real Claude Code). |
| `watcher/test/sim2/` | A scripted tick simulation with fixture JSON. |
| `docs/` | The council-approved plans and incident write-ups. Superseded documents go under `docs/history/`. |

`install.sh` copies `watcher/` to `~/prwatch`. The runtime files live under `watcher/` so the watcher's own
`CLAUDE.md` and skills do not load when you open Claude Code in this repo to work on it.

## The development loop

1. Edit in the repo.
2. Unlock the installed copy. The lock is a manual `chflags -R uchg` on `~/prwatch/{bin,shims,config,.claude,angles,CLAUDE.md}`;
   the unlock command (`chflags -R nouchg …`) is in `watcher/README.md`, "Locking the watcher's own files".
   `install.sh` refuses to run while the copy is locked.
3. `./install.sh`
4. `PRWATCH_REPO=$PWD/watcher ~/prwatch/test/harness/run.sh`
5. `~/prwatch/test/harness/live-check.sh` after any Claude Code update, or when hooks or the harness surface changed.
6. Re-lock with the `chflags -R uchg` command printed by `install.sh`.

`run.sh` tests the **installed** copy under `~/prwatch`, not the repo, and needs macOS. `PRWATCH_REPO` lets it
check that the installed copy matches the repo; without it that check is skipped visibly.

## Scripts decide, model obeys

Every count, window, key and path check lives in `watcher/bin/`. The skills and `watcher/CLAUDE.md` only repeat
what a script printed; they never work anything out for themselves. The harness asserts the prose against the
scripts, so a rule that only exists in prose fails the build. If you want new behaviour, put it in a script and have
the skill repeat the script's output.

## Prose sync

The launcher banner, `watcher/README.md` and the `prwatch-start` skill are asserted together by `run.sh`. Run
`run.sh` after each prose edit, not only at the end, so you find out which of the three you forgot while the edit is
still fresh.

## Pull requests

- Follow `.github/pull_request_template.md`.
- Plain-English summary first; the technical detail goes below it.
- No dates or merge windows in the body.
- One `CHANGELOG.md` entry per PR under each affected heading (Added, Changed, Removed) in `[Unreleased]`; sub-bullets allowed.
- Each PR changes code, prose and harness asserts together.

## Parliament re-pin cadence

Under `docs/plan-v2.md`, PR 4 adds a review-engine adapter that pins the Parliament of Chaos plugin by its whole
install tree (`config/parliament.lock`, D3). Once that lands, every Parliament of Chaos release needs a re-pin PR,
made by running `install.sh --repin` and committing the new lock. The `--repin` flag does not exist yet; this
paragraph is here so the cadence is written down before it is needed.

## Repository settings (convention)

These are settings, not code, so they are recorded here:

- Squash merges only.
- Delete-branch-on-merge off.
- Never merge on red CI.

## Licence

By contributing, you agree that your contributions will be licensed under the MIT licence in `LICENSE`.
