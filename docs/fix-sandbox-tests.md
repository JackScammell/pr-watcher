# Fix: tests couldn't run in the sandbox (Vision #1723, 2026-09-29)

The testing-build reviewer ran no tests on #1723 and still voted `APPROVE`. There were two separate failures. The
draft did tell Jack plainly that no tests had run: its first question for him said so.

## 1. `dotnet test`: root cause confirmed and reproduced
- **Symptom:** "vstest.console process failed to connect to testhost process after 90 seconds" (again after 300 s
  with `VSTEST_CONNECTION_TIMEOUT=300`).
- **Reproduced** with `claude -p` using `~/prwatch/config/settings.json` (the watcher's own sandbox), on #1742's
  Vision build copy, running `SignInTypeTests` with `--diag`. The testhost log:
  `testhost started with --endpoint 127.0.0.1:057119` → `TcpClient.ConnectAsync(IPAddress, Int32)` →
  **`SocketException (13): Permission denied`** after 0 ms. It isn't a timeout, a crash or a file write.
- **Cause:** with `allowLocalBinding: true`, Claude Code's seatbelt profile allows `network-outbound (remote ip
  "localhost:*")`. .NET's `TcpClient()` creates a **dual-stack IPv6 socket** by default, so connecting it to
  127.0.0.1 goes out as `::ffff:127.0.0.1`, which the sandbox's `localhost` rule doesn't match. Claude Code already
  handles this for Java by adding `-Djava.net.preferIPv4Stack=true`; there is no .NET equivalent. The watcher's own
  diagnosis ("loopback works") tested with a plain IPv4 socket, which is allowed.
- **Proof, in the watcher's sandbox:**
  - Python AF_INET → 127.0.0.1: connect OK.
  - Python dual-stack AF_INET6 → `::ffff:127.0.0.1`: **Operation not permitted**.
  - The same `dotnet test` with `DOTNET_SYSTEM_NET_DISABLEIPV6=1`: **Passed 5/5**.

## 2. `scripts/check-endpoint-tests.sh`: cause confirmed (by the watcher)
- A bare `mktemp -d` on macOS uses the per-user Darwin temp dir (`/var/folders/…/T/`), not `$TMPDIR`. The sandbox
  allows writes only to `$TMPDIR` (`/tmp/claude-503`) and a few other paths.
- This is the Vision repo's script, which is PR-controlled content, so the watcher shouldn't patch it. Widening the
  sandbox to `/var/folders/…` (shared by every app) is rejected.

## 3. Angular/Karma: found while verifying (it never worked in the sandbox)
Run in the watcher's sandbox:
- `ng test` with ChromeHeadless fails with "Cannot start ChromeHeadless".
- Full Chrome aborts with `Failed to create socket directory` → `ProcessSingleton … Aborting`.
- chrome-headless-shell aborts with `FATAL … bootstrap_check_in org.chromium.Chromium.MachPortRendezvousServer: Permission denied`.

Chrome must **register** Mach services, and Claude Code's sandbox settings can only grant Mach *lookup*
(`allowMachLookup`). Unix-socket bind in `$TMPDIR` is also refused. **Chrome can't run inside Claude Code's sandbox at all.**

Further facts from the sandbox:
- macOS `mktemp -d` and `mktemp -d -t x` here ignore `$TMPDIR` (even when it is set explicitly) and use `/var/folders/…/T/`.
- Python AF_UNIX bind under `$TMPDIR` → EPERM.

## 4. .NET integration tests: found while verifying
- In the watcher's sandbox, `VisionApi.IntegrationTests` gave **220 failed** of 300. All had the same error:
  `TypeInitializationException: System.Net.CookieContainer … GetDomainName: -1`.
- Cause: Claude Code's sandbox allows only a fixed list of `sysctl`s. `sysctl kern.nisdomainname` and `getdomainname()`
  both give **EPERM** in the watcher sandbox, so `CookieContainer`, which every WebApplicationFactory test client
  uses, can't initialise. No setting changes the list.
- Fix: `bin/prwatch-dotnettest.sh`, the same pattern as ngtest: a watcher-owned profile that allows `sysctl` and
  `/private/tmp/.dotnet` (.NET named-mutex shared memory, as prep's profile does). Result: **243 passed / 0 failed**.

## Jack's requirements (2026-09-29)
- Fully automated. Tests run as part of the review, and Jack shouldn't need `run tests` for normal coverage.
- Run all suites. Tests that would connect to a **real local service** (a DB/Redis connection string on
  localhost/127.0.0.1/*.test) are not run and are recorded as could-not-run. In-memory databases and WebApplicationFactory are fine.

## Changes (revision 2, implemented)
1. **.NET:** `settings.json` `env`: `DOTNET_SYSTEM_NET_DISABLEIPV6=1`. All the `bin/` scripts re-exec with `env -i`, so it
   reaches **only** sandboxed Bash; prep, buildrun and post never see it. Verified in the sandbox:
   `VisionApi.UnitTests` TZ=UTC **8139 passed / 0 failed / 43 skipped**, and TZ=Europe/London the same.
2. **`mktemp` wrapper:** `~/prwatch/shims/mktemp`, first on the session `PATH` (set by the launcher; `shims/` is
   read-only like `bin/`). Without a template (`mktemp`, `mktemp -d`, `mktemp [-d] -t prefix`) it calls
   `/usr/bin/mktemp` with the template under `${TMPDIR:-/tmp}`. Calls that already have a template pass straight
   through. The sandbox isn't widened and PR code isn't edited. Scripts that call `/usr/bin/mktemp` by absolute
   path still fail and are recorded as could-not-run.
3. **Angular: `bin/prwatch-ngtest.sh <key> <app>`**, allow-listed and excluded from Claude's sandbox like prep and
   buildrun, with no prompt. It runs `npx ng test --watch=false --browsers=ChromeHeadless` in the build copy
   under a **watcher-owned seatbelt profile**, modelled on prep's restore profile:
   - reads everything except `/Users`, `/private/tmp` and `/private/var/folders`. The exceptions are the build copy,
     the node install, `~/.cache/puppeteer` (chrome-headless-shell) and a private temp dir;
   - writes only to the build copy and a private per-run temp dir (with `TMPDIR` and the Chrome user-data-dir set
     there);
   - network: loopback only (bind, inbound and outbound on localhost, plus unix sockets under the private temp dir),
     and no remote hosts;
   - Mach: allowed, including register, which is what Chrome needs;
   - `CHROME_BIN` is set to a wrapper around chrome-headless-shell (`~/.cache/puppeteer`, newest version). If it's
     missing, the script exits 2 and `/prwatch-start` test 8 warns. There's no fallback to Google Chrome, which
     aborts on its ProcessSingleton. A separate watchdog enforces a hard time limit. The process group, and
     anything still running from the build copy, is killed on exit, interrupt or timeout;
   - output goes to the archive as `reviews/ng-test-<app>.log`. The exit code is 0 for passed, 1 for tests failed,
     and 2 for couldn't start.

   The testing-build angle calls it instead of running `ng test` itself.
4. **`angles/testing-build.md`:**
   - `--diag` for dotnet;
   - the definition of "ran", and no `APPROVE` if nothing ran;
   - the local-services rule;
   - sandbox limits limited to the exact command;
   - command output treated as untrusted;
   - Angular via `prwatch-ngtest.sh`.
5. **Review §6 / decide:**
   - `tests.ran` holds test runs only, and builds go in `built`;
   - `ci` comes from `checks.json`;
   - no `approve` when nothing ran unless CI is green, with a note;
   - the Tests line shows CI when nothing ran.
6. **Regression:**
   - `run.sh` asserts cover: the env var; the scripts using `env -i`; the angle rules; the review/decide rules; the
     mktemp wrapper (unit tests for its argument handling); the ngtest profile (no remote network, no home writes);
   - `live-check.sh` D: in the real sandbox, IPv4 OK, the dual-stack status reported, a dotnet test if a Vision
     build copy exists (otherwise SKIP), and `mktemp -d` working through the wrapper.
7. **Docs:** a single "Sandbox limits for PR tests" section in BUILD-NOTES.md, which the angle points to.

## Verification (2026-09-29)
- **Prototype:** Karma in the watcher-owned profile, with chrome-headless-shell `--no-sandbox`, on #1742: **3749/3749 SUCCESS**
  in 26 s. Jack ran it himself (`!`), because Claude Code's safety checker won't launch a browser with its sandbox off
  from this session.
- **End to end in the real watcher setup** (`claude -p`, auto mode, `~/prwatch/config/settings.json`, `shims` first on
  `PATH`, #1742's build copy):
  - `mktemp` resolves to `~/prwatch/shims/mktemp`;
  - `bash scripts/check-endpoint-tests.sh` passes with exit 0 ("All new endpoints have tests"). It was blocked before;
  - `dotnet test` passes (5/5, `SignInTypeTests`). The full project gave 8139/0/43 in both time zones;
  - the model called `prwatch-ngtest.sh ACT-Training/Vision#1742 frontend` through its allow rule with no prompt and
    no checker block: **Executed 3749 of 3749 SUCCESS, exit 0**, with no Chrome or Karma processes left over. (The
    first run found a verdict bug, exit 2 on success, which was fixed and covered by tests.)
