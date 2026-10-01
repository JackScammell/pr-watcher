# Windows port of pr-watcher (WSL2)

Status: r14, council-approved (2026-10-01). Plan only; no code has been changed. The install chapter of the
Windows guide, `docs/windows-wsl.md`, has existed since r6 (S0 below).

- **Specialists:** system-architect, security-knight, config-curator, test-prophet, doc-bard, plus a Claude Code
  docs check.
- **Reviewers:** architecture-skeptic, maintainability-curmudgeon, security-nag, performance-troll, testing-tyrant.
- See the **Revision log** at the end for each round-1 finding and how it was resolved.

## Goal

Run the PR watcher on Jack's Windows 11 laptop:
- from **this single repo**;
- using **WSL2**;
- with **the same features and the same safety guarantees as the Mac**;
- with the **WSL install fully documented**.

The Mac install must keep working and keep passing its tests.

"Same features" means all of these:
- the 08:00–16:00 weekday tick loop;
- the reviewer council;
- sandboxed automatic .NET, Angular and Python tests;
- the human gate before any GitHub write:
  1. Jack's choice in the console;
  2. the permission prompt;
  3. a confirm dialog drawn outside Claude;
- desktop notifications, the watchdog, keep-awake and the single-instance lock;
- `cap`, `pause` and `stop`;
- locking the watcher's own files.

**Done** means all of the following hold.
- **On WSL2:** the offline harness passes, the launcher preflight and security self-tests pass, the mutation pass
  is recorded, and the W-checklist (table in §12) passes.
- **On the Mac:** two gates.
  - **(a)** The renderer reproduces today's token-only files byte for byte, measured against the baseline tag
    `pre-wsl-port`.
  - **(b)** The script changes pass `run.sh` (case count never lower than the baseline), `live-check.sh`, the Mac
    T-tests listed in Phase 7, and a reviewed diff.

## Existing Capabilities Found

Inventory pass (Explore, 2026-10-01). Paths are repo-relative.

- **`watcher/bin/*.sh` (13 scripts).** All are zsh. Each re-execs under `env -i … /bin/zsh`, and they use heavy
  zsh-only syntax (glob qualifiers, `extendedglob`, `zsystem flock`). Nothing runs under bash. zsh is packaged for
  Ubuntu, so **no rewrite is needed**.
- **`prwatch-notify.sh`.** The **only** notification sink.
  - It has fixed templates, a `clean()` allowlist sanitiser, a 30-min throttle and `notify.log`.
  - The backend is `osascript` (`:40-45`).
  - It has 13 code call sites, plus the settings `Notification` hook.
- **The two `osascript display dialog` confirm gates.** They are at `prwatch-post.sh:72-91` and
  `prwatch-buildrun.sh:48-51` (Cancel is the default; they give up after 840 s). `post.sh:52-53` snapshots
  `draft/review-body.md` to `post/body-as-posted.md`, which is the file that gets posted. `post.sh:88` uses
  `open -e` for "Show full text".
- **`kill_strays()`** is copied verbatim in `post.sh:14-34` and `buildrun.sh:26-46` (it uses `ps -axo` and `lsof`).
- **Seatbelt profiles.**
  - `prep.sh:88-96`: restore, with network.
  - `ngtest.sh:36-50` and `dotnettest.sh:35-50`: tests, loopback only.
  - The print seams (`PRWATCH_NGTEST_PRINT`, `PRWATCH_DTEST_PRINT`) are asserted by `run.sh`.
- **`shims/mktemp`.** A macOS-only fix, first on the session PATH (launcher `:77`). On GNU it passes straight
  through, and `run.sh:220` already accepts GNU wording.
- **`test/stub/osascript`.** The double for every dialog and notification. It logs to a fixed
  `~/prwatch/test/stub/osa.log` that **no test asserts on**.
- **The test suite:**
  - `run.sh`: ~113 offline cases, mutation-checked when written (BUILD-NOTES "Background-agent fix");
  - `live-check.sh`;
  - `test/sim2/`;
  - `test/guard-cases.txt` and `test/sec/guard-cases.tsv`, which are **byte-identical duplicates**.
- **`install.sh`.** It `rsync`s into `~/prwatch` (keeping the runtime dirs), refuses on a `chflags uchg` lock
  (`ls -lO`), and copies the launcher to the Desktop.
- **Locked files are listed by hand in three places:**
  - the README lock and unlock commands;
  - the `install.sh` check (only `bin` and `shims`);
  - the settings `denyWrite` and Edit/Write deny lists.
- **`launcher/PR Watcher.command`.** Handles claude discovery, the gh checks, the lock, `caffeinate`, the watchdog,
  env setup and the `claude` invocation.
- **No OS detection anywhere.**
- **`/Users/jack` is hard-coded 191 times across 15 files:**
  - `settings.json` (62);
  - the guard regex;
  - `CLAUDE.md`;
  - 5 skills;
  - the testing-build angle;
  - both guard-case files;
  - `run.sh:193` and `:476`.

  The scripts themselves use `$HOME/prwatch`. `env.PRWATCH_HOME` is set but nothing reads it.
- **BSD/mac-only calls:**
  - `stat -f %m` (launcher `:60`, `notify.sh:36`, `state.sh:62`);
  - `date -j -f` (`tick.sh:24`);
  - `date -v` (`state.sh:51`, and `run.sh:169,177,357,359`);
  - `ps -axo`;
  - `ls -lO` and `chflags`;
  - `uuidgen`;
  - `/usr/sbin/lsof`;
  - `/opt/homebrew/bin`;
  - the Herd nvm path;
  - `chrome-headless-shell-mac*`;
  - `/Applications/Google Chrome.app`;
  - `caffeinate`.
- **The Windows checkout has CRLF in every file** (`core.autocrlf=true`, no `.gitattributes`).
- **Pre-existing bug.** `pause` stores `date -v+NM -Iseconds`, and `tick.sh:30` compares it with `date -Iseconds` as
  a **string**. Across a UK clock change the offsets differ, so the pause ends an hour early or late.

## Reuse Decision

**Extended in place:**
- **All 13 `bin/` scripts.**
  - They stay in zsh, and BSD-only calls become zsh builtins that behave the same on both OSes: `zsh/stat`
    `zstat`, `zsh/datetime` `strftime` / `strftime -r` / `$EPOCHSECONDS`, `zsh/zselect`, and `ps -A -o`.
  - There are no per-OS forks: nine scripts carry security rules that would drift apart.
- **`prwatch-notify.sh`.** It stays the only sink; only its final display step moves behind the UI seam.
- **`post.sh` and `buildrun.sh`.** The dialog step calls `prw_confirm`. `kill_strays()` moves from its two copies
  into the platform lib.
- **`prep.sh`, `ngtest.sh`, `dotnettest.sh` and `buildrun.sh`.** Confinement calls `prw_confine`. The Mac SBPL moves
  into the seam, with output identical to today's (golden files). The print seams stay.
- **`install.sh`, `run.sh`, `live-check.sh` and the stub pattern.**

**Created:**
- **Sourced libs in `watcher/bin/`:**
  - `prwatch-platform.zsh`;
  - `prwatch-ui.zsh`;
  - `prwatch-confine.zsh`;
  - `prwatch-render.zsh` (the single renderer, used by `install.sh` and the harness).

  There is no existing OS abstraction. Living in `bin/` means they are locked, `denyWrite`'d and blocked by the
  guard (only listed scripts are callable).
- **`watcher/bin/prwatch-launch.zsh`.** The shared launcher body. The Mac `.command` becomes a thin wrapper. A
  second launcher would drift from the lock, watchdog and cap banner.
- **`watcher/config/protected-paths.tsv`.** The **single manifest** of protected paths: lock set, sandbox
  `denyWrite` set, and writable set. Lock commands, `prw_locked`, the settings cross-check and the S6/W tests all
  read it.
- **`watcher/config/ui-schema.json`.** The single UI request schema (version, kinds, sounds, buttons, size caps). The
  writer, the broker, the helper and both test suites read it. `test/fixtures/ui/` holds the shared corpus of valid
  and hostile requests.
- **`watcher/sbin/prwatch-uibroker` and `watcher/sbin/install-root.zsh`.** WSL-only root pieces, with no analogue on
  the Mac.
- **`windows/`.** Contains `PRWatcher.ps1`, `PRWatcherHelper.ps1`, `install-windows.ps1`, Pester tests and a short
  `windows/README.md`. Changes here need Pester green plus a re-run of S5.
- **`watcher/config/wsl.conf`, `.gitattributes`, `docs/windows-wsl.md`, and `test/fixtures/render/`** (golden
  rendered trees for mac and wsl with a fake `$HOME`).

**Kept:**
- **`shims/mktemp` stays unchanged on both OSes.** It is a pass-through on GNU.

## Options Considered

- **A. Native Windows, no WSL.** Rejected.
  - Claude Code's Bash sandbox doesn't run on native Windows, and `failIfUnavailable: true` is a hard requirement.
  - It would need a PowerShell rewrite.
  - There is no confinement primitive for running PR tests.
- **B. WSL2 with forked scripts.** Rejected. Every security rule and the harness would exist twice.
- **C. WSL2, shared scripts, interop ON, with `notify`/`post` calling `powershell.exe` directly.** Rejected.
  - Any process in the distro could start Windows processes as Jack. That includes PR-influenced restore code,
    `buildrun` code and lingering PR processes.
  - It also includes `wsl.exe -u root`, which gives root in the distro and defeats every lock.
  - Claude Code's sandbox blocks interop only with the optional seccomp filter, and never for unsandboxed scripts
    (sandboxing docs).
- **D. Shared scripts with seams; a dedicated distro with interop and automount OFF; a Windows helper and root broker
  for the UI.** **Recommended.**
  - Pros:
    - one codebase;
    - nothing in the distro can reach Windows processes or files;
    - answers can't be forged by non-root processes;
    - PR code is hidden from `$HOME`;
    - tests run in a private network namespace.
  - Cons:
    - a broker, a helper and a Windows installer to maintain;
    - the Mac scripts get touched, with mitigations in the Phase 1 gates;
    - facts we can't verify until WSL is installed (Phase 0).
- **E. The helper polls the spool over `\\wsl.localhost` (9P) and acks with one `wsl.exe` per answer.** Rejected in
  favour of a single long-lived stdio broker.
- **F. A separate `prw-pr` uid for PR code, with iptables owner rules.** **Deferred.** bwrap with `/home` hidden on
  every PR-code path (§5) already keeps tokens away from PR code. Reconsider it if S4 shows a toolchain that can't run
  with `/home` hidden.
- **G. Managed settings in `/etc/claude-code/managed-settings.json`.** **Deferred.**
  - The Mac uses `--settings` plus a locked `config/`; keeping one mechanism keeps one review surface.
  - On WSL, `config/` is protected by a lock that only root can lift.
- **H. An elevated helper** (UIPI). **Rejected.**
  - It would mean a daily UAC prompt.
  - The trust root is Jack's Windows account, and anything already running as him can call `wsl.exe -u root`.
  - Nothing in the distro can reach the dialog.

## Recommended Approach

Option D.

### 1. Platform seam: `bin/prwatch-platform.zsh`

**Ordering invariant (lint-enforced).** Each script's first line stays the `env -i` re-exec. Before the scrub,
the only platform logic allowed is an inline PATH choice:

```
[[ $OSTYPE == darwin* ]] && P=/opt/homebrew/bin:/usr/local/share/dotnet:/usr/bin:/bin || P=/usr/local/share/dotnet:/usr/bin:/bin
```

- **No lib is sourced before the scrub.** That also removes today's pre-exec `NODE_BIN` glob from prep, buildrun
  and ngtest.
- After the re-exec, the script sources the platform lib, then adds `path=($(prw_node_bin) $path)` where it needs
  node.

**Lazy loading.**
- Every script that needs `prw_*` sources `prwatch-platform.zsh`.
- `prwatch-ui.zsh` is sourced only by notify, post, buildrun and the launcher.
- `prwatch-confine.zsh` is sourced only by prep, ngtest, dotnettest and buildrun.
- Hooks (guard, agenthook, prompthook) source the platform lib only if they use a helper.

**The lib is fork-free and side-effect free.**
- It reads `$OSTYPE`.
- It reads `/proc/sys/kernel/osrelease` with zsh `read`, not `cat`.
- It does nothing else.

**Detection.** `prw_detect [fakeroot]` returns:
- `mac` when `$OSTYPE == darwin*`;
- `wsl` when `$OSTYPE == linux*` and the osrelease matches `microsoft`;
- anything else: **exit 70, "unsupported platform"**.

The `fakeroot` argument exists **only for the harness's detection tests**, which call the function directly. There is
**no environment override**: backend selection always uses real detection.

| Helper | mac | wsl |
|---|---|---|
| `prw_mtime f` | `zstat +mtime` | same |
| `prw_epoch_plus_min n`, `prw_parse_local "YYYY-MM-DDTHH:MM"` (malformed → 64) | `strftime`, `strftime -r` | same |
| `prw_sleep s` | `zselect -t` (builtin, no fork) | same |
| `prw_sha12 f` | `shasum -a 256` | `sha256sum` |
| `prw_uuid` | `uuidgen` | `/proc/sys/kernel/random/uuid` |
| `prw_proc_cwd pid` | `lsof -a -d cwd -p` | `readlink /proc/$pid/cwd` |
| `prw_ps_tree` | `ps -A -o pid=,ppid=` | same |
| `prw_node_bin` | newest Herd nvm `bin` | newest `~/.nvm/versions/node/*/bin` |
| `PRW_DOTNET` | `/usr/local/share/dotnet` | `/usr/local/share/dotnet` (installed there on purpose) |
| `prw_headless_shell` | `…/chrome-headless-shell-mac*/…` | `…/chrome-headless-shell-linux64/…` |
| `PRW_LAUNCHER_MATCH` | `prwatch-launch.zsh` | same |
| `prw_kill_strays` | moved here from post/buildrun | same |
| `prw_locked` | every manifest lock path shows `uchg` (`ls -lO`) | every manifest lock path shows `i` (`lsattr -d`) |
| `prw_lock_commands` | prints `chflags -R uchg …` from the manifest | prints the PowerShell `wsl.exe -u root --exec chattr -R +i …` line from the manifest |

