#!/bin/zsh
# prwatch-prompthook.sh prompt|sched  — hook, never called by the model. The only way to change today's council cap.
#   prompt (UserPromptSubmit): a prompt that is exactly "cap N" (trimmed, any case) is Jack's: write state/cap/request.json
#          {session,n} and run prwatch-state.sh cap N, which refuses without that fresh request. Reply to the model with
#          one "PRWATCH CAP:" line. Any other prompt: nothing printed or written. Always exit 0 (never blocks a prompt).
#   sched (PreToolUse, any tool named like Cron/Schedule/Wakeup/Trigger): a scheduled prompt could reach UserPromptSubmit
#          like Jack's typing → only /prwatch-start's two CronCreate jobs, CronList and CronDelete; anything else exit 2.
[[ -z "${PRWATCH_CLEAN:-}" ]] && exec /usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin LANG=en_GB.UTF-8 PRWATCH_CLEAN=1 \
  ${${(f)"$(/usr/bin/env | /usr/bin/grep '^PRWATCH_')"}:#} /bin/zsh "$0" "$@"
emulate -L zsh; set -u; setopt extendedglob
PRW=$HOME/prwatch; S=$PRW/state
[[ -n ${PRWATCH_TESTMODE:-} ]] && S=${PRWATCH_STATE_DIR:-$PRW/test/state}
p=$(cat) || p=""
j() { print -r -- "$p" | /usr/bin/jq -r "$1" 2>/dev/null; }
trim() { print -r -- ${${1##[[:space:]]#}%%[[:space:]]#}; }          # strip leading and trailing whitespace
plain() { print -r -- ${${1//[^A-Za-z0-9 ().,-]/}[1,80]}; }          # safe for the model's context: no markup, 80 chars

case ${1:-} in
  prompt)
    t=$(trim "$(j '.prompt // ""')")
    [[ $t == (#i)cap\ ##[0-9](#c1,3) ]] || exit 0          # the whole prompt; the range is checked by state.sh
    n=${t##* }
    [[ "$(/usr/bin/jq -r .session_id $S/session.lock 2>/dev/null)" == "${PRWATCH_SESSION_ID:-x}" ]] \
      || { print "PRWATCH CAP: not changed (this window is not the current watcher)."; exit 0; }
    mkdir -p $S/cap
    /usr/bin/jq -n --arg s $PRWATCH_SESSION_ID --arg n $n '{session:$s,n:$n}' > $S/cap/request.json
    out=$($PRW/bin/prwatch-state.sh cap $n 2>/dev/null); rc=$?    # stdout only: today's JSON, or the refusal reason
    rm -f $S/cap/request.json                               # single use, whatever happened
    if (( rc == 0 )); then
      msg=$(/usr/bin/jq -r '"up to \(.cap) reviews may start today (normally \(.cap_default)); \(.used) started so far"' <<<$out 2>/dev/null)
      print -r -- "PRWATCH CAP: ${msg:-up to $n reviews may start today}. Any queued PRs start at the next check."
    else
      print -r -- "PRWATCH CAP: not changed ($(plain "$out"))."
    fi
    exit 0 ;;
  sched)
    tool=$(j '.tool_name // ""')
    [[ $tool == (CronList|CronDelete) ]] && exit 0
    if [[ $tool == CronCreate ]]; then                      # recurring defaults to true when absent
      c=$(j '"\(.tool_input.cron // "")|\(.tool_input.prompt // "")|\(.tool_input.recurring | if . == null then true else . end)"')
      [[ $c == "*/15 8-15 * * 1-5|/prwatch-tick|true" || $c == "3 16 * * 1-5|/prwatch-eod|true" ]] && exit 0
    fi
    print -u2 "prwatch: nothing may be scheduled except /prwatch-start's two jobs: CronCreate /prwatch-tick at */15 8-15 * * 1-5 and /prwatch-eod at 3 16 * * 1-5 (recurring)."
    exit 2 ;;
esac
exit 0
