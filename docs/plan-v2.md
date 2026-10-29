# PR watcher v2 — plan

Status: **council-approved, revision 3b**. Plan only; nothing in `watcher/` has changed yet. Implementation waits on
Jack's answers to the open questions in §10 (each has a stated default).

Six grumpy reviewers (architecture, security, testing, documentation, maintainability, standards) reviewed over five
rounds: round 1 all APPROVE-WITH-NOTES, round 2 one APPROVE, round 3 four, rounds 4–5 closed the last two. Every
finding and its change is mapped in §12.

Baseline: `main` at `9136d29`. Facts about Claude Code 2.1.312, the Parliament of Chaos plugin (1.28.0) and GitHub
were verified on the day of writing and are listed in §9. Anything still unverified is marked **UNVERIFIED** and has a
live-check item in §7 with a stated fallback.

## 1. What Jack asked for

1. **Review engine.** Use Claude Code's built-in review by default, or the Parliament of Chaos reviewers when the
   plugin is installed. If it is not installed, encourage the user to install it.
2. **Inbox.** Pick up every pull request where Jack is requested as reviewer, in any organisation or personal repo,
   not just ACT-Training.
3. **No count limits.** Remove the daily cap. The watcher runs for eight hours from the moment it is started.
4. **Legitimise the repo.** Add the files the Parliament of Chaos repo gained on 28 Oct (licence, code of conduct,
   security policy, issue and PR templates) and whatever else a project someone else could pick up needs.

Then review this plan with the council and iterate until every reviewer approves.

## 2. What stays exactly as it is (do not re-litigate)

- Nothing is posted to GitHub without Jack's console choice, a permission prompt and the Mac dialog (invariant 1).
- The model never calls `gh`; all GitHub reads and the single write live in `bin/*.sh` (invariant 2).
- Reviewers run in the foreground only; the harness-fault abort stays (`docs/fix-background-agents.md`).
- Draft PRs are skipped. The >3000-line go-ahead question is a **size** gate and stays. The `attempts < 3` retry is a
  **crash** guard and stays. Neither is a count limit.
- `state/` is written only by `prwatch-state.sh`, the launcher (`session.lock`), the hooks' `harness/` markers and the
  prompt hook's one-use request files (`state/stop/`, `state/pause/`, `state/repo/`). The watcher's own files are
  write-denied to the model and locked with `chflags uchg`.
- The sandbox denies reads of `~/.ssh`, `~/.config/gh`, `~/.netrc`, Keychains, `~/.composer`, `~/Documents/GitHub`.
  The Laravel static-only rule (no `composer install`, Flux key never exposed) applies to every repo.
- Direct review requests only (`user-review-requested:@me`), Jack's September choice. Team requests do not count.
- "Scripts decide, model obeys": every count, window, key and path check lives in `bin/`; skills and `CLAUDE.md` only
  repeat what a script printed. The harness asserts the prose against the scripts.
- Jack's writing rules: plain English first, British English, no dates or merge windows in PR bodies, fold small
  follow-ups into the PR rather than raising issues.

## 3. The one structural idea: split "engine" from "watcher"

Today `/prwatch-review` is a monolith: prep → pick angles → council → verify → draft → ready. The plan draws a line
through the middle of it.

