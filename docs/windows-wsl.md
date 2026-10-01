# PR watcher on Windows (WSL2): install

Status: 2026-10-01. **Install chapter only: written before Phase 0, nothing in it has been run on Windows yet.**
It is written for Jack's laptop: admin rights, Linux username `jackscammell`, Docker Desktop not installed. Nothing
here touches the Mac install, which stays in use in the office. Run one watcher per day: the Mac in the office, this
one at home (the rule is in the plan, Risks, "Two watchers on one account").
It follows the plan in [`docs/windows-port.md`](windows-port.md) (§4 and Phase 0). Where this guide and the plan
disagree, the plan wins.

This chapter takes you from "WSL not installed" to a locked-down `PRWatcher` distro with the tools installed and
logged in. Following it **is** Phase 0 spikes S1 and S2. The watcher itself doesn't run on Windows yet: the scripts
still need Phases 1 to 5.

**About the VERIFY markers.** A step marked **VERIFY (S1)** or **VERIFY (S2)** could not be checked before writing,
or can only be proved on the real laptop. When you run it, note what happened. If it worked as written, the marker
comes out. If it didn't, the fix goes into this file in the same change. Markers for later spikes (S3, S4) stay until
those spikes run.

**Where to type each command.** Every block says which shell it is for:

| Label | Where |
|---|---|
| Windows (admin) | PowerShell opened with **Run as administrator** |
| Windows | Ordinary PowerShell or Windows Terminal, as you |
| Linux | A shell inside the `PRWatcher` distro, as `jackscammell` |
| Linux (root) | A root shell opened from Windows with `wsl -d PRWatcher -u root` (steps 3 and 7 only) |

## 1. Before you start

### What you need

| Need | Why | How to check |
|---|---|---|
| Admin rights | `wsl --install` must run as administrator | You have admin rights on this laptop (confirmed 2026-10-01). Right-click PowerShell → **Run as administrator**. |
| Virtualisation turned on | WSL2 runs a small virtual machine | Task Manager → **Performance** → **CPU**: "Virtualization: Enabled". If it says Disabled, it is a BIOS setting. |
| About an hour, and a restart | | |

Only step 2 needs admin rights. Everything after it runs as you. **VERIFY (S1):** record any blocker you meet in
BUILD-NOTES, as S1 asks.

### Docker Desktop

Docker Desktop isn't installed on this laptop (2026-10-01), and the watcher doesn't need it. If you install it later:
- keep its WSL integration **off** for `PRWatcher` (Docker Desktop → **Settings** → **Resources** → **WSL
  integration**: `PRWatcher` not ticked);
- keep **Expose daemon on tcp://localhost:2375 without TLS** off;
- re-run the checks in step 8a afterwards.

These rules are owned by plan Open Question 5. If the integration is ever switched on, the watcher refuses to start
(plan §4, preflight check 3). Don't run other distros with listening services while the watcher runs: all WSL2
distros share one network.

### Push the repo first

The distro gets the watcher by cloning it from GitHub (step 6), and step 8 copies files out of that clone. So this
guide, the plan and anything else you want to test must be **committed and pushed** before step 6. If you are reading
this from a Windows or Mac checkout, check that `git status` there is clean and the branch is pushed.

### The Linux username

Your Linux username is **`jackscammell`** (decided 2026-10-01). It becomes your Linux home folder
(`/home/jackscammell`), and the watcher's paths are built from it, so it can't easily be changed later. Every command
in this guide already uses it, so you can paste them as they are.

<!-- linux-user: jackscammell -->
On a machine with a different username, replace `jackscammell` everywhere in this guide. That includes the hidden
`linux-user` marker comment above (a Phase 2 test will read it), step 3b's `adduser` and `usermod`, step 3d's
`default=` line, step 7a's `gpasswd`, `grep` and `id` lines, and every `/home/…` path. That Phase 2 test will also
fail on any of those command lines that still names the old user.

## 2. Install WSL

Windows (admin):

```powershell
wsl --install --no-distribution
```

