# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Repository files: licence, code of conduct, security policy, contributing guide, changelog, issue and PR templates, Dependabot, editorconfig; the `check` workflow (syntax on Ubuntu, harness on macOS); the committed sim2 expected table; and `.gitignore` entries for Claude Code's per-repo worktrees and agent memory.
- The 8-hour session window: the launcher records `started_epoch` in `session.lock`; `prwatch-tick.sh --window` is a pure read that reports `in_window`, `start_closed` or `session_over` (with `started`, `elapsed_min`, `starts_until`, `ends_at`); new reviews start only in the first 7½ hours and `prwatch-prep.sh` refuses with exit 27 after that. The constants and the clock helpers live in `watcher/bin/prwatch-common.zsh`.
- `stop` and `pause N` are handled by the prompt hook with a one-use request file, so only Jack typing at the prompt can stop or pause a session; the model repeats the hook's `PRWATCH STOP:` / `PRWATCH PAUSE:` line.
- `prwatch-state.sh check` (read-only state check) and `eod-done` (the session's posted / waiting / not started / failed counts, once per session).
- The session summary runs from the tick once the 8 hours are up; the tick skill then removes the one cron job and prints "Session finished".

### Changed

- `docs/cap-override.md` moved to `docs/history/`; the harness default `PRWATCH_REPO` is now `~/Documents/GitHub/pr-watcher/watcher`.
- One session cron job (`*/15 * * * *` → `/prwatch-tick`); the summary is no longer a separate job and the sched gate accepts only that one string.
- The launcher's watchdog and exit notice take the session status from `prwatch-tick.sh --window`; the "stopped early" notification now says the watcher stopped before the end of its session.
- Stop markers are per session (`stopped-<session_id>`; old dated markers are ignored and swept); every `events.jsonl` line carries `session`; `paused_until` is stored as epoch seconds; the tick status `stopped_for_today` is now `stopped`.
- `watcher/CLAUDE.md`, the five skills and both READMEs describe the session in elapsed time (the first 7½ hours, the next launch) and never name a clock time or a day of the week.

### Removed

- The daily review cap: `cap N`, the `PRWATCH CAP:` hook line, `prwatch-state.sh today`, `daily-inc`, `cap` and `stop-today`, prep exits 24 and 26, state exit 65, the `cap` notification kind, the `daily` and `cap_override` state fields (dropped on the first write), and the harness checks that asserted them.
- The office-hours and working-week window: nothing in the watcher checks the time of day or the day of the week any more.

## [0.1.0] - 2026-10-29

### Added

- The council-approved v2 plan (`docs/plan-v2.md`): review engine, cross-org inbox, 8-hour window, repo files.
- The Windows port plan (`docs/windows-port.md`) and the WSL2 install guide (`docs/windows-wsl.md`).
- `cap N`: raising the daily review cap for one day, with the seven rounds of Parliament review notes applied (`docs/cap-override.md`).
- All PR tests run automatically inside sandboxes.
- First build: the daily council review loop with the double-click launcher.

### Fixed

- Reviewers launched in the background after Claude Code 2.1.284 (`docs/fix-background-agents.md`).

[Unreleased]: https://github.com/JackScammell/pr-watcher/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/JackScammell/pr-watcher/releases/tag/v0.1.0