**DST fix.** `paused_until` is stored as epoch seconds and compared with `$EPOCHSECONDS`. A legacy string value is
treated as expired.

**Lint (harness preflight).** It fails if any of these appear outside the lib:
- `date -v`, `date -j`, `stat -f` or `ls -lO`;
- a `source` of any `prwatch-*.zsh` before a script's `env -i` line.

### 2. Path rendering

**Tokens.**
- **`@USER_HOME@`** expands to the absolute home path **including its leading `/`** (for example `/home/jackscammell`). So
  `Read(/@USER_HOME@/prwatch/**)` renders to `Read(//home/jackscammell/prwatch/**)`. This convention is documented in
  `config/README.md` (new, short) and in the renderer's header.
- **`@GH_BIN@`** and **`@HEADLESS_GLOB@`**.
- **`@LINUX_USER@`** (WSL only) is the Linux username, used by `config/wsl.conf`'s `[user] default=` line.

**Files that carry tokens:**
- `settings.json`;
- the guard regex;
- `CLAUDE.md`;
- the skills;
- the testing-build angle;
- `run.sh`;
- `test/sec/guard-cases.tsv`. This becomes the only copy, with a platform column (`all|mac|wsl`).
  `guard-cases.txt` is deleted.

`docs/plan.md` and `BUILD-NOTES.md` are historical and stay as they are.

**What `install.sh` does:**
1. Stage `watcher/`.
2. Render, with a zsh fixed-string substitution (no `sed`).
3. `rsync --delete-after` the staged tree into `~/prwatch`.

**The renderer refuses (with a non-zero exit) if any of these holds:**
- `$HOME` doesn't match `^/[A-Za-z0-9_/-]+$` (a `.` would act as a wildcard in the guard regex);
- there is an unknown token;
- a token is still left after rendering;
- a source file is missing;
- the destination is a symlink;
- on WSL, any `/Users/` remains;
- `jq empty` fails;
- `@GH_BIN@` isn't an absolute, root-owned path.

**Golden fixtures (token files only).** The fixtures in `test/fixtures/render/{mac,wsl}/` cover **only the files that
contain tokens**: `settings.json`, the guard, `gitconfig`, `wsl.conf` and the `.tsv`. They are rendered with
`HOME=/Users/jack` and with `HOME=/home/jackscammell`.
- For every other file, the harness asserts that the rendered file equals the source with tokens substituted. A
  wording edit to a skill therefore never needs a fixture update, and fixture diffs stay small enough to actually
  read.
- The harness renders the repo into a temp directory and `cmp`s the token files against the fixtures.
- Regenerating the fixtures is a deliberate, reviewed step: run `prwatch-render.zsh --update-fixtures` and put the
  diff in the PR.
- The repo↔install sync check (`run.sh:476`) compares the install against the **rendered** repo. `$REPO` is a
  required argument and has no `/Users/...` default.
- A repo test fails if `/Users/jack` appears outside `docs/` and `BUILD-NOTES.md`.

### 3. Protected-paths manifest and the superset `settings.json`

**`config/protected-paths.tsv`** has two columns, `path` and `class`. Each class means:
- `lock` — immutable after install: `bin`, `sbin`, `shims`, `config`, `.claude`, `angles`, `CLAUDE.md`.
- `denywrite` — written only by the unsandboxed scripts or hooks, never by the session: `state` and `repos`.
  Prep clones into `repos`, so these two are not chattr-locked.
- `writable` — `test`, `cache`, `work` and `gh-empty`.
- `root-installed` (WSL) — files that `install-root.zsh` puts outside `~/prwatch`, each with its source, target,
  owner and mode:
  - `sbin/prwatch-uibroker` → `/usr/local/sbin/prwatch-uibroker`, `root:root 0755`;
  - `config/wsl.conf` → `/etc/wsl.conf`, `root:root 0644`;
  - `/var/lib/prwatch/ui` and `resp/`, `root:root 0755`.

  `install-root.zsh` and preflight checks 6 and 8 both read this class. Neither keeps a list of its own.

**Harness cross-checks:**
- every top-level entry under `watcher/` is classified;
- every path in `lock` ∪ `denywrite` appears in `sandbox.filesystem.denyWrite` **and** in the Edit/Write deny rules
  of the rendered settings;
- `prw_locked` and `prw_lock_commands` cover exactly the `lock` class;
- the `root-installed` entries match what `install-root.zsh` and the preflight check (both tested against a fakeroot).

**Lock commands have one owner: `prw_lock_commands`** in the platform lib. `prwatch-render.zsh --lock-commands`
delegates to it in one line. The README lock section and `docs/windows-wsl.md` both say "run
`~/prwatch/bin/prwatch-render.zsh --lock-commands`" instead of copying a list.

**Checklist for a new protected path, script or preflight check.** It lives in `config/README.md`. The harness
enforces it: an unclassified entry fails, a preflight check without its fakeroot case fails, and a guarded script that
isn't in the guard's canonical list fails.

**Superset `settings.json`.** jq's `*` replaces arrays, so an overlay would need hand-written merging and would split
the security posture across two files. Instead there is one file with the union of entries. An entry for a path that
doesn't exist on one OS is inert there.

Additions. Reads go in both `permissions.deny` and `sandbox.credentials.files`.
- **Secrets:**
  - `~/.claude/.credentials.json` (plaintext on Linux);
  - `~/.claude.json`;
  - `~/.git-credentials` and `~/.config/git/credentials`;
  - `~/.config/composer`;
  - `~/.npmrc` and `~/.nuget/NuGet`;
  - `~/.docker`, `~/.gnupg`, `~/.aws` and `~/.azure`;
  - `~/.local/share/keyrings`;
  - `//mnt/**` and `//run/WSL/**`.
- **Persistence (Edit/Write deny):**
  - `~/.bashrc`, `~/.profile`, `~/.bash_profile` and `~/.zshenv`;
  - `~/.config/systemd/user/**` and `~/.config/autostart/**`;
  - `//etc/**`;
  - `Bash(crontab *)`.
- **Bash denies:**
  - `Bash(*.exe*)`, `Bash(cmd.exe *)`, `Bash(powershell.exe *)`, `Bash(pwsh *)` and `Bash(wsl.exe *)`;
  - `Bash(bwrap *)`, `Bash(chattr *)` and `Bash(sudo *)`;
  - `Bash(/usr/bin/gh *)` and `Bash(/usr/local/bin/gh *)`.
- `env.PRWATCH_HOME` is removed.

**The macOS-only key.** The docs say `network.allowLocalBinding` is macOS-only. Spike S2 must show two things: that
Linux ignores the key without error, and that loopback works in the Linux sandbox. If the key causes an error, it
moves to a **named** rendered fragment, `config/settings.mac-only.json`. The renderer merges that one fragment with a
single, tested jq expression. This is the only allowed exception, and it is recorded in BUILD-NOTES.

**`config/gitconfig`.** The credential helper becomes `helper = !@GH_BIN@ auth git-credential`.

### 4. Dedicated, isolated distro

**The `PRWatcher` distro (Ubuntu 24.04) is used only for the watcher.**
- Docker Desktop WSL integration is **off** for it. (Docker Desktop isn't installed on the laptop as of 2026-10-01.
  Open Question 5 has the rules if it is installed later.)
- The docs say not to run other distros with listening services while the watcher runs, and warn about the Docker
  TCP API (2375). All WSL2 distros share one network namespace.

**`/etc/wsl.conf`** is installed from `watcher/config/wsl.conf` by `install-root.zsh`:

```
[interop]
enabled=false
appendWindowsPath=false
[automount]
enabled=false
mountFsTab=false
[boot]
command=sysctl -w dev.tty.legacy_tiocsti=0
[user]
default=<linux user>
```

The file **replaces** the image's own `/etc/wsl.conf`. If Ubuntu's image ships `[boot] systemd=true`, that line is
dropped, and that is deliberate. Nothing in the watcher needs systemd: the broker is started by the Windows helper
(§6), and the ticks are Claude Code session cron. No systemd also means fewer root services running in the distro. S1
records the image's original file in BUILD-NOTES.

**`%USERPROFILE%\.wslconfig`** settings. The file is global, and the docs say so. This table owns the values. Guide
step 3d owns only how to work them out and apply them, and says "values per plan §4". This file stays on the Windows
side and no later phase generates it, so the table remains the owner.

| Setting | Section | Value | Why |
|---|---|---|---|
| `guiApplications` | `[wsl2]` | `false` | no WSLg X11/Wayland sockets |
| `networkingMode` | `[wsl2]` | `nat` (never `mirrored`) | |
| `memory` | `[wsl2]` | `min(12, floor(0.6 × host RAM in GB))` GB (16 GB host → 9GB; 32 GB → 12GB) | leaves Windows enough while .NET and Chrome run |
| `swap` | `[wsl2]` | `4GB` | |
| `processors` | `[wsl2]` | `max(4, floor(logical CPUs / 2))` | |
| `autoMemoryReclaim` | `[experimental]` | `gradual` | Microsoft lists it under `[experimental]` |

**No root path from the watcher user.** `install-root.zsh` does all of the following:
- removes the user from `sudo`, `adm`, `lxd` and `docker`;
- makes sure no `/etc/sudoers.d` entry grants the user anything;
- makes sure the root password is locked (`passwd -S root` shows `L`);
- makes sure `pkexec`/polkit isn't installed.

Root work is done **only from Windows**, using `wsl.exe -d PRWatcher -u root --exec …`. That covers the root
install, lock and unlock.

**Claude Code sandbox.** It needs `bubblewrap`, `socat` and the **optional seccomp filter**
(`npm i -g @anthropic-ai/sandbox-runtime`). Here the filter is **required**: it blocks AF_UNIX sockets in sandboxed
Bash (sandboxing docs). On the Mac, unix-socket bind is already refused, so this is parity.
- **Protecting the filter.** `npm i -g` under nvm puts it in a folder the watcher user can write (the nvm Node's
  global `lib/node_modules/@anthropic-ai/sandbox-runtime`). A session that could replace it would switch the AF_UNIX
  block off for the next session. So that folder joins `protected-paths.tsv` in the **`lock`** class. It is rendered
  as `@SANDBOX_RUNTIME_DIR@`, which the renderer resolves from the `node` it records. That brings the folder under
  `chattr -R +i` (recursive, like every lock path, §8), `sandbox.filesystem.denyWrite` and the Edit/Write deny
  rules, all from the manifest.
- **Pinning the Node.** The rest of `~/.nvm` stays writable, so a session could install another Node, with its own
  unlocked copy of the filter. Two rules close that:
  - Preflight check 11 resolves `node` exactly as the launcher will put it on PATH, and refuses if it isn't the one
    the renderer recorded ("Node changed since install — re-run install.sh, then lock").
  - S2 records **how Claude Code finds the filter** (guide 4e, VERIFY (S2)). If discovery depends on anything other
    than the recorded Node's global folder (for example nvm's `alias/default` or a PATH search), that path joins the
    `lock` class too. The choice is recorded in BUILD-NOTES before Phase 2.
- Preflight check 11 (below) confirms all this, and self-test 11 proves the filter is active. Updating the filter or
  Node means unlocking, the same as for the watcher's own files.

**Launcher preflight: `prw_wsl_preflight`.** It runs on **every** WSL launch, before claude starts. One function, with
one harness case per check. If any check fails, the launcher refuses with a plain message and an `error launcher`
notification. The checks:
1. The broker is alive: `broker.alive` is fresher than 15 s. So the Windows shortcut is the **only supported entry
   point**.
2. WSLInterop binfmt is absent or disabled, and no `/run/WSL/*_interop` socket exists. If S3 shows the sockets exist
   even when interop is disabled, this check becomes a connect test instead.
3. `/mnt/c` and `/mnt/wslg` are absent, and so is `/var/run/docker.sock`.
4. The networking mode is NAT (`wslinfo --networking-mode`; VERIFY in S1). If `wslinfo` lacks the option, S1
   records the output of `ip -4 route show default` and `ip -4 addr show eth0`. The council then picks the check from
   that evidence before Phase 2, and the choice is recorded in BUILD-NOTES.
5. `legacy_tiocsti` is `0`.
6. The deployed `/etc/wsl.conf` matches the rendered repo copy.
7. The user is not in `sudo`, `adm`, `lxd` or `docker`. `sudo -n true` fails. Root's password is locked.
8. The broker binary is root:root 0755. `/var/lib/prwatch/ui` and `resp/` are root:root 0755.
9. `prw_locked` is true. This is the only check skipped in test mode, and test mode always forces dry-run posts
   (below).
10. The helper version matches.
    - **What "version" means:** the sha256 of `windows/*.ps1` plus `ui-schema.json`. It is computed by the renderer
      from the repo, and computed again by `install-windows.ps1` from the deployed copies.
    - **The one canonical byte stream**, defined once in `config/README.md`, and the same in zsh and PowerShell:
      1. take the relative names, sorted by byte order;
      2. for each file, emit `<name>\n`, then its bytes with any UTF-8 BOM removed and CRLF turned into LF, then `\n`;
      3. hash the concatenation.
      
      A shared fixture directory is hashed by both the harness (zsh) and Pester (PowerShell), and the two results
      must be equal. `windows/*.ps1` are kept ASCII-only (a lint checks this), because PowerShell 5.1 reads BOM-less
      files as ANSI.
      
      The fixture, `watcher/test/fixtures/hash/`, is **built to exercise the normalisation**: one file with a UTF-8
      BOM, one with CRLF line endings, and names whose locale sort order differs from their byte order (for example
      `B.ps1`, `a.ps1` and `_x.ps1`). The real `.ps1` files are ASCII-only. Without this fixture, mutation 26 and
      Pester mutation 6 could survive while the test stays green.
      - `.gitattributes` would otherwise rewrite its line endings on checkout, so it gets
        `watcher/test/fixtures/hash/** -text`.
      - A harness case asserts the bytes survived: the CRLF file contains `\r\n` and the BOM file starts with
        `EF BB BF`.
    - The helper computes it **once per process** and reuses it when the broker restarts.
    - **The check:** the broker records the version the helper sends at handshake.
      - If the version is missing or different, the preflight warns: "desktop helper is out of date — re-run
        install-windows.ps1".
      - The broker also **refuses every confirm** from that helper and answers it `NoHelper`. A stale helper can still
        show notifications, but it can never take part in a post. It fails to "not posted".
