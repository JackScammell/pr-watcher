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
- The inbox spans every repository the GitHub login can see: the tick searches `user-review-requested:@me` with no owner filter (`gh search prs --state open --limit 100 --sort updated --order desc --json number,repository,author`).
- First-sighting gate: the first PR from a repository with no `repos` entry and no tracked key is classified `new_repo` (nothing fetched, nothing written); the tick sends one `newrepo` notification per unseen repository (its body reads "First pull request from a repository the watcher has not seen. In Terminal, type allow or block, then owner/repo.") and prints `First PR from <owner>/<repo> by <author>: type allow <owner>/<repo> or block <owner>/<repo>` in `notices` once per repository per check, even when several of its pull requests are waiting (the tick JSON still carries one `new_repo` item per pull request), until Jack types `allow <owner>/<repo>` or `block <owner>/<repo>` at the prompt. The prompt hook handles it with a one-use request file, `prwatch-state.sh repo-allow|repo-block` (exit 64 and event `repo_refused` without that request) records `repos["<owner>/<repo>"]` as `allowed` or `blocked` (events `repo_allow`, `repo_block`), and the model repeats the hook's `PRWATCH REPO:` line. A blocked repo's PRs classify as `blocked_repo`.
- One repo gate, enforced in the scripts: a repo is allowed when `repos[<owner>/<repo>]` is `allowed`, or when it has no `repos` entry and some tracked key starts with `<owner>/<repo>#`; `blocked` never passes; all lookups are case-insensitive. A repo with no `repos` entry but a tracked pull request counts as allowed and is recorded as `allowed` the first time a new pull request of that repo is queued. `prwatch-prep.sh` refuses with `repo not allowed` (exit 25) before any clone or fetch, and `prwatch-state.sh set <key> …` for a new key refuses with `repo not allowed` (exit 64, event `repo_not_allowed`); existing keys can still be updated.
- Blocked → withdrawn: a tracked PR whose repo is blocked is withdrawn on the next check (`withdrawn_from=<previous status>`, reason `blocked_repo`), so `block` now withdraws any tracked PR of that repo. A search that returns exactly 100 rows is treated as partial: nothing is withdrawn for being missing from the search that check (a pull request of a blocked repo that does appear in the search is still withdrawn) and the notice `search truncated at 100; nothing withdrawn this check` is shown. The search is sorted by most recently updated (`--sort updated --order desc`) so the newest requests survive truncation.
- `profile.json` gains `has_pii`: true when a changed path matches `learner|staff|person|attendance|safeguard|address|dob` (case-insensitive).
- The key grammar `<owner>/<repo>#<n>` is defined once in `watcher/bin/prwatch-common.zsh` (owner `[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?`, repo `[A-Za-z0-9_][A-Za-z0-9._-]{0,99}`, `n` with no leading zero and at most 7 digits) together with the worktree and archive name builders.

### Changed

- `docs/cap-override.md` moved to `docs/history/`; the harness default `PRWATCH_REPO` is now `~/Documents/GitHub/pr-watcher/watcher`.
- One session cron job (`*/15 * * * *` → `/prwatch-tick`); the summary is no longer a separate job and the sched gate accepts only that one string.
- The launcher's watchdog and exit notice take the session status from `prwatch-tick.sh --window`; the "stopped early" notification now says the watcher stopped before the end of its session.
- Stop markers are per session (`stopped-<session_id>`; old dated markers are ignored and swept); every `events.jsonl` line carries `session`; `paused_until` is stored as epoch seconds; the tick status `stopped_for_today` is now `stopped`.
- `watcher/CLAUDE.md`, the five skills and both READMEs describe the session in elapsed time (the first 7½ hours, the next launch) and never name a clock time or a day of the week.
- Every script takes the whole key: `prwatch-prep.sh <key> <sha40> <round>` and `prwatch-post.sh --key <key> --sha <sha40> --event … --body-sha … [--tech …]` (no `--repo`, `--pr` or default owner); buildrun, ngtest, dotnettest, cleanup and state take the key as before.
- Paths carry the owner: clones in `repos/<owner>__<repo>`, worktrees in `work/<owner>__<repo>-pr<n>-<sha7>` (and `-build`), archives in `~/Documents/vision-reviews/<date>-<owner>-<repo>-pr<n>-round<k>` with owner and repo lower-cased. Old folders are left alone.
- The GitHub login comes from `gh api user --jq .login` in the launcher, exported as `PRWATCH_LOGIN` and written as `login` in `session.lock`; the launcher prints the organisations the login can see (`Organisations your login can see`) as information only, never as a gate. Scripts fail closed without it: the tick (full and `--dry-run`; `--window` is exempt) prints `{"status":"error","kind":"no_login"}`, prep exits 25 (`no login`), post exits 64. The skills take the login from `session.lock`, never from a name.
- `allow`/`block` are case-insensitive: the repo is stored lower-cased and the hook's `PRWATCH REPO:` reply echoes what was typed.
- Upgrade: relaunch from the launcher. Old clones under `repos/<repo>` are not reused — delete them or move them by hand with `mv repos/<repo> repos/<owner>__<repo>`; old worktrees are swept after 3 days.
- `watcher/CLAUDE.md` and the skills gain the `allow`/`block` rows, the `new_repo` and `blocked_repo` reasons and the standing answer that the Laravel and sandbox rules apply to every repo; the sim2 table grows to 22 rows and the guard cases cover the new prep, post and state shapes.
- Times shown to Jack are HH:MM (`started_hm`, `starts_until`, `ends_at`, pause `until`), with "tomorrow" or "yesterday" added when the day differs; the end-of-session notification is titled "Session summary". The sched gate refuses a `CronCreate` with any field beyond cron, prompt and recurring, or a non-boolean `recurring`. Scripts refuse a malformed session id. `prwatch-prep.sh` answers a lock without `started_epoch` with exit 25 ("no session start"), keeping 27 for the 7½-hour cut-off.
- A shared `repo_status` helper reports a repository as `allowed`, `blocked`, `seen` (no `repos` entry but a tracked key) or `unseen`; `repo_allowed`, the tick and `prwatch-state.sh set` all read it.
- A strict `WT_PAT` worktree pattern, built from the key grammar, is used by cleanup and reserved for the PR 4 skill hook.
- Prep's sandboxed dependency restore keeps out the GitHub login, the lock JSON and the `gh` config directory.
- `has_pii` matches a wider, anchored path vocabulary: learner, student, apprentice, employer, employee, staff, person, people, user, contact, parent, guardian, candidate, applicant, attendance, safeguard, ehcp, medical, disability, address, dob, birth, nino, national insurance, uln, email, phone, payroll, salary, each matched at a path or word boundary. The flag is advisory until a consumer reads it.

### Removed

- The daily review cap: `cap N`, the `PRWATCH CAP:` hook line, `prwatch-state.sh today`, `daily-inc`, `cap` and `stop-today`, prep exits 24 and 26, state exit 65, the `cap` notification kind, the `daily` and `cap_override` state fields (dropped on the first write), and the harness checks that asserted them.
- The office-hours and working-week window: nothing in the watcher checks the time of day or the day of the week any more.
- The hard-coded reviewer login and the ACT-Training organisation check: the `--owner` filter on the inbox search, the launcher's `gh api orgs/ACT-Training` check, the Vision-only `pr<N>` archive slug, and `prwatch-post.sh --repo`/`--pr`.

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
