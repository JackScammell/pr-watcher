#!/bin/zsh
# prwatch-prompthook.sh prompt|cron  — hook, never called by the model. The only way to change today's council cap.
#   prompt (UserPromptSubmit): a prompt that is exactly "cap N" (trimmed, any case) is Jack's: write state/cap/request.json
#          {session,n} and run prwatch-state.sh cap N, which refuses without that fresh request. Reply to the model with
#          one "PRWATCH CAP:" line. Any other prompt: nothing printed or written. Always exit 0 (never blocks a prompt).
#   cron (PreToolUse CronCreate): a cron prompt would reach UserPromptSubmit like Jack's typing → only /prwatch-start's
#          two jobs may be scheduled; anything else exit 2.
[[ -z "${PRWATCH_CLEAN:-}" ]] && exec /usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin LANG=en_GB.UTF-8 PRWATCH_CLEAN=1 \
  ${${(f)"$(/usr/bin/env | /usr/bin/grep '^PRWATCH_')"}:#} /bin/zsh "$0" "$@"
emulate -L zsh; set -u; setopt extendedglob
PRW=$HOME/prwatch; S=$PRW/state
[[ -n ${PRWATCH_TESTMODE:-} ]] && S=${PRWATCH_STATE_DIR:-$PRW/test/state}
p=$(cat) || p=""
j() { print -r -- "$p" | /usr/bin/jq -r "$1" 2>/dev/null; }

case ${1:-} in
  prompt)
    t=$(j '.prompt // ""'); t=${${t##[[:space:]]#}%%[[:space:]]#}
    [[ $t == (#i)cap\ ##[0-9](#c1,3) ]] || exit 0          # the whole prompt; the range (1-12) is checked by state.sh
    n=${t##* }
    mkdir -p $S/cap
    /usr/bin/jq -n --arg s "${PRWATCH_SESSION_ID:-}" --arg n $n '{session:$s,n:$n}' > $S/cap/request.json
    out=$($PRW/bin/prwatch-state.sh cap $n 2>&1); rc=$?
    rm -f $S/cap/request.json                               # single use, whatever happened
    if (( rc == 0 )); then
      print -r -- "PRWATCH CAP: $(/usr/bin/jq -r '"up to \(.cap) reviews may start today (normally \(.cap_default)); \(.used) started so far. Any queued PRs start at the next check."' <<<$out)"
    else
      print -r -- "PRWATCH CAP: not changed (${${out//[^A-Za-z0-9 ().,-]/}[1,80]}). Type cap and a number from 1 to 12 on its own."
    fi
    exit 0 ;;
  cron)
    c=$(j '"\(.tool_input.cron // "")|\(.tool_input.prompt // "")|\(.tool_input.recurring | if . == null then true else . end)"')
    [[ $c == "*/15 8-15 * * 1-5|/prwatch-tick|true" || $c == "3 16 * * 1-5|/prwatch-eod|true" ]] && exit 0
    print -u2 "prwatch: only /prwatch-start's two jobs may be scheduled: /prwatch-tick at */15 8-15 * * 1-5 and /prwatch-eod at 3 16 * * 1-5 (recurring)."
    exit 2 ;;
esac
exit 0