11. The seccomp filter is protected ("Protecting the filter" and "Pinning the Node" above). Three things must
    hold:
    - the `node` the launcher resolves is the one the renderer recorded;
    - `@SANDBOX_RUNTIME_DIR@` exists and is in the `lock` set;
    - **every** file and folder under it carries `i`. This is a recursive check, done with a single `lsattr -R`
      call rather than one call per file, and not only `lsattr -d` on the folder.

    **How check 11 is tested.** Each condition has its own fakeroot case, and mutation 13 is split into **13a, 13b and
    13c**, one per condition, so dropping any single condition fails a test.
    - The `node` lookup goes through the launcher's own PATH-building function, which takes the fakeroot as an
      argument like the rest of the preflight.
    - Attributes are read through one function, `prw_immutable <dir>`. It **wraps the single `lsattr -R` call** and
      returns success only if every entry carries `i`. It **fails closed**: any `lsattr` error or unreadable entry
      counts as "not immutable".
    - `run.sh` redefines `prw_immutable` when it calls the preflight directly, because the harness can't set `i`
      without root. So the stub replaces exactly the code path the real check uses. The 13c cases cover a nested
      file without `i` and an `lsattr` error.
    - zsh doesn't import functions from the environment, so the launcher can't be handed a redefinition. The lib
      also defines `prw_immutable` **unconditionally**, with no "already defined?" guard. So a definition made
      earlier, for example from a startup file, is replaced. A harness case pre-defines it and checks that the lib's
      version wins. (`~/.zshenv` is already in §3's Edit/Write deny list.)

**How it runs.** The preflight runs **once, at launch only**, never from hooks or ticks. It reads `/proc`,
`/etc/group` and `/etc/wsl.conf` with zsh builtins and `zstat`, keeping forks to a minimum. `sudo -n true` is
wrapped in `timeout 3`.

**No environment seam.** The checks resolve paths against a root passed as a **function argument**,
`prw_wsl_preflight [fakeroot]`, which defaults to `/`.
- The launcher always calls it **with no argument**, in test mode too, so no launch can point the preflight at a
  fake tree.
- Only `run.sh` calls the function directly with a fakeroot.
- Checks 1, 8 and 10 depend on the broker from Phase 4. Until then they are tested only against fake trees. Their
  first real run is the Phase 5 launcher step, and W0 repeats it.

**Test mode is always dry, enforced by `post.sh` itself on both OSes.** Whenever `PRWATCH_TESTMODE` is set,
`post.sh` posts as a dry run and **refuses** `PRWATCH_DRY_POST=0` (exit 64). This holds with or without a test resp
dir, and however `post.sh` was started.
- **What it replaces:** today's `post.sh:11` escape. Nothing in the repo, README or harness uses that escape, and the
  README already promises "posting in test mode is always a dry run". So this is a tightening, not a feature loss.
- **Belt and braces:** the launcher also exports `PRWATCH_DRY_POST=1` in test mode, and `PRWatcher.ps1` has no
  `-DryPost` parameter.

### 5. Confinement seam: `bin/prwatch-confine.zsh`

**Profiles are declared once, as data, at the top of the file.** Each declaration gives the network mode, the
writable dirs and the read-only dirs. Each backend translates that declaration, and the print-mode tests assert each
backend's output against it.

| Profile | Network | Writable | Read-only (beyond system) |
|---|---|---|---|
| `restore` | full | build copy, `cache/` | node bin |
| `ngtest` | loopback only (private) | build copy, privdir | node bin, chrome-headless-shell root |
| `dotnettest` | loopback only (private) | build copy, privdir | NuGet cache, `PRW_DOTNET` |
| `buildrun` (WSL only; Jack-approved "run tests") | full | build copy, `cache/`, privdir | node bin, `PRW_DOTNET` |

**mac backend.**
- It keeps today's SBPL templates per profile, with paths taken from the declaration.
- A golden-file harness case proves the output is byte-identical to today's `PRWATCH_*_PRINT` output.
- `buildrun` stays unconfined on the Mac, as it is today.

**wsl backend** runs `bwrap` with these options:
- **Process isolation:** `--die-with-parent --new-session` (setsid, no controlling terminal),
  `--unshare-user-try --unshare-pid --unshare-ipc --unshare-uts --unshare-cgroup-try`.
- **Read-only system:** `--ro-bind /usr /usr`, symlinks for `/bin`, `/lib`, `/lib64` and `/sbin`,
  `--ro-bind /etc /etc`.
- **Kernel filesystems:** `--proc /proc` and `--dev /dev`, plus a 1 GB `--tmpfs /dev/shm` for Chrome.
- **Hidden directories:** tmpfs over `/tmp`, `/var/tmp`, `/home`, `/root`, `/run` and `/mnt`. This hides the gh
  token, the Claude token, the Composer key, `/run/WSL` and `/mnt/wslg`.
- **Binds:** only what the declaration lists.
- **Network:** `--unshare-net` for loopback-only profiles; `--share-net` for full.

**How the rules map across platforms:**
- **Test network.** The private loopback is stricter than the Mac's port allowlist and denylist.
- **`/tmp/.dotnet`.** .NET's named mutex lives in the private `/tmp`.
- **Dialog wording.** On WSL the `buildrun` dialog says "outside the test sandbox, with network access; your home
  folder stays hidden". The Mac text is unchanged.

**Timeout and reaping.**
- The perl watchdog keeps its process-group kill.
- `--die-with-parent` plus the pid namespace mean that killing bwrap kills everything inside.
- S4 must prove that the LIMIT kill reaps the whole tree, so that LIMIT 1500/2100 can't silently become the 2400 s
  Bash ceiling.

### 6. UI seam: `bin/prwatch-ui.zsh`, root broker, and Windows helper

The seam has two verbs.
- **`prw_notify <subtitle> <msg> <sound>`** shows a notification.
- **`prw_confirm <kind> <title> <summary> <bodyfile>`** asks for confirmation. It prints exactly one of:
  `Post`, `Run`, `Cancel`, `Timeout` or `NoHelper`.

All enums come from `ui-schema.json`.

**mac backend.** Today's osascript calls, moved verbatim. That includes `Show full text` and `open -e`.

**wsl backend.**

1. **Request.**
   - **Where it goes:** `~/prwatch/state/ui/req/<id>.json`. It is written with mode 0600 to a `.tmp` file and then
     renamed. `state/` is already sandbox `denyWrite`.
   - **`id`:** 32 hex characters.
   - **Fields:** `{v,id,kind,title,subtitle,summary,body,sound,buttons,timeout_s,created}`. Each field must match
     `ui-schema.json`.
   - **`body`:** for `confirm-post`, it is built **from the bytes of the snapshot `$snap`** (`post/body-as-posted.md`),
     the same file that is fingerprinted and posted. It is capped at 64 KB.
2. **Broker.** The broker is `/usr/local/sbin/prwatch-uibroker` (root:root 0755), rendered with the watcher uid and
   home.
   - **How it starts.** The helper starts **one** long-lived broker:
     `wsl.exe -d PRWatcher -u root --exec /usr/local/sbin/prwatch-uibroker`. `--exec` avoids a root shell and rc
     files.
   - **Instance and environment.** The broker takes `flock /var/lib/prwatch/ui/broker.lock`, so there is a single
     instance, and it re-execs itself under `env -i`.
   - **Polling.** It polls the local req dir every 1 s (`zselect`, no fork).
   - **Reading a request.**
     1. Open with `sysopen -r -o nofollow`.
     2. Run `zstat` **on the open fd**: it must be a regular file owned by the watcher uid.
     3. Read **at most 131 073 bytes** and refuse if the last one arrives (over 128 KB).
     4. Hash exactly the bytes that were read.
     5. Only then parse with `jq` against the schema.
   - **Replay and flooding.** It refuses an id that already has a `resp/` file or appears in today's
     `/var/lib/prwatch/ui/seen`. It also rate-limits:
     - at most 20 notifications a minute;
     - **at most one open confirm**.

     The seen list is a per-day directory under `/var/lib/prwatch/ui/seen/<date>/`, one empty file per id.
     - Lookups are a `zstat` existence test across **today's and yesterday's** directories, so an id stays known for
       a rolling 48 hours and no file is scanned.
     - Older directories are removed at broker start and at midnight rollover, never while handling a request.
     - The broker also refuses any request whose `created` time is more than 900 s old.
     - The hash is taken over the buffered bytes, never by re-reading the path.

     Excess requests are dropped and logged. A dropped confirm is answered `Cancel`, and the broker sends one
     notification: "a confirm dialog is already open — the second one was cancelled". That way Jack knows why.
   - **Forwarding and answers.**
     - It forwards each request once, on stdout, as `{req, req_sha256}`.
     - It reads `{"id","answer"}` lines on stdin. An `answer` must be one of that request's `buttons`, or `Timeout`.
     - It writes `/var/lib/prwatch/ui/resp/<id>.json` = `{id,answer,req_sha256}` to a temp file in the root-only dir,
       then renames it.
   - **Heartbeat.** It touches `broker.alive` every 5 s.
   - **Handshake.** It records the helper version sent at handshake (see §4 check 10). If the version is missing or
     doesn't match, it answers every confirm `NoHelper`.
   - **Clock.** If S7 shows drift, it runs `hwclock -s` on a wall-clock jump of more than 60 s against its monotonic
     counter.
3. **Helper.** `PRWatcherHelper.ps1`, run under Windows PowerShell 5.1 with `-STA -NoProfile`.
   - **Reading broker output.** It reads broker lines with a **blocking** read, uses `ConvertFrom-Json` with a size
     cap, and validates each request against `ui-schema.json`. It never runs `Invoke-Expression` and never
     dot-sources anything.
   - **Broker restarts.** If the broker hits EOF, the helper restarts it with backoff.
   - **Version.** At startup the helper computes the sha256 of its own deployed `.ps1` files and `ui-schema.json`,
     and sends it at handshake. Nobody bumps a version number by hand. Pester loads the schema and corpus from the
     **repo** paths, never from a copy.
   - **Toasts.** Jack's choice (2026-10-01): every notification **stays on screen until he dismisses it**, for every
     notification kind. There is no transient style.
     - The XML DOM is built with `CreateTextNode`.
     - **Persistence.** Every toast uses `scenario="reminder"`, which Windows keeps on screen until dismissed.
       Microsoft's toast schema says the reminder scenario "will be silently ignored unless there's a toast button
       action". So each toast carries **exactly one** action: the system-handled Dismiss button
       (`activationType="system"`, `arguments="dismiss"`). **VERIFY (S5):** that this button is enough to keep a
       reminder on screen.
     - **Still no app activation.** No other action, no `launch` attribute, and no app-defined arguments.
       - The AUMID is registered under `HKCU\Software\Classes\AppUserModelId\<AUMID>` (display name and icon only).
         It is not registered on the launcher shortcut.
       - No `ToastActivatorCLSID`, COM activator or protocol is registered, so a click on the toast body has nothing
         to launch.
       - Windows handles Dismiss alone. **VERIFY (S5):** clicking the toast body launches nothing (no new watcher
         window, no helper activation logged). If it does, the AUMID registration is changed before Phase 4 is done.
     - **Replacement, not pile-up.** Each toast has `Group="prwatch"` and a `Tag` made of the first 16 hex characters
       of sha256(kind|ref). A newer notification of the same kind for the same PR replaces the older one. The
       broker's rate limits (20 a minute) apply before the helper sees anything.
     - Sounds come from a fixed map.
     - **When the fallback is used.** Before every toast, the helper reads `ToastNotifier.Setting`.
       - Anything other than `Enabled` (`DisabledForApplication`, `DisabledForUser`, `DisabledByGroupPolicy`,
         `DisabledByManifest`) means the **notice window** is used instead. So does an exception from `Show()`.
       - If S5 shows the reminder doesn't stay up, the notice window becomes the only path, chosen by a constant in
         the helper.
       - **Do Not Disturb is respected, as on the Mac**, where Focus also holds notifications back. Toasts sent
         during Do Not Disturb wait in the notification centre until dismissed, and the console window still shows
         everything. W1 records what happens.
     - **The notice window** replaces the `NotifyIcon` balloon, which disappears on its own.
       - **Content:** a read-only multi-line text box (not one label per notice), so text is never parsed as
         markup or mnemonics. One Close button. It stays until closed: no timer, and no `Close()` outside the
         Close button's handler.
       - **Size:** newest first, capped at **50** entries. Older ones are dropped, with a line saying "N older
         notices not shown — see notify.log" (`notify.log` already has every notice).
       - **Focus:** it is shown without activation (`ShowWithoutActivation`), so it never takes the keyboard. While
         a confirm dialog is open, it drops out of TopMost, so it can never cover Post or Cancel.
   - **Confirm dialog.**
     - It is a TopMost WinForms form showing the summary, then the full body in a read-only scrolling box.
     - **Cancel** is the default and Accept button, so Enter and Esc both cancel.
     - **Post** (or **Run**) stays disabled for 2 s.
     - It closes itself with `Timeout` after 840 s.
   - **Keep-awake.** For its whole life it holds `SetThreadExecutionState(ES_CONTINUOUS|ES_SYSTEM_REQUIRED)` on its
     own thread. This replaces `caffeinate -i`.
4. **The script waits for the answer.**
   1. If `broker.alive` is older than 15 s, the answer is `NoHelper`, and post exits 11 with "Not posted (desktop
      helper not running)".
   2. Otherwise it polls `resp/<id>.json` every 0.5 s (`zselect`) for up to 900 s.
   3. It trusts the answer **only if** all of these hold: the file is a regular file and not a symlink; it is owned
      by uid 0; its `id` matches; and its `req_sha256` equals the sha256 of the request bytes the script wrote.
      Anything else is `Cancel`, and it is logged.
   4. Both files are removed afterwards.
