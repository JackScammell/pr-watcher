#!/bin/zsh -l
# PR Watcher launcher — double-click to start a watcher session (8 hours from now).
set -u
PRW="$HOME/prwatch"
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
source "$PRW/bin/prwatch-common.zsh"                           # window constants, login grammar, engine helpers (GRUMPS, tree_sha256, mem_thaw)
SE=$(date +%s); CLAUDE_BIN=""                                  # session start, in epoch seconds: the only clock the window uses
CONF="$PRW/config"; MEMROOT="$HOME/.claude/agent-memory"; PINS="$HOME/.claude/plugins/installed_plugins.json"
if [[ -n "${PRWATCH_TESTMODE:-}" ]]; then                      # test harness only
  [[ -n "${PRWATCH_STUB_BIN:-}" ]] && { PATH="$PRWATCH_STUB_BIN:$PATH"; [[ -x "$PRWATCH_STUB_BIN/claude" ]] && CLAUDE_BIN="$PRWATCH_STUB_BIN/claude"; }
  [[ -n "${PRWATCH_TEST_STARTED_EPOCH:-}" ]] && SE=$PRWATCH_TEST_STARTED_EPOCH   # the only place this name appears
  CONF="${PRWATCH_TEST_CONF:-$CONF}"; MEMROOT="${PRWATCH_TEST_MEMROOT:-$MEMROOT}"; PINS="${PRWATCH_TEST_PINS:-$PINS}"   # the harness points all three at fixtures
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
#     engine-fallback.json is written only by live-check.sh (L1, L5); a file that cannot be read loads no plugin.
unset TEAMS_WEBHOOK_URL APP_NAME CLAUDE_PLUGIN_DATA           # the plugin's hooks run outside the sandbox: give them nothing
CV=$("$CLAUDE_BIN" --version 2>/dev/null); CV=${CV%% *}
EIN="${PRWATCH_ENGINE:-}"; unset PRWATCH_ENGINE                # an input to this decision only
[[ -z "$EIN" || "$EIN" == builtin ]] || say_err "PRWATCH_ENGINE can only be builtin."
ENGINE=builtin; PLUG=""; PVER=""; REASON=""; FB="$CONF/engine-fallback.json"; PL="$CONF/parliament.lock"
fbv() { /usr/bin/jq -r "$1" "$FB" 2>/dev/null; }
blocked=0; [[ -f "$FB" ]] && { [[ "$(fbv 'type')" == object ]] || { blocked=1; print "config/engine-fallback.json is unreadable: Parliament is not loaded."; }
  [[ "$(fbv '.parliament_blocked')" == true ]] && blocked=1; }
found=$(/usr/bin/jq -r '[.plugins // {} | to_entries[] | select(.key | startswith("chaos@")) | .value[0].version][0] // ""' "$PINS" 2>/dev/null)
if [[ -n "$EIN" ]]; then REASON="PRWATCH_ENGINE=builtin"
elif (( blocked )); then REASON="parliament blocked by live-check"
  print -r -- "Parliament was blocked by live-check under Claude Code $(fbv '.claude_version // "?"'); you are on $CV: run live-check.sh to clear it."
elif [[ ! -f "$PL" ]]; then REASON="no Parliament pin"
  [[ -n "$found" ]] && print -r -- "Parliament $found is installed but not pinned; read it, then run install.sh --repin."
else
  pp=$(/usr/bin/jq -r '.installPath // ""' "$PL" 2>/dev/null); pv=$(/usr/bin/jq -r '.version // ""' "$PL" 2>/dev/null); psha=$(/usr/bin/jq -r '.tree_sha256 // ""' "$PL" 2>/dev/null)
  if [[ -z "$pp" || ! -d "$pp" ]]; then REASON="the pinned Parliament folder is missing"
  else
    [[ -e "$pp/src/hooks/.env" ]] && say_err "Parliament has a src/hooks/.env file beside its hooks, so the watcher will not load it. Remove the file, re-read the plugin, then run install.sh --repin."
    if [[ -n "$psha" && "$(tree_sha256 "$pp")" == "$psha" ]]; then ENGINE=parliament; PLUG="$pp"; PVER="$pv"; REASON="pinned tree matches"
    else REASON="Parliament differs from the pin"
      print -r -- "Parliament ${found:-(changed)} is installed but the watcher is pinned to $pv; read the diff, then run install.sh --repin."; fi
  fi
