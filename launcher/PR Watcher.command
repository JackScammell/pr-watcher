#!/bin/zsh -l
# PR Watcher launcher — double-click to start a watcher session (8 hours from now).
set -u
PRW="$HOME/prwatch"
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
source "$PRW/bin/prwatch-common.zsh"                           # window constants, login grammar, engine helpers (GRUMPS, tree_sha256, mem_thaw)
SE=$(date +%s); CLAUDE_BIN=""                                  # session start, in epoch seconds: the only clock the window uses
CONF="$PRW/config"; MEMROOT="$HOME/.claude/agent-memory"; PINS="$HOME/.claude/plugins/installed_plugins.json"; SNAPROOT="$PRW/plugin-snap"; RSYNC=/usr/bin/rsync
if [[ -n "${PRWATCH_TESTMODE:-}" ]]; then                      # test harness only
  [[ -n "${PRWATCH_STUB_BIN:-}" ]] && { PATH="$PRWATCH_STUB_BIN:$PATH"; [[ -x "$PRWATCH_STUB_BIN/claude" ]] && CLAUDE_BIN="$PRWATCH_STUB_BIN/claude"; }
  [[ -n "${PRWATCH_TEST_STARTED_EPOCH:-}" ]] && SE=$PRWATCH_TEST_STARTED_EPOCH   # the only place this name appears
  CONF="${PRWATCH_TEST_CONF:-$CONF}"; MEMROOT="${PRWATCH_TEST_MEMROOT:-$MEMROOT}"; PINS="${PRWATCH_TEST_PINS:-$PINS}"   # the harness points these at fixtures
  SNAPROOT="${PRWATCH_TEST_SNAPROOT:-$SNAPROOT}"; RSYNC="${PRWATCH_TEST_RSYNC:-$RSYNC}"   # RSYNC: a stub that alters the copy (B3)
fi
print -n "\e]0;PR watcher\a"                                   # window title (claude may overwrite it)
SD="$PRW/state"; [[ -n "${PRWATCH_TESTMODE:-}" ]] && SD="${PRWATCH_STATE_DIR:-$PRW/test/state}"
mkdir -p "$PRW/state" "$SD"                                    # state/activity always lives in $PRW/state (hooks touch it)
say_err() { "$PRW/bin/prwatch-notify.sh" error launcher; print -r -- "$1"; print -n "Press any key to close."; read -k1; exit 1; }
[[ "$SE" == <-> ]] || say_err "Bad session start time."

# 1. Find claude >= 2.1. /usr/local/bin/claude on this Mac is an OLD 1.0.x npm install — never prefer it.
min_ok() { local v; v=$("$1" --version 2>/dev/null) || return 1; v=${v%% *}
  local -a p; p=(${(s:.:)v}); (( p[1] > 2 || (p[1] == 2 && p[2] >= 1) )) }
if [[ -z "$CLAUDE_BIN" ]]; then
  for c in "$HOME/Library/Application Support/Herd/config/nvm/versions/node/"*/bin/claude(N-nOn) \
           "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" "${commands[claude]:-}" /usr/local/bin/claude; do
    [[ -n "$c" && -x "$c" ]] && min_ok "$c" && { CLAUDE_BIN="$c"; break; }
  done
fi
[[ -n "$CLAUDE_BIN" ]] || say_err "Could not find Claude Code 2.1 or newer."
export PATH="${CLAUDE_BIN:h}:/usr/local/share/dotnet:$HOME/.dotnet/tools:$PATH"   # node for claude and ng; dotnet for builds
print -r -- "claude: $CLAUDE_BIN ($("$CLAUDE_BIN" --version))"

# 2. GitHub login, using the REAL gh config (the session gets an empty one). The login is the only identity the
#    scripts use (PRWATCH_LOGIN): the inbox is every repo it can see, so the org list is information only.
GH_CONFIG_DIR="$HOME/.config/gh" gh auth status >/dev/null 2>&1 || say_err "GitHub CLI not logged in — run: gh auth login, then double-click again."
LOGIN=$(GH_CONFIG_DIR="$HOME/.config/gh" gh api user --jq .login 2>/dev/null)
oklogin "$LOGIN" || say_err "GitHub did not return a usable login — check gh auth."
export PRWATCH_LOGIN="$LOGIN"
orgs=$(GH_CONFIG_DIR="$HOME/.config/gh" gh api user/orgs --jq '.[].login' 2>/dev/null | paste -sd' ' -)
print -r -- "Signed in as $LOGIN. Organisations your login can see: ${orgs:-none}"