5. **Why answers go through root.** A watcher-uid process can write anything under `~`, but it can't write
   `/var/lib/prwatch`: there is no root path (§4) and interop is off. This restores the T-CGEvent guarantee: nothing
   in the session can answer the dialog.
6. **Test-mode limits.**
   - `PRWATCH_UI_RESP_DIR` and `PRWATCH_BUILDRUN_FAKE` are honoured **only** when `PRWATCH_TESTMODE` is set. Without
     test mode they are ignored: the real resp dir and the real recipes are used.
   - In test mode `post.sh` is always a dry run and refuses `PRWATCH_DRY_POST=0` (§4).
   - With a test resp dir set, `buildrun.sh` refuses to run unless `PRWATCH_BUILDRUN_FAKE` is also set (that runs a
     fake recipe).
   - All three variables (`PRWATCH_UI_RESP_DIR`, `PRWATCH_BUILDRUN_FAKE`, `PRWATCH_DRY_POST`) get guard tripwire
     entries and `.tsv` rows. The model can't set any of them, because env prefixes are already blocked.
   - Harness cases and mutations 16–17 (§11) prove each one is ignored outside test mode.
7. **Trust root.** The trust root is Jack's Windows account, just as his macOS account is today. This is documented.

**`post.sh` hardening (applies on both OSes):**
- The fingerprint of `$snap` is checked again after the answer, just before `gh pr review --body-file $snap`. If it
  changed, exit 8.
- A draft containing CR or a UTF-8 BOM is rejected with exit 9: "the draft has Windows line endings or a BOM — save
  it with Unix (LF) line endings, then say edited".
- **Already reviewed from the other machine.** Jack runs the Mac watcher in the office and the Windows one at home,
  and each keeps its own state. So `post.sh` also asks GitHub.
  - **What it reads.** `gh api --paginate "repos/$R/pulls/$n/reviews?per_page=100"`, combined with `jq -s`, so a
    review on page 2 or later is still seen.
  - **What counts as a match.** All of these must hold:
    - `.user.login` equals the watcher's GitHub login, compared case-insensitively;
    - `.commit_id` equals the full 40-character `$sha`;
    - `.state` is not `PENDING`.

    A pending review Jack has started on github.com but not submitted posts nothing, so it doesn't count. A
    `DISMISSED` review does count: it still blocks a repost on that commit. Jack can review the next commit, or post
    by hand.
  - **One login value.** The login lives in one constant, `PRW_GH_LOGIN` in `bin/prwatch-platform.zsh`. `post.sh`
    and `prwatch-tick.sh` both use it; the tick's re-request lookup hard-codes it today.
  - **On a match** it refuses with exit 7 (the existing "already posted" code) and the message "you already
    reviewed this commit (from your other machine?) — not posting".
  - **When.** Once in step 4, before the dialog. Again after Jack clicks Post, just before `gh pr review`, so a
    review posted elsewhere while the dialog was open is caught. `--allow-stale` doesn't bypass it.
  - **This machine stops asking.** Before exiting 7, `post.sh` records the key as `posted` with `posted_sha=$sha`
    through `prwatch-state.sh`, as it already does after a successful post. The `/prwatch-decide` exit-7 line becomes
    "already posted for this commit (here or from your other machine); nothing more to do". Phase 4 step 18 owns
    that `SKILL.md` edit, so it ships with the check.
  - **Fails closed.** If `gh` fails, returns something that isn't JSON, or `jq` fails, the post doesn't go ahead:
    exit 10, as for the existing live PR check. It is never treated as "no match".
  - **Dry runs** report the finding and exit 0. They don't record `posted`.
  - **Tests.** The `gh` stub gains a call log (`$T/gh.log`) and a per-call answer sequence (a counter file), so the
    reviews read can answer differently before and after Post. Harness cases:
    1. a match before the dialog → exit 7, no confirm shown (the UI log has no confirm), no `pr review` call, and
       state `posted` with `posted_sha=$sha`;
    2. no match before, a match after Post → exit 7, no `pr review` call, state `posted`;
    3. a review on a different commit → posts;
    4. a `PENDING` review on the same commit → posts;
    5. the match on page 2 of a paginated answer → exit 7;
    6. `gh` fails on the reviews read → exit 10, no `pr review` call, state unchanged;
    7. non-JSON reviews output → exit 10, state unchanged;
    8. a dry run with a match → reports it, exit 0, state not `posted`.

    Mutations: 28 drops the check after Post, 29 drops the check before the dialog, and 30 drops the `PENDING`
    filter.
- **GitHub behaviour to confirm.** The plan relies on a submitted review of any kind (including Comment only)
  removing Jack's review request, so the PR leaves `user-review-requested:@me` on both machines. This is checked
  once on a test PR before Phase 4 is done, and recorded in BUILD-NOTES.
- **Accepted:** before the other machine withdraws a reviewed PR (two ticks), it could start one extra council on
  it. That wastes effort and posts nothing.

### 7. Launchers

**`bin/prwatch-launch.zsh` (shared).** This is today's `.command` body, with these changes:
- platform calls replace the Mac paths;
- the lock match uses `PRW_LAUNCHER_MATCH`;
- on the Mac it starts `caffeinate -i -w $$`;
- on WSL it runs `prw_wsl_preflight` (§4).

The watchdog, the banner (whose cap numbers the harness checks), the env exports and the `claude` flags are all
unchanged.

**Mac `launcher/PR Watcher.command`.** It becomes `#!/bin/zsh -l` plus `exec "$HOME/prwatch/bin/prwatch-launch.zsh"`.
The macl problem with replacing the Desktop launcher then almost never happens.

**Windows `PRWatcher.ps1`.** The Desktop shortcut "PR Watcher" opens it in Windows Terminal, as
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File`. ExecutionPolicy is not a boundary: the files are protected
because nothing in the distro can reach them. The script:
1. starts the helper (one instance only, via a named mutex);
2. waits for `broker.alive`;
3. runs `wsl.exe -d PRWatcher --cd ~ --exec <home>/prwatch/bin/prwatch-launch.zsh` in the foreground;
4. stops the helper when that exits.

**Test parameters.** The whitelist is `-TestMode`, `-OnlyPr <key>` and `-Now <time>`. There is no `-DryPost`: test
mode is always dry (§4).
- `-OnlyPr` must match `^ACT-Training/[A-Za-z0-9._-]+#[0-9]+(,ACT-Training/[A-Za-z0-9._-]+#[0-9]+)*$`.
- `-Now` must match `^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$`.
- Only with `-TestMode` does the script run `--exec /usr/bin/env PRWATCH_TESTMODE=1 PRWATCH_ONLY_PR=… PRWATCH_NOW=…
  <launcher>`. Without it, none of these variables are set.

This is the T6/W6 route.

Pester covers `PRWatcher.ps1` with `wsl.exe` behind a seam:
- an unknown parameter is rejected;
- `-OnlyPr` and `-Now` values containing `;`, a backtick, `$()` or a space are rejected;
- the exact `wsl.exe` argv for both a normal launch and a test launch;
- `PRWATCH_TESTMODE` is present only with `-TestMode`;
- a second instance reuses the running helper (named mutex).

**Closing the window.** Closing the window ends `wsl.exe`, sends SIGHUP and claude exits (T9).

**`install-windows.ps1`** runs as Jack, not elevated. It:
1. copies `windows\*.ps1` and `ui-schema.json` from the in-distro clone to `%LOCALAPPDATA%\PRWatcher\`;
2. checks that the deployed files hash to the same version the renderer computed from the repo;
3. writes `config.json` `{distro, linuxUser, linuxHome}`;
4. registers the toast AUMID and the Desktop shortcut;
5. runs `wsl.exe -u root --exec …/install-root.zsh`, then `wsl.exe --terminate PRWatcher`. `wsl.conf` changes only
   take effect when the distro restarts, so without the restart the first launch would fail preflight check 5 with
   no explanation;
6. runs `PRWatcherHelper.ps1 -SelfTest`.

It is idempotent: a second run changes nothing. Pester covers it, with `wsl.exe` behind a seam.

### 8. Locking

The lock set is the manifest's `lock` class, and `prwatch-render.zsh --lock-commands` prints the exact commands.
- **On the Mac:** `chflags -R uchg …`.
- **On WSL:** a PowerShell line, `wsl.exe -d PRWatcher -u root --exec chattr -R +i <every lock path>`.

On WSL only Windows-side Jack can unlock, which is stronger than `uchg`, since the owner can clear that flag.
`install.sh` refuses while `prw_locked` is true.

### 9. Wording

- **`CLAUDE.md` invariant 2** adds `powershell`, `pwsh`, `cmd.exe`, `wsl.exe`, `*.exe`, `bwrap`, `chattr` and `sudo`.
- **Skills:** "a Mac dialog" becomes "the confirm dialog", and "on your Mac" becomes "on this computer".
- **The pre-dialog line comes from the UI seam:**
  - on the Mac it says "Cmd-Tab to 'osascript'";
  - on WSL it says "Alt-Tab to 'PR Watcher - confirm post'".
- **`/prwatch-start` test 8** uses `@HEADLESS_GLOB@`.
- **The guard tripwire** adds
  `\.exe|pwsh|bwrap|chattr|sudo|prwatch-uibroker|PRWATCH_UI_RESP_DIR|PRWATCH_BUILDRUN_FAKE|PRWATCH_DRY_POST|PRWATCH_TESTMODE|PRWATCH_STUB_BIN`,
  with a `.tsv` row for each.

### 10. `/prwatch-start` self-tests (WSL; mac prints `n/a`)

These are in-session confirmations of the preflight, plus checks only the sandbox can show. Any failure blocks
scheduling.
- **9.** `cmd.exe /c ver` fails.
- **10.** `/mnt/c`, `/mnt/wslg` and `/var/run/docker.sock` are absent.
- **11.** A sandboxed Python `socket.socket(socket.AF_UNIX)` fails, which shows the seccomp filter is active.
- **12.** Sandboxed `cat ~/.claude/.credentials.json` and `ls ~/.config/gh` both fail.
- **13.** A sandboxed `touch /var/lib/prwatch/ui/resp/x` fails.
- **14.** `legacy_tiocsti` is `0`.

### 11. Test strategy

**`run.sh` changes:**
- It sources the platform lib and prints `platform: X`.
- `skip()` names every skip.
- The summary reads `P/N passed, S skipped (platform=X, commit=<sha>)` and is also written to
  `test/state/summary-<platform>.txt`.
- **Minimum counts:**
  - The Mac minimum is the Phase-1 baseline count recorded in BUILD-NOTES, and it may never go down.
  - Every case is tagged `all`, `mac` or `wsl`. The WSL minimum is **derived** from those tags (the `all` and `wsl`
    cases), not maintained by hand. The only number kept by hand is the Mac baseline floor, and a run that executes
    fewer than its platform's minimum fails.

**One UI test double.** `ui_log` normalises both backends' calls to the same JSONL:
- on the Mac, the stub osascript calls, with the log moved into `$T`;
- on WSL, the spool requests.

The stub answers come from `PRWATCH_STUB_ANSWER`.

**New cases:**
- **Rendering:** golden `cmp` for mac and wsl; idempotence; each renderer refusal path (bad `$HOME`, unknown token,
  leftover token, missing source, symlinked destination, leftover `/Users/` on WSL).
- **Manifest cross-checks** (§3).
- **Platform lib:**
  - detection via fake roots; unknown platform exits 70;
  - the lint;
  - a timing budget for 100 guard runs against the Mac baseline.
- **Builtins:**
  - `zstat` throttle at 1799, 1800 and 1801 s;
  - cap freshness at 59, 60 and 61 s;
  - files backdated portably with `touch -t $(strftime …)`.
- **DST:**
  - `PRWATCH_NOW` across the 2026-03-29 gap and the repeated hour on 2026-10-25;
  - pause across both changes.
- **Confinement:**
  - golden SBPL output on the Mac;
  - bwrap argv against the profile declarations;
  - live escape cases on WSL. Each must fail: reading `~/.ssh`, `curl`, connecting to `127.0.0.1:3306`, reading
    `/mnt/c`, running `cmd.exe`, TIOCSTI.
- **Spool and broker:**
  - the shared corpus, valid and hostile: `x" & (do shell script "id") --`, `$(id)`, a backtick,
    `"; Start-Process calc; "`, CRLF, NUL;
  - broker refusals: non-hex id, `../`, unknown id, replay including across a restart, an answer not in the buttons,
    a symlink, the wrong owner, an oversize body, a second open confirm, a notification flood;
  - fd-based checks: a file swapped after open is still refused.
- **Responses and post:**
  - forged, mismatched, symlinked or stale responses → `Cancel`;
  - `draft/` swapped after the answer → nothing posted;
  - fingerprint changed after the answer → 8;
  - CR or BOM in the draft → 9.
- **Test-mode escape hatches.** Each case below runs with `PRWATCH_TESTMODE` **unset**:
  - `PRWATCH_UI_RESP_DIR` points at a dir containing a forged `Post` → the real resp dir is used (nothing is answered,
    so the result is Timeout or NoHelper);
  - `PRWATCH_BUILDRUN_FAKE` is set → ignored, and the real recipe path (behind the dialog) is used;
  - the launcher with test-mode variables but no `PRWATCH_TESTMODE` → a normal launch, full preflight against `/`.

  And these run with test mode on:
  - `buildrun` with a test resp dir but no FAKE → refused;
  - `post.sh` with `PRWATCH_DRY_POST=0`, both with and without a test resp dir → refused (exit 64);
  - a launcher test-mode session exports `PRWATCH_DRY_POST=1`.
- **Launcher:**
  - one case per `prw_wsl_preflight` check, each made to fail by calling the function with a fakeroot;
  - a case that the launcher calls the preflight with **no** argument, by grep and by running it under a fake `PATH`;
  - a stale or missing helper version → the broker answers a confirm `NoHelper`;
  - a Mac case that the wrapper starts `caffeinate`.
- **`install.sh` WSL branch:**
  - refuses while `prw_locked` is true;
  - names each missing dependency;
  - contains no `sudo` call (grep, plus a run with a `sudo` stub that fails the test if it is invoked);
  - a second run is idempotent.