`--no-distribution` installs WSL itself without the default Ubuntu, so that step 3 can create the distro under its
own name. Restart the laptop when it finishes.

After the restart, Windows:

```powershell
wsl --version
```

It should print a WSL version and a kernel version. Ubuntu 24.04 uses WSL's newer image format, which needs **WSL
2.4.10 or later**. If the version is older, run `wsl --update`.

## 3. Create the `PRWatcher` distro

### 3a. Named install (try this first)

Windows:

```powershell
wsl --install Ubuntu-24.04 --name PRWatcher
```

It downloads Ubuntu 24.04, then opens it and asks you to create a user. Enter `jackscammell` and a password you will
remember. You need this password for `sudo` in step 4. After step 7 it is no longer useful for anything.

When you reach the Linux prompt, type `exit`. **VERIFY (S1):** `--name` is documented by Ubuntu and needs a recent
WSL, but hasn't been tried on this laptop.

If you see "`--name` is not supported", or an unknown option error, use 3b instead.

### 3b. Fallback: import the image

1. In a browser, open <https://releases.ubuntu.com/noble/> and download the newest
   `ubuntu-24.04.<N>-wsl-amd64.wsl` file, plus `SHA256SUMS`. In the commands below, replace `<N>` with the number in
   the file you downloaded.
2. Check the download. Windows:

   ```powershell
   Get-FileHash $HOME\Downloads\ubuntu-24.04.<N>-wsl-amd64.wsl -Algorithm SHA256
   ```

   The hash must match the line for that file in `SHA256SUMS`.
3. Import it. Windows:

   ```powershell
   mkdir $env:LOCALAPPDATA\PRWatcher\distro
   wsl --import PRWatcher $env:LOCALAPPDATA\PRWatcher\distro $HOME\Downloads\ubuntu-24.04.<N>-wsl-amd64.wsl --version 2
   ```

   **VERIFY (S1):** Microsoft documents `--import` for a tar file. A `.wsl` file is a tar archive in the new format,
   but importing one with `--import` hasn't been tried here.
4. An imported distro starts as root, with no user. Create yours. Windows:

   ```powershell
   wsl -d PRWatcher -u root
   ```

   Linux (root):

   ```sh
   adduser jackscammell
   usermod -aG sudo jackscammell
   printf '[user]\ndefault=jackscammell\n' >> /etc/wsl.conf
   exit
   ```

   Windows:

   ```powershell
   wsl --terminate PRWatcher
   ```

   **VERIFY (S1):** whether the imported image already has an `/etc/wsl.conf`, and whether it runs Ubuntu's
   first-start user setup anyway. If it asks you to create a user on first start, do that instead of the commands
   above.

### 3c. Check

Windows:

```powershell
wsl -l -v
```

`PRWatcher` is listed with **VERSION 2**. Open it with `wsl -d PRWatcher`. The prompt should show `jackscammell`.
Type `exit`.

### 3d. Cut the distro off from Windows (now, before installing anything)

After this step the distro can't see your Windows files (`/mnt/c`) or start Windows programs. Nothing in steps 4 to 6
needs either: the logins have you copy URLs into the Windows browser by hand. Doing it now means nothing you download
in step 4, and no login token from step 5, ever sits in a distro that can reach Windows.

**`/etc/wsl.conf`.** These are the values from plan §4. Windows:

```powershell
wsl -d PRWatcher -u root
```

Linux (root). First look at what is there, so you can record it:

```sh
cat /etc/wsl.conf
```

Then replace it (paste the whole block as it is):

<!-- wsl.conf:begin -->
```sh
cat > /etc/wsl.conf <<'EOF'
[interop]
enabled=false
appendWindowsPath=false
[automount]
enabled=false
mountFsTab=false
[boot]
command=sysctl -w dev.tty.legacy_tiocsti=0
[user]
default=jackscammell
EOF
exit
```
<!-- wsl.conf:end -->

