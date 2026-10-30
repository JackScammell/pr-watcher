#!/bin/zsh
# prwatch-agenthook.sh post|pre|ended  — hook, never called by the model. Backstop for subagents launched in the background
# (Claude Code 2.1.284 made that the default; CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 is the real fix).
#   post (PostToolUse Agent|TaskStop): an Agent result that is not status "completed" is a harness fault
#        (async_launched/isAsync, or any unknown status): marker state/harness/<agentId>.marker {session,key,agent,t},
#        stop file, notify "error harness" (throttled 30 min), exit 2 so the model is told. No status at all → notify
#        "error hookdrift" only (fails open; the env var and self-test 7 still stand). Successful TaskStop of a marked
#        agent → <agentId>.stopped; other TaskStop wording → hookdrift, marker stays live.
#   ended (SubagentStop): a marked agent finished on its own (TaskStop would now be refused before any hook runs)
#        → <agentId>.stopped. Unmarked → <agentId>.ended note, in case the fault marker is written after it (race).
#        Always exits 0: exit 2 on SubagentStop would keep the subagent running.
#   pre  (PreToolUse *): Agent calls (tool Agent or Task, or any call naming a subagent_type) first pass the subagent-type
#        allow-list (plan D6). pre fails closed: settings.json runs it as "… pre || exit 2", since Claude Code blocks
#        only on exit 2. Then, while this session has an unarchived fault (see live()), deny every tool except TaskStop/TaskList, Read/Glob/Grep,
#        CronList/CronDelete, ToolSearch (to load a deferred TaskStop) and canonical `prwatch-state.sh harness-abort|get` — nothing may prompt or start
#        while PR code runs. Follow-up is `prwatch-state.sh harness-abort <key>` (needs every marker .stopped).
# The model cannot write state/ (sandbox denyWrite + permission deny), so markers are not forgeable by PR text.
# cleanup --sweep archives markers/notes older than a day; a new session id ignores older sessions' markers.
[[ -z "${PRWATCH_CLEAN:-}" ]] && exec /usr/bin/env -i HOME="$HOME" ${TZ:+TZ=$TZ} PATH=/usr/bin:/bin LANG=en_GB.UTF-8 PRWATCH_CLEAN=1 \
  ${${(f)"$(/usr/bin/env | /usr/bin/grep '^PRWATCH_')"}:#} /bin/zsh "$0" "$@"
emulate -L zsh; set -u; setopt extendedglob nullglob
PRW=$HOME/prwatch; source $PRW/bin/prwatch-common.zsh 2>/dev/null || { [[ ${1:-} == pre ]] && exit 2; exit 0; }
S=$PRW/state
[[ -n ${PRWATCH_TESTMODE:-} ]] && S=${PRWATCH_STATE_DIR:-$PRW/test/state}
NL=$'\n'; H=$S/harness; SID=${PRWATCH_SESSION_ID:-}       # SID: this session's id (the skill hook reads PRWATCH_SESSION_ID directly)
p=$(cat) || { [[ ${1:-} == pre ]] && exit 2; exit 0; }
log() { mkdir -p $H; print -r -- "$(date -Iseconds) $*" >> $H/hook.log; }
j() { print -r -- "$p" | /usr/bin/jq -r "$1" 2>/dev/null; }
tool=$(j '.tool_name // ""')
# gated while this session has an unarchived fault: live markers, and stopped ones until harness-abort has killed the
# PR's leftover processes and archived them (a finished subagent may have left background shells). Probe markers
# (key none) gate only while live: nothing runs harness-abort for them.
live() { local m; for m in $H/*.marker $H/*.stopped; do
  [[ "$(/usr/bin/jq -r '"\(.session) \(.key)"' $m 2>/dev/null)" == $SID\ * ]] || continue
  [[ $m == *.marker || "$(/usr/bin/jq -r .key $m 2>/dev/null)" != none ]] && return 0; done; return 1; }

case ${1:-} in
  post)
    case $tool in
      Agent)
        st=$(j '.tool_response.status // ""'); as=$(j '.tool_response.isAsync // ""')
        aid=$(j '.tool_response.agentId // ""'); [[ $aid == [A-Za-z0-9_-](#c1,64) ]] || aid=""
        if [[ $st == completed && $as != true ]]; then [[ -n $aid ]] && rm -f $H/$aid.ended   # normal foreground result
        elif [[ -z $st && -z $as ]]; then
          log "drift: Agent tool_response has neither status nor isAsync"; $PRW/bin/prwatch-notify.sh error hookdrift
        elif [[ $st != completed || $as == true ]]; then   # async_launched, or a status name we have never seen
          [[ $st == async_launched || $as == true ]] || log "unknown Agent status '${st[1,40]}' treated as a fault"
          id=$(j '.tool_response.agentId // ""'); [[ $id == [A-Za-z0-9_-](#c1,64) ]] || id=unknown-$(date +%s)
          # one PR at a time (CLAUDE.md invariant 7), so this session owns at most one reviewing item
          key=$(/usr/bin/jq -r --arg s "$SID" '[.prs|to_entries[]|select(.value.status=="reviewing" and .value.owner==$s)|.key][0] // "none"' $S/state.json 2>/dev/null)
          [[ $key == ${~KEY_PAT} ]] || key=none
          mkdir -p $H; ext=marker; [[ -f $H/$id.ended ]] && { ext=stopped; rm -f $H/$id.ended; }   # it already finished
          /usr/bin/jq -n --arg s "$SID" --arg k "$key" --arg a "$id" --arg t "$(date -Iseconds)" \
            '{session:$s,key:$k,agent:$a,t:$t}' > $H/$id.$ext
          touch $S/stopped-$SID; log "fault agent=$id key=$key"
          if [[ $key == none ]]; then next="report PROBLEM (this is the start-up probe). "
          else next="run exactly this command, unquoted, on its own:${NL}$PRW/bin/prwatch-state.sh harness-abort $key${NL}"; fi
          $PRW/bin/prwatch-notify.sh error harness
          print -u2 "PRWATCH HARNESS FAULT: that subagent was launched in the background. Call TaskStop on it (and on every other subagent from the same dispatch) now; if TaskStop says it is not running, it has already finished — that counts as stopped. Do not ask Jack anything or start anything else until they are all stopped. Then ${next}The watcher is stopped for this session."
          exit 2
        fi ;;
      TaskStop)
        id=$(j '.tool_response.task_id // .tool_input.task_id // ""'); msg=$(j '.tool_response.message // ""')
        if [[ $id == [A-Za-z0-9_-](#c1,64) && -f $H/$id.marker ]]; then
          if [[ $msg == Successfully\ stopped* ]]; then mv $H/$id.marker $H/$id.stopped; log "stopped agent=$id"
          else log "drift: TaskStop of marked $id said: ${msg[1,120]}"; $PRW/bin/prwatch-notify.sh error hookdrift; fi
        fi ;;
    esac
    exit 0 ;;
  ended)
    id=$(j '.agent_id // ""')
    if [[ $id != [A-Za-z0-9_-](#c1,64) ]]; then
      [[ -z $id && "$(j '.hook_event_name // ""')" == SubagentStop ]] && { log "drift: SubagentStop without agent_id"; $PRW/bin/prwatch-notify.sh error hookdrift; }
      exit 0; fi
    if [[ -f $H/$id.marker ]]; then mv $H/$id.marker $H/$id.stopped; log "ended agent=$id (finished on its own)"
    elif [[ ! -f $H/$id.stopped ]]; then mkdir -p $H; : > $H/$id.ended; fi   # foreground agents: removed by post
    exit 0 ;;
  pre)
    if [[ $tool == (Agent|Task) || -n "$(j '.tool_input.subagent_type // empty')" ]]; then   # D6: which subagents may exist (specialists have Bash; senior-council and
      sa=$(j '.tool_input.subagent_type // ""')   # deliberation-conductor spawn); a grump only under parliament, and only
      g=${sa#chaos:grumpy-}                       # one whose memory the launcher froze (GRUMPS)
      if [[ -n "$(j '.tool_input.isolation // ""')" ]]; then why="subagents with isolation are not allowed"
      elif [[ $sa == general-purpose ]]; then why=""
      elif [[ $sa == chaos:grumpy-* ]] && (( ${GRUMPS[(Ie)$g]} )) && [[ $(engine_of $S/session.lock "${SID:-x}") == parliament ]]; then why=""
      else why="subagent_type must be general-purpose, or chaos:grumpy-<name> under the parliament engine (got '${${sa//[^A-Za-z0-9:_-]/}[1,40]}')"; fi
      [[ -n $why ]] && { log "denied Agent: $why"; print -u2 "prwatch: $why"; exit 2; }
    fi
    live || exit 0
    [[ $tool == (TaskStop|TaskList|ToolSearch|Read|Glob|Grep|CronList|CronDelete) ]] && exit 0
    [[ $tool == Bash && "$(j '.tool_input.command // ""')" == $PRW/bin/prwatch-state.sh\ (harness-abort|get)(\ [A-Za-z0-9/._@#:=+-]##)# ]] && exit 0
    log "denied $tool while background subagents are live"
    k=""; for m in $H/*.marker $H/*.stopped; do [[ "$(/usr/bin/jq -r .session $m 2>/dev/null)" == $SID ]] || continue
      k=$(/usr/bin/jq -r .key $m 2>/dev/null); [[ $k == ${~KEY_PAT} ]] && break; k=""; done
    print -u2 "PRWATCH HARNESS FAULT: this session has an unfinished harness fault. TaskStop any background subagent still running (\"not running\" means it already finished). Nothing else may prompt or start until then.${k:+${NL}Then run exactly this command, unquoted, on its own:${NL}$PRW/bin/prwatch-state.sh harness-abort $k}"
    exit 2 ;;
esac
exit 0
