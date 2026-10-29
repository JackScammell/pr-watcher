#!/bin/zsh
# prwatch-prompthook.sh prompt|sched  — hook, never called by the model. The only way to stop or pause the session, or
# to allow or block a repo.
#   prompt (UserPromptSubmit): a prompt that is exactly "stop", "pause N", "allow <owner>/<repo>" or "block
#          <owner>/<repo>" (trimmed, any case) is Jack's: write state/stop|pause|repo/request.json {session,n} and run
#          prwatch-state.sh stop / pause N / repo-allow|repo-block <owner/repo>, which refuse without that fresh
#          request. Reply to the model with one "PRWATCH STOP:" / "PRWATCH PAUSE:" / "PRWATCH REPO:" line. Any other
#          prompt: nothing printed or written. Always exit 0 (never blocks a prompt).
#   sched (PreToolUse, any tool named like Cron/Schedule/Wakeup/Trigger): a scheduled prompt could reach UserPromptSubmit
#          like Jack's typing → only /prwatch-start's one CronCreate job, CronList and CronDelete; anything else exit 2.
[[ -z "${PRWATCH_CLEAN:-}" ]] && exec /usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin LANG=en_GB.UTF-8 ${TZ:+TZ=$TZ} PRWATCH_CLEAN=1 \
  ${${(f)"$(/usr/bin/env | /usr/bin/grep '^PRWATCH_')"}:#} /bin/zsh "$0" "$@"
emulate -L zsh; set -u; setopt extendedglob
PRW=$HOME/prwatch; source $PRW/bin/prwatch-common.zsh
S=$PRW/state
[[ -n ${PRWATCH_TESTMODE:-} ]] && S=${PRWATCH_STATE_DIR:-$PRW/test/state}
p=$(cat) || p=""                                   # not "|| exit 0" as in agenthook: sched must fail closed
j() { print -r -- "$p" | /usr/bin/jq -r "$1" 2>/dev/null; }
trim() { print -r -- ${${1##[[:space:]]#}%%[[:space:]]#}; }          # strip leading and trailing whitespace
plain() { print -r -- ${${1//[^A-Za-z0-9 ().,-]/}[1,80]}; }          # safe for the model's context: no markup, 80 chars

case ${1:-} in
  prompt)
    t=$(trim "$(j '.prompt // ""')")
    if   [[ $t == (#i)stop ]]; then kind=stop; n=stop; cmd=(stop); TAG="PRWATCH STOP"; bad="not done"
    elif [[ $t == (#i)pause\ ##[0-9](#c1,3) ]]; then kind=pause; n=${t##* }; cmd=(pause $n); TAG="PRWATCH PAUSE"; bad="not changed"   # the range is checked by state.sh
    elif [[ $t == (#i)(allow|block)\ [^[:space:]]## ]] && okrepo "${t#* }"; then     # "allow ../x", "allow a/b#1": not ours
         kind=repo; verb=${(L)t%% *}; r=${t#* }; n="$verb $r"; cmd=(repo-$verb $r); TAG="PRWATCH REPO"; bad="not changed"
    else exit 0; fi                                     # "stop please", "pause x", "pause 9999", "cap 8": not ours
    [[ "$(/usr/bin/jq -r .session_id $S/session.lock 2>/dev/null)" == "${PRWATCH_SESSION_ID:-x}" ]] \
      || { print "$TAG: $bad (this window is not the current watcher)."; exit 0; }
    mkdir -p $S/$kind
    /usr/bin/jq -n --arg s $PRWATCH_SESSION_ID --arg n "$n" '{session:$s,n:$n}' > $S/$kind/request.json
    out=$($PRW/bin/prwatch-state.sh $cmd 2>/dev/null); rc=$?    # stdout only: result, or the refusal reason
    rm -f $S/$kind/request.json                         # single use, whatever happened
    if (( rc != 0 )); then print -r -- "$TAG: $bad ($(plain "$out"))."
    elif [[ $kind == stop ]]; then print -r -- "$TAG: the watcher is stopped for this session - no more checks or reviews."
    elif [[ $kind == repo ]]; then
         [[ $verb == allow ]] && print -r -- "$TAG: $r allowed - its pull requests will be picked up at the next check." \
                              || print -r -- "$TAG: $r blocked - its pull requests are ignored."
    else u=$(/usr/bin/jq -r '.until // ""' <<<$out 2>/dev/null); [[ $u == [0-9][0-9]:[0-9][0-9] ]] || u="?"
         print -r -- "$TAG: checks skipped for $n minutes (until $u)."; fi
    exit 0 ;;
  sched)                                                    # subshell: any error in it means "deny", never exit 1
    ( tool=$(j '.tool_name // ""')
      [[ $tool == (CronList|CronDelete) ]] && exit 0
      [[ $tool == CronCreate ]] || exit 1
      # recurring: true when absent, must be a real boolean; any field beyond cron/prompt/recurring is refused
      c=$(j '"\(.tool_input.cron // "")|\(.tool_input.prompt // "")|\(.tool_input.recurring | if . == null then true elif type == "boolean" then . else "bad" end)|\(.tool_input | keys - ["cron","prompt","recurring"] | length)"')
      [[ $c == "*/15 * * * *|/prwatch-tick|true|0" ]] ) && exit 0
    print -u2 "prwatch: nothing may be scheduled except /prwatch-start's one job: CronCreate /prwatch-tick at */15 * * * * (recurring)."
    exit 2 ;;
esac
exit 0