| Layer | Owned by | Changes with the engine? |
| --- | --- | --- |
| Inbox, classification, window, state, prep (clone, worktrees, `input/`), decide, post | watcher (scripts + skills) | never |
| **Static review panel**: who reads the diff and reports findings with a verdict | **engine** (`parliament`, `builtin` or `builtin-agent`) | yes |
| `claims` angle (falsify the PR's claims in the build copy), `testing-build` angle (runs tests), verify, draft | watcher | never |

Both engines produce the same artefact: `A/reviews/<member>.md` files ending `VERDICT: REJECT | APPROVE-WITH-NOTES |
APPROVE | NO-FINDINGS`, which the existing verify and draft steps already consume. The engine is chosen **once, by the
launcher**, and recorded in `session.lock`. The model reads that file; it never decides.

## 4. Decisions

| # | Topic | Decision | Why |
| --- | --- | --- | --- |
| D1 | Engine mechanics | `parliament` = one foreground `Agent` per member with `subagent_type: chaos:grumpy-<name>`. `builtin` = one `Skill` call `/code-review high <worktree>`. `builtin-agent` = one `general-purpose` opus agent with `angles/default-review.md` (only if live check L1 shows `/code-review` cannot review a worktree path). All three plus the watcher's `claims` and `testing-build` angles. | The grumpy reviewers are read-only by frontmatter, the safest possible subagents. `/chaos:parliament-review` was rejected: it forks its own orchestrator, can ask questions mid-review, counts rounds via `gh`, and has a posting path. |
| D2 | Engine choice and record | Launcher only. Detection: `config/parliament.lock` names the pinned `installPath`; if that directory exists and its whole-tree hash (D3) matches, engine = `parliament`; otherwise `builtin`, or `builtin-agent` when `config/engine-fallback.json` (`{builtin_agent: bool, parliament_blocked: bool, reason, claude_version}`, locked with `config/`, written only by `live-check.sh` when Jack runs it) says so. `parliament_blocked: true` (written by a failed L5) makes the launcher choose `builtin` even with a matching pin, until Jack deletes the file after re-reading and re-pinning the plugin. The `builtin_agent` flag is honoured only when the file's `claude_version` equals `claude --version`; otherwise it is ignored, the launcher prints "engine-fallback.json is for <x>, you are on <y>: re-run live-check L1", and proceeds as `builtin`, so that fallback expires with the build it was measured on. `parliament_blocked` does **not** expire: while the file has `parliament_blocked: true` the launcher chooses `builtin` regardless of `claude_version`, passes no `--plugin-dir`, and prints "Parliament was blocked by live-check under Claude Code <x>; you are on <y>: run live-check.sh to clear it". Only a passing L5 in `live-check.sh` clears it (writes `parliament_blocked: false` with the new version), or Jack deletes the file. `claude plugin list --json` is used only to print what is installed and to suggest `install.sh --repin`. Terminal override `PRWATCH_ENGINE=builtin` is an **input** to the launcher, never a second source. The record is one object in `session.lock`: `engine: {engine, plugin_id, version, plugin_dir, reason}`. The launcher exports the whole lock it wrote as `PRWATCH_LOCK_JSON`; a tick-recreated lock is that object plus `recreated: true`, so no per-field env plumbing is needed (`PRWATCH_SESSION_ID`, `PRWATCH_STARTED_EPOCH` and `PRWATCH_LOGIN` stay as scalars for the scripts that compare them). Tick echoes `engine` from the lock in every JSON. | `--setting-sources project,local` excludes user settings, so the plugin only loads with an explicit `--plugin-dir` (verified). One launcher-written file, one lifetime, one enum used verbatim by the skill hook, tick and `meta.json`. `session.lock` is rewritten every launch, so a one-off L1 decision needs a `config/` home. |
| D3 | Plugin pinning | **Pin the whole install tree**: `config/parliament.lock` = `{version, installPath, tree_sha256}` where `tree_sha256 = find <installPath> -type f -not -path '*/.git/*' -print0 \| sort -z \| xargs -0 shasum -a 256 \| shasum -a 256`. Exact match → `--plugin-dir`. Any mismatch → `builtin` plus "Parliament <found> is installed but the watcher is pinned to <pinned>; read the diff, then run `install.sh --repin`". `install.sh --repin` writes the lock from the current install (Jack runs it; the watcher never does). Document the cadence in `CONTRIBUTING.md`: every Parliament release needs a re-pin PR. | Plugin hooks run **outside** the Bash sandbox, `plugin.json` can register hook files anywhere in the tree, and `.claude/rules/*.md` are injected into the session context (verified). A file list would miss all of that and rot with the plugin's layout. |
| D4 | Reviewer memory | Launcher, before `exec claude`: `mkdir -p ~/.claude/agent-memory/${MEMORY_PREFIX}-grumpy-<name>` for every grumpy reviewer the panel can dispatch (so nothing is created unfrozen; `MEMORY_PREFIX` is a constant in `prwatch-common.zsh` set from the directory name L6 records for the `chaos@inline` load), then `chflags -R uchg` each directory **and every file in it**; record the list in `session.lock.frozen_memory`; `chflags -R nouchg` the list on exit (trap). At every launcher start, thaw anything listed in a stale lock (dead pid) first and print one line. Manual recovery is `install.sh --thaw` (Terminal only; `install.sh` is never a canonical script, so the model cannot call it), named in README "If something goes wrong". `chflags` added to the guard tripwire. If Claude Code documents a per-session switch that disables agent memory, prefer it and delete the `chflags` path (Q6; the implementer checks `claude --help` and the docs as a PR 4 step). | Verified: grumpy reviewers persist user-scope memory even though they have no Write tool, so the harness writes it. Hostile PR text could otherwise poison memory that Jack's other sessions read. `uchg` on a directory alone leaves existing files writable in place. A thaw on a model-callable script would be a one-call undo of the control. |
| D5 | Plugin commands | Three layers, and the hook is the decider: (a) new PreToolUse hook on `Skill` (`bin/prwatch-skillhook.sh`), an **allow-list**: `prwatch-*` (`start|tick|eod` with no argument, `review|decide` with one key), and `code-review` only under D7; everything else, including every `chaos:*` command, exit 2; fail closed on an unknown payload shape. (b) `permissions.deny` `Skill(chaos:*)` and, in case the glob does not match namespaced names, the named dangerous commands. (c) `skillOverrides: user-invocable-only` for the eight orchestrating commands. A comment in `settings.json` says which layer is authoritative. | The watcher uses Parliament's **agents**, never its **commands**. Typed `/chaos:…` by Jack bypasses PreToolUse by design; the cron prompt is pinned by the sched gate, so no other typed path exists. |
| D6 | Subagent types | `prwatch-agenthook.sh pre` allows `subagent_type` ∈ {`general-purpose`, `chaos:grumpy-*`} only; anything with `isolation` set is refused. Launcher exports `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1`. | Specialists have Bash; `senior-council` and `deliberation-conductor` can spawn. |
| D7 | Built-in `/code-review` | Remove the `Skill(code-review)` deny and the `skillOverrides: off`. The skill hook allows it only when `session.lock.engine.engine == "builtin"` **and** the argument is exactly `<low\|medium\|high> $PRW/work/<WT_PAT>` (the worktree pattern from `prwatch-common.zsh`, D14) and that directory exists. A second check refuses `--comment`, `--post`, `--fix`, `--max-findings`, `ultra`, `max`, `xhigh`, bare numbers, `..`. Keep `review`, `security-review`, `schedule`, `loop` denied and off. `Skill(code-review *)` is in `allow` so auto mode does not second-guess the hook; the narrowed `deny` entries win over `allow` (deny-beats-allow is stated in `settings.json` and asserted by the harness). | `--comment` and `--post` are the posting paths; `--fix` edits; a PR-number target needs `gh`. Backstops stay: `gh` deny plus logged-out `GH_CONFIG_DIR`, no network, write-denied tree. |
| D8 | Transcription | Grumpy reviewers cannot Write, and `/code-review` returns text. The orchestrator writes `A/reviews/<member>.md` as `# <member> — transcribed verbatim from the hand-back (untrusted)` + the text + a `VERDICT:` line taken only from the member's final verdict line (builtin: derived mechanically, Critical/High → REJECT, Medium/Low → APPROVE-WITH-NOTES, none → APPROVE). | Keeps invariant 5: the file is data the model copies, never instructions it follows. |
| D9 | Panel selection (Parliament) | Computed by the skill from `A/input/profile.json` and the file list, mirroring `parliament-review`: floor = security-nag + code-reviewer (+ privacy-paranoid when `has_pii`); tiered: testing-tyrant (code or tests), performance-troll (SQL or .NET), accessibility-auditor (frontend), architecture-skeptic + maintainability-curmudgeon (≥500 lines), standards-enforcer (unless proportionate), documentation-pedant (docs only); proportionate (<50 lines or docs only) = floor only; round ≥2 = floor + last round's REJECTs, focus `delta.patch`. The watcher's own `security`, `backend-data`, `frontend` angle files stay in the repo but are not dispatched under Parliament (Q2). | One table in the skill, no new script. |
| D10 | Parliament probe fails at start | Self-test 7b (foreground PONG with `chaos:grumpy-code-reviewer`; `chaos:grumpy-security-nag` visible; a `chaos:list-commands` Skill call refused by the hook). Any failure → `PROBLEM`, the session stops, the launcher window says "relaunch with `PRWATCH_ENGINE=builtin`". Never a silent fallback. | The engine is a launcher decision; the model switching engine mid-session would be the model choosing (Q5). |
| D11 | Inbox query | `gh search prs --state open --limit 100 --json number,repository,author -- "user-review-requested:@me"` (drop `--owner`; `author` added for the D16 notice so no extra read is needed). No notifications API. | Verified to span every repo the token can see. Notifications keep merged items for weeks. |
| D12 | Key grammar, one file | `<owner>/<repo>#<n>`: owner `[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?`; repo `[A-Za-z0-9_][A-Za-z0-9._-]{0,99}` (no leading `-` or `.`, so never `.`/`..`, never an option); n `[1-9][0-9]{0,6}` (no leading zero). Defined once in **`bin/prwatch-common.zsh`** (sourced after the `env -i` re-exec by every script and the launcher; never called, so correctly absent from the guard canon) together with `key_split` (`o=${k%%/*}; rest=${k#*/}; repo=${rest%%\#*}; n=${rest##*\#}`), the worktree builder/matcher (D14) and the window constants (D18). Used at every entry point: tick (at ingestion from `repository.nameWithOwner`), state, prep, post, cleanup, buildrun, ngtest, dotnettest, agenthook (×2), notify, skill hook. Guard charset already admits `/` and `-`: unchanged. | Existing keys are already `ACT-Training/Vision#1803`, so this is a regex loosening, not a migration. One grammar, one validator. |
| D13 | Script arguments | **Every script takes the key**, never owner/repo pieces: `prwatch-prep.sh <key> <sha40> <round>`; `prwatch-post.sh --key <key> --sha … --event … --body-sha … [--tech …]`; buildrun/ngtest/dotnettest/cleanup unchanged in shape. Each script validates with `okkey` and splits with `key_split`; every path is built from the split parts. | One call shape for the skills to render and the guard to recognise. |
| D14 | Paths | `repos/${o}__${repo}`, `work/${o}__${repo}-pr${n}-${sha7}[-build]`, archive `~/Documents/vision-reviews/<date>-${o:l}-${repo:l}-pr${n}-round${k}`. Built only by `wt_name`/`archive_name` in `prwatch-common.zsh`; matched only by `WT_PAT`/`WT_GLOB` from the same file (prep, state `harness-abort`, cleanup sweep, post `kill_strays`, the skill hook). Old folders untouched. | `__` is unambiguous (owners cannot contain `_`), keeps `work/` flat, and one builder/matcher pair means the skill hook cannot drift from prep. Archive root stays (Q3). |
| D15 | Login | Launcher: `LOGIN=$(gh api user --jq .login)` with the real gh config, validated, exported as `PRWATCH_LOGIN` and written to `session.lock.login`. Replaces the three hard-coded `JackScammell` (tick timeline filter, prep prior-review filter, post receipt URL). Scripts fail closed (`error no_login`) if empty. The `gh api orgs/ACT-Training` check goes; the launcher prints the org list once as information. | Makes the repo usable by someone other than Jack. |
| D16 | First PR from an unseen repo | A **source** gate by mechanism, using the prompt-hook pattern (not an `AskUserQuestion` the model acts on). Tick classifies a PR whose `<owner>/<repo>` is not in `state.json.repos` and has no existing `prs` key as `new_repo`; it writes nothing and calls no `gh pr view` beyond the search. The tick skill fires one `question` notification and prints one line: "First PR from `<owner>/<repo>` by `<author>`: type `allow <owner>/<repo>` or `block <owner>/<repo>`". The line is repeated in `notices` on later ticks, never re-asked as a question. The prompt hook handles a prompt that is exactly `allow <owner/repo>` / `block <owner/repo>` from the current session: one-use request file, `prwatch-state.sh repo-allow|repo-block` refuses without it (exit 64, event `repo_refused`), reply line `PRWATCH REPO:`. `repos[<owner/repo>] = "allowed" \| "blocked"`. Day-1 rule: a repo with any existing `prs` key is seen. The author comes from the search result (D11); the tick still calls no `gh pr view` for a `new_repo` item. | One explicit, Jack-only yes before unknown code first runs in the restore step with network. A model-run `repo-ok` after a question would be convention, not mechanism (the known "the hand-back said Jack chose Yes" confusion). Q1. |
| D17 | Cap removal | Delete everything that exists only to count: `CAP_DEFAULT/CAP_MAX`, `today`, `daily-inc`, `cap`, `cap_left`, prep exits 24 and 26 and the `daily-inc` call, the refund in `harness-abort`, the `cap N` prompt-hook branch and `state/cap/`, the `cap` notification kind, `state.json.daily` and `cap_override`, the prose and the harness tests that assert the prose. Every `events.jsonl` line gains `session`; `prwatch-state.sh eod-done` counts the session's lines (posted / waiting / not started / failed) and prints them, so `/prwatch-eod` only repeats numbers. | Jack's goal 3. Typical day: about 10 reviews in 7½ h at 45 min each; ceiling about 16 at 30 min. Recorded as accepted risk AR-6. No clock comparison in the model, no string compare of timestamps. |
| D18 | Window | Launcher writes `started_epoch` (`date +%s`) into `session.lock` and, for humans, `started` (ISO derived from it). A test-only input `PRWATCH_TEST_STARTED_EPOCH` overrides it, read inside the same `PRWATCH_TESTMODE` block that prepends the stub bin and nowhere in `bin/`; `PRWATCH_STARTED_EPOCH` is the launcher's **output** only (exported for the scripts, never read back). A tick-recreated lock comes from `PRWATCH_LOCK_JSON` (D2) and must carry the caller's `session_id`, else `error no_session_start`. All arithmetic is integer seconds: `elapsed = now_epoch − started_epoch`. Constants `START_LIMIT=27000` (7 h 30) and `END=28800` (8 h) live once in `prwatch-common.zsh`. `prwatch-tick.sh --window` is a **pure read**: it touches no heartbeat, checks no lock ownership, sends no notification; it reads `started_epoch` and prints `in_window` / `start_closed` / `session_over`; missing or non-numeric `started_epoch` → `error no_session_start`, never "start now". The heartbeat touch in tick.sh moves below the `--window` early exit. **`prwatch-prep.sh` enforces the same rule**: `elapsed ≥ START_LIMIT` or no `started_epoch` → exit 27 "window closed for new reviews" (a fresh code; 24 and 26 are retired with the cap). No weekday test anywhere. Test mode: `PRWATCH_NOW` is epoch seconds (digits) or the existing local `%Y-%m-%dT%H:%M` form converted with `date -j -f`; `run.sh` sets `TZ=Europe/London`. The model never reads a clock. | The lock is under `state/`, which the model cannot write. Epoch arithmetic is DST-proof by construction and needs no offset parsing (macOS `date -j -f` refuses `+01:00`). Prep's check makes the 7½-hour cut-off a script decision, not advice the model honours. A `--window` that touched the heartbeat would let the watchdog (D21) refresh its own stuck test. |
| D19 | Scheduling | Exactly one session cron: `*/15 * * * *` → `/prwatch-tick`. The sched gate accepts only that string. At `elapsed ≥ END` the tick prints `session_over` with `eod_due: true` once (guarded by `state/eod-done-<session_id>`); the tick skill runs `/prwatch-eod`, which calls `prwatch-state.sh eod-done` (refused unless `elapsed ≥ END` and the lock is the caller's session; prints the counts) and sweeps. Then the skill `CronDelete`s the job and prints "Session finished". | One pinned string, one clock. A hook-computed one-shot EOD cron would be a second clock source and could be missed during a long review. Jitter: up to 7.5 min late, so the summary lands 0–22.5 min after T+8h. |
| D20 | `stop` and `pause N` | Into the prompt hook, replacing the `cap N` branch with the identical one-use request pattern: a prompt that is exactly `stop` or `pause N` (N ≤ 480) from the current session writes `state/stop/request.json` or `state/pause/request.json` `{session, n}`, runs `prwatch-state.sh stop` / `pause N` (refused without a fresh ≤2-minute matching request: exit 64, event `stop_refused`/`pause_refused`), deletes the request, and prints one `PRWATCH STOP:` / `PRWATCH PAUSE:` line for the model to repeat. The session, value and age check is **one** function, `fresh_request <kind> <value>` in `prwatch-state.sh`, consumed by `stop`, `pause` and `repo-allow|repo-block` alike. `stopped-<date>` → `stopped-<session_id>`; tick status `stopped_for_today` → `stopped`. `CLAUDE.md` rows: "`stop` — handled by a hook; repeat the `PRWATCH STOP:` line, `CronList` + `CronDelete` the tick job, say Session finished". `prwatch-decide` free-text `stop`/`pause N` → `set <key> awaiting_decision`, stop asking, print "type `stop` at the prompt". `prwatch-agenthook.sh pre` L78 drops the `stop-today` allowance (keeps `harness-abort|get`). | Jack-only **by mechanism**, so nothing in PR text can shorten or pause the session. `harness-abort` keeps its own marker-authorised stop path. |
| D21 | Watchdog and exit notice | The launcher's watchdog subshell and its exit path call `prwatch-tick.sh --window` (a pure read, D18) and act on `status`: armed from `elapsed ≥ 900`, normal while `in_window`/`start_closed`, extends up to `END + 6000` only while a review or question is live, skips while `stopped-<session_id>` exists; `session-ended` notice only if the status is not `session_over` and no stop file. The stuck test (`age(state/activity) > 1800`) is unaffected because `--window` never touches the heartbeat. | One window implementation; the launcher owns no constants. |
| D22 | Install nudge | Launcher prints two static lines when the engine is not `parliament`: `claude plugin marketplace add https://github.com/JackScammell/Parliament-Of-Chaos.git` and `claude plugin install chaos@chaos`, with "read the plugin's SECURITY.md first; the watcher never installs it for you; relaunch after installing". Start banner one line. README "Review engines" section. Nothing in the model's context says "install"; `Bash(claude *)` denied and `claude plugin` in the guard tripwire. | The watcher must never pull and execute third-party hook code on Jack's behalf. |
| D23 | Repo files | ADD: `LICENSE` (MIT), `CODE_OF_CONDUCT.md`, `SECURITY.md`, `CONTRIBUTING.md`, `CHANGELOG.md`, `.github/ISSUE_TEMPLATE/{bug_report,feature_request}.yml` + `config.yml`, `.github/pull_request_template.md`, `.github/dependabot.yml`, `.editorconfig`, `.github/workflows/check.yml`. SKIP: `CODEOWNERS`, a `VERSION` file (tags + CHANGELOG carry it). Move `docs/cap-override.md` → `docs/history/` with a "superseded" header, keeping its "How it's enforced" heading (linked by name). Contents specified in §5 PR 1. | Parliament baseline. `SECURITY.md` cannot promise GitHub private vulnerability reporting (public repos only per GitHub docs). |
| D24 | CI | Two jobs. `syntax` on `ubuntu-latest` (timeout 5 min): `apt-get install zsh`, `zsh -n` on `install.sh`, `launcher/PR Watcher.command`, `watcher/bin/*.sh`, `watcher/shims/*`, `watcher/test/harness/*.sh`, `watcher/test/sim2/*.sh`, `watcher/test/stub/osascript`; `jq empty` on `watcher/config/settings.json`, `watcher/test/sim2/*.json`, `watcher/test/harness/fixtures/*.json`. The workflow comment says this catches unbalanced quotes and bad JSON, not logic. `harness` on `macos-latest` (timeout 15 min): `sudo mkdir -p /Users/jack/Desktop && sudo chown -R "$(id -un)" /Users/jack`; `./install.sh` with `HOME=/Users/jack` (verified: `install.sh` never runs `chflags`; the lock is a manual step); then, with `HOME=/Users/jack`, `PRWATCH_REPO=$GITHUB_WORKSPACE/watcher`, `PRWATCH_LAUNCHER=$GITHUB_WORKSPACE/launcher/PR Watcher.command`, `</dev/null`: `run.sh`, `test/sim2/tick-sim2.sh`, and the guard-cases loop over both case files with a `cmp` of the two. `actions/checkout` pinned to the full commit SHA of its current release (looked up at implementation, tag in a trailing comment), `permissions: contents: read`, concurrency per ref, no secrets. `live-check.sh` never runs in CI. | The guard regex and the settings allow list are literal `/Users/jack/prwatch` by design, so a scratch HOME fails three or four checks today. Creating the path tests the exact artefact Jack runs; a `sed` under CI would test a different one. The proper fix is the path-rendering seam already planned in `docs/windows-port.md` §2. |
| D25 | Order of work | Four PRs, smallest risk first: **PR 1** repo files + CI; **PR 2** window, cap removal, stop/pause hook; **PR 3** inbox, keys, paths, login, first-sighting gate; **PR 4** engine adapter, plugin pin, skill hook, memory freeze, nudge. Each PR changes code, prose and harness asserts together, and `run.sh` is run after each prose edit, not only at the end. `PR 1` does not merge until Q7 (licence) is answered. | The harness asserts the banner, README and skill prose against the scripts. |

## 5. File-by-file change list

Line numbers are from `main` at `9136d29`. Lines marked (UNVERIFIED) come from the brief's inventory, not a read of
the file this pass; the first step of the PR that touches them is `grep -n` for the named string, then fix the plan or
the line before editing.

### PR 1 — repo files and CI

- `LICENSE`: MIT, `Copyright (c) 2026 Jack Scammell`. Blocked on Q7.
- `CODE_OF_CONDUCT.md`: Contributor Covenant 2.1; enforcement contact = the maintainer's GitHub handle
  (`@JackScammell`); one project paragraph: reviews post under the user's own GitHub identity, so never add a code path
  that posts without the three steps, and never weaken the sandbox or the `gh` deny "to make a test pass".
- `SECURITY.md`: (a) what counts as a vulnerability (PR-controlled content causing a post, running outside the sandbox,
  reading credentials, reaching the network from a review sandbox, escaping the canonical-call rule; any way the model
  can call `gh`/`git push`/`osascript`; a scheduled prompt posing as the user); what does not (a wrong review, a test the
  sandbox cannot run, the accepted risks in §8). (b) how to report: open an issue in this repository (private at the
  time of writing; the implementer confirms in Settings) or email the address on the maintainer's GitHub profile; what
  to include (commit, `claude --version`, the `state/` entry, never PR contents); if the repo goes public, switch to
  GitHub's "Report a vulnerability" and add the link to `config.yml`. (c) supported versions: `main` only; the
  installed copy must match (the harness checks drift). (d) "what it does and does not do".
- `CONTRIBUTING.md`: where things live; the edit → unlock → `install.sh` → `run.sh` (with `PRWATCH_REPO`) →
  `live-check.sh` after any Claude Code update → re-lock loop; `run.sh` runs the **installed** copy and needs macOS;
  "scripts decide, model obeys"; prose sync (launcher banner, `watcher/README.md`, start skill asserted together; run
  `run.sh` after each prose edit); PR body shape; no dates; a changelog line per PR; the Parliament re-pin cadence
  (`install.sh --repin` PR per plugin release); repo settings as convention (squash only, delete-branch-on-merge off,
  don't merge on red); the baseline's closing "By contributing… licensed under MIT" clause once Q7 is settled.
- `CHANGELOG.md`: Keep a Changelog. `[Unreleased]` (each PR adds its own line). Prior entries seeded from
  `git log --format='%ad %h %s' --date=short`: Windows port docs; cap override plus seven review rounds grouped under
  one heading; first build, background-agent fix, sandboxed tests.
- `.github/ISSUE_TEMPLATE/bug_report.yml`: fields what happened (plain English); watcher commit and whether
  `install.sh` was re-run; `claude --version`; `run.sh` result; `live-check.sh` result if a Claude Code update is
  involved; the `state/` entry (key and status only); notification text; checkbox "No PR content, credentials or review
  text pasted"; label `bug`. `feature_request.yml`: problem; which invariant it touches (dropdown: none / posting /
  GitHub access / sandbox / foreground reviewers / scheduling); proposed behaviour; "does it change what the model is
  told or what a script enforces"; label `enhancement`. `config.yml`: `blank_issues_enabled: false`; contact link
  "Security problem" → `SECURITY.md`.
- `.github/pull_request_template.md`: Summary / Related issues / Testing performed (`run.sh` result, `live-check.sh` if
  hooks or harness surface changed, which T-tests re-run, mutation results) / Documentation checklist (README,
  `watcher/README.md`, `watcher/CLAUDE.md`, skill banners, launcher banner, `CHANGELOG.md`); "No dates or merge windows
  in this body."
- `.github/dependabot.yml` (github-actions, monthly), `.editorconfig` (2-space, LF, utf-8; markdown keeps trailing
  whitespace), `.github/workflows/check.yml` per D24.
- `docs/history/cap-override.md` (moved; two-line superseded header; `grep -rn cap-override .` and repoint every
  link); `docs/plan.md`, `watcher/BUILD-NOTES.md`, `docs/windows-port.md`, `docs/windows-wsl.md`: dated header note only.
- `README.md` layout table: new rows; `docs/cap-override.md` row repointed.
- `watcher/test/harness/run.sh` L476: default `PRWATCH_REPO` → `$HOME/Documents/GitHub/pr-watcher/watcher`.
- Tags: `v0.1.0` on today's `main`; `v1.0.0` after PR 4 (Q8).

### PR 2 — window, cap removal, stop/pause hook

- `watcher/bin/prwatch-common.zsh` (new, sourced): window constants `START_LIMIT=27000 END=28800 WATCHDOG_ARM=900
  WATCHDOG_EXTEND=6000`; `now_epoch()` honouring `PRWATCH_NOW` in test mode (digits = epoch; `%Y-%m-%dT%H:%M` = local
  via `date -j -f`; anything else exit 64); `started_epoch()` reading the lock. (Key and path helpers arrive in PR 3.)
- `launcher/PR Watcher.command` L38–39 lock gains `started_epoch` (and `started` derived from it; the
  `PRWATCH_TEST_STARTED_EPOCH` override lives in the L6 `PRWATCH_TESTMODE` block); `export PRWATCH_STARTED_EPOCH
  PRWATCH_LOCK_JSON`; L46–63 watchdog per D21 (calls `--window`); L65–68 drop the weekend note and the `cap 8` line, reword L66–67 to
  "Runs for 8 hours from now (new reviews for the first 7½); type `stop` to finish early"; L90 per D21.
- `watcher/bin/prwatch-tick.sh` L16 heartbeat touch moves below the `--window` early exit; L24–32: `elapsed` per D18;
  `--window` JSON `{status, started, elapsed_min, starts_until, ends_at}` with no touch, no lock check, no
  notification; `stopped-$PRWATCH_SESSION_ID`; status `stopped`; `session_over` + `eod_due` from `eod-done-<sid>`; L20
  recreated lock = `PRWATCH_LOCK_JSON` plus `recreated: true` (so `login` and `engine` ride along automatically once
  PR 3 and PR 4 add them to the lock); L94–98 JSON gains `started, elapsed_min, starts_until, ends_at`, loses
  `councils_today, cap, cap_default, cap_max, cap_left`. `paused_until` stored and compared as epoch.
- `watcher/bin/prwatch-state.sh` L12 delete constants; L16–20 delete `today`, add read-only `check` (exit 0 ok, 70
  unreadable or non-object `prs`; needs no session); L15 initial literal `{"prs":{},"go_ahead":{},"repos":{}}`; L52
  `stop-today` → `stop` touching `stopped-$PRWATCH_SESSION_ID`, refused without the hook's request (64,
  `stop_refused`); `pause N` likewise (`pause_refused`; N ≤ 480; stores epoch); one `fresh_request` function for both
  (and for `repo-*` in PR 3); L54–71 delete `daily-inc`/`cap` (exit 65 retired: it was the cap refusal); L96–97 drop the
  refund; every event line gains `session`; new `eod-done` per D19 (prints `{posted, waiting, not_started, failed}` for
  the session; 64 if `elapsed < END`; 5 if another session); one-time `del(.daily,.cap_override)` on first write.
- `watcher/bin/prwatch-prep.sh` L19–24: delete the `daily-inc` block and exits 24/26; new exit 27 = window closed per
  D18; exit 25 = "session or login precondition failed" (other session, or empty `PRWATCH_LOGIN` from PR 3).
- `watcher/bin/prwatch-prompthook.sh` L19–35: `prompt` branch handles `stop` and `pause N` per D20; L41–42 sched accepts
  only `*/15 * * * *|/prwatch-tick|true`.
- `watcher/bin/prwatch-agenthook.sh` L52 `stopped-$SID`; L56 "stopped for this session"; L78 drop `stop-today`.
  `prwatch-cleanup.sh` sweep removes `stopped-*` and `eod-done-*` older than two days (UNVERIFIED lines).
  `prwatch-notify.sh` delete the `cap` kind; "before 16:00" → "before the end of its session"; `harness` template
  "off for today" → "off for this session" (UNVERIFIED lines).
- `watcher/CLAUDE.md`: L3 "One interactive session per weekday" → "One session, 8 hours from launch"; L5 "Only
  `prwatch-state.sh` writes `state/`" → "`state/` is written only by `prwatch-state.sh`, the launcher (`session.lock`),
  the hooks' `harness/` markers and the prompt hook's one-use request files"; delete the `cap N` row; L25 `stop` row and `pause` row per D20; L27 `status` row
  without `today` ("print the `--window` line and the engine"); standing answer 1 → "new councils only start in the
  first 7½ hours (`--window` says `in_window`; prep refuses with 27 after that)"; sweep "today" wording. B9 asserts
  the exit number in CLAUDE.md and the skills matches the one in `prwatch-prep.sh`.
- Skills: `prwatch-start` §2 one `CronCreate`, banner from `--window` JSON, no `cap`; `prwatch-tick` statuses
  `session_over` (+ `eod_due`), `start_closed`, `stopped`, no cap bullet, exit 27 = "window closed, leave queued";
  `prwatch-review` §2.2 exit 27 wording, drop 24 and 26, delete the "refunds today's slot" sentence in §4, "off for today" →
  "off for this session"; `prwatch-eod` repeats the `eod-done` counts, "Session summary: posted a, waiting b, not
  started c, failed d", "at the next launch"; `prwatch-decide` §4 free-text `stop`/`pause N` per D20.
- `README.md` L3–5: "runs for eight hours from the moment you start it". `watcher/README.md`: daily-use bullets,
  commands table (no `cap`; `stop`/`pause` rows), L28–35 session wording, T3 rewritten around `started_epoch`, T13
  reworded, T17 deleted, "Do T6… on a weekday" deleted, T2 notes that a Terminal dry run needs `PRWATCH_STARTED_EPOCH`
  in test mode.
- Harness: delete 57 checks (cap section + refunds), change 44, keep the lock behaviour by moving it onto `set`.
  Add: **B1** window (T+0, T+7h29m59s, T+7h30, T+7h59m59s, T+8h, T−1m → not `in_window`, midnight, DST end
  25 Oct 2026 and DST start 29 Mar 2026 as epoch pairs, Saturday inside 8 h → `in_window`, missing/non-numeric
  `started_epoch` → error, dry run without a lock → error, JSON has no cap keys, `start_closed` still classifies,
  `session_over` writes no state; **B1.17** `eod-done-<sid>` present → `eod_due:false` and `events.jsonl` unchanged;
  `eod-done` under another session → 5; before `END` → 64; unparseable `PRWATCH_NOW` → 64; **B1.18** `--window` and
  `--dry-run --window` leave the `state/activity` mtime unchanged and send no notification when the lock belongs to
  another session; prep at T+7h31 → 27; a tick-recreated lock equals `PRWATCH_LOCK_JSON` plus `recreated` and its
  `session_id` equals `PRWATCH_SESSION_ID`; `PRWATCH_LOCK_JSON` unset, non-JSON or carrying another `session_id` →
  `error no_session_start`, no lock written); **B2** stop/pause
  (`stopped-sid-A` seen only by `sid-A`; legacy `stopped-<date>` ignored; `stop` from another session → 5; `$SS stop`
  with no request → 64, request from `sid-B` → 64, request 2 min old → 64, request 30 s old → accepted and consumed,
  second call 64; `ph "pause 30"` sets `paused_until`; `ph "pause x"`/`"stop please"`/`"pause 9999"` ignored; model-run
  `$SS stop` under a live fault marker → denied; pause across a DST change → expired; `END` inside a pause →
  `session_over`); **B2.7** launcher in test mode with a stub `claude` that exits at once, `</dev/null`:
  `PRWATCH_TEST_STARTED_EPOCH` = now−9h → no `session-ended` line; now → one; now + stop file → none; **B2.8** (a) in
  test mode, `PRWATCH_STARTED_EPOCH=1` in the environment leaves the lock's `started_epoch` within 5 s of now (the
  launcher never reads its own output name); (b) code shape: `PRWATCH_TEST_STARTED_EPOCH` appears in the launcher only
  inside the `PRWATCH_TESTMODE` block and `! grep -rq PRWATCH_TEST_STARTED_EPOCH watcher/bin`; **B8** sched gate (new string allowed; both
  old strings, `/prwatch-eod`, `*/10`, extra fields → 2; start skill has exactly one job and the string matches the
  gate); **B9** prose (`! grep -Eiq 'cap [0-9]|daily cap|review limit|at most 12|normally 6|PRWATCH CAP'`; no
  `08:00|15:30|16:00|Mon.?Fri|weekday|1-5 ` in launcher banner, README, CLAUDE.md, skills; no `today` in model-facing
  text; "8 hours" and "7½"/"7 h 30" present; `! grep -Eq 'with 24|exit 24|exit 26'` in CLAUDE.md and the tick/review
  skills, and the window exit number they quote equals the one defined in `prwatch-prep.sh`); **B10** legacy tolerance (`today`/`daily-inc`/`cap`/`stop-today` → 64;
  `ph "cap 8"` → 0, no file; old `daily`/`cap_override` fields dropped on first write; `stopped-<date>` ignored);
  **B11** lock on `set` (10 parallel writers → valid JSON; held → 75; short wait → 0). `run.sh` sets
  `TZ=Europe/London`.
