#!/bin/zsh
# prwatch-skillhook.sh — PreToolUse(Skill) hook, never called by the model. The authoritative layer for skills (plan D5,
# D7; settings.json's deny rules and skillOverrides are backstops). An allow-list; exit 0 only for:
#   prwatch-start | prwatch-tick | prwatch-eod   with no argument
#   prwatch-review | prwatch-decide              with exactly one key <owner>/<repo>#<n>
#   code-review   only when this session's lock says engine "builtin", args contain none of the refused words, and
#                 args are exactly "<low|medium|high> /Users/jack/prwatch/work/<worktree>" (WT_PAT) naming a directory
#                 that exists and is not a symlink
# Everything else exits 2: every chaos:* command, review, security-review, schedule, loop, an unknown skill, and any
# payload that is not {tool_name:"Skill", tool_input:{skill:<string>[, args:<string>]}} (fail closed). The field names
# were recorded from Claude Code 2.1.314; in test mode the raw tool_input is appended to state/harness/skillgate.log so
# live-check L4 shows the cause if they ever change.
[[ -z "${PRWATCH_CLEAN:-}" ]] && exec /usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin LANG=en_GB.UTF-8 ${TZ:+TZ=$TZ} PRWATCH_CLEAN=1 \
  ${${(f)"$(/usr/bin/env | /usr/bin/grep '^PRWATCH_')"}:#} /bin/zsh "$0" "$@"
emulate -L zsh; set -u; setopt extendedglob
PRW=$HOME/prwatch; source $PRW/bin/prwatch-common.zsh
S=$PRW/state
[[ -n ${PRWATCH_TESTMODE:-} ]] && S=${PRWATCH_STATE_DIR:-$PRW/test/state}
no() { print -u2 "prwatch skill gate: $1"; exit 2; }
p=$(cat 2>/dev/null) || p=""
if [[ -n ${PRWATCH_TESTMODE:-} ]]; then mkdir -p $S/harness
  print -r -- "$(/usr/bin/jq -c '.tool_input' <<<"$p" 2>/dev/null || print unparsable)" >> $S/harness/skillgate.log; fi
shape=$(/usr/bin/jq -r 'if type == "object" and .tool_name == "Skill" and (.tool_input | type) == "object"
  and ((.tool_input | keys) - ["skill","args"] | length) == 0 and (.tool_input.skill | type) == "string"
  and ((.tool_input.args // "") | type) == "string" then "ok" else "bad" end' <<<"$p" 2>/dev/null)
[[ $shape == ok ]] || no "unrecognised Skill call (refused; nothing ran)"
sk=$(/usr/bin/jq -r '.tool_input.skill' <<<"$p"); a=$(/usr/bin/jq -r '.tool_input.args // ""' <<<"$p")
shown=${${sk//[^A-Za-z0-9:_-]/}[1,40]}
case $sk in
  prwatch-(start|tick|eod))  [[ -z $a ]] && exit 0; no "$shown takes no argument" ;;
  prwatch-(review|decide))   okkey "$a" && exit 0; no "$shown takes exactly one key, <owner>/<repo>#<n>" ;;
  code-review)
    eng=$(engine_of $S/session.lock "${PRWATCH_SESSION_ID:-x}")
    [[ $eng == builtin ]] || no "code-review runs only under the builtin engine (this session: ${eng:-no engine})"
    # the second check: posting, editing and escalation words anywhere, whatever the grammar below would say (M10)
    [[ $a == *(--comment|--post|--fix|--max-findings|..)* ]] && no "code-review may not post, edit, or leave the worktree"
    for w in ${(s: :)a}; do [[ $w == (ultra|max|xhigh|[0-9]##|\#*) ]] && no "code-review only at low, medium or high, on a worktree"; done
    [[ $a == (low|medium|high)\ $PRW/work/${~WT_PAT} ]] || no "code-review takes exactly: <low|medium|high> $PRW/work/<worktree>"
    d=${a#* }; [[ -d $d && ! -L $d ]] && exit 0
    no "that worktree does not exist" ;;
  chaos:*) no "Parliament commands are never run by the watcher; its reviewers are dispatched only as Agent calls" ;;
  *)       no "${shown:-an empty skill name} is not a watcher skill" ;;
esac
