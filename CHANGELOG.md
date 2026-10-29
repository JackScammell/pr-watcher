# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Repository files: licence, code of conduct, security policy, contributing guide, changelog, issue and PR templates, Dependabot, editorconfig; the `check` workflow (syntax on Ubuntu, harness on macOS); the committed sim2 expected table; and `.gitignore` entries for Claude Code's per-repo worktrees and agent memory.

### Changed

- `docs/cap-override.md` moved to `docs/history/`; the harness default `PRWATCH_REPO` is now `~/Documents/GitHub/pr-watcher/watcher`.

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