- Mutations for this PR: M1 delete the `started_epoch` read → B1; M2 `<` → `<=` at T+7h30 → B1; M3 `>=` → `>` at T+8h
  → B1; M4 `state.sh stop` skips the request check → B2; M11 sched gate accepts any cron with prompt `/prwatch-tick`
  → B8; M13 `--window` touches the heartbeat → B1.18; M14 prep skips the window check → B1 (prep at T+7h31 → 27).

### PR 3 — inbox, keys, paths, login, first-sighting gate

- `watcher/bin/prwatch-common.zsh`: `KEY_PAT`, `okkey`, `key_split`, `wt_name`, `archive_name`, `WT_PAT`, `WT_GLOB`
  per D12/D14.
- `launcher/PR Watcher.command` L26: replace `gh api orgs/ACT-Training` with the login capture per D15 and an
  informational `gh api user/orgs --jq '.[].login'` line; lock gains `login`.
- `watcher/bin/prwatch-tick.sh` L39 drop `--owner`, add `author` to `--json`; validate `repository.nameWithOwner` at
  ingestion (a hostile value writes nothing and calls no `gh pr view`); L63 `--arg me "$PRWATCH_LOGIN"`; fail closed on
  empty login; `new_repo` reason per D16 (first-match row before `new`; author from the search row).
