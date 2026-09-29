# Build notes: PR watcher (built 2026-09-29 from plan Revision 3.1)

Source of truth: `/Users/jack/Documents/pr-review-watcher-plan/plans/plan.md`, Appendix A.1–A.10. The appendix blocks were extracted mechanically, then diffed against the executed harness copies:
- `r31test/home/prwatch/bin` for tick, state and notify;
- `r3test/` for post, prep, cleanup and guard;
- buildrun differs from `r3test/` only in its header comment, and settings only in the `npm_config_cache` line, both as the 3.1 log says.

Every change from the appendix is listed below.

## Changes applied because of Jack's answers (binding)

1. **15:30 start cut-off.** Applies to `bin/prwatch-tick.sh`.
   - `--window` now prints `in_window` only for 08:00–15:29 on weekdays. From 15:30 to 15:59 it prints `{"status":"start_closed","hm":…}`, and outside the window it prints `outside_window` as before.
   - Normal ticks still run until 16:00. Their `ok` JSON has a new `can_start` boolean.
   - The tick skill re-checks `--window` before every council, so no council starts at or after 15:30. A council already running finishes.
   - Evidence: T3 below.
2. **Drafts skipped:** unchanged (row a).
3. **Technical-detail comment asked each time:** `/prwatch-decide` asks Q2 as a separate call every time.
4. **Tests automatic:** the testing-build angle runs by default (still subject to T15).
5. **Laravel.** Applies to `bin/prwatch-prep.sh`.
   - A repo counts as Laravel when `composer.json` at the PR head has `require["laravel/framework"]` (read with `git show`).
   - `profile.json` gains `is_laravel`. Prebuild is skipped entirely: no composer, npm or dotnet restore. `prebuild.log` says "Tests NOT run (Laravel - Flux Pro credentials)".
   - The review skill never dispatches testing-build for Laravel. `/prwatch-decide` prints exactly `Tests: NOT run (Laravel — Flux Pro credentials)` and refuses `run tests`.

## Coordinator follow-up: Laravel opt-in switch. NOT implemented (blocked)

Jack asked (via the coordinator) for an opt-in switch, off by default:
- `laravel_tests` plus `composer_auth_file` in a config file;
- prep would run `composer install --no-scripts` with `COMPOSER_AUTH` read from that file;
- testing-build would run `php artisan test`.

When I tried to add this to `prwatch-prep.sh`, the Claude Code auto-mode classifier **denied the edit as a security weakening**. The code would have passed licence credentials into a dependency download that PR-controlled `composer.json` influences, while the download has network access.

Following that denial, I did not implement it by any other route. Nothing about the switch exists in the build. No `prwatch.conf` and no config keys were created. If Jack wants it, he needs to approve it explicitly and have it added as a separate change. The README states the risk in one sentence.

What I did add, which only tightens things: `Read(~/.composer/**)` in the permission deny list, and `~/.composer` in `sandbox.credentials.files`. Jack's Flux key in `~/.composer/auth.json` is now unreadable by the session and by sandboxed PR code.

Separate observation: `~/Documents/GitHub/attendance/auth.json` exists in Jack's own clone. It isn't in any deny list, so a sandboxed PR process could read it. Jack may want to add `Read(//Users/jack/Documents/GitHub/**/auth.json)` or move the file.

## Plan bugs found by execution (fixed minimally)

1. **dotnet restore of Vision hung forever under the restore profile.** Applies to `bin/prwatch-prep.sh`.
   - What happened: `dotnet restore api/VisionApi.sln` ran for more than 9 minutes at about 57% CPU and downloaded nothing. `cache/tmp/MSBuildTemp/` filled with 133 `MSBuild_pid-*.failure.txt` files, each reading `System.Net.Sockets.SocketException (13): Permission denied at … NamedPipeServerStream … Microsoft.Build.BackEnd.NodeEndpointOutOfProcBase`.
   - Cause: a multi-project solution makes MSBuild start out-of-process worker nodes. Those nodes bind a named-pipe socket under `/tmp`, and the deny-default profile only allows writes to `/private/tmp/.dotnet`. The node creation retries forever. The plan's earlier fixture was a single-project solution, so it never started worker nodes.
   - Fix: `dotnet restore "$s" -m:1` (in-process, no worker nodes). The profile was **not** widened.
   - Evidence: the same restore under the same profile and env with `-m:1` gave `rc=0`, restored all 12 projects, and wrote no failure files. The cold-cache T2 re-run is below.
   - I also added `-m:1` to the testing-build angle's `dotnet build` / `dotnet test` recipe, because Claude's sandbox may deny `/tmp` pipes the same way (unverified; T15 will show). Buildrun runs unsandboxed and is unchanged.