- **`install-root.zsh`**, run against a fakeroot: it sets the `root-installed` owners and modes, removes the user
  from the groups, and locks the root password (stubbed `usermod`, `passwd`); a second run is idempotent.
- **Guard:** the new `.tsv` rows for WSL and test-mode variables.

**Windows side.** Pester 5 tests for the helper (`-SpoolRoot` and `-AckCommand` seams) and for
`install-windows.ps1` (`wsl.exe` seam). They cover:
- the shared corpus;
- that hostile text is shown as literal text;
- that a timeout never produces `Post`;
- that a request is handled exactly once;
- that a version is sent;
- that a second install run changes nothing.

The helper also has a `-SelfTest` switch for the live box.

**Mutation pass (blocking for acceptance).** Each of these mutations is applied in turn. A test must fail for each,
and the result is recorded in BUILD-NOTES:
1. drop `nofollow`;
2. check owner and size by path instead of fd;
3. skip the replay check;
4. accept any answer;
5. drop the `req_sha256` comparison;
6. drop the uid-0 owner check on the response;
7. drop the post-answer fingerprint re-check;
8. drop the CR/BOM check;
9. remove `--unshare-net`;
10. bind `$HOME`;
11. remove `--new-session`;
12. remove each new guard regex alternative;
13. remove each preflight check (check 11 is split into 13a, 13b and 13c, one per condition);
14. let the renderer leave a token;
15. drop a manifest path from `denyWrite`;
16. honour `PRWATCH_UI_RESP_DIR` without test mode;
17. honour `PRWATCH_BUILDRUN_FAKE` without test mode;
18. let the launcher pass a fakeroot (or read one from the environment);
19. drop the open-confirm cap;
20. don't read the `seen` dirs at broker start;
21. skip the unclassified-entry manifest check;
22. accept a confirm from a helper with a mismatched version;
23. don't force `PRWATCH_DRY_POST=1` in a test-mode launch;
24. drop the `buildrun` FAKE requirement when a test resp dir is set (its target case asserts exit 64, the scripts'
    usage-refusal code, and that no recipe ran);
25. drop `post.sh`'s test-mode refusal of `PRWATCH_DRY_POST=0` (its target case asserts exit 64 and that the `gh`
    stub log has no `pr review` or `pr comment` call, not just a non-zero exit);
26. drop the canonical-hash LF/BOM normalisation on the zsh side;
27. edit one line of the guide's marked `wsl.conf` block (the guide-vs-config case must fail);
28. drop `post.sh`'s second already-reviewed check, the one after Post (the "review appears while the dialog is open"
    case must fail);
29. drop `post.sh`'s first already-reviewed check, the one before the dialog (the "match before the dialog" case
    must fail on "no confirm shown");
30. drop the `PENDING` filter from the already-reviewed match (the "pending review → posts" case must fail).

**The mutation list is data:** `test/mutations.tsv` holds the id, the file, the patch (a zsh fixed-string substitution) and the target
cases. `test/mutate.zsh` applies each mutation to a temp copy, runs its target cases and expects at least one
failure. It prints a table with three outcomes: **killed**, **survived**, and **did not apply** (the substitution
matched nothing). A "did not apply" fails the run just as a survivor does, so a refactor that removes a patch's
target string can't quietly retire its mutation.
- **Merge rule:** any PR touching the broker, `prwatch-ui.zsh`, `prwatch-confine.zsh`, `prwatch-render.zsh`,
  `post.sh`, `buildrun.sh`, the preflight, the guard or the manifest must attach a fresh `mutate.zsh` table with no
  survivors and nothing that failed to apply, so the record never goes stale.
- **Runtime ceiling:** 10 minutes, measured warm on Jack's Windows laptop ("warm" means the second consecutive run,
  with the NuGet and npm caches already populated). If the pass grows beyond that, it moves to a nightly run, and the merge rule then
  runs only the mutations whose files the PR touches.

Each mutation is tagged with the cases it targets. Only those cases run per mutation, followed by one full run at the
end. The guard timing budget uses the median of 3 runs with a 1.5× tolerance, runs once (not once per mutation), and
Pester runs separately from `run.sh`.

Pester gets eight mutations:
1. string-concatenated toast XML;
2. a timeout that returns `Post`;
3. no schema validation;
4. `PRWatcher.ps1` accepting an `-OnlyPr` value with `;`;
5. `PRWatcher.ps1` setting `PRWATCH_TESTMODE` without `-TestMode` (the Windows twin of mutation 18);
6. dropping the canonical-hash LF/BOM normalisation on the PowerShell side;
7. a toast without the system Dismiss action, without `scenario="reminder"`, or with any other action or a `launch`
   attribute (the toast-XML case asserts `scenario="reminder"`, exactly one action, `activationType="system"` /
   `arguments="dismiss"`, and no `launch`);
8. the fallback notice window closing itself. It is killed in two ways:
   - a static case parses the helper's AST and fails on any `Timer` or `AutoClose` in the notice-window code, or any
     `Close()` outside the Close button handler;
   - a behavioural case opens the window in test mode with an injectable clock, advances it by an hour, and asserts
     the window is still open, holds at most 50 entries, and shows the "older notices" line after the 51st.

Pester also includes a case that hashes the deployed schema and corpus against the repo copies, and the
cross-language canonical-hash case (§4 check 10).

**`live-check.sh` changes:**
- **F:** checks that the real Claude sandbox can't exec `.exe`, can't see `/mnt`, and can't open AF_UNIX.
- **G:** a helper round trip. It is skipped visibly when the helper is absent, and **that skip fails Phase 7
  acceptance**.
- **D on WSL:** runs the bwrap-confined dotnet test.

**Merge rule.** A PR touching shared scripts attaches both platforms' `summary-*.txt` files, stamped with the same
commit.

### 12. Mac T-tests → WSL W-tests

| Mac | WSL | What differs on WSL |
|---|---|---|
| T0 first launch | W0 | Desktop shortcut. The preflight prints every check OK. Self-tests 1–14 OK. Then `stop`, `/exit`. |
| T1 notifications | W1 | Run `prwatch-notify.sh test x` while the watcher window is open. Expect a toast and a `notify.log` line. The toast stays on screen until you click Dismiss (wait at least 5 minutes; record the times shown, checked and dismissed, with a screenshot, as in S5). Clicking the toast body launches nothing. Turn notifications off for PR Watcher and repeat: the fallback notice window appears and stays until closed. Also try Do Not Disturb on and off, and record what happens (toasts should wait in the notification centre, as on the Mac). |
| T2 prep | W2 | Same command. The restore print shows `--share-net`. Run it twice: the second restore takes under 10 s. |
| T3 window times | W3 | Same, plus 2026-03-29T01:30 and 2026-10-25T01:30. |
| T4 sim2 | W4 | Same. |
| T5 guard | W5 | `.tsv` command. 0 mismatches. The count of `all` rows equals the Mac's. |
| T5b lock-down | W5b | Same as the Mac, and each of these is also denied or fails: `cmd.exe /c ver`, `ls /mnt/c`, `cat ~/.claude/.credentials.json`, `wsl.exe -u root`. |
| T6 dry run | W6 | `PRWatcher.ps1 -TestMode -OnlyPr 'ACT-Training/Vision#1803' -Now 2026-09-29T10:00`. The dialog comes through the helper. Post → `dry-run.txt`. |
| T7 question timeout | W7 | Same. |
| T8 two windows | W8 | Same mechanism as the Mac: the new launcher takes over `session.lock` (`PRW_LAUNCHER_MATCH`), and at its next tick the old window gets `superseded`, its "please close" toast, and stops. The second `PRWatcher.ps1` reuses the running helper through the named mutex. |
| T9 close mid-review | W9 | Same. Also try `wsl --shutdown` mid-review. Both re-queue. |
| T10 first real PR | W10 | Same. |
| T11 edited draft | W11 | Same. Also save the draft from Windows Notepad via `\\wsl.localhost`. A CRLF/BOM draft → exit 9 with the plain message. Otherwise exit 8. |
| T12 dialog left open | W12 | After 14 min → `Timeout` → `awaiting_decision`. Kill the helper mid-dialog → `Cancel`/`NoHelper`, never Post. A permission prompt left 30 min → "Waiting on you" toast. |
| T12b slow Post | W12b | Same. |
| T13 stopped early | W13 | Same. |
| T14 two PRs | W14 | Same. |
| T15 sandboxed tests | W15 | dotnet and ng run under bwrap (private network). `run tests` → helper "outside the test sandbox" dialog. |
| T16 title injection | W16 | Same hostile title. Literal in the spool JSON and in the toast. Nothing runs. |
| T17 cap | W17 | Same. |
| T-CGEvent | W-INPUT | From sandboxed Bash **and** from an approved `buildrun` child, try to answer an open throwaway dialog: write a forged `resp` file under `~` and under `/var/lib/prwatch` (EACCES); `powershell.exe` SendKeys (not found); `xdotool` (no display); TIOCSTI into the terminal (fails). The dialog stays unanswered. |
| — | W-INTEROP | The S3 escape list, run as the user, in the sandbox, and as root inside the distro. All fail. |
| — | W-FORGE | Forged, mismatched, symlinked or replayed responses, and a request swapped after it was written → `Cancel`. |
| — | W-SLEEP | Sleep the laptop for 30 min mid-day. Within 10 s of resume, the WSL clock is within 2 s of Windows. No false "Waiting on you". Ticks resume. |

## Risks & Trade-offs

**Mac regression from shared edits.**
- Gate (a) and gate (b) cover it.
- The renderer lands first, against `pre-wsl-port`.
- The launcher split is its own phase.
- The both-platforms merge rule applies.

**Facts we can't verify yet.** Phase 0 blocks everything else. A failed spike goes back to the council. The open
items are:
- whether `allowLocalBinding` is accepted on Linux;
- whether the seccomp filter blocks interop;
- whether root can re-enable WSLInterop;
- whether unprivileged bwrap works under the WSL kernel and AppArmor;
- whether `wsl --install … --name` and `wslinfo` exist;
- whether Group Policy allows toasts.

**Mid-port exposure.** **No live (non-test-mode) WSL session runs before Phase 7 acceptance.** Before then, WSL runs
are test-mode only, with posts as dry runs. Phase 2 (the security baseline) also lands before the broker exists.

**Admin rights on a work laptop.** WSL needs admin rights and virtualisation. Jack has admin rights on the laptop
(confirmed 2026-10-01), so no IT ticket is needed. S1 still records any blocker it meets.

**More moving parts on Windows.** Accepted, for isolation. Every failure resolves to "not posted".

**Network during restore and `buildrun`.** On the Mac, restore and `buildrun` have network access. Under WSL NAT they
can also reach the Windows host gateway and other distros' loopback.
- This is the same exposure class as the Mac's localhost.
- Tokens stay hidden.
- The docs advise against running listening services in other distros.
- A firewall rule is deferred.

**Plaintext tokens on Linux.** They are hidden from every PR-code path (bwrap), the session and the sandbox. Only
trusted watcher scripts can read them.

**Clock after sleep.** W-SLEEP and S7 measure it, and the broker resyncs the clock if needed.

**Toast persistence.** Decided: every notification stays until dismissed (Jack, 2026-10-01). It relies on
`scenario="reminder"` plus the system Dismiss button, which S5 verifies. If that doesn't hold, the persistent notice
window takes over (§6).

**Two watchers on one account.** Jack keeps both: the Mac in the office, and Windows when working from home
(confirmed 2026-10-01). The rule is **one machine per day**. If he switches part-way through a day, he types `stop`
in the first watcher window before starting the other. Two things protect against a slip:
- GitHub drops a PR from `user-review-requested:@me` once Jack reviews it, so the other machine stops tracking it
  (withdrawn after two ticks);
- `post.sh` refuses to post on a commit Jack has already reviewed (§6, "`post.sh` hardening").

A full cross-machine session lock stays deferred.

**Performance.**
- Everything lives on ext4, never `/mnt/c`.
- The libs are fork-free and lazy-loaded.
- Polling uses builtin `zselect`.
- The VM is sized at 12 GB plus 4 GB swap.