- `watcher/bin/prwatch-state.sh` L29 `okkey` from the shared file; L83 worktree prefix via `wt_name`; new
  `repo-allow|repo-block <owner/repo>` (via `fresh_request`; stores `allowed`/`blocked`; events `repo_allow`,
  `repo_block`, `repo_refused`).
- `watcher/bin/prwatch-prompthook.sh`: `allow <owner/repo>` / `block <owner/repo>` branch per D16, reply `PRWATCH REPO:`.
- `watcher/bin/prwatch-prep.sh` L2–4, L16–18: `<key> <sha40> <round>`, `okkey` + `key_split`; L29–32 names via
  `wt_name`/`archive_name`; L34 clone URL `$GITBASE/${o}/${repo}.git`; L67 `--arg me "$PRWATCH_LOGIN"`; L75–81 `has_pii`
  in `profile.json` (regex `(learner|staff|person|attendance|safeguard|address|dob)` over changed paths).
- `watcher/bin/prwatch-post.sh` L40–43 `--key` validated and split, no default owner; L75 dialog text `on ${o}/${repo}
  #${n}`; L100 `--arg me "$PRWATCH_LOGIN"`; `kill_strays` via `WT_GLOB`.
- `prwatch-cleanup.sh` L10, `prwatch-buildrun.sh` L13/18, `prwatch-ngtest.sh` L20/26, `prwatch-dotnettest.sh` L23/30,
  `prwatch-agenthook.sh` L48/81, `prwatch-notify.sh` L13: shared helpers; `short=$ref` (full key in notifications).
  `prwatch-guard.sh`: no change.