- **`test/harness/run.sh`: 154/154.** It covers the shim (all option forms, containment, pass-through), ngtest
  (arguments, spec-dir validation, session, state, Laravel refusal, Karma verdicts, the generated profile: deny
  default, `/Users` reads denied, loopback only, writes only to the build copy and private dir), guard, settings,
  launcher `PATH` order, and the angle, review and decide wording.

## Verification, final (2026-09-30), all through the real watcher setup and each script's allow rule in auto mode
| Suite (#1742 build copy) | Result |
|---|---|
| `prwatch-dotnettest.sh` VisionApi.UnitTests, UTC / London | 8139 passed / 0 failed / 43 skipped, both time zones |
| `prwatch-dotnettest.sh` VisionApi.IntegrationTests, UTC / London | 243 / 0 / 57, both time zones (was 220 failed in Claude's sandbox) |
| `prwatch-ngtest.sh` frontend (hardened profile) | 3749 of 3749 SUCCESS |
| `prwatch-ngtest.sh` learner | 251 of 251 SUCCESS |
| `scripts/check-endpoint-tests.sh` (sandboxed, via the mktemp shim) | exit 0 |

- `test/harness/run.sh`: **192/192**. The ngtest and dotnettest profiles are compiled and exercised with
  `sandbox-exec`: `~/.ssh` is unreadable, home is unwritable, there's no remote network, the clipboard is blocked,
  MySQL:3306 is unreachable (ngtest), and the domain-name `sysctl` works (dotnettest). Fake runs cover pass, fail,
  timeout (with nothing left over) and a process escaping its group (swept). Verdicts are checked against real Karma
  and vstest summaries, and a zero-test run gives 2.
- Closing-review hardening:
  - dotnettest hard-denies well-known local service ports (3306, 5432, 6379, 1433, 27017, 5672, 11211, 80, 443,
    9000, 8080), and the harness checks that 3306 is unreachable;
  - any `Failed!` line from a multi-framework project fails the run;
  - project paths must be relative and can't start with `-`;
  - log and temp names come from the full project path.
- Known gaps: Python `unittest` (ACT-Scripts) hasn't been run in the sandbox. There was no build copy, and AF_UNIX
  bind is refused, which would break `multiprocessing`-based tests; those would show up as failures to explain.

## Not changed
- Claude Code's sandbox rules (no widening). Chrome gets its own tighter profile instead, with `--no-sandbox` inside it (Jack's decision, option 1).
- The optional unsandboxed `run tests` path stays, but it isn't needed for normal coverage.