# 2b. Review engine (plan D1–D3, D22): decided here, once, and written into the lock; the model only reads it.
#     parliament  the pinned Parliament of Chaos tree (config/parliament.lock) is installed byte for byte → --plugin-dir
#     builtin     otherwise, or PRWATCH_ENGINE=builtin, or config/engine-fallback.json says parliament_blocked
#     builtin-agent  instead of builtin when engine-fallback.json says builtin_agent for THIS Claude Code version
#                    (never when PRWATCH_ENGINE=builtin forces builtin)
#     engine-fallback.json is written only by live-check.sh (L1, L5/L6); a file that cannot be read loads no plugin.
#     The rules are decide_engine's, in prwatch-common.zsh; this block only acts on its result.
unset TEAMS_WEBHOOK_URL APP_NAME CLAUDE_PLUGIN_DATA           # the plugin's hooks run outside the sandbox: give them nothing
CV=$("$CLAUDE_BIN" --version 2>/dev/null); CV=${CV%% *}
EIN="${PRWATCH_ENGINE:-}"; unset PRWATCH_ENGINE                # an input to this decision only
[[ -z "$EIN" || "$EIN" == builtin ]] || say_err "PRWATCH_ENGINE can only be builtin. Unset PRWATCH_ENGINE or set it to builtin, then relaunch."
decide_engine "$EIN" "$CONF/engine-fallback.json" "$CONF/parliament.lock" "$PINS" "$CV"
(( $? == 2 )) && say_err "Parliament has a src/hooks/.env file beside its hooks, so the watcher will not load it. Remove the file, re-read the plugin, then run: ~/Documents/GitHub/pr-watcher/install.sh --repin"
(( ${#NOTES} )) && print -rl -- $NOTES
# 2c. Parliament runs from a snapshot the watcher owns (plugin-snap/parliament-<sha>), locked (chflags -R uchg) for
#     the session and hashed AFTER locking, so the files checked are the files Claude Code reads for 8 hours; the
#     install folder can change under it without effect. plugin-snap/ is outside every sandbox's writable area (Bash
#     sandbox denyWrite + Edit/Write deny; the PR-test sandboxes write only the build copy and cache/), because the
#     plugin's hooks run unsandboxed. Its .in_use/ (Claude Code's own per-process files) stays writable.
SNAP=""
snap_lock()   { /usr/bin/chflags -R uchg "$1" && /usr/bin/chflags -R nouchg "$1/.in_use"; }
snap_unlock() { /usr/bin/chflags -R nouchg "$1" 2>/dev/null; }
if [[ $ENGINE == parliament ]]; then
  SNAP="$SNAPROOT/parliament-$(/usr/bin/jq -r .tree_sha256 "$CONF/parliament.lock")"
  if [[ -L "$SNAPROOT" || -L "$SNAP" ]]; then                  # never rm, copy or chflags through a planted link
    ENGINE=builtin PLUG="" PVER="" REASON="the snapshot folder is a symlink"; SNAP=""
    print "$SNAPROOT or the snapshot in it is a symlink, so Parliament is not loaded. Remove the link, then relaunch."
  else
    if [[ -d "$SNAP" ]] && pin_matches "$CONF/parliament.lock" "$SNAP"; then snap_lock "$SNAP"   # reuse
    else snap_unlock "$SNAP"; rm -rf "$SNAP"; mkdir -p "$SNAPROOT" \
           && "$RSYNC" -a --exclude '/.in_use' --exclude '/.git' "$PLUG/" "$SNAP/" && mkdir -p "$SNAP/.in_use" && snap_lock "$SNAP"; fi
    if [[ -d "$SNAP" ]] && pin_matches "$CONF/parliament.lock" "$SNAP"; then PLUG="$SNAP"
    else snap_unlock "$SNAP"; ENGINE=builtin PLUG="" PVER="" REASON="Parliament's files differ from the pin"; SNAP=""
      print "Parliament's files changed while the watcher was copying them, so it is not loaded. Relaunch to try again."; fi
  fi
fi
EJ=$(engine_json)
FROZEN=(); [[ $ENGINE == parliament ]] && for g in $GRUMPS; do FROZEN+=("$MEMROOT/${MEMORY_PREFIX}-grumpy-$g"); done   # D4: frozen after the lock names them

# 3. Single-instance lock (test mode: the lock lives where the scripts look for it). started_epoch is the session clock:
#    every script measures the window from it; PRWATCH_STARTED_EPOCH / PRWATCH_LOCK_JSON are outputs only, never read back.
export PRWATCH_SESSION_ID="$(uuidgen)" PRWATCH_PID=$$
LOCK="$SD/session.lock"
if [[ -f "$LOCK" ]]; then
  oldpid=$(/usr/bin/jq -r .pid "$LOCK" 2>/dev/null)
  if watcher_pid_live "$oldpid"; then
    print "Another watcher window is running (pid $oldpid). Replace it? [Y/n]"; read -k1 a; print
    [[ "$a" == [nN] ]] && exit 0                                # (a live window thaws its own folders, and its snapshot, when it exits)
  else                                                          # stale lock: its window died without its exit trap (R10)
    c=$(mem_thaw "$MEMROOT" ${(f)"$(lock_frozen "$LOCK")"})
    (( c > 0 )) && print "Unfroze $c reviewer memory folder(s) left frozen by an earlier watcher window."
  fi
fi
/usr/bin/jq -n --arg t "$PRWATCH_SESSION_ID" --argjson p $$ --arg s "$(date -r "$SE" -Iseconds)" --argjson e "$SE" --arg l "$LOGIN" \
   --argjson eng "$EJ" --args '{session_id:$t,pid:$p,started:$s,started_epoch:$e,login:$l,engine:$eng}
   + (if ($ARGS.positional | length) > 0 then {frozen_memory:$ARGS.positional} else {} end)' "${FROZEN[@]}" \
   > "$LOCK.tmp" && mv "$LOCK.tmp" "$LOCK" || say_err "Could not write the lock file."
export PRWATCH_STARTED_EPOCH=$SE PRWATCH_LOCK_JSON="$(/usr/bin/jq -c . "$LOCK")"
# 3b. Reviewer memory (D4): Parliament's grumpy reviewers keep user-scope memory that Jack's other sessions read, so it
#     is frozen (chflags -R uchg, the folder and every file in it) for this session and thawed when this window exits.
#     A folder a newer window has listed in its own lock is left to that window, and so is the snapshot it runs from.
thaw_mine() { local keep=() p mine=0
  [[ "$(/usr/bin/jq -r .session_id "$LOCK" 2>/dev/null)" == "$PRWATCH_SESSION_ID" ]] && mine=1
  (( mine )) || keep=(${(f)"$(lock_frozen "$LOCK")"})
  for p in $FROZEN; do (( ${keep[(Ie)$p]} )) || mem_thaw "$MEMROOT" "$p" >/dev/null; done; FROZEN=()
  [[ -n $SNAP ]] && { (( mine )) || [[ "$(/usr/bin/jq -r '.engine.plugin_dir // ""' "$LOCK" 2>/dev/null)" != "$SNAP" ]]; } && snap_unlock "$SNAP"; SNAP=""; }
trap thaw_mine EXIT; trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
for d in $FROZEN; do memdir_ok "$MEMROOT" "$d" && mkdir -p "$d" && /usr/bin/chflags -R uchg "$d" || say_err "Could not freeze reviewer memory ($d)."; done

# 4. Keep the Mac from idle-sleeping while Claude runs (closing the lid still sleeps).
caffeinate -i -w $$ & CAF=$!

# 5. Watchdog, independent of the Claude session (heartbeat = $PRW/state/activity, touched by hooks and scripts).
#    The window comes from prwatch-tick.sh --window (a pure read: it never touches the heartbeat it is judged by).
touch "$PRW/state/activity"
(
  trap 'kill $SL 2>/dev/null; exit 0' TERM
  last=$(date +%s)
  while kill -0 $$ 2>/dev/null; do
    sleep 300 & SL=$!; wait $SL; now=$(date +%s)
    (( now - last > 600 )) && touch "$PRW/state/activity"      # we were asleep: restart the clock
    last=$now
    [[ -f "$SD/stopped-$PRWATCH_SESSION_ID" ]] && continue      # Jack typed "stop"
    elapsed=$(( now - SE )); (( elapsed >= WATCHDOG_ARM )) || continue
    w=$("$PRW/bin/prwatch-tick.sh" --window 2>/dev/null); wst=$(/usr/bin/jq -r '.status // ""' <<<"$w" 2>/dev/null)
    case "$wst" in
      in_window|start_closed) ;;
      session_over)                                             # after END only while a review/question is live, up to END+WATCHDOG_EXTEND
        (( elapsed < END + WATCHDOG_EXTEND )) || continue
        /usr/bin/jq -e '[.prs[]?|select(.status=="reviewing" or .status=="asking")]|length>0' "$SD/state.json" >/dev/null 2>&1 || continue ;;
      *) continue ;;                                            # error or unknown: nothing to judge
    esac
    age=$(( now - $(stat -f %m "$PRW/state/activity") ))
    (( age > 1800 )) && "$PRW/bin/prwatch-notify.sh" stuck watchdog   # throttled to 1 per 30 min inside notify
  done
) & WD=$!

