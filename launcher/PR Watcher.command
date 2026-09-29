#!/bin/zsh -l
# PR Watcher launcher — double-click to start today's watcher.
set -u
PRW="$HOME/prwatch"
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
[[ -n "${PRWATCH_TESTMODE:-}" && -n "${PRWATCH_STUB_BIN:-}" ]] && PATH="$PRWATCH_STUB_BIN:$PATH"   # test harness only
print -n "\e]0;PR watcher\a"                                   # window title (claude may overwrite it)
SD="$PRW/state"; [[ -n "${PRWATCH_TESTMODE:-}" ]] && SD="${PRWATCH_STATE_DIR:-$PRW/test/state}"
mkdir -p "$PRW/state" "$SD"                                    # state/activity always lives in $PRW/state (hooks touch it)
say_err() { "$PRW/bin/prwatch-notify.sh" error launcher; print -r -- "$1"; print -n "Press any key to close."; read -k1; exit 1; }

# 1. Find claude >= 2.1. /usr/local/bin/claude on this Mac is an OLD 1.0.x npm install — never prefer it.
min_ok() { local v; v=$("$1" --version 2>/dev/null) || return 1; v=${v%% *}
  local -a p; p=(${(s:.:)v}); (( p[1] > 2 || (p[1] == 2 && p[2] >= 1) )) }
CLAUDE_BIN=""
for c in "$HOME/Library/Application Support/Herd/config/nvm/versions/node/"*/bin/claude(N-nOn) \
         "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" "${commands[claude]:-}" /usr/local/bin/claude; do
  [[ -n "$c" && -x "$c" ]] && min_ok "$c" && { CLAUDE_BIN="$c"; break; }
done
[[ -n "$CLAUDE_BIN" ]] || say_err "Could not find Claude Code 2.1 or newer."
export PATH="${CLAUDE_BIN:h}:/usr/local/share/dotnet:$HOME/.dotnet/tools:$PATH"   # node for claude and ng; dotnet for builds
print -r -- "claude: $CLAUDE_BIN ($("$CLAUDE_BIN" --version))"

# 2. GitHub login + org access, using the REAL gh config (the session gets an empty one).
GH_CONFIG_DIR="$HOME/.config/gh" gh auth status >/dev/null 2>&1 || say_err "GitHub CLI not logged in — run: gh auth login, then double-click again."
GH_CONFIG_DIR="$HOME/.config/gh" gh api orgs/ACT-Training --silent 2>/dev/null || say_err "GitHub can't see ACT-Training (SSO authorisation?) — check gh auth."

# 3. Single-instance lock (test mode: the lock lives where the scripts look for it).
export PRWATCH_SESSION_ID="$(uuidgen)" PRWATCH_PID=$$
LOCK="$SD/session.lock"
if [[ -f "$LOCK" ]]; then
  oldpid=$(/usr/bin/jq -r .pid "$LOCK" 2>/dev/null)
  if [[ "$oldpid" == <-> ]] && kill -0 "$oldpid" 2>/dev/null && [[ "$(ps -p "$oldpid" -o command=)" == *"PR Watcher.command"* ]]; then
    print "Another watcher window is running (pid $oldpid). Replace it? [Y/n]"; read -k1 a; print
    [[ "$a" == [nN] ]] && exit 0
  fi
fi
/usr/bin/jq -n --arg t "$PRWATCH_SESSION_ID" --argjson p $$ --arg s "$(date -Iseconds)" \
   '{session_id:$t,pid:$p,started:$s}' > "$LOCK.tmp" && mv "$LOCK.tmp" "$LOCK" || say_err "Could not write the lock file."

# 4. Keep the Mac from idle-sleeping while Claude runs (closing the lid still sleeps).
caffeinate -i -w $$ & CAF=$!

# 5. Watchdog, independent of the Claude session (heartbeat = $PRW/state/activity, touched by hooks and scripts).
touch "$PRW/state/activity"
(
  trap 'kill $SL 2>/dev/null; exit 0' TERM
  last=$(date +%s)
  while kill -0 $$ 2>/dev/null; do
    sleep 300 & SL=$!; wait $SL; now=$(date +%s)
    (( now - last > 600 )) && touch "$PRW/state/activity"      # we were asleep: restart the clock
    last=$now
    hm=$(date +%H%M); dow=$(date +%u)
    (( dow <= 5 && 10#$hm >= 815 )) || continue
    [[ -f "$SD/stopped-$(date +%F)" ]] && continue               # Jack typed "stop"
    if (( 10#$hm >= 1600 )); then                               # after 16:00 only while a review/question is live
      (( 10#$hm < 1740 )) || continue
      /usr/bin/jq -e '[.prs[]?|select(.status=="reviewing" or .status=="asking")]|length>0' "$SD/state.json" >/dev/null 2>&1 || continue
    fi
    age=$(( now - $(stat -f %m "$PRW/state/activity") ))
    (( age > 1800 )) && "$PRW/bin/prwatch-notify.sh" stuck watchdog   # throttled to 1 per 30 min inside notify
  done
) & WD=$!

(( $(date +%u) >= 6 )) && print "Note: it's the weekend — the watcher only checks Monday to Friday."
print "While a review runs (up to ~45 min) this window is busy; what you type waits. Esc stops that review (it resumes at the next check)."
print "Type 'stop' to finish for the day, 'pause 60' to skip checks for an hour, 'd' to be asked about waiting drafts now."
print "At permission prompts choose 'Yes' — never 'Yes, and don't ask again'."

cd "$PRW" || say_err "Missing $PRW"
export GH_CONFIG_DIR="$PRW/gh-empty"          # the session's own gh is logged out
export CLAUDE_AFK_TIMEOUT_MS=600000           # unanswered questions continue after 10 min (never a decision)
export BASH_DEFAULT_TIMEOUT_MS=600000         # 10 min for ordinary Bash calls
export BASH_MAX_TIMEOUT_MS=2400000            # 40 min ceiling for prep / post / buildrun
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
hm=$(date +%H%M)
(( $(date +%u) <= 5 && 10#$hm < 1600 )) && [[ ! -f "$SD/stopped-$(date +%F)" ]] && "$PRW/bin/prwatch-notify.sh" error session-ended
# Only remove the lock if it is still ours (a newer window may have taken over).
[[ "$(/usr/bin/jq -r .session_id "$LOCK" 2>/dev/null)" == "$PRWATCH_SESSION_ID" ]] && rm -f "$LOCK"
print -n "Press any key to close this window."; read -k1