This replaces the whole file. If the old file had other lines (for example `systemd=true` under `[boot]`), they are
dropped on purpose: nothing in the watcher needs systemd (plan §4). Note the old lines in BUILD-NOTES. Once the
watcher's installer exists, it rewrites this same file in step 7 (see the note there). The block above is kept
identical to `watcher/config/wsl.conf` by a test.

**VERIFY (S1):** that the `legacy_tiocsti` setting exists in the WSL kernel (it is checked in 8a).

**`%USERPROFILE%\.wslconfig`.** This file is **global**: it applies to every WSL2 distro on the laptop, not only
`PRWatcher`. The values are set by plan §4; this step shows how to work them out. Work out two numbers first.
Windows:

```powershell
[Math]::Max(4, [Math]::Floor([Environment]::ProcessorCount / 2))
[Math]::Min(12, [Math]::Floor(0.6 * (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB))
```

The first number is `processors`: half your logical CPUs, rounded down, but never less than 4. The second is
`memory` in GB: 60% of your RAM, rounded down, but never more than 12. On a 16 GB laptop it prints 9; on 32 GB it
prints 12.

Create or edit `C:\Users\<you>\.wslconfig` (Notepad is fine) so that it contains:

```ini
[wsl2]
guiApplications=false
networkingMode=nat
memory=<memory>GB
swap=4GB
processors=<processors>

[experimental]
autoMemoryReclaim=gradual
```

Put in your two numbers. If the file already has other settings, keep them unless they conflict, and never set
`networkingMode=mirrored`. `autoMemoryReclaim` belongs under `[experimental]`, as Microsoft's documentation lists it.

**Restart WSL** so both files take effect. Windows:

```powershell
wsl --shutdown
wsl -l --running
```