print "Runs for 8 hours from now (new reviews for the first 7½); type 'stop' to finish early."
print "While a review runs (up to ~45 min) this window is busy; what you type waits. Esc stops that review (it resumes at the next check)."
print "Type 'stop' to finish the session, 'pause 60' to skip checks for an hour, 'd' to be asked about waiting drafts now."
print "At permission prompts choose 'Yes' — never 'Yes, and don't ask again'."
typeset -A GLOSS; GLOSS=(parliament "Parliament of Chaos reviewers" builtin "Claude Code's /code-review" builtin-agent "one general reviewer")
print -r -- "Engine: $ENGINE${PVER:+ $PVER} (${GLOSS[$ENGINE]}). Why: $REASON."
if [[ $ENGINE == parliament ]]; then print "Reviewer notes are read-only until this window closes (other Claude sessions can't save to them either)."
else
  if [[ -z "$EIN" && -z "$FOUND" ]]; then                      # D22: a nudge, never an install
    print "For the Parliament of Chaos reviewers, read the plugin's SECURITY.md first (https://github.com/JackScammell/Parliament-Of-Chaos/blob/main/SECURITY.md), then install it yourself (the watcher never does) and relaunch:"
    print "claude plugin marketplace add https://github.com/JackScammell/Parliament-Of-Chaos.git"
    print "claude plugin install chaos@chaos"
  fi