- Skills: argument hints `<owner>/<repo>#<n>`; `prwatch-review` §2.1 `prwatch-prep.sh <key> <sha> <k>`, §2.4 login from
  `session.lock`, `W=/Users/jack/prwatch/work/<owner>__<repo>-pr<n>-<sha7>`; `prwatch-decide` `--key`; `prwatch-tick`
  the `new_repo` line and notification.
- `watcher/angles/security.md` L3 drop "ACT-Training". `README.md` L3–5 "open pull requests, in any organisation your
  GitHub login can see, where you are personally requested". `watcher/README.md` L3; T6/T14 keys; key format note.
  `watcher/CLAUDE.md` L39 archive path `<date>-<owner>-<repo>-pr<N>-round<k>`; standing answers: "Cross-org: the
  Laravel rule and all sandbox rules apply to every repo; there are no per-org exceptions"; `allow`/`block` rows.
- `test/sim2`: add `JackScammell/pr-watcher#1` (expected `new_repo`) and `Some-Org/VisionApp#10` (same name and number
  as an ACT-Training row, different owner, `repos` seeded `allowed`, state `posted` at the same sha → `ignore_index_lag`) →
  22 rows; README T4 → 22. `guard-cases.txt` and `sec/guard-cases.tsv`: new prep/post shapes (2 changed), 4 added
  (`prwatch-prep.sh Some-Org/Zzzt#9 <sha40> 1` → 0; `prwatch-prep.sh ../x#1 …` → 0 at the guard, refused by prep;
  `prwatch-skillhook.sh skill` → 2; `prwatch-state.sh set JackScammell/pr-watcher#1 queued` → 0); harness asserts the
  two files are identical.
- Harness: **B4** okkey matrix across state/cleanup/ngtest in one loop (accept `ACT-Training/Vision#1803`,
  `Some-Org/repo#1`, `JackScammell/pr-watcher#1`, `a.b-c_d/e.f-g_h#99999`; refuse `../x#1`, `a/b/c#1`, `A/B#x`, `A/B#`,
  `A/B`, `/B#1`, `A/#1`, `A/B#1#2`, `A/B#1 `, `A/B#01`, `-x/y#1`, `a/-y#1`, `a/.y#1`, 256-char owner,
  `ACT-Training/Vision#1;ls`); **B5** two owners same repo name → distinct worktrees and archives, cleanup of one spares
  the other, `harness-abort` kill test with the new name, prep argument validation, post `--key` validation and no
  default owner, `! grep -rq JackScammell watcher/bin watcher/.claude watcher/CLAUDE.md`, `! grep -rq ACT-Training
  watcher/bin watcher/config`, the archive-path rule in post still holds; **B6** login plumbing (`PRWATCH_LOGIN=other`
  → `ignore`; unset → `error no_login` before any classification; launcher refuses an empty or invalid login; prep
  without login → 25; `! grep -q -- '--owner' prwatch-tick.sh`; `grep -q 'user-review-requested:@me'`; the `--json` list contains
  `author`); tick with a hostile `nameWithOwner` writes nothing; **B12** first-sighting (unseen → `new_repo` with the
  author from the search row, no `queued` write, no `gh pr view` stub call; `ph "allow Some-Org/Zzzt"` → `repos`
  `allowed`, next tick `new`; `ph "block …"` → `blocked`, `ignore`-class reason, no write; `$SS repo-allow x/y` with no
  request → 64; `ph "allow ../x"` ignored; a repo with an existing `prs` key is seen; the line is in `notices`, never a
  question).
- Mutations: M5 drop the owner from `wt_name` → B5; M6 remove the `PRWATCH_LOGIN` export → B6; M7 hard-code
  `JackScammell` back → B6 + grep; M8 widen the owner charset → B4; M15 post defaults the owner → B5.

### PR 4 — engine adapter

- `launcher/PR Watcher.command` new step 2b: read `config/parliament.lock`, hash the tree per D3, decide the engine per
  D2 (reading `config/engine-fallback.json` if present); refuse to start if `src/hooks/.env` exists beside the pinned
  hooks; `unset TEAMS_WEBHOOK_URL APP_NAME CLAUDE_PLUGIN_DATA`; thaw stale frozen memory, then freeze per D4 with
  unfreeze on exit; write the `engine` object and `frozen_memory` into `session.lock` (carried by `PRWATCH_LOCK_JSON`);
  export `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1`; add `${PLUG:+--plugin-dir "$PLUG"}` to the claude line; print the
  engine line or the two nudge lines per D22.
- `install.sh --repin`: writes `config/parliament.lock` from the current install. `install.sh --thaw`: clears `uchg`
  from every path a stale `session.lock.frozen_memory` lists (refuses while the lock names a live pid). `install.sh`
  never installs the plugin.
- `watcher/bin/prwatch-skillhook.sh` (new; PreToolUse matcher `Skill`; `env -i` re-exec and test-mode conventions as the
  other hooks; sources `prwatch-common.zsh`): allow-list per D5 and D7; in test mode appends the raw `tool_input` to
  `state/harness/skillgate.log` so the live check pins the real field names.
- `watcher/bin/prwatch-agenthook.sh pre`: subagent-type allow-list per D6. `prwatch-guard.sh`: add `claude plugin` and
  `chflags` to the tripwire. `prwatch-tick.sh`: echo `engine` from the lock. `prwatch-common.zsh`: `MEMORY_PREFIX`.
