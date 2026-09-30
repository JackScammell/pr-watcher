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

## Background-agent fix (2026-09-29, after the first live run)
- Claude Code auto-updated to 2.1.284 at 10:37. From that version, `Agent` defaults to background and `run_in_background` is gone from its schema. The first live council (Vision#1742) came back with `async_launched` reviewers and was stopped by hand.
- Fix: `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` in settings `env` and in the launcher.
- Backstop: `bin/prwatch-agenthook.sh` hooks, `prwatch-state.sh harness-abort`, start self-test 7.
- Full design, the council rounds and the evidence are in `docs/fix-background-agents.md`. Tests: `test/harness/run.sh` (113/113, mutation-checked), plus `test/harness/live-check.sh` against real Claude Code. Run the live check after every Claude Code update.
- The hook writes `state/harness/` and `state/stopped-*` directly: it is harness-run code like the `touch state/activity` hooks, not the model. That is deliberate, so a missing or mismatched session lock can't disable it.
- Follow-up: auto mode delivers subagent reports as `[Subagent hand-back]` messages (`SubagentHandback`). Test 7 and review §4 now accept that. See "Auto-mode hand-back" in the doc.

## Sandbox limits for PR tests (2026-09-29, Vision #1723; docs/fix-sandbox-tests.md)
This is the single list of what the testing-build reviewer can and can't do inside Claude Code's sandbox, all reproduced under `config/settings.json`.
- **.NET loopback.** `TcpClient()` is dual-stack, so testhost reaches 127.0.0.1 as `::ffff:127.0.0.1`, which the seatbelt rule `network-outbound (remote ip "localhost:*")` doesn't match (EACCES). `env.DOTNET_SYSTEM_NET_DISABLEIPV6=1` fixes it. It reaches only sandboxed Bash, because every `bin/` script re-execs with `env -i`. Result: `VisionApi.UnitTests` 8139/0/43 in both UTC and Europe/London. A test that genuinely needs IPv6 fails for this environmental reason.
- **`mktemp` without a template** ignores `$TMPDIR` on this Mac and uses `/var/folders/…/T`, which is refused. `shims/mktemp` comes first on the session `PATH` (set by the launcher) and supplies a `$TMPDIR` template. Calls to `/usr/bin/mktemp` by absolute path are still refused.
- **Unix-socket bind** under `$TMPDIR` is refused (EPERM).
- **Domain-name `sysctl`** (`kern.nisdomainname`, `getdomainname()`) is refused, and settings can't change the fixed `sysctl` list. .NET's `CookieContainer` then fails to initialise, and every `WebApplicationFactory` test failed (IntegrationTests: 220 of 300). So .NET tests run through `bin/prwatch-dotnettest.sh`:
  - it has an allow rule and is excluded from Claude's sandbox;
  - it uses its own `sandbox-exec` profile: `sysctl` allowed; no `/Users` reads except the build copy, the NuGet cache and a private dir; writes only to the build copy, the private dir and `/private/tmp/.dotnet` (named-mutex shared memory, as in prep); loopback network only (testhost's port is random); clipboard and preferences blocked.

  Result: IntegrationTests 243 passed / 0 failed / 57 skipped.
- **Chrome can't run inside the sandbox.** It must register Mach services (`bootstrap_check_in`), and settings can only allow Mach *lookup*. So Angular runs through `bin/prwatch-ngtest.sh`:
  - it has an allow rule and is excluded from Claude's sandbox;
  - it uses its own `sandbox-exec` profile: no `/Users` reads except the build copy, node, chrome-headless-shell and a private dir; writes only to the build copy and the private dir; loopback network only;
  - chrome-headless-shell runs with `--no-sandbox`, because its inner sandbox can't nest in sandbox-exec (Jack's decision). It depends on `~/.cache/puppeteer/chrome-headless-shell`.

  Result on #1742: 3749/3749 SUCCESS in 26 s.
- **Real local services.** Test projects that would connect to a real local DB, Redis or queue aren't run (Jack's decision). In-memory databases and WebApplicationFactory are fine.

## Daily cap override (2026-09-30; docs/cap-override.md)
- Jack types `cap N` (1–12) to change today's council cap; it lapses overnight. Only `bin/prwatch-prompthook.sh` (UserPromptSubmit) can set it: it writes `state/cap/request.json` and calls `prwatch-state.sh cap N`, which refuses without that fresh request. Like the agenthook markers, the request is written by harness-run code, never the model.
- `prwatch-prep.sh` now takes the day's slot (`daily-inc`, exit 65 → prep exit 24) before anything else; the review skill no longer calls `daily-inc`. The model can no longer skip the count.
- A PreToolUse `CronCreate` hook allows only the `/prwatch-tick` and `/prwatch-eod` jobs, so a scheduled prompt can't pose as Jack.
- `prwatch-state.sh` holds a `zsystem flock` for every write. Without it, parallel writes emptied `state.json` in testing.
- In test mode `prwatch-state.sh` honours `PRWATCH_NOW` for `daily`/`cap_override` dates, matching `prwatch-tick.sh`. Before this, T6-style runs counted against the real date while the tick read the fake one.
