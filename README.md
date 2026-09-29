# PR watcher

A Claude Code session that runs on your Mac between 08:00 and 16:00 on weekdays. Every 15 minutes it looks for
open ACT-Training pull requests where you are personally requested as reviewer, reviews each one with a council
of reviewer agents, and pings you with a macOS notification when a draft review is ready.

**Nothing is posted to GitHub until you pick an action in the console, approve the permission prompt, and click
Post on a Mac dialog.**

## Install / update

```zsh
git clone https://github.com/JackScammell/pr-watcher.git ~/Documents/GitHub/pr-watcher
~/Documents/GitHub/pr-watcher/install.sh
```

`install.sh` copies `watcher/` into `~/prwatch` (leaving its `state/`, `repos/`, `cache/`, `work/` alone) and
puts **PR Watcher.command** on your Desktop. Double-click it each morning.

Re-run `install.sh` after pulling changes, with the watcher closed. If you have locked `~/prwatch` (`chflags uchg`,
see `watcher/README.md`), unlock it first; `install.sh` refuses while it is locked. Afterwards run
`~/prwatch/test/harness/run.sh`, and after any Claude Code update run `~/prwatch/test/harness/live-check.sh`.

## Layout

| Path | What |
|---|---|
| `launcher/PR Watcher.command` | The double-click launcher (copied to the Desktop by `install.sh`) |
| `watcher/` | Everything that runs from `~/prwatch`: scripts, settings, skills, reviewer angles, tests |
| `watcher/README.md` | How to start, stop, pause; notification setup; day-1 test checklist; lock/unlock |
| `watcher/BUILD-NOTES.md` | Deviations from the plan found while building, with evidence |
| `docs/plan.md` | The council-approved plan (Revision 3.1) this was built from |
| `docs/fix-background-agents.md` | The 2026-09-29 background-reviewer incident: cause, fix, safety net, verification |
| `watcher/test/harness/` | `run.sh` (offline safety-net tests) and `live-check.sh` (real Claude Code check after updates) |

The runtime files live under `watcher/` so the watcher's own `CLAUDE.md` and skills don't load when you open
Claude Code in this repo to work on it.