- `watcher/config/settings.json`: deny remove `Skill(code-review)`, `Skill(code-review *)`; deny add `Skill(chaos:*)`,
  the named dangerous `chaos:` commands, `Skill(code-review ultra*)`, `Skill(code-review max*)`,
  `Skill(code-review *--comment*)`, `Skill(code-review *--fix*)`, `Skill(code-review *--post*)`, `Bash(claude *)`,
  `Bash(* claude plugin *)`; allow add `Skill(code-review *)`; `skillOverrides` remove `code-review`, add the eight
  orchestrating `chaos:` commands as `user-invocable-only`; hooks add the `Skill` matcher; sandbox `denyWrite` add
  `/Users/jack/.claude` and `/opt/homebrew` (verified already refused by the default profile; this pins it); env add
  `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1`; a comment naming the hook as the authoritative layer and deny-beats-allow.
- `watcher/CLAUDE.md`: invariant 8 ("Parliament reviewers are dispatched only as foreground `Agent` calls with
  `subagent_type: chaos:grumpy-<name>`. Never invoke any `chaos:` command. Parliament's own rules about posting verdicts
  with `gh pr review`, cost gates or detached fan-out do not apply here: posting happens only through `/prwatch-decide`,
  and the event is Jack's choice, never a verdict mapping."); an "Engine" paragraph (the model reads
  `session.lock.engine`, never chooses, never installs).