2. **The `.prwatch-venv` name tripped the guard.** Applies to `bin/prwatch-prep.sh`, `bin/prwatch-buildrun.sh` and `angles/testing-build.md`.
   - The guard blocks any command containing `prwatch-` unless it's a canonical script call. So the testing-build agent's `… .prwatch-venv/bin/python -m unittest` would be blocked (exit 2, verified), which counts toward the auto-mode block limit.
   - Fix: renamed the venv to `.pw-venv` (same exclude entry, same buildrun recipe). The new form passes the guard (exit 0, verified).

## Things the plan left to the builder (authored here, not in the appendix)
- `CLAUDE.md`, the five skills (`.claude/skills/prwatch-{start,tick,review,decide,eod}/SKILL.md`) and the five angle files were written from plan §§5–7 (plus the fuller r2 text for §6/§7 and the standing probes).
- **Self-test sandbox probe.** It uses `touch ~/prwatch/state/.sandbox-probe`, which must fail. It doesn't use `bin/`, because once Jack runs `chflags uchg` a write to `bin/` fails even without a sandbox.
- **Round number.** Taken from state (`round` plus `last_reviewed_sha`) for the prep argument, then corrected after prep from `reviews.json` (parliament rule plus the `prwatch round=` marker, lower if ambiguous). The skills record `round=<k>` in state.
- **`open` at the decision question** prints the path rather than running `open`. `open` is a LaunchServices call that the sandbox would probably block, and a block counts toward the limit.
- **The eod notification ref** is `posted-N.waiting-N.not-started-N.failed-N`, because notify refs can't contain spaces or commas.
- **Known guard false positives:** any Bash command containing the word `hub` or `gh` on its own (for example `git grep -n hub`, which a reviewer might use for SignalR hubs). The angle files tell reviewers to use the Grep tool.

## Not done (by instruction)
- `chflags uchg` not run. The lock and unlock commands are in `README.md`.
- No Claude session started, no dialogs, no real notifications, nothing posted. `prwatch-post.sh` was only run with bad arguments and in test mode, and exited before the network or dialog step.

## Test results (run by the builder, 2026-09-29, test mode only)
See the final report. Raw outputs: `test/t2-prep.out`, `test/state/notify.log`, `test/stub/osa.log`.

### Summary of builder test results
- `zsh -n`: all 8 bin scripts plus the launcher OK. `jq empty config/settings.json` OK.
- T3: `--window` gives outside 07:59, in 08:00, in 15:29, start_closed 15:30, start_closed 15:59, outside 16:00, outside Sunday, in 26 Oct 09:00. A `--dry-run` tick at 15:30 gives `ok` with `can_start:false`.
- T4: sim2 prints the 20 lines matching the plan's Checks table. A live dry-run tick with `PRWATCH_ONLY_PR=ACT-Training/Vision#1803` gives `reason:new`, `size:36`.
- T5: 35 cases (25→2, 10→0), no mismatches.
- T2, cold package cache (after the `-m:1` fix): exit 0 in 83 s. 24 `Restored …/api/…csproj` lines, `added 2901 packages`, no MSB1025/MSB1003/"command not found". 7 linked issues. Build copy `git status` clean. Nothing written under `~/Documents/vision-reviews`.
- Notify (stub osascript): bogus kind → 64, bad ref → 64; test, error, stuck and eod → 0. A second `error gh_auth` was throttled (no log line). T16 injection title rendered as literal sanitised text.
- State, cleanup, buildrun, post and tick argument checks: 64 on bad arguments; state with the wrong session → 5.
- Post in test mode with stub osascript: wrong fingerprint → 8, Cancel → 11 (`last-attempt.json`), Post → 0 with only `dry-run.txt` and state `skipped dry_run=1`. **No GitHub write.**
- Test state was reset afterwards. Evidence is in `test/builder-evidence/`.

## Orchestrator change (2026-09-29)
- Added sandbox credentials deny + Read deny for `~/Documents/GitHub` (Jack's own clones hold `auth.json` Flux keys and `.env` files). The watcher never needs them: it uses its own clones in `~/prwatch/repos`. Closes builder open risk 5.