fi
if [[ $ENGINE != parliament && "$(fbv '.builtin_agent')" == true ]]; then
  if [[ "$(fbv '.claude_version')" == "$CV" ]]; then ENGINE=builtin-agent; REASON="$REASON; /code-review cannot review a worktree (live-check L1)"
  else print -r -- "engine-fallback.json is for $(fbv '.claude_version'), you are on $CV: re-run live-check L1."; fi
fi
EJ=$(/usr/bin/jq -nc --arg e $ENGINE --arg v "$PVER" --arg d "$PLUG" --arg r "$REASON" \
  '{engine:$e, plugin_id:(if $e == "parliament" then "chaos@inline" else null end), version:(if $v == "" then null else $v end), plugin_dir:(if $d == "" then null else $d end), reason:$r}')
FROZEN=(); [[ $ENGINE == parliament ]] && for g in $GRUMPS; do FROZEN+=("$MEMROOT/${MEMORY_PREFIX}-grumpy-$g"); done   # D4: frozen after the lock names them

# 3. Single-instance lock (test mode: the lock lives where the scripts look for it). started_epoch is the session clock:
#    every script measures the window from it; PRWATCH_STARTED_EPOCH / PRWATCH_LOCK_JSON are outputs only, never read back.
export PRWATCH_SESSION_ID="$(uuidgen)" PRWATCH_PID=$$
LOCK="$SD/session.lock"
if [[ -f "$LOCK" ]]; then
  oldpid=$(/usr/bin/jq -r .pid "$LOCK" 2>/dev/null)
  if [[ "$oldpid" == <-> ]] && kill -0 "$oldpid" 2>/dev/null && [[ "$(ps -p "$oldpid" -o command=)" == *"PR Watcher.command"* ]]; then
    print "Another watcher window is running (pid $oldpid). Replace it? [Y/n]"; read -k1 a; print
    [[ "$a" == [nN] ]] && exit 0                                # (a live window thaws its own folders when it exits)
  else                                                          # stale lock: its window died without its exit trap (R10)
    c=$(mem_thaw "$MEMROOT" ${(f)"$(/usr/bin/jq -r '.frozen_memory[]? // empty' "$LOCK" 2>/dev/null)"})
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
#     A folder a newer window has listed in its own lock is left to that window.
thaw_mine() { (( ${#FROZEN} )) || return 0; local keep=() p
  [[ "$(/usr/bin/jq -r .session_id "$LOCK" 2>/dev/null)" == "$PRWATCH_SESSION_ID" ]] || keep=(${(f)"$(/usr/bin/jq -r '.frozen_memory[]? // empty' "$LOCK" 2>/dev/null)"})
  for p in $FROZEN; do (( ${keep[(Ie)$p]} )) || mem_thaw "$MEMROOT" "$p" >/dev/null; done; FROZEN=(); }
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
if [[ $ENGINE == parliament ]]; then print -r -- "Engine: parliament $PVER (Parliament of Chaos reviewers; their memory is frozen for this session)."
else print -r -- "Engine: $ENGINE ($REASON)."
  if [[ -z "$EIN" && -z "$found" ]]; then                      # D22: a nudge, never an install
    print "For the Parliament of Chaos reviewers, read the plugin's SECURITY.md first, then install it yourself (the watcher never does) and relaunch:"
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
export CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1  # a reviewer can never start reviewers of its own (D6)
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