Wait until the second command says no distributions are running (Microsoft's "8 second rule"). Then check, Windows:

```powershell
wsl -d PRWatcher --exec ls /mnt/c
```

It must fail with `No such file or directory`. The full checks are in step 8.

## 4. Install the tools (while you still have sudo)

Everything in this step uses `sudo` or downloads from the internet. It must all be done before step 7, which removes
`sudo` for good. All commands are Linux, inside `wsl -d PRWatcher`.

Until step 7 is done, `jackscammell` can still become root, and every installer here, including npm packages' own
install scripts, runs while sudo is still reachable. So between now and then, run only the commands in this guide.

### 4a. Ubuntu packages

```sh
sudo apt update
sudo apt upgrade -y
sudo apt install -y zsh jq git rsync lsof bubblewrap socat python3-venv curl
```

`bubblewrap` and `socat` are what Claude Code's Bash sandbox needs on Linux. The watcher's own scripts are zsh.

### 4b. GitHub CLI (`gh`) from GitHub's apt repository

Ubuntu's own `gh` package is old. Install from GitHub's repository instead: open <https://cli.github.com/>, follow
**Install** → **Linux** → **Debian, Ubuntu**, and paste the commands it gives for the official apt repository.
**VERIFY (S1):** the commands were not copied here because they couldn't be checked against the current page. When
S1 runs, paste the exact commands you used into this section.

Then:

```sh
command -v gh
gh --version
```

`gh` should be `/usr/bin/gh`, owned by root. The plan's renderer refuses a `gh` that isn't an absolute, root-owned
path.

### 4c. .NET into `/usr/local/share/dotnet`

The watcher expects .NET at `/usr/local/share/dotnet` on both Mac and Linux (plan §1). Install the SDK version that
Vision's `global.json` asks for. Read it on GitHub (`ACT-Training/Vision`, file `global.json`) or in your Mac clone.
Don't pick a version yourself.

Microsoft's `dotnet-install.sh` script installs an SDK into a folder you choose. Get it from the .NET install-script
page on Microsoft Learn (search "dotnet-install scripts"), then run it with `sudo`, the install folder
`/usr/local/share/dotnet` and the version from `global.json`. **VERIFY (S1):** the download link and the exact options
(`--install-dir`, and `--version` or `--jsonfile`) weren't checked before writing. Record the exact command here when
it works. The .NET runtime also needs some Ubuntu libraries; if `dotnet` complains about a missing library (such as
ICU), install it with apt and record it here.

Check:

```sh
/usr/local/share/dotnet/dotnet --list-sdks
```

It lists the version from `global.json`.

### 4d. nvm and Node

The watcher looks for Node under `~/.nvm/versions/node/*/bin` (plan §1), so install it with nvm.

1. Install nvm with the install command in the README of the nvm project (`nvm-sh/nvm` on GitHub). That command
   names a specific nvm version, so copy it from the README rather than from here. **VERIFY (S1).**
2. Close the shell and open a new one (`exit`, then `wsl -d PRWatcher`), so `nvm` is on the PATH. Re-entering from
   Windows like this still works after step 3d: that step only stops the distro reaching Windows, not the other way
   round.
3. Install the Node version Vision asks for. **VERIFY (S1):** it wasn't confirmed whether Vision has an `.nvmrc` or
   only an `engines` entry in `package.json`. Use whichever it has, for example `nvm install <version>`.

Check:

```sh
ls ~/.nvm/versions/node/
node --version
```

### 4e. Claude Code (native installer) and the sandbox's seccomp filter

1. Install Claude Code with the **native installer** command for Linux from the Claude Code setup page
   (<https://code.claude.com/docs>, "Set up Claude Code"). Don't use the npm package. **VERIFY (S2):** paste the exact
   command used here. The launcher looks for `~/.local/bin/claude` among other places.
2. Install the seccomp filter. The plan makes it **required**: it blocks Unix sockets inside sandboxed Bash, which is
   how the Mac already behaves.

   ```sh
   npm i -g @anthropic-ai/sandbox-runtime
   ```

   This installs into the nvm Node, so no `sudo`. That folder is writable by `jackscammell` for now. Once the
   watcher is installed, it joins the watcher's locked files (plan §4, "Protecting the filter"), so updating the
   filter later means unlocking first.
3. Check:

   ```sh
   claude --version
   command -v bwrap socat
   ```

   **VERIFY (S2):** how Claude Code finds the seccomp filter when it is installed under nvm, and how to see that it is
   active. Record the discovery path in BUILD-NOTES: the plan locks whatever that path depends on (plan §4, "Pinning
   the Node"). Self-test 11 (a sandboxed `AF_UNIX` socket fails) is the real proof, and it comes in S3.

### 4f. chrome-headless-shell and its libraries

Angular tests use Puppeteer's headless Chrome. The plan's Linux path is
`~/.cache/puppeteer/chrome-headless-shell/*/chrome-headless-shell-linux64/chrome-headless-shell`.

```sh
npx @puppeteer/browsers install chrome-headless-shell --path ~/.cache/puppeteer
ls ~/.cache/puppeteer/chrome-headless-shell/
```

Then run Chrome once, **now**:

```sh
~/.cache/puppeteer/chrome-headless-shell/*/chrome-headless-shell-linux64/chrome-headless-shell --version
```

It prints a version. If it refuses to start, it names the missing library. Install it with `sudo apt install -y
<package>`, run the line again, and repeat until it prints a version. List each library you added here. This is the
cheap moment to find them: S4 runs after step 7, when sudo is gone, and from then on any library S4 finds missing has
to go through the root route from Windows (end of step 7).

**VERIFY (S4):** that `--path` gives exactly the folder layout above, and that `--version` starting is enough (S4
runs real tests).

## 5. Log in

Do both logins now. Copy the URLs by hand into a browser on Windows. The distro can't open a browser for you: since
step 3d it can't start Windows programs.

### 5a. GitHub

```sh
gh auth login
```

Choose **GitHub.com**, **HTTPS**, and **Login with a web browser**. It prints a one-time code and a URL
(`https://github.com/login/device`). Open the URL in your Windows browser, enter the code and approve. If GitHub asks
you to authorise single sign-on for ACT-Training, do it.

Check:

```sh
gh auth status
gh api orgs/ACT-Training --silent && echo ok
```

The second line prints `ok`. These are the same two checks the launcher makes.

### 5b. Claude Code

```sh
claude
```

Follow the login prompts. When it shows a URL, copy it into your Windows browser, sign in, and paste any code it gives
you back into the terminal. Then type `/exit`. **VERIFY (S2):** the exact login screens on Linux.

## 6. Clone the repo inside the distro

Linux:

```sh
gh repo clone JackScammell/pr-watcher ~/pr-watcher
cd ~/pr-watcher
git ls-files --eol | grep crlf
```

The last command should print **nothing**.

Clone it in your Linux home, **never under `/mnt/c`**, and never use the Windows checkout: Windows Git converts the
scripts to CRLF line endings and they break. (Since step 3d, `/mnt/c` doesn't exist anyway.)

## 7. Remove root access (last of all)

After this step:
- `jackscammell` can't use `sudo`;
- any root work is done **only from Windows**, with `wsl.exe -d PRWatcher -u root --exec …`.

So check that steps 4 to 6 are complete before you start: afterwards, installing anything needs the root route.

**What is done by hand, and for how long:**
- **Now** (until Phase 2 ships `watcher/config/wsl.conf` and `watcher/sbin/install-root.zsh`): you do step 7a by
  hand, and `/etc/wsl.conf` stays as step 3d wrote it.
- **After Phase 2:** `install-root.zsh` does 7a and rewrites `/etc/wsl.conf` from `watcher/config/wsl.conf`. You run
  it from Windows through the root route, then restart the distro (`wsl --terminate PRWatcher`), because `wsl.conf`
  only takes effect on restart. Phase 2 adds the exact command here.
- **After Phase 6:** `install-windows.ps1` runs `install-root.zsh` and restarts the distro for you, and this step
  becomes "run the installer".
- **Either way**, step 3d stays a hand step, because it runs before the repo is in the distro. Its file is a checked
  copy of `watcher/config/wsl.conf`: a test keeps the two identical.
- `.wslconfig` stays a Windows-side file.

### 7a. Take sudo away from `jackscammell`

Windows:

```powershell
wsl -d PRWatcher -u root
```

Linux (root):

```sh
for g in sudo adm lxd docker; do gpasswd -d jackscammell $g 2>/dev/null; done
ls /etc/sudoers.d/
grep -n jackscammell /etc/sudoers
passwd -l root
passwd -S root
id jackscammell
dpkg -l polkitd pkexec policykit-1 2>/dev/null | grep '^ii'
exit
```

What to look for:
- `gpasswd` errors are hidden, so its own output proves nothing. The `id` line is what shows this step worked.
- `/etc/sudoers.d/` should contain only `README`. If any other file mentions `jackscammell`, remove that file.
- The `grep` on `/etc/sudoers` prints nothing.
- `passwd -S root` shows `L` as the second field (locked).
- `id jackscammell` lists none of `sudo`, `adm`, `lxd` or `docker`.
- The `dpkg` line prints nothing, which means polkit and `pkexec` aren't installed. If it prints a line, remove that
  package and record it in BUILD-NOTES. **VERIFY (S1):** the package names on Ubuntu 24.04 (`polkitd` and `pkexec`
  are expected to be the real packages, and `policykit-1` a transitional one).

### 7b. Restart WSL

Windows:

```powershell
wsl --shutdown
wsl -l --running
```

Wait until the second command says no distributions are running, then open it again with `wsl -d PRWatcher`.

### From now on: root work only from Windows

Inside the distro there is no `sudo` and no root password. When something needs root (installing a package, and later
locking and unlocking the watcher's files), run it from **Windows**:

```powershell
wsl.exe -d PRWatcher -u root --exec <command> <arguments>
```

For example, to install a package:

```powershell
wsl.exe -d PRWatcher -u root --exec apt-get install -y <package>
```

`--exec` runs the program directly, with no root shell. Keep the `-y`, so `apt-get` doesn't stop to ask.

## 8. Check it worked

### 8a. S1: the distro

| # | Where | Command | Expected |
|---|---|---|---|
| 1 | Windows | `wsl -l -v` | `PRWatcher` with VERSION `2` |
| 2 | Windows | `wsl -d PRWatcher --exec ls /mnt/c` | fails: `No such file or directory` |
| 3 | Windows | `wsl -d PRWatcher --exec wslinfo --networking-mode` | `nat` |
| 4 | Linux | `cmd.exe /c ver` | fails: `command not found` |
| 5 | Linux | `sudo -n true; echo $?` | an error message (such as `sudo: a password is required`), then a number that isn't `0` |
| 6 | Linux | `id` | no `sudo`, `adm`, `lxd` or `docker` |
| 7 | Windows | `wsl.exe -d PRWatcher -u root --exec passwd -S root` | second field `L` |
| 8 | Linux | `cat /proc/sys/dev/tty/legacy_tiocsti` | `0` |
| 9 | Windows | `wsl.exe -d PRWatcher -u root --exec id` | `uid=0(root)` |

Rows 1 to 3 are the plan's S1 pass criteria. Rows 4 to 9 confirm steps 3d and 7; the full escape tests come in S3.

- **VERIFY (S1):** row 3. The plan isn't sure `wslinfo` exists or has that option. If it doesn't, run
  `ip -4 route show default` and `ip -4 addr show eth0` inside the distro and paste both outputs into BUILD-NOTES.
  The council picks the networking check from them (plan §4, check 4).
- **VERIFY (S1):** row 8. If the file doesn't exist, the WSL kernel lacks the setting; record it and tell the council.

### 8b. S2: the Claude Code sandbox

S2 uses a **hand-rendered** copy of the watcher's settings, because the renderer doesn't exist until Phase 1. Phase 1's
renderer replaces this whole block, and it is deleted from the guide then. Linux:

```sh
mkdir -p ~/prwatch/config ~/prwatch/bin ~/prwatch/test/sec ~/s2
sed "s#/Users/jack#$HOME#g" ~/pr-watcher/watcher/config/settings.json > ~/prwatch/config/settings.json
sed "s#/Users/jack#$HOME#g" ~/pr-watcher/watcher/bin/prwatch-guard.sh > ~/prwatch/bin/prwatch-guard.sh
chmod +x ~/prwatch/bin/prwatch-guard.sh
sed "s#/Users/jack#$HOME#g" ~/pr-watcher/watcher/test/sec/guard-cases.tsv > ~/prwatch/test/sec/guard-cases.tsv
```

Then add the Linux secrets from plan §3 to the copy's deny lists, so that S2 tests the reads the port will deny, not
only today's Mac list:

```sh
f=~/prwatch/config/settings.json
jq '.permissions.deny += ["Read(~/.claude/.credentials.json)","Read(~/.claude.json)","Read(~/.git-credentials)",
      "Read(~/.config/git/credentials)","Read(~/.config/composer/**)","Read(~/.npmrc)","Read(~/.nuget/NuGet/**)",
      "Read(~/.docker/**)","Read(~/.gnupg/**)","Read(~/.aws/**)","Read(~/.azure/**)",
      "Read(~/.local/share/keyrings/**)","Read(//mnt/**)","Read(//run/WSL/**)"]
    | .sandbox.credentials.files += (["~/.claude/.credentials.json","~/.claude.json","~/.git-credentials",
      "~/.config/git/credentials","~/.config/composer","~/.npmrc","~/.nuget/NuGet","~/.docker","~/.gnupg","~/.aws",
      "~/.azure","~/.local/share/keyrings","/mnt","/run/WSL"] | map({path: ., mode: "deny"}))' "$f" > "$f.new" \
  && mv "$f.new" "$f"
grep -c /Users/ ~/prwatch/config/settings.json ~/prwatch/bin/prwatch-guard.sh ~/prwatch/test/sec/guard-cases.tsv
jq empty ~/prwatch/config/settings.json && echo json-ok
```

The `grep -c` line prints `0` for each file, and `jq` prints `json-ok`.

This copy is **only for S2**. It is not the plan's superset settings (Phase 2), and the other watcher scripts it names
are not on Linux yet, so hook errors about missing scripts are expected and are not an S2 failure. A **settings
error** at start-up is a failure.

**Guard check.** Type `zsh` first, then:

```zsh
n=0; while IFS=$'\t' read -r want c || [[ -n $want ]]; do (( n++ )); got=$(/usr/bin/jq -nc --arg c "$c" '{tool_input:{command:$c}}' | ~/prwatch/bin/prwatch-guard.sh >/dev/null 2>&1; print $?); [[ $got == $want ]] || print "MISMATCH ($got≠$want): $c"; done < ~/prwatch/test/sec/guard-cases.tsv; print "checked $n"; grep -c . ~/prwatch/test/sec/guard-cases.tsv
```

It prints no `MISMATCH` lines, then `checked <n>`, then a number. The two numbers must be equal: that shows the loop
read every row. Any `MISMATCH` line, or two different numbers, is a failure. (The `.tsv` has no blank lines. A blank
line would be counted by the loop but not by `grep`, so it shows up as a failure rather than slipping through.)

**Sandbox check.** Linux:

```sh
cd ~/s2
claude --settings ~/prwatch/config/settings.json
```

Then, in the session:

| # | Do | Expected |
|---|---|---|
| 1 | Start the session, then type `/sandbox` | No settings error. `/sandbox` shows sandboxing as enabled. |
| 2 | Ask Claude to run `echo hello` in Bash | It runs sandboxed and prints `hello` |
| 3 | Ask Claude to run `cat ~/.claude/.credentials.json` in Bash | The tool result is a refusal from the sandbox or a permission rule, not Claude declining to try |
| 4 | Ask Claude to run `ls ~/.config/gh` in Bash | As row 3 |
| 5 | Ask Claude to run exactly this in Bash: `python3 -m http.server 8765 --bind 127.0.0.1 >/dev/null 2>&1 & p=$!; sleep 1; curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8765/; kill $p` | `200`: loopback works in sandboxed Bash |

Then `/exit`. Paste the tool results for rows 3 to 5 into BUILD-NOTES.

- **VERIFY (S2):** row 1. What `/sandbox` shows in this version of Claude Code. Even if it shows nothing useful, the
  session starting at all is evidence: `failIfUnavailable` makes Claude Code refuse to start without the sandbox.
- **VERIFY (S2):** row 1 also covers the plan's open question whether Linux accepts `network.allowLocalBinding` (the
  docs call it macOS-only). If it causes an error, record it: the plan then moves it to
  `config/settings.mac-only.json`.
- **VERIFY (S2):** rows 3 and 4. If Claude refuses to run the command at all, ask it to run it anyway so the sandbox
  answers. A refusal by Claude doesn't count either way. In BUILD-NOTES, record which rule refused it: the sandbox
  credentials block or a permission deny.
- **VERIFY (S2):** row 5. Whether the sandbox lets a server bind loopback, and whether `curl` reaches it with
  `strictAllowlist` on. If row 5 fails, record exactly what failed.

Record the results in BUILD-NOTES. S2 passes when rows 1 to 5 and the guard check pass.

## Still to come

Phase 6 (plan step 23) adds these sections. They depend on Phases 2 to 5.
- **Install:** `install.sh` (WSL branch) and `install-windows.ps1`, replacing the hand-done parts of step 7,
  rewriting `wsl.conf` from the repo and restarting the distro (step 3d stays a hand step).
- **Desktop shortcut:** the "PR Watcher" shortcut, the only supported way to start the watcher.
- **Notifications and Do Not Disturb:** Windows toast setup. Notifications stay on screen until you dismiss them
  (your choice, plan §6), and this section covers what Do Not Disturb does to them.
- **Locking:** run `~/prwatch/bin/prwatch-render.zsh --lock-commands` and use the line it prints.
- **W-checklist:** the day-1 tests for Windows (plan §12).
- **Update and uninstall:** including copying out the archive before `wsl --unregister`, which deletes it.
- **Troubleshooting:** one entry per launcher preflight message.