**Deferred** (not needed for parity):
- the separate PR-code uid (F);
- managed settings (G);
- a firewall or owner-match rule;
- a full cross-machine session lock (double posting is already covered by `post.sh`'s already-reviewed check);
- OSC 52 from untrusted output;
- DNS exfiltration during restore;
- GitHub Actions CI on three OSes.

## Suggested Task Breakdown

**Phase 0: verification spikes.** Run on the WSL machine. Blocking. Evidence goes into BUILD-NOTES. Pass criteria are
listed for each spike.

**S0: install guide first.** The install chapter of `docs/windows-wsl.md` is written before S1, with every step that
can only be proved on Windows marked VERIFY (S1) or VERIFY (S2). S1 and S2 are done **by following it**. Each fix
found on the way goes back into the guide in the same change, and its VERIFY marker is removed only when the step has
run as written. If the fix changes a value the plan also states (a package, a `wsl.conf` key, a `.wslconfig` value),
the plan is updated in the same change, because the plan wins on conflict.

The guide and plan must be **committed and pushed** before S1, because the distro clones the repo from GitHub (guide
step 6) and S2 reads the watcher files from that clone.

*Evidence:* BUILD-NOTES gets one line per guide step, in one of three forms:
- **ran as written**;
- **changed**, with a link to the guide fix;
- **VERIFY kept**, naming the spike that covers it.

*Pass:* every step from the start of the guide to the end of step 8 has an evidence line; no step is "VERIFY kept"
for S1 or S2. Markers for S3–S8 (for example the S4 Chrome-library marker) are expected to remain.

1. **S1: distro.** Install WSL and the `PRWatcher` distro (`--name`, or the `--import` fallback), following
   `docs/windows-wsl.md`. Apply `wsl.conf` and `.wslconfig`.
   *Pass:* `wsl -l -v` shows PRWatcher on version 2; `ls /mnt/c` fails; `wslinfo --networking-mode` prints `nat`, or a
   fallback is recorded. Record any IT or admin blockers.
2. **S2: Claude Code sandbox.** Install Claude Code natively, then bwrap, socat and the seccomp filter. Use a
   hand-rendered `settings.json`.
   S2 runs before Phase 1 and after the guide's lockdown. Because it runs before Phase 1, it:
   - hand-renders `prwatch-guard.sh` and `guard-cases.tsv` (`/Users/jack` → the Linux home), not just
     `settings.json`;
   - adds §3's **Secrets** reads to the hand-rendered `permissions.deny` and `sandbox.credentials.files` with one
     `jq` step, so the credential checks test the Linux deny list rather than today's Mac one.

   Phase 1's renderer replaces the hand-render, and the guide's block is deleted then.

   *Pass:*
   - the sandbox starts under `failIfUnavailable`, and there is no settings error;
   - reads of `~/.claude/.credentials.json` and `~/.config/gh` are refused with a sandbox or permission message,
     not just the model declining;
   - loopback works in sandboxed Bash;
   - every guard `.tsv` row gives its expected exit code. The check loop prints how many rows it checked, and that
     number equals the non-empty line count of the `.tsv`, so a silently skipped row fails. (The `all`-row comparison
     against the Mac only applies once Phase 1 adds the platform column.)
3. **S3: escape tests.** Run as the user, in the sandbox, and as root. Try:
   - `cmd.exe`;
   - `/init` with `WSL_INTEROP`;
   - writing `1` to `binfmt_misc/WSLInterop`;
   - connecting directly to `/run/WSL/*_interop`;
   - `ls /mnt/c` and `ls /mnt/wslg`;
   - AF_UNIX and `.credentials.json` (sandbox only);
   - TIOCSTI from a `setsid` child.

   *Pass:* every attempt fails, and `wsl.exe -u root --exec id` from Windows works.
4. **S4: bwrap prototypes.** Run each of these under its profile:
   - `dotnet restore -m:1` of Vision;
   - `dotnet test` of IntegrationTests, which exercises CookieContainer;
   - `ng test` with linux64 chrome-headless-shell and `--no-sandbox`;
   - a Python venv plus pip install;
   - a `buildrun`-style run.

   *Pass:* each completes with real results; a second restore takes under 10 s; `lo` is up in the private network
   namespace and Karma connects on 127.0.0.1; `/dev/shm` works for Chrome; a forced LIMIT kill **with `--new-session` on** reaps the
   whole tree (`pgrep -f <buildcopy>` is empty).
5. **S5: helper and broker on the ACT laptop.**
   *Pass:*
   - in 10 trials, a toast appears within 3 s at least 9 times (the 3 s budget includes the broker's 1 s poll);
   - a `scenario="reminder"` toast with only the system Dismiss button is still on screen after 5 minutes, and goes
     when Dismiss is clicked. If it isn't, BUILD-NOTES records that and the notice window becomes the main path;
   - clicking the toast body launches nothing: no new watcher window, and no activation in the helper log;
   - with notifications turned off for the app, the fallback notice window appears and stays until closed;
   - **soak:** 50 notifications in a row. Record the helper's memory and confirm the window still responds. Toasts
     for the same PR and kind replace each other, and the notice window holds 50 entries plus the "older notices"
     line.
   - **Evidence, on a pass as well as a fail:** BUILD-NOTES records, for the persistence checks, the time shown, the
     time checked (at least 5 minutes later) and the time dismissed, with a screenshot taken at 5 minutes or later;
   - the dialog round trip works;
   - `powercfg /requests` lists a SYSTEM request while the helper runs and none after it exits.
6. **S6: lock.**
   *Pass:* after `chattr +i`, Claude Code fails to write `.claude/settings.local.json` and `bin/x`.
7. **S7: clock.**
   *Pass:* after a 30-min sleep, the WSL clock is within 2 s of Windows within 10 s of resume (resync allowed);
   `date +%Z` shows GMT or BST.
8. **S8: Claude Code in Windows Terminal.**
   *Pass:* each of these is observed, with a transcript saved: AskUserQuestion; Esc; in-session cron firing;
   permission prompts; the OSC title; SIGHUP on window close.

**Phase 1: Mac groundwork, behaviour-neutral.**

9. Tag `pre-wsl-port`. Record today's `run.sh` count in BUILD-NOTES.
10. Add `.gitattributes` and renormalise:
    ```
    * text=auto eol=lf
    *.ps1 text eol=crlf
    *.cmd text eol=crlf
    *.png binary
    watcher/test/fixtures/hash/** -text
    ```
11. Add `prwatch-render.zsh`, the tokens, the golden fixtures, and the single `guard-cases.tsv`. **Gate (a):** the
    token-only files render byte-identical to `pre-wsl-port`. The same change deletes the hand-render block (and its
    `jq` secrets list) from guide step 8b, which then says to run the renderer.
12. Add `protected-paths.tsv` and the manifest cross-checks, plus `--lock-commands`.
13. Add `prwatch-platform.zsh`, the ordering invariant and lint, the builtins, `kill_strays` moved into the lib, the
    epoch-based pause with DST tests, and portable backdating in `run.sh`.
14. Harness infrastructure: the platform header, `skip()`, minimum counts, the summary file, the `ui_log` double,
    and `osa.log` moved into `$T`.
    **Gate (b):** the Mac harness (count ≥ baseline), live-check, T3, T4 and T5, plus a reviewed diff.

**Phase 2: WSL security baseline.** This lands before any UI or confinement code.

15. The superset settings, the guard tripwire, the new `.tsv` rows, and the `CLAUDE.md` and skill wording.
16. `install-root.zsh` and `prw_wsl_preflight`, with one harness case per check (fakeroot argument). Also self-tests 9–14
    and live-check F. `watcher/config/wsl.conf` becomes the owner of the `wsl.conf` body. `install-root.zsh` writes
    it at guide step 7, and preflight check 6 compares the deployed file with it. The same change deletes the body from
    §4, which then points at the file.
    - **Guide step 3d stays a hand step.** It runs before the repo is in the distro (step 6), so `install-root.zsh`
      can't run there yet.
    - 3d keeps writing the **whole** body as a bootstrap. It is only four sections, so a subset would save nothing,
      and the whole body keeps TIOCSTI hardening on from the start.
    - At step 7, `install-root.zsh` overwrites it with the rendered file, and check 6 catches any difference in the
      deployed file.
    - A harness case also compares the guide's 3d heredoc with `config/wsl.conf`, so the guide's copy can't drift
      either. The config file stays the one owner, and the guide's block is a checked copy of it. **How the case
      works:**
      1. **Anchor.** The guide wraps the block in `<!-- wsl.conf:begin -->` and `<!-- wsl.conf:end -->`. The case
         takes the lines strictly between `cat > /etc/wsl.conf <<'EOF'` and the closing `EOF` inside those markers.
      2. **Fail closed.** If it finds no marked block or more than one, the case fails.
      3. **Substitution.** The guide uses the real username (`jackscammell`) so its commands can be pasted as they
         are. It declares the username once, in `<!-- linux-user: jackscammell -->`. The case reads that
         declaration, and fails if it is missing or appears more than once. It renders `config/wsl.conf` with
         `@LINUX_USER@` set to that name, and fails naming any `@…@` token it can't map. It compares the result with
         the guide's block.
         - **Rename safety.** The case also checks that the guide's username-bearing commands name the declared user:
           `adduser`, `usermod -aG`, `gpasswd -d`, `grep -n … /etc/sudoers`, `id`, `default=` and `/home/…`. It fails
           naming any line that uses a different name, so a rename can't leave the step 7a lockdown checks pointing
           at the old user.
         - **Seeded faults.** Three harness cases must each fail and name the reason: the guide with no declaration,
           the guide with two, and a config containing an unknown `@FOO@`.
      4. **Byte-exact comparison.** Each side is normalised to end in exactly one `\n`.
      5. **Mutation 27** edits one line of the guide's block, and the case must then fail.

**Phase 3: confinement seam.**

17. `prwatch-confine.zsh`: the profile declarations, the Mac backend (golden SBPL) and the bwrap backend. Wire it into
    prep, ngtest, dotnettest and buildrun (WSL). Add the print and live escape cases.

**Phase 4: UI seam, broker and helper.**

18. `ui-schema.json` and its corpus. `prwatch-ui.zsh`: the Mac backend moved verbatim, and the spool backend. Wire it
    into notify, post and buildrun. Add the snapshot-body rule, the post-answer fingerprint re-check, CR/BOM
    rejection, the test-mode limits, and the already-reviewed check (§6 "`post.sh` hardening", mutations 28–30).
    The same change:
    - adds `PRW_GH_LOGIN` to `prwatch-platform.zsh` and makes `prwatch-tick.sh` use it;
    - extends the `gh` stub with its call log and answer sequence;
    - edits the exit-7 line in `.claude/skills/prwatch-decide/SKILL.md`.

    These `post.sh` changes apply on the Mac too, so the Mac harness runs with them before Phase 4 is done.
19. `prwatch-uibroker` and its harness cases.
20. `PRWatcherHelper.ps1` and its Pester tests. Add live-check G.

**Phase 5: launcher split.**

21. `prwatch-launch.zsh`, the Mac wrapper, `PRW_LAUNCHER_MATCH` and `PRWatcher.ps1` with test parameters. Re-run the
    Mac harness, plus T0, T8 and T13 on the Mac.

**Phase 6: install and docs.**

22. The `install.sh` WSL branch: a dependency check that names anything missing, refusal while locked, and no sudo.
    Also `install-windows.ps1` with its Pester tests.
23. Complete `docs/windows-wsl.md`. The install chapter has existed since S0 (prerequisites to lockdown); this step
    adds the sections that depend on Phases 2–5 and replaces the hand-done lockdown with `install-root.zsh`. The
    finished guide covers:
    - prerequisites (admin rights, which Jack has, and virtualisation);
    - `wsl --install --no-distribution`, then creating the distro, with an `--import` fallback;
    - `wsl.conf` and `.wslconfig`;
    - the apt packages and the gh apt repo (the list is owned by guide step 4a);
    - .NET into `/usr/local/share/dotnet`, and nvm and Node (versions as guide steps 4c and 4d say);
    - the Claude Code native installer and the seccomp filter;
    - chrome-headless-shell and its libraries;
    - `gh auth login` with a device code, and Claude login by copying the URL;
    - cloning inside the distro, `install.sh`, and `install-windows.ps1`;
    - notifications and Do Not Disturb;
    - locking via `--lock-commands`;
    - the §12 W-checklist;
    - update, and uninstall (`wsl --unregister` deletes the archive, so copy it out first);
    - a "Troubleshooting" section keyed by preflight message.

    Steps stay marked VERIFY until S1–S8 confirm them. `README.md` gets one line (its layout rows for both Windows docs exist since r6).
    `watcher/README.md` stays the single daily-use source, with short "Windows:" notes. It gains an "Office (Mac) or
    home (Windows)" note: one machine per day, and type `stop` in the first window before switching. Its lock section points to
    `--lock-commands`.

**Phase 7: mutation pass and acceptance.**

24. Run the mutation pass (§11). Every mutation must be killed, and the results recorded in BUILD-NOTES.
25. On WSL: the harness, the §12 W-checklist, and live-check including G (a skip fails).
26. On the Mac: the full regression run: the harness, live-check, T0, T3–T6, T8, T12, T16 and T17.
27. Lock both installs. Add the BUILD-NOTES entry. Only after this do live WSL sessions begin.

## Open Questions

All five questions were answered by Jack on 2026-10-01.

1. **Resolved.** Jack has admin rights on the laptop, so no IT ticket is needed.
2. **Resolved.** The Linux username is `jackscammell`.
3. **Resolved.** Both stay in use: the Mac watcher in the office, and the Windows one when working from home. The
   Mac install must keep working, which was already a goal. Risks ("Two watchers on one account") has the
   one-machine-per-day rule and the double-post guard.
4. **Resolved.** Every notification stays on screen until dismissed (§6).
5. **Resolved.** Docker Desktop isn't installed on the laptop. It may be installed later; the watcher doesn't need
   it. If it is installed:
   - its WSL integration stays **off** for `PRWatcher`;
   - its "Expose daemon on tcp://localhost:2375 without TLS" setting stays **off**;
   - preflight check 3 (`/var/run/docker.sock` absent) refuses to launch if the integration is switched on;
   - guide step 8a is re-run.

## Revision log

**r3 (round-1 review: architecture REJECT, maintainability REJECT, testing REJECT, security APPROVE-WITH-NOTES,
performance APPROVE-WITH-NOTES)**

- **[arch B1]** The byte-identical gate contradicted Phase 1's script edits. Resolved:
  - it is now split into gate (a), renderer on token-only files vs `pre-wsl-port`, and gate (b), harness,
    live-check, T-tests and a reviewed diff;
  - the renderer lands first (Done, Phase 1).
- **[arch 2]** The PATH came from a lib loaded before the scrub. Resolved: an inline OSTYPE prologue, libs sourced
  only after `env -i`, and a lint (§1).
- **[arch 3]** Posting could silently die when started outside the shortcut. Resolved: the shortcut is the only
  entry point, and preflight check 1 **refuses** without a live broker (§4).
- **[arch 4] / [maint 4]** Profile policy was mixed with mechanism. Resolved: a single declarative profile table
  that both backends translate, with tests against it (§5).
- **[arch 5]** Security wiring came late. Resolved: Phase 2 is now the security baseline, before confinement and UI,
  and no live WSL session runs before Phase 7.
- **[maint B1]** The lock list lived in several places. Resolved: `config/protected-paths.tsv` drives the lock
  commands, `prw_locked`, the `denyWrite`/deny cross-check and the S6/W tests (§3, §8).
- **[maint 2]** The sync check only compared the renderer with itself. Resolved: golden render fixtures, a reviewed
  `--update-fixtures` step, and `$REPO` required (§2).
- **[maint 3]** The UI schema was written three times. Resolved: `config/ui-schema.json` plus a shared corpus (§6).
- **[maint 5]** Drift on the Windows side. Resolved: a helper version stamp, the broker handshake, a preflight
  warning, and `windows/README.md` ownership rules.
- **[maint minor]** The `@USER_HOME@` leading slash is now documented. The mac-only fragment is a named file. The
  lock and unlock commands are printed, not copied.
- **[test B1]** Mutation-checking was added as an acceptance blocker, with an explicit list (§11, Phase 7).
- **[test B2]** The launcher refusal checks now have one harness case each (fakeroot argument, since r4), plus a Mac `caffeinate`
  case.
- **[test B3]** The installers are now verified on every launch by `prw_wsl_preflight` (wsl.conf, groups, sudo,
  root password, broker and dir modes, lock). `install-windows.ps1` has Pester tests and idempotence (§4, §7).
- **[test B4]** Added the full §12 T→W table, including W-INPUT as the T-CGEvent counterpart, plus W-INTEROP,
  W-FORGE and W-SLEEP.
- **[test 5]** Phase 0 now has objective pass criteria. Also added: renderer refusal cases, the commit-stamped
  summary file, the minimum-count rule, golden print files, and live-check G skips failing acceptance.
- **[sec 1]** The dialog body now comes from the `$snap` bytes, with a test for `draft/` being swapped after the
  answer.
- **[sec 2]** The broker now checks the open fd, uses a bounded read, refuses replays (including across restarts),
  and rate-limits to one open confirm.
- **[sec 3]** Root checks were broadened: groups, sudoers, root password locked, no polkit. They are enforced by the
  preflight.
- **[sec 4]** The `PRWATCH_PLATFORM` env override was removed (fakeroot is for detection tests only). `buildrun`
  refuses a test resp dir without FAKE. Guard rows were added.
- **[sec 5]** The lock set is named in the manifest. S3 gained the binfmt write and direct socket connect, and the
  preflight checks for interop sockets.
  - **Not adopted:** adding `repos` to the chattr set. Prep clones into `repos`, so it stays sandbox
    denyWrite-only, exactly as on the Mac.
- **[perf 1–6]** Adopted:
  - lazy, fork-free libs and a guard timing budget;
  - 0.5 s `zselect` polling, a blocking read in the helper, and broker respawn;
  - S4 criteria for restore reuse, the LIMIT reap, `lo` up and `/dev/shm`;
  - `.wslconfig` set to 12 GB plus 4 GB swap, `autoMemoryReclaim` and processors;
  - the broker clock resync.

**r4 (round-2 review: architecture, maintainability, security and performance APPROVE-WITH-NOTES; testing REJECT)**

- **[test N1 — BLOCKING]** Nothing proved the test-only switches are ignored outside test mode. Resolved:
  - `PRW_ROOT` is gone. The preflight takes a fakeroot as a **function argument**, the launcher never passes one,
    and a harness case checks that.
  - `PRWATCH_UI_RESP_DIR` and `PRWATCH_BUILDRUN_FAKE` are honoured only in test mode, with harness cases that run
    with test mode unset.
  - Mutations 16–18 and 23 were added.
  - `PRWATCH_DRY_POST=0` with a test resp dir is refused, and a case covers it.
  - The guard tripwire and `.tsv` rows now cover `PRWATCH_DRY_POST` and `PRWATCH_TESTMODE` (§4, §6, §9, §11).
- **[arch N1] / [sec N1]** Test mode was too strong. Resolved:
  - A test-mode launch now always exports `PRWATCH_DRY_POST=1`, and `PRWatcher.ps1` has no `-DryPost`.
  - Only the lock check is skipped in test mode.
  - There is no environment seam that can fake the preflight (§4, §7).
- **[arch N2]** Checks 1, 8 and 10 were only tested against a fake tree until late. Stated in §4, with the first
  real run at the Phase 5 launcher step and again in W0.
- **[arch N3] / [maint N2] / [sec N5]** Helper drift. Resolved:
  - The version is now the sha256 of the deployed `.ps1` files plus `ui-schema.json`, so nobody bumps it by hand.
  - A missing or mismatched version makes the broker answer every confirm `NoHelper`, so drift fails to "not
    posted" (§4 check 10, §6).
- **[arch N4]** W8 now names its mechanism: the existing `session.lock` takeover plus `superseded`, and the helper
  mutex.
- **[arch N5]** The manifest gained a `root-installed` class (broker, `wsl.conf`, `/var/lib/prwatch`). The installer
  and preflight read it (§3).
- **[maint N1]** Golden fixtures now cover only the token files. Every other file is checked as "source with tokens
  substituted" (§2).
- **[maint N3]** The mutation list is data (`test/mutations.tsv`) driven by `test/mutate.zsh`, with a merge rule to
  re-run it on security-relevant changes (§11).
- **[maint N4]** Lock commands have one owner, `prw_lock_commands`. The render flag delegates to it.
- **[maint N5]** The WSL minimum count is derived from the case tags. A new-path, script and preflight-check
  checklist lives in `config/README.md`, enforced by the harness.
- **[test N2]** Pester now covers `PRWatcher.ps1`: the parameter whitelist, hostile values, exact argv, test-mode
  gating and the mutex.
- **[test N3]** Added three mutations (open-confirm cap, seen-dir reload, manifest classification), plus harness cases
  for the `install.sh` WSL branch and `install-root.zsh`.
- **[test N4]** Pester reads the schema and corpus from the repo. A case hashes the deployed copies against them.
- **[sec N2]** The seen window is now a rolling 48 hours, and requests older than 900 s are refused.
- **[sec N3]** A dropped second confirm triggers a "confirm already open" notification.
- **[perf]** Recorded:
  - the preflight runs at launch only, with few forks and a `timeout 3` on `sudo -n`;
  - the seen list is a per-day dir with `zstat` lookups;
  - the toast budget includes the 1 s poll;
  - the LIMIT reap is tested with `--new-session` on;
  - processors is set to a number;
  - mutation runs are targeted, the timing check is median-of-3 with a 1.5× tolerance, and Pester runs separately.

**r5 (round-3 review: all five APPROVE-WITH-NOTES on r4, with no blocking items; the notes below are folded in)**

- **[test R1] / [sec N1]** `post.sh` now refuses `PRWATCH_DRY_POST=0` whenever `PRWATCH_TESTMODE` is set, on both
  OSes. Test mode no longer depends on the launcher's export to stay dry. Nothing in the repo used the old escape.
- **[test R2] [test R3]** Mutations 24–25 cover the two test-mode refusals. Pester mutation 5 is the twin of mutation
  18 on the Windows side.
- **[arch NB1] / [maint 1]** One canonical byte stream for the helper version: sorted names, BOM stripped, LF. It is
  defined in `config/README.md`. A zsh and Pester cross-language case checks it, mutation 26 and Pester mutation 6
  cover it, and the `.ps1` files are kept ASCII-only.
- **[arch NB2]** Already covered by r4's launcher case, which checks that the preflight is called with no argument.
- **[maint 2]** `mutate.zsh` reports "did not apply" as a failure, kept separate from killed and survived.
- **[sec N2]** `PRWATCH_STUB_BIN` is added to the tripwire and to the `.tsv` rows.
- **[perf 1–3]** The helper hash is computed once per process. The mutation pass has a 10-minute ceiling, with a
  nightly fallback. Seen directories are cleaned up at broker start and at midnight, never while handling a request.

**r6 (Jack's brief: the WSL install must be documented in the project, and the final version must itself be
reviewed)**

- The plan moved from `.project-files/plans/windows-port-wsl2.md` to `docs/windows-port.md`, next to the other
  council plans (`docs/plan.md`, `docs/cap-override.md`).
- **S0** added: the install chapter of `docs/windows-wsl.md` is written before Phase 0, and S1/S2 are run by
  following it. Before r6, the guide was only written in Phase 6, after Jack would already have installed WSL
  without it.
- Step 23 now completes the guide rather than creating it.
- Writing the install chapter found four gaps in the plan, now fixed:
  - `autoMemoryReclaim` goes under `[experimental]` in `.wslconfig`, not `[wsl2]`. The §4 table now names the section
    for each setting.
  - §4's `wsl.conf` replaces the whole file, which drops any `systemd=true` from the image. That's now stated as
    deliberate, with the reason.
  - Step 23 installs the toolchains before `gh auth` and before cloning, so it now says where the versions are read
    from.
  - S2's "same `all`-row count" needs Phase 1's platform column. Before Phase 1, S2 compares the total row count, and
    it hand-renders the guard and the `.tsv` as well as `settings.json`.
- r5's folded-in notes had not been reviewed. r6 goes back to all five reviewers, with the documentation pedant
  added for the new guide.

**r7 (round-4 review on r6: all six APPROVE-WITH-NOTES, with no blocking items; the notes below are folded in,
and r7 goes back to all six for confirmation)**

Plan:
- **[arch 2]** The seccomp filter was installed in a folder the watcher user can write. It now joins the `lock`
  class as `@SANDBOX_RUNTIME_DIR@`, and preflight check 11 confirms it (§4). Mutation 13 ("remove each preflight
  check") covers the new check.
- **[test N2] / [maint 2]** S0 now has an evidence rule: one BUILD-NOTES line per guide step. It says S3–S8 markers
  stay, that a fix to a value the plan also states updates the plan in the same change, and that the docs must be
  pushed before S1.
- **[arch 1] / [test N1] / [test N3]** S2's credential rows tested the Mac deny list, and its row-count check
  couldn't fail. Resolved:
  - the hand-render adds §3's Secrets with one `jq` step;
  - a refusal must come from the sandbox or a permission rule, not from Claude declining;
  - the guard loop prints the rows it checked, which must equal the non-empty line count;
  - S2 is stated to run after the lockdown.
- **[maint 1] / [maint 3]** Ownership. Phase 2 step 16 makes `watcher/config/wsl.conf` the only copy of the
  `wsl.conf` body, deleting it from §4 and the guide. Step 23 points to guide 4a/4c/4d for the package list and
  versions instead of repeating them.
- **[test N4]** The canonical-hash fixture now has a BOM, CRLF and locale-vs-byte-order names, so mutation 26 and
  Pester mutation 6 can be killed.
- **[test N5]** The target cases for mutations 24 and 25 now name what they assert.
- **[test N6]** The S1 networking fallback names its commands (§4 check 4).
- **[perf 1] / [perf 2] / [doc 1]** `.wslconfig`: `processors = max(4, floor(CPUs/2))` and
  `memory = min(12, floor(0.6 × RAM))` GB, so a 16 GB laptop isn't starved.
- **[perf 5]** The mutation ceiling is measured warm on Jack's laptop.

Guide (`docs/windows-wsl.md`):
- **[sec 1]** `wsl.conf` and `.wslconfig` moved from step 7 to a new step **3d**, before any download or login. This
  closes the window in which fetched installers and fresh tokens sat in a distro that could reach Windows. It also
  matches step 23's order. Step 7 is now only "remove root access", and the guide says to run nothing but its own
  commands until then.
- **[sec 2] / [sec 3] / [sec 5]** The polkit check uses `polkitd pkexec policykit-1`. `/etc/sudoers` is grepped as
  well as `sudoers.d`. The text says the `id` line is what proves the step.
- **[sec 4]** S2 row 5 is one exact command that starts, tests and kills the server.
- **[doc 2]** The Ubuntu image filename uses a `<N>` placeholder. **[doc 3]** "Push the repo first". **[doc 4]**
  The Chrome `--version` check runs before the lockdown. **[doc 5]** Re-entering after 3d is explained. **[doc 6]**
  8a rows 4 and 5 give the expected output.
- **[arch 4]** The root route example is `apt-get install -y`. **[maint 4]** The hard-coded "37 rows" is gone.
  **[maint 5]** The S2 hand-render is marked for deletion in Phase 1.
- **[arch 5]** The README row says "council-approved". It stays, on the condition that r7 is approved.
- **Not adopted:** [perf 4] (say the NuGet cache stays on ext4). It already follows from the guide's clone location
  and the plan's cache paths.

**r8 (round-5 confirmation on r7: all six APPROVE-WITH-NOTES, with no blocking items; r8 goes back to all six for
confirmation)**

- **Found while folding round 5 (not raised by a reviewer).** r7 moved `wsl.conf` to guide step 3d, which runs
  before the repo is in the distro, so "after Phase 2, `install-root.zsh` does 3d" couldn't work. Resolved in Phase 2
  step 16:
  - after Phase 2, 3d stays a hand step that writes a **bootstrap** subset (`[interop]`, `[automount]`, `[user]`);
  - `install-root.zsh` overwrites it with the full rendered file at step 7, and check 6 verifies it;
  - `watcher/config/wsl.conf` stays the one owner.

  The guide's step 7 note and its "Still to come" line say the same.
- **[sec r5-1] / [arch r5-N1]** The filter lock is `chattr -R +i`, like every lock path. Check 11 now verifies every
  file under the folder, not just the folder.
- **[sec r5-2] / [arch r5-N2]** "Pinning the Node": check 11 refuses if the launcher's `node` isn't the one the
  renderer recorded. S2 records how Claude Code finds the filter, and whatever that path depends on joins the `lock`
  class (§4; guide 4e).
- **[test r5-T1]** `.gitattributes` would have normalised the hash fixture's CRLF and BOM bytes away.
  `watcher/test/fixtures/hash/** -text` was added (Phase 1 step 10), plus a harness case that asserts the bytes.
- **[test r5-T2]** Mutation 24's case asserts exit 64. **[test r5-T3]** The guide says the `.tsv` has no blank
  lines, and that one would fail safe.
- **[maint r5-N1]** The §4 `.wslconfig` table owns the values; guide 3d owns only how to work them out.
  **[maint r5-N2]** Phase 1 step 11 deletes the guide's S2 hand-render block. **[maint r5-N3]** Covered by the
  bootstrap change above. The 3b fallback's `[user]` line is superseded by 3d's file, as before.
- **[doc r5-1]** The "Still to come" install line is corrected. **[doc r5-2]** There is a reminder to replace
  `<linux-user>` inside the heredoc.
- **[perf r5-3]** "Warm" is defined (second consecutive run, caches populated). **[sec r5-3]** S2 records which rule
  refused rows 3 and 4.
- **Not changed:** [perf r5-1]. The "12 GB plus 4 GB swap" wording is in the r3 log entry, which is history.
  [perf r5-2] (re-run the one-liners after a hardware change) is cosmetic.

**r9 (round-6 confirmation on r8: security APPROVE; architecture, maintainability, performance, testing and
documentation APPROVE-WITH-NOTES; no blocking items)**

- **[maint r6-N1] / [arch r6-N2] / [doc r6-1,3]** r8's bootstrap subset is replaced by a simpler rule. Guide 3d keeps
  writing the **whole** `wsl.conf`, which is only four sections, so TIOCSTI hardening is on from the start. A harness
  case keeps the guide's block identical to `config/wsl.conf`. `install-root.zsh` still overwrites the file at step
  7, and check 6 still verifies it (Phase 2 step 16). Security's view that deferring TIOCSTI was harmless is noted;
  the whole file costs nothing and removes the subset idea.
- **[arch r6-N1] / [sec r6-N1]** `install-windows.ps1` runs `wsl.exe --terminate PRWatcher` after
  `install-root.zsh`, so the new `wsl.conf` is live before the first launch (§7). The guide's step 7 note says so.
- **[test r6-N1] / [test r6-N2]** Check 11 has a fakeroot case per condition and mutations 13a–c. `node` resolves
  through the launcher's PATH function with the fakeroot. Attributes are read via `prw_immutable`, which `run.sh`
  redefines. zsh doesn't import functions from the environment, so this adds no seam.
- **[perf r6-1]** Check 11 uses a single `lsattr -R`.
- **[sec r6-N2]** Guide step 4 says that npm install scripts run while sudo is still reachable.
  **[doc r6-2]** The guide's step 7 note is split into "Now" and "After Phase 2" bullets.
- **Not changed:** [maint r6-N2] (where the bootstrap text lives). It is now a checked copy of `config/wsl.conf`, and
  step 16 says so. [perf r6-2] (record both timings) is left to the BUILD-NOTES entry.

**r10 (round-7 confirmation on r9: architecture APPROVE; maintainability, security, performance, testing and
documentation APPROVE-WITH-NOTES; no blocking items)**

- **[test r7-N1] / [maint r7-N2]** The guide-vs-config case is now fully specified (Phase 2 step 16):
  - the `<!-- wsl.conf:begin/end -->` markers in the guide (now added), and it fails on zero or several blocks;
  - `<linux-user>` → `@LINUX_USER@` (a new token, §2);
  - a byte-exact comparison with one trailing newline;
  - mutation 27.
- **[test r7-N2] / [sec r7-L2]** `prw_immutable <dir>` wraps the single `lsattr -R` and fails closed. The stub
  replaces that same function. The 13c cases include an `lsattr` error.
- **[sec r7-L1]** The lib defines `prw_immutable` unconditionally, and a harness case shows a pre-existing definition
  is replaced. `~/.zshenv` was already write-denied (§3).
- **[doc r7-1] / [doc r7-2]** The guide's step 7 note is split into Now, After Phase 2 and After Phase 6. Before, it
  wrongly had `install-windows.ps1`, a Phase 6 deliverable, running from Phase 2. "Now" says `wsl.conf` stays as 3d
  wrote it. **[maint r7-N1]** A missing blank line before a VERIFY marker is fixed.
- **Not changed:** [perf r7] (watch `lsattr -R` latency). It is covered by the preflight's existing timing budget.

**r11 (Jack's answers to the open questions, 2026-10-01)**

- **Open Question 1:** Jack has admin rights, so there's no IT ticket. Updated: Risks, step 23, guide "What you need".
- **Open Question 2:** the username is `jackscammell`. The guide now uses it literally, so its commands paste as they
  are. Pasting `adduser <linux-user>` into bash fails, and a literal `default=<linux-user>` would be worse. The
  guide declares the name once (`<!-- linux-user: jackscammell -->`). The Phase 2 step 16 drift case reads that
  declaration instead of swapping a placeholder, and fails naming any token it can't map, which also covers [arch
  r8-1]. The examples in §2 use `/home/jackscammell`.
- **Open Question 4: notifications stay until dismissed. This is a design change.** Microsoft's toast schema says
  `scenario="reminder"` "will be silently ignored unless there's a toast button action". So the r10 rule "toasts
  have no actions" is replaced in §6:
  - each toast has exactly one action, the system-handled Dismiss button (`activationType="system"`,
    `arguments="dismiss"`);
  - there is still no `launch` attribute, no app-defined arguments, and no activation of the helper.

  Supporting changes:
  - The `NotifyIcon` balloon fallback, which disappears on its own, becomes a persistent TopMost notice window.
  - S5 and W1 test that toasts persist, and test the fallback.
  - Pester mutations 7 (wrong toast actions) and 8 (the fallback closing itself) are added.
- **Open Question 5:** Docker Desktop isn't installed. The rules for installing it later are in Open Question 5, §4
  and the guide's Docker section. Preflight check 3 already refuses if its integration is switched on.
- **Open Question 3** (retire or keep the Mac watcher) **is still open.**

**r12 (round-9 review on r11: all six APPROVE-WITH-NOTES, with no blocking items)**

- **[arch r9-1, Medium]** The fallback trigger is defined at runtime (§6). The helper reads `ToastNotifier.Setting`
  before every toast; anything but `Enabled`, or a `Show()` exception, uses the notice window. Do Not Disturb is
  respected, as on the Mac: toasts wait in the notification centre, and W1 records it.
- **[sec r9-a]** A click on the toast body has nothing to launch. The AUMID is registered under
  `HKCU\Software\Classes\AppUserModelId` and not on the launcher shortcut, with no `ToastActivatorCLSID`, COM
  activator or protocol. S5 and W1 click the body and expect nothing.
- **[perf r9-1] / [arch r9-2] / [sec r9-b]** Pile-up and size:
  - toasts carry `Group`/`Tag`, so a newer notice for the same PR and kind replaces the older one;
  - the notice window is a read-only text box (no labels, so no mnemonic or markup parsing), capped at 50 entries
    with an "older notices" line;
  - it is shown without activation, and drops out of TopMost while a confirm dialog is open, so it can't cover Post
    or Cancel.
- **[perf r9-4]** S5 has a 50-notification soak.
- **[test r9-1, Medium]** Pester mutation 8 is killed by a static AST case (no timer, no `AutoClose`, no stray
  `Close()`) and a behavioural case (injectable clock, +1 hour, still open, cap of 50). **[test r9-3]** Mutation 7
  asserts `scenario="reminder"` explicitly.
- **[test r9-2, Medium]** S5 and W1 record the times shown, checked and dismissed, plus a screenshot, on a pass as
  well as a fail.
- **[maint r9-1] / [arch r9-3] / [test r9-4]** Step 16's drift case also checks the guide's username-bearing
  commands (`adduser`, `usermod`, `gpasswd`, `grep … /etc/sudoers`, `id`, `default=`, `/home/…`). It has three
  seeded-fault cases: no declaration, two declarations, and an unknown token. The guide's "different machine" note
  lists those places.
- **[maint r9-2]** The guide's Docker section names Open Question 5 as the owner of its rules. **[doc r9-1/2]**
  "A Phase 2 test will read it", and the rename note lists the places.
- **Not changed:** [maint r9-3] (the username in the guide's status line). It is listed in the rename note's
  "everywhere".

**r13 (Jack's answer to Open Question 3, 2026-10-01: both machines stay in use, the Mac in the office and Windows
at home)**

- Open Question 3 is resolved. Every open question is now answered.
- Risks ("Two watchers on one account"): the rule is **one machine per day**, with `stop` in the first window
  before switching part-way through a day. Two protections are named. GitHub drops a reviewed PR from
  `user-review-requested:@me`, which is the watcher's search (the `gh search prs` call in `prwatch-tick.sh`). And the new `post.sh` check
  below.
- **New `post.sh` hardening, both OSes: already reviewed from the other machine** (§6). Each machine keeps its own
  state, so two watchers running at once could both post a waiting draft.
  - `post.sh` reads the PR's reviews and refuses (exit 7) if Jack already has a review on `$sha`. It checks before
    the dialog and again after Post.
  - It records the key as `posted` so this machine stops asking.
  - If GitHub can't be read, it fails closed (exit 10).
  - There are harness cases and mutation 28. It lands in Phase 4 step 18, and the Mac harness runs with it.
  - The "Deferred" list now defers only a full cross-machine session lock.
- Step 23: `watcher/README.md` gains an "Office (Mac) or home (Windows)" note. The guide's status line says the Mac
  install isn't touched and gives the one-watcher-per-day rule.

**r14 (round-11 review on r13: all six APPROVE-WITH-NOTES, with no blocking items)**

The already-reviewed guard in §6 is tightened:
- **[sec r11-1, Medium]** A `PENDING` review doesn't count. A `DISMISSED` one does, and that is stated.
- **[perf r11-1] / [sec r11-2, Medium]** It reads every page (`--paginate`, `per_page=100`, `jq -s`).
- **[sec r11-3/4] / [perf r11-4]** It matches on `.user.login` (case-insensitively) and the full 40-character
  `commit_id`. A `gh`/JSON/`jq` failure is exit 10, never "no match".
- **[arch r11-3]** One `PRW_GH_LOGIN` constant, shared with `prwatch-tick.sh`.
- **[test r11-1..5, Medium]** The `gh` stub gains a call log and an answer sequence. There are eight harness cases:
  match before the dialog with no confirm shown, match after Post, a different commit, `PENDING`, page 2, `gh`
  failure, non-JSON, and dry run. Refusals assert state `posted`; failures assert state unchanged. Mutations 29
  (first check) and 30 (`PENDING` filter) are added.
- **[maint r11-2, Medium]** Phase 4 step 18 owns the `SKILL.md` exit-7 edit, `PRW_GH_LOGIN` and the stub changes.
  **[maint r11-1]** The guide's one-machine line points to Risks.
- **[arch r11-2]** "A review of any kind removes the review request" is confirmed on a test PR before Phase 4 is
  done. **[arch r11-1]** One possible extra council per slip is accepted, since it posts nothing.
- **[doc r11]** The r13 log names the search call instead of a line number. The Review outcome wording now says
  "approved, with or without notes". (The docs are valid UTF-8; the odd characters were the reviewer's console.)
- **Not changed:** [arch r11-4] (a harness case for re-request then the other machine). It is covered by case 1
  (the same commit is refused whatever the reason).

## Review outcome

| Reviewer | R1 (r2) | R2 (r3) | R3 (r4) | R4 (r6) | R5 (r7) | R6 (r8) | R7 (r9) | R8 (r10) | R9 (r11) | R10 (r12) | R11 (r13) | R12 (r14) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| grumpy-architecture-skeptic | REJECT | APPROVE-WN | APPROVE-WN | APPROVE-WN | APPROVE-WN | APPROVE-WN | APPROVE | APPROVE-WN | APPROVE-WN | APPROVE | APPROVE-WN | APPROVE-WN |
| grumpy-maintainability-curmudgeon | REJECT | APPROVE-WN | APPROVE-WN | APPROVE-WN | APPROVE-WN | APPROVE-WN | APPROVE-WN | APPROVE | APPROVE-WN | APPROVE | APPROVE-WN | **APPROVE** |
| grumpy-security-nag | APPROVE-WN | APPROVE-WN | APPROVE-WN | APPROVE-WN | APPROVE-WN | APPROVE | APPROVE-WN | APPROVE | APPROVE-WN | APPROVE-WN | APPROVE-WN | **APPROVE** |
| grumpy-performance-troll | APPROVE-WN | APPROVE-WN | APPROVE-WN | APPROVE-WN | APPROVE-WN | APPROVE-WN | APPROVE-WN | APPROVE | APPROVE-WN | APPROVE | APPROVE-WN | **APPROVE** |
| grumpy-testing-tyrant | REJECT | REJECT | APPROVE-WN | APPROVE-WN | APPROVE-WN | APPROVE-WN | APPROVE-WN | APPROVE | APPROVE-WN | APPROVE-WN | APPROVE-WN | APPROVE-WN |
| grumpy-documentation-pedant | — | — | — | APPROVE-WN | APPROVE-WN | APPROVE-WN | APPROVE-WN | APPROVE | APPROVE-WN | APPROVE-WN | APPROVE-WN | **APPROVE** |

APPROVE-WN = approve with non-blocking notes.

**r14 is the approved version.** It includes all five of Jack's answers and the double-post guard. All six
reviewers approved it in round 12 with no blocking items: four clean APPROVEs, and two with low notes. The design
text was not changed after round 12.

**Implementation notes** (low; to be handled when the code is written, not design changes):
- From round 8:
  - **[sec r8-1]** `run.sh` defines its `prw_immutable` stub **after** sourcing the lib; a harness assertion checks
    the order.
  - **[test r8-1]** The guide-vs-config case fails if the markers are present but the `<<'EOF'` start line or the
    closing `EOF` inside them is missing.
- From round 10:
  - **[test r10-4] / [arch r10]** A fourth seeded fault for step 16's rename safety: a guide line where
    `usermod -aG` names a different user. The case must fail naming that line.
  - **[sec r10-1]** The helper checks the `HKCU\Software\Classes\AppUserModelId\<AUMID>` values at startup and logs
    any change.
  - **[sec r10-2]** S5 also clicks a toast after the helper has exited and expects nothing to launch.
  - **[perf r10]** S5's soak records a memory figure and sets a growth ceiling from the first measurement.
  - **[doc r10-1]** The guide's "a Phase 2 test" pointer names plan step 16.
- From round 12:
  - **[test r12-1]** Add already-reviewed cases for a login with different capitals (still a match) and a review
    whose `commit_id` shares only a prefix with `$sha` (not a match).
  - **[test r12-2]** Add mutations that drop the "record `posted`" step and that turn a `gh` failure into "no match".
    Cases 1, 6 and 7 should kill them.
  - **[arch r12-2]** A re-request on a commit Jack already reviewed is refused by design (exit 7). Say so in the
    `/prwatch-decide` exit-7 text.
  - **[arch r12-3]** If a home for user identity (not OS differences) appears, move `PRW_GH_LOGIN` there. Optionally
    check it against `gh api user` at launch.