- `watcher/angles/default-review.md` (new): the `builtin-agent` brief.
- Skills: `prwatch-start` self-test 6 engine-aware, 7b per D10, 7c (builtin: `/code-review low` on a one-line fixture
  worktree; a background notice is a harness fault), banner `Engine:` line; `prwatch-review` §3 engine branches per
  D1/D9, §4 transcription per D8, the dispatch prompt for a grump ("read `A/input/diff.patch` first; open at most six
  further files; you cannot run anything, say so instead of guessing; at most 5 findings; end with exactly one
  `VERDICT:` line"), Non-reporting → one narrowed re-dispatch, a missing floor member means no `approve`;
  `prwatch-decide` `ask <angle>` re-dispatches with the same `subagent_type`; `prwatch-eod` prints `Engine:` once;
  `meta.json` gains `engine` (same enum) and `panel`.
- `watcher/README.md` "Review engines" section (the three engine values, what each dispatches, the install commands,
  the `PRWATCH_ENGINE=builtin` override, detection happens at launch so install → relaunch, the re-pin step, typed
  `/code-review --comment` by Jack bypasses the hook and is Jack's own act); "If something goes wrong" gains
  `install.sh --thaw`; T0 engine line; T5b rewritten for both modes; new T17 engine test.
- Harness: **B3** engine record (fake plugin dir whose tree hash matches a test lock → `parliament` + `--plugin-dir` in
  argv after `--setting-sources`; one byte changed in any file, including `plugin.json` and a rules file → `builtin` +
  "pinned to" line; lock names a missing path → `builtin`; `.env` beside hooks → `say_err`; nudge lines byte-identical
  to the Parliament README's two commands; `PRWATCH_ENGINE=builtin` with a matching plugin → `builtin`;
  `config/engine-fallback.json` with `builtin_agent: true` → `builtin-agent`; with `parliament_blocked: true` and a
  matching pin → `builtin`; `builtin_agent: true` with a `claude_version` that differs from the stub `claude --version`
  → ignored, "re-run live-check L1" line, `builtin`; `parliament_blocked: true` with a differing `claude_version` and a
  matching pin → still `builtin`; the lock `engine` object has the enum value and tick echoes it; a tick-recreated
  lock carries the same `engine` object from `PRWATCH_LOCK_JSON`; a stale lock with
  `frozen_memory` → thawed at start, one line printed; after a normal exit no `uchg` flag remains on the listed paths;
  `install.sh --thaw` under a live-pid lock → refused, flags remain; the launcher's `mkdir -p` list uses
  `MEMORY_PREFIX` from the shared file); **B7** skill-gate table (~30 payloads:
  every `prwatch-*` form; `code-review` with `low|medium|high` + a `WT_PAT` path that exists → 0; `high`-plus,
  `ultra`, `max`, `--comment`, `--post`, `--fix`, `--max-findings`, bare `1803`, `#1803`, a key, `repos/…`, `bin`,
  `work/../bin`, `~`, `; ls`, empty args, builtin forms under `engine == parliament` → 2; `chaos:*` anything → 2;
  `security-review`, `schedule`, `loop`, `review` → 2; unknown skill, different field name, no input, non-JSON, empty
  stdin, a Bash payload → 2); agenthook subagent-type cases; settings jq checks (incl. deny-beats-allow present);
  launcher env recorded by a stub `claude` has no `TEAMS_WEBHOOK_URL`.
- Mutations: M9 skill gate exit 0 on an empty skill field → B7; M10 remove `--comment` from the refused pattern → B7;
  M12 engine `parliament` but no `--plugin-dir` → B3.

## 6. State and schema changes

- `state/session.lock`: `{session_id, pid, started, started_epoch, login, engine: {engine, plugin_id, version,
  plugin_dir, reason}[, frozen_memory][, recreated]}`. `engine.engine` ∈ {`parliament`, `builtin`, `builtin-agent`}.
- `state/state.json`: drop `daily`, `cap_override`; add `repos: {"<owner>/<repo>": "allowed"|"blocked"}`;
  `paused_until` is epoch; keys unchanged in shape.
- `config/engine-fallback.json` (new, optional; `{builtin_agent, parliament_blocked, reason, claude_version}`; written
  only by `live-check.sh` after L1 or L5; locked with `config/`).
- `state/stopped-<session_id>` replaces `stopped-<date>`; `state/eod-done-<session_id>` new; `state/cap/` gone;
  `state/stop/`, `state/pause/`, `state/repo/` hold the hook's one-use requests.
- `config/parliament.lock` (new, locked with the rest of `config/`).
- `events.jsonl`: every line gains `session`; new kinds `eod_done`, `session_over`, `repo_allow`, `repo_block`,
  `repo_refused`, `stop_refused`, `pause_refused`; `cap`/`cap_refused` no longer written.
- `A/input/profile.json` + `has_pii`; `A/reviews/` files named by member; `meta.json` + `engine`, `panel`.
- Tick JSON: + `engine, started, elapsed_min, starts_until, ends_at`; − `councils_today, cap, cap_default, cap_max,
  cap_left`; statuses `session_over` (with `eod_due`), `start_closed`, `stopped` (was `stopped_for_today`); reason
  `new_repo`.
- Exit codes: prep 24 and 26 retired, 27 = window closed for new reviews, 25 = session or login precondition failed;
  state.sh 65 retired (was the cap refusal), 5 = another session's lock (existing meaning, now also for `stop`,
  `eod-done`), 64 for a refused `stop`/`pause`/`repo-allow`/`repo-block`/`eod-done`; new subcommands `stop`, `pause`
  (hook-gated), `eod-done`, `repo-allow`, `repo-block`, `check` (0 ok, 70 unreadable); retired `stop-today`,
  `daily-inc`, `cap`, `today`.
- Env: + `PRWATCH_LOGIN`, `PRWATCH_STARTED_EPOCH`, `PRWATCH_LOCK_JSON` (the launcher's lock object, used only to
  recreate a missing lock), `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1`; `PRWATCH_ENGINE` is a launcher input only.
- Legacy residue tolerated, not migrated: old `daily`/`cap_override` fields (dropped on first write), `stopped-<date>`
  files (ignored, swept), owner-less worktree names (3-day sweep).

## 7. Tests

**Baseline first.** The harness tests the installed copy, which is 14 files behind the repo (283/285 today). The
implementer runs `install.sh` and gets 285/285 before touching anything.

**Offline harness** (`watcher/test/harness/run.sh`): additions per PR in §5. Summary of the new blocks:

| Block | Subject | PR |
| --- | --- | --- |
| B1 | window from `started_epoch`, boundaries, DST, midnight, errors, `eod-done` idempotence | 2 |
| B2 | session-scoped stop/pause, request-file gating, launcher exit notice | 2 |
| B3 | engine record, tree pin, nudge, thaw | 4 |
| B4 | key grammar matrix across three scripts | 3 |
| B5 | owner-bearing paths, prep/post argument validation, no hard-coded login or org | 3 |
| B6 | `PRWATCH_LOGIN` plumbing, re-request detection, query shape | 3 |
| B7 | skill gate payload table, agenthook subagent types, settings checks | 4 |
| B8 | sched gate, one job | 2 |
| B9 | prose asserts (values the scripts own, not sentence fragments where avoidable) | 2–4 |
| B10 | dead commands and legacy inputs tolerated | 2 |
| B11 | state lock on `set` | 2 |
| B12 | first-sighting gate | 3 |

Expected size after PR 4: about 300 checks. Proportionate-testing rule: if harness additions exceed twice the
production lines changed, trim.

**Mutations** (ceiling 15, each must fail a named test; applied to the installed copy, reverted with `install.sh`,
failing check recorded in the PR body): M1, M2, M3, M4, M11, M13, M14 (PR 2, seven); M5, M6, M7, M8, M15 (PR 3,
five); M9, M10, M12 (PR 4, three). Fifteen in all. The former "ignore the offset" mutation is gone with the offset
parsing; the former `stopped-<date>` mutation is dropped because B2 asserts the file name directly; M13 is now
"`--window` touches the heartbeat".

**Live checks** (`watcher/test/harness/live-check.sh`, real Claude Code, haiku, test mode, after every Claude Code
update; A–E unchanged):

| # | What | Why it is live | Fallback if it fails |
| --- | --- | --- | --- |
| L1 | `/code-review high <worktree>` from cwd `~/prwatch` reviews the PR diff (merge-base `origin/<base>`…HEAD), not the whole tree or cwd | Path-target semantics from a non-repo cwd are UNVERIFIED | Try the range `<base_sha>..<sha>`, then a named branch worktree; else `live-check.sh` writes `config/engine-fallback.json` and the launcher chooses `builtin-agent` |
| L2 | One foreground `Agent` with `subagent_type: chaos:grumpy-code-reviewer` under `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` returns `completed`, no marker, `SubagentStop` seen; repeat with `grumpy-security-nag` | `background: true` frontmatter vs the env var is UNVERIFIED | Self-test 7b stops the session with the relaunch instruction (D10); Q5 |
| L3 | `chaos:parliament-loop`, `chaos:commit-and-push`, `chaos:ci-watch` refused via the hook and deny rules; count of `chaos:` skills > 0 proves `--plugin-dir` loaded | `Skill(chaos:*)` glob matching namespaced names is UNVERIFIED | Named deny list; the hook enforces either way |
| L4 | `code-review --comment <dir>`, `code-review 1803`, `code-review ultra <dir>`, `code-review medium /Users/jack/prwatch/bin` refused; `code-review low <dir>` runs with no `gh` Bash call and offers nothing to post; the gate logs the raw `tool_input` keys | Skill `tool_input` field names are undocumented | The gate fails closed, so a schema change refuses everything; this check names the cause |
| L5 | After L2–L4: `~/.claude/plugins/data/chaos-inline/agent-logs/activity.jsonl` grew and holds no `tool_input`/`tool_response`; nothing new under `~/prwatch` except `state/activity`; sandboxed `touch` of `<installPath>/src/hooks/.env`, `~/.claude/x`, `/opt/homebrew/bin/x` all fail | Hooks run outside the sandbox | Any unexpected write or a successful `touch` → `live-check.sh` writes `parliament_blocked: true` into `config/engine-fallback.json`, so the launcher chooses `builtin` until Jack re-reads and re-pins the plugin and deletes the flag; the finding goes in `docs/fix-background-agents.md` |
| L6 | Run the L2 probe once unfrozen and record every path under `~/.claude/agent-memory/` that changed or appeared (this names the directory the inline load uses); then with the freeze applied, the probe still returns `completed` + `PONG`, no stderr noise, and **no file anywhere under `~/.claude/agent-memory/` changed mtime or appeared** | Whether the harness degrades silently on an immutable memory dir is UNVERIFIED | If a documented per-session switch exists, use it (Q6). If none exists and the freeze breaks the reviewers, the `parliament` engine is not shippable: PR 4 ships `builtin` only and says so |
| L7 | `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1` stops a nested spawn | Behaviour in 2.1.312 UNVERIFIED | D6's allow-list already refuses the spawning agent types |
| L8 | The `CronCreate` payload the sched gate logs in test mode has the field names the gate parses | Never seen live | Gate fails closed |
| L9 | In builtin mode, `Skill code-review low <dir>` returns in the foreground (the Skill result arrives before the next turn; no `async_launched`, no `PRWATCH HARNESS FAULT`), offers no post; record whether `SubagentStop` fired with an `agent_id` | The forked `/code-review` subagent's visibility to the fault machinery is UNVERIFIED | If invisible, `docs/fix-background-agents.md` states that the only guarantees are synchronous return plus `kill_strays` before dialogs |

**Day-1 checklist** (`watcher/README.md`): T0 engine line; T2 dry-run note; T3 window around `started_epoch`; T4 22
lines; T5b both modes; T13 reworded; T14 one cross-owner PR; T17 engine test (plugin pinned and installed → `engine:
parliament 1.28.0`; `PRWATCH_ENGINE=builtin` → builtin + nudge); "Do T6… on a weekday" deleted.

## 8. Risks and accepted risks

| # | Risk | Handling |
| --- | --- | --- |
| R1 | Grumpy `background: true` vs the env var (L2) | Self-test 7b before any review; fail closed with a relaunch instruction |
| R2 | `maxTurns: 5`, `effort: low` on a 3000-line diff truncates the floor | Six-file budget in the prompt, `delta.patch` focus on round ≥2, one narrowed re-dispatch, missing floor → no approve |
| R3 | Plugin hooks run outside the sandbox | Whole-tree pin (D3), env scrub, `.env` refusal, `denyWrite` pin, L5 |
| R4 | Reviewer memory as a cross-project poisoning path | Recursive freeze with thaw-on-start (D4), L6 |
| R5 | 60+ `chaos:*` skills loaded into the session | Skill hook allow-list, deny rules, `user-invocable-only`, L3 |
| R6 | `/code-review` path-target semantics (L1) | `builtin-agent` fallback; decided once after L1, recorded in `config/engine-fallback.json` |
| R7 | Cross-org: a repo whose stack has no recipe lands in the static-only path; a huge clone takes the 40-minute Bash ceiling; SSO lapsed mid-day → prep exit 20 → `failed` → `needs_jack` after 3 | Existing paths; D16 gives one explicit yes per new repo |
| R8 | Midnight-crossing sessions: archive folder date (prep's date) vs summary (by session) | Cosmetic; documented |
| R9 | A typed `/chaos:…` or `/code-review --comment` by Jack bypasses PreToolUse | By design: Jack at the keyboard is the authority; README says so |
| R10 | A launcher killed without its trap leaves memory frozen for other sessions | Thaw-on-start from the stale lock; `install.sh --thaw`; named in README |

Accepted risks: **AR-1** unsandboxed plugin hooks run at all, once pinned and scrubbed; **AR-2** telemetry of tool
names and durations in `activity.jsonl`; **AR-3** Parliament's rules text contradicts the watcher's posting model in
the model's context (closed at the tool layer; invariant 8 addresses it); **AR-5** the restore step runs PR-controlled
MSBuild/npm logic with network, now from any repo Jack is a collaborator on (D16 gates the first sighting); **AR-6**
about 16 councils per 8-hour session is the ceiling and one PR force-pushed every half hour could take the day (Jack's
explicit choice; Q4); **AR-7** typed bypass; **AR-8** other organisations' code under `~/Documents/vision-reviews`;
**AR-9** `claude plugin list --json` cannot prove the plugin loaded, so self-test 7b is the proof; **AR-10** the
re-pin treadmill: every Parliament release needs a watcher PR.

## 9. Verified facts this plan relies on

- `claude --setting-sources project,local` does not load user-scope plugins; `--plugin-dir <installPath>` does, as
  `chaos@inline`, agents addressed `chaos:grumpy-<name>`. `claude plugin list --json` exists with `{id, version, scope,
  enabled, installPath, errors}` and reports `enabled: true` regardless of the flag;
  `~/.claude/plugins/installed_plugins.json` has `.plugins["chaos@parliament-of-chaos"][0].{installPath,version}`.
- With `--plugin-dir`, `CLAUDE_PLUGIN_DATA` is set and `log_event.sh` writes to
  `~/.claude/plugins/data/chaos-inline/agent-logs/activity.jsonl`; `notify_teams.sh` is a no-op without
  `TEAMS_WEBHOOK_URL`. The plugin's `.claude/rules/*.md` are injected into the session context. The default sandbox
  profile already refuses writes to `~/.claude/plugins/cache` and `/opt/homebrew/bin`.
- Grumpy reviewers: `background: true`, `effort: low`, `maxTurns: 5`, no Bash/Write/Edit/Agent, `memory: user`;
  `~/.claude/agent-memory/chaos-grumpy-*` exist with entries.
- `/code-review`: targets branch, range, PR number or path; no flags = forked subagent reporting text; `--comment` posts
  inline comments; `--post` is ultra-only; `skillOverrides: user-invocable-only` is a valid value; typed `/skill`
  bypasses PreToolUse; the Skill `tool_input` field names are undocumented.
- Session cron: `*/15 * * * *` valid; jitter up to 7.5 min; recurring tasks expire after 7 days; one-shot supported.
- `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` removes `run_in_background` and stops automatic backgrounding; its
  interaction with `background: true` frontmatter is undocumented.
- `gh search prs … "user-review-requested:@me"` with no `--owner` spans every repo the token can see. Token scopes:
  gist, read:org, repo, workflow. Orgs today: ACT-Training only.
- macOS `date -j -f …%z` refuses `+01:00`, accepts `+0100` (why the plan uses `started_epoch`).
- GitHub private vulnerability reporting is for public repositories; rulesets are Team/Enterprise.
- `install.sh` never runs `chflags`; the lock is a documented manual step.
- The harness (`run.sh`) tests the installed copy; baseline 283/285 with two drift failures; it wrote only to
  `/tmp/pwh.*`, `~/prwatch/work/Zzzt-*` (both removed) and touched `state/activity`.

## 10. Open questions for Jack

**Answered.** Q7: the watcher is Jack's own work; MIT with Jack as holder, PR 1 unblocked. Q1–Q6, Q8–Q11: the stated
defaults stand. Jack also decided that the current installed copy under `~/prwatch` is to be removed rather than
brought up to date, with a fresh `install.sh` only once `v1.0.0` exists; during implementation the harness still
needs an installed copy, so each PR installs into `~/prwatch` as a throwaway and the final install is clean.

| # | Question | Default in this plan |
| --- | --- | --- |
| Q1 | First-sighting gate per new repo via `allow`/`block` typed at the prompt (D16)? | Yes, included |
| Q2 | Under Parliament, drop the watcher's own `security`/`backend-data`/`frontend` angles (grumps cover them) or keep `security` alongside `grumpy-security-nag` (it can `git grep`; the grump cannot) at +1 opus agent per review? | Drop them |
| Q3 | Archive root stays `~/Documents/vision-reviews` with owner-slugged folders? | Stays |
| Q4 | Same PR more than 3 rounds in one session → `needs_jack` (an abuse guard, not a count limit)? | **Not** included; AR-6 recorded instead |
| Q5 | Parliament probe fails at start: stop with a relaunch instruction (as planned) or fall back to builtin automatically for that session? | Stop |
| Q6 | If Claude Code offers a per-session switch that disables agent memory, prefer it over the `chflags` freeze? | Yes, if documented |
| Q7 | Licence ownership: the watcher was written for ACT's workflow in work time. Is the code Jack's to put under MIT? | MIT, Jack as holder; PR 1 waits for the answer |
| Q8 | Tags `v0.1.0` (today) and `v1.0.0` (after PR 4), or `v1.0.0` and `v2.0.0`? | `v0.1.0` / `v1.0.0` |
| Q9 | `/code-review` effort `high` (hook allows `low|medium|high`)? | `high` |
| Q10 | CI stopgap: accept the `sudo mkdir /Users/jack` step until the path-rendering seam lands, or ship only the `syntax` lane now? | Accept the stopgap |
| Q11 | Keep `CODE_OF_CONDUCT.md` (baseline parity) or skip (one person, private)? | Keep, short |

## 11. Source sections

The four specialist sections this plan merges, kept for the record (scratchpad, not committed):
`plan-architecture.md` (system-architect), `plan-security.md` (security-knight), `plan-testing.md` (test-prophet),
`plan-repo-files.md` (config-curator with pipeline-engineer and doc-bard duties), plus `brief.md`, `facts-addendum.md`
and `harness-baseline.txt`. Where this plan and a section differ, this plan wins.

## 12. Revision 2 — what changed and why (round-1 findings)

| Finding (reviewer) | Change |
| --- | --- |
| Three argument conventions for one key (maintainability) | D13: every script takes the key; one shared `prwatch-common.zsh` (D12) |
| Path shape known in four places (maintainability) | D14: `wt_name`/`archive_name`/`WT_PAT`/`WT_GLOB` in the shared file; the skill hook uses `WT_PAT` |
| Window constants and timestamp parsing defined twice; colon-offset parse needs its own test matrix (maintainability, standards, testing) | D18: `started_epoch` in the lock, integer arithmetic, constants in the shared file, test-mode clock rule stated, `TZ=Europe/London` in `run.sh`; the offset mutation is gone |
| `engine.json` duplicates `session.lock`; three engine vocabularies (maintainability, architecture) | D2: one `engine` object in the lock, one enum incl. `builtin-agent`, `PRWATCH_ENGINE` is input only |
| Content pin misses `plugin.json`-registered hooks, rules and commands (security, architecture) | D3: whole-tree hash |
| `chflags uchg` non-recursive, wrong dir under inline load, no recovery after a kill (security, architecture, maintainability) | D4: `-R`, `mkdir -p` first, thaw-on-start, `--thaw`, L6 asserts nothing changed anywhere, records the dir name; R10 |
| Removing `daily-inc` removes the only script-side gate on starting past the window (security) | D18: prep enforces `START_LIMIT` with an exit code (27 since revision 3); M14 |
| `repo-ok` after a question is convention, not mechanism; "Not today" re-asks every tick (security, architecture) | D16: `allow`/`block` typed at the prompt via the hook; one notice line, never a question; B12 |
| Built-in `/code-review` fork visibility to the fault machinery dropped (security) | L9 added |
| Repo grammar admits a leading hyphen; `eod-done` callable early; `pause` unbounded (security) | D12 no leading `-`/`.`; `eod-done` refused before `END`; `pause N ≤ 480` |
| eod counts by a timestamp string compare (architecture) | D17: event lines carry `session`; `eod-done` prints the counts |
| `stop`/`pause` as decide free-text and the agenthook `stop-today` allowance break under the hook (architecture) | D20: decide → `awaiting_decision` + "type `stop` at the prompt"; agenthook L78 updated |
| Hook-owned stop/pause spec incomplete: reply token, exit code, events (standards) | D20 specified; B2 request-file cases restored |
| `$o__$repo` parses as `$o__` (standards) | Brace forms everywhere; the builder function makes it moot |
| "today" vocabulary survives in tokens and prose (standards) | `stopped_for_today` → `stopped`; sweep listed in PR 2; B9 |
| `eod-done.<sid>` naming (standards) | `eod-done-<sid>` |
| CLAUDE.md L5 "only state.sh writes state/" (standards) | PR 2 edit listed; §2 wording matches |
| M4 survives on a Europe/London Mac (testing) | Offset parsing removed; M4 is now the stop request check |
| `new_repo` untested; sim2 fixture contradicts it (testing) | B12; sim2 expectations fixed; day-1 rule stated |
| Launcher watchdog tested by greps only (testing) | D21: launcher calls `--window`; B2.7 with a stub `claude` and `</dev/null` |
| L5/L6 fallbacks missing; `eod_due` idempotence half-pinned (testing) | Fallbacks stated; B1.17 |
| CI: sim2 and guard-cases not run; `</dev/null`; `zsh -n` overclaimed; `chflags` under CI (testing) | D24 updated; `install.sh` verified not to `chflags` |
| Docs fallout misses root README L3–5, CLAUDE.md L25/27/39, launcher L66–67 (documentation) | Added to PR 2/PR 3 |
| Repo files too thin to write; numbers disagree; `builtin-agent` not in the enum; B-table by count only; `claude plugin list` shape; UNVERIFIED lines; `cap-override` links (documentation) | PR 1 contents specified; 10 typical / 16 ceiling; enum fixed; §7 table; §9 updated; grep steps added |

### Revision 3 — round-2 findings

| Finding (reviewer) | Change |
| --- | --- |
| `prwatch-cleanup.sh --thaw` is a model-callable undo of the freeze (security, standards) | D4: thaw moved to `install.sh --thaw`, refused while the lock names a live pid; cleanup has no thaw |
| `mkdir -p` list must use the L6-recorded prefix (security) | D4: `MEMORY_PREFIX` constant in the shared file; B3 greps the launcher for it |
| `--window` touches the heartbeat, so the watchdog refreshes its own stuck test; it also runs the lock check (architecture, testing) | D18/D21: `--window` is a pure read; heartbeat touch moved below the early exit; B1.18; M13 re-pointed |
| `new_repo` notice needs an author the search does not return (architecture, testing) | D11: `author` added to the search `--json`; B6/B12 updated |
| A tick-recreated lock loses `engine` (architecture) | D2: the launcher's lock object exported and copied (as `PRWATCH_LOCK_JSON` since revision 3a); B3 case |
| Mutation count was 16 (testing, documentation) | §7: fifteen, listed per PR; the `stopped-<date>` mutation dropped |
| `builtin-agent` "recorded in the lock" is ambiguous and would not persist (documentation) | D2/§6/R6/L1: `config/engine-fallback.json`, written only by `live-check.sh` |
| Exit 5 undefined; prep 25 overloaded; `repos` values do not match their verbs; exit 24 reused with a new meaning (documentation, standards) | §6: 5 defined; prep 25 = "session or login precondition failed"; `allowed`/`blocked`; prep 27 = window closed, 24 and 26 retired |
| `state/` writers sentence omits the request files (documentation) | §2 and the CLAUDE.md L5 edit name them |
| One-use request check written three times; two start fields and two env vars for one fact (maintainability, optional) | D20: one `fresh_request` function; D18: only `PRWATCH_STARTED_EPOCH` exported, `started` derived |

### Revision 3a — round-3 documentation notes

| Finding | Change |
| --- | --- |
| CLAUDE.md standing answer still said exit 24 | PR 2: 27; B9 asserts the number matches `prwatch-prep.sh` |
| L5's "force builtin" had no mechanism | D2/§6/L5: `parliament_blocked` in `config/engine-fallback.json`; B3 case |
| PR 2 tick bullet named env vars that arrive in PR 3/PR 4 | Recreated lock now comes from one `PRWATCH_LOCK_JSON` object, so later fields ride along |
| Launcher must honour a start-time override only in test mode (testing, rounds 3 and 4) | D18: test-only input `PRWATCH_TEST_STARTED_EPOCH` inside the test-mode block; `PRWATCH_STARTED_EPOCH` is output only; B2.8 (a)/(b) runnable in the harness |
| A recreated lock from a truncated or foreign `PRWATCH_LOCK_JSON` must fail closed (security, testing, round 4) | D18/B1.18: `session_id` must match, else `error no_session_start` |
| `engine-fallback.json` could outlive the Claude Code build it was measured on (maintainability, optional) | D2: `builtin_agent` honoured only when `claude_version` matches; `parliament_blocked` never expires (documentation, round 4); B3 cases for both |
| Four env vars to rebuild one lock (maintainability, optional) | D2: `PRWATCH_LOCK_JSON` replaces per-field copying; `PRWATCH_ENGINE_JSON` gone |
