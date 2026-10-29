#!/bin/zsh -l
# PR Watcher launcher — double-click to start a watcher session (8 hours from now).
set -u
PRW="$HOME/prwatch"
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
source "$PRW/bin/prwatch-common.zsh"                           # window constants (START_LIMIT, END, WATCHDOG_*)
SE=$(date +%s); CLAUDE_BIN=""                                  # session start, in epoch seconds: the only clock the window uses
if [[ -n "${PRWATCH_TESTMODE:-}" ]]; then                      # test harness only
  [[ -n "${PRWATCH_STUB_BIN:-}" ]] && { PATH="$PRWATCH_STUB_BIN:$PATH"; [[ -x "$PRWATCH_STUB_BIN/claude" ]] && CLAUDE_BIN="$PRWATCH_STUB_BIN/claude"; }
  [[ -n "${PRWATCH_TEST_STARTED_EPOCH:-}" ]] && SE=$PRWATCH_TEST_STARTED_EPOCH   # the only place this name appears
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

# 3. Single-instance lock (test mode: the lock lives where the scripts look for it). started_epoch is the session clock:
#    every script measures the window from it; PRWATCH_STARTED_EPOCH / PRWATCH_LOCK_JSON are outputs only, never read back.
export PRWATCH_SESSION_ID="$(uuidgen)" PRWATCH_PID=$$
LOCK="$SD/session.lock"
if [[ -f "$LOCK" ]]; then
  oldpid=$(/usr/bin/jq -r .pid "$LOCK" 2>/dev/null)
  if [[ "$oldpid" == <-> ]] && kill -0 "$oldpid" 2>/dev/null && [[ "$(ps -p "$oldpid" -o command=)" == *"PR Watcher.command"* ]]; then
    print "Another watcher window is running (pid $oldpid). Replace it? [Y/n]"; read -k1 a; print
    [[ "$a" == [nN] ]] && exit 0
  fi
fi
/usr/bin/jq -n --arg t "$PRWATCH_SESSION_ID" --argjson p $$ --arg s "$(date -r "$SE" -Iseconds)" --argjson e "$SE" --arg l "$LOGIN" \
   '{session_id:$t,pid:$p,started:$s,started_epoch:$e,login:$l}' > "$LOCK.tmp" && mv "$LOCK.tmp" "$LOCK" || say_err "Could not write the lock file."
export PRWATCH_STARTED_EPOCH=$SE PRWATCH_LOCK_JSON="$(/usr/bin/jq -c . "$LOCK")"

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

cd "$PRW" || say_err "Missing $PRW"
export GH_CONFIG_DIR="$PRW/gh-empty"          # the session's own gh is logged out
export CLAUDE_AFK_TIMEOUT_MS=600000           # unanswered questions continue after 10 min (never a decision)
export BASH_DEFAULT_TIMEOUT_MS=600000         # 10 min for ordinary Bash calls
export BASH_MAX_TIMEOUT_MS=2400000            # 40 min ceiling for prep / post / buildrun
export CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 # reviewers must run in the foreground (2.1.284 made background the default)
export PATH="$PRW/shims:$PATH"                # mktemp shim: sandboxed scripts get a $TMPDIR template (docs/fix-sandbox-tests.md)
"$CLAUDE_BIN" \
  --settings "$PRW/config/settings.json" \
  --setting-sources project,local \
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
# Only remove the lock if it is still ours (a newer window may have taken over).
[[ "$(/usr/bin/jq -r .session_id "$LOCK" 2>/dev/null)" == "$PRWATCH_SESSION_ID" ]] && rm -f "$LOCK"
print -n "Press any key to close this window."; read -k1