fi

cd "$PRW" || say_err "Missing $PRW"
PLUGARGS=(); [[ -n "$PLUG" ]] && PLUGARGS=(--plugin-dir "$PLUG")   # user plugins never load (--setting-sources): this is the only way in
if [[ $ENGINE == builtin ]]; then                # self-test 7c's worktree: two commits, a one-line change (a WT_PAT name)
  STW="$PRW/work/prwatch__selftest-pr1-0000000"; rm -rf "$STW"
  ( mkdir -p "$STW" && cd "$STW" && G=(/usr/bin/git -c user.name=prwatch -c user.email=prwatch@localhost -c init.defaultBranch=main -c commit.gpgsign=false)
    $G init -q && print 'a = 1' > f.py && $G add f.py && $G commit -qm base && $G checkout -qb pr && print 'a = 2' > f.py && $G commit -qam 'One-line change' ) >/dev/null 2>&1 \
    || print "Could not create the self-test worktree; self-test 7c will say PROBLEM."
fi
export GH_CONFIG_DIR="$PRW/gh-empty"          # the session's own gh is logged out
export CLAUDE_AFK_TIMEOUT_MS=600000           # unanswered questions continue after 10 min (never a decision)
export BASH_DEFAULT_TIMEOUT_MS=600000         # 10 min for ordinary Bash calls
export BASH_MAX_TIMEOUT_MS=2400000            # 40 min ceiling for prep / post / buildrun
export CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 # reviewers must run in the foreground (2.1.284 made background the default)
export CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1  # a reviewer can never start reviewers of its own (D6); also in settings.json's env,
                                              # which reaches the session's subagents: this export covers the launch itself
export PATH="$PRW/shims:$PATH"                # mktemp shim: sandboxed scripts get a $TMPDIR template (docs/fix-sandbox-tests.md)
"$CLAUDE_BIN" \
  --settings "$PRW/config/settings.json" \
  --setting-sources project,local \
  "${PLUGARGS[@]}" \
  --strict-mcp-config --no-chrome \
  --add-dir "$HOME/Documents/vision-reviews" \
  --autocompact 300k \
  -n "PR watcher $(date +%F)" \
  "/prwatch-start"
rc=$?
kill $WD $CAF 2>/dev/null                    # no watchdog / caffeinate once Claude has exited
print "Watcher stopped at $(date +%H:%M) (exit $rc)."
# Early exit notice: only if the session was still running (not over, not stopped by Jack).
w=$("$PRW/bin/prwatch-tick.sh" --window 2>/dev/null); wst=$(/usr/bin/jq -r '.status // ""' <<<"$w" 2>/dev/null)
[[ "$wst" != session_over && ! -f "$SD/stopped-$PRWATCH_SESSION_ID" && "$(/usr/bin/jq -r .session_id "$LOCK" 2>/dev/null)" == "$PRWATCH_SESSION_ID" ]] \
  && "$PRW/bin/prwatch-notify.sh" error session-ended     # not when a newer window has taken the lock over
# Only remove the lock if it is still ours (a newer window may have taken over); thaw first, while the lock says whose.
thaw_mine
[[ "$(/usr/bin/jq -r .session_id "$LOCK" 2>/dev/null)" == "$PRWATCH_SESSION_ID" ]] && rm -f "$LOCK"
print -n "Press any key to close this window."; read -k1
