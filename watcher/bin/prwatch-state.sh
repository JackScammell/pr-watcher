#!/bin/zsh
# prwatch-state.sh — the only writer of state.json.
#   set <key> <status> [k=v ...] | freeze <key> | get <key> | pause <min> | stop-today | go-ahead <key> <sha40> | daily-inc
#   | miss <key> <n>   (withdrawn-pass counter; changes nothing else, no event, no notification)
# Values must match [A-Za-z0-9._/:@#+-]* — e.g. recommendation=request-changes (not "REQUEST CHANGES").
[[ -z "${PRWATCH_CLEAN:-}" ]] && exec /usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin LANG=en_GB.UTF-8 PRWATCH_CLEAN=1 \
  ${${(f)"$(/usr/bin/env | /usr/bin/grep '^PRWATCH_')"}:#} /bin/zsh "$0" "$@"
emulate -L zsh; set -u; setopt extendedglob
PRW=$HOME/prwatch; S=$PRW/state
[[ -n ${PRWATCH_TESTMODE:-} ]] && S=${PRWATCH_STATE_DIR:-$PRW/test/state}
mkdir -p $S; F=$S/state.json; [[ -f $F ]] || print '{"prs":{},"daily":{},"go_ahead":{}}' > $F
[[ "$(jq -r .session_id $S/session.lock 2>/dev/null)" == "${PRWATCH_SESSION_ID:-x}" ]] || { print superseded; exit 5; }
STATUSES='(queued|reviewing|ready|asking|awaiting_decision|posted|skipped|failed|draft_seen|closed|withdrawn|go_ahead_pending|go_ahead_declined)'
okkey() { [[ $1 == ACT-Training/[A-Za-z0-9._-]##\#[0-9]## ]] || { print "bad key"; exit 64; } }
write() { jq "$@" $F > $F.tmp && mv $F.tmp $F; }
now=$(date -Iseconds)
case ${1:-} in
  set) okkey ${2:-}; key=$2; stt=${3:-}; [[ $stt == ${~STATUSES} ]] || { print "bad status"; exit 64; }; shift 3
       args=(--arg k $key --arg s $stt --arg t $now); f='.prs[$k] = ((.prs[$k] // {}) + {status:$s, updated_at:$t}'
       i=0; for kv in "$@"; do [[ $kv == [a-z_]##=[A-Za-z0-9._/:@#+-]# ]] || { print "bad field $kv"; exit 64; }
         args+=(--arg v$i ${kv#*=}); f+=" + {\"${kv%%=*}\": \$v$i}"; (( i++ )); done
       [[ $stt == reviewing ]] && { args+=(--arg sid ${PRWATCH_SESSION_ID} --arg pid ${PRWATCH_PID:-0}); f+=' + {owner:$sid, owner_pid:$pid}'; }
       [[ $stt == posted ]] && { args+=(--arg tu "$(date -u +%Y-%m-%dT%H:%M:%SZ)"); f+=' + {posted_at:$tu}'; }   # UTC, same form as GitHub timeline
       [[ $stt == (posted|skipped) ]] && f+=' + {last_reviewed_sha: (.prs[$k].sha // "")}'                        # round>=2 delta base
       write "${args[@]}" "$f)"
       print -r -- "{\"t\":\"$now\",\"key\":\"$key\",\"status\":\"$stt\"}" >> $S/events.jsonl
       case $stt in   # notifications are side effects of state changes, not model memory
         asking) $PRW/bin/prwatch-notify.sh decision $key;;
         go_ahead_pending) [[ " $* " == *" asked=1 "* ]] && $PRW/bin/prwatch-notify.sh question $key;;   # ping when the question is ASKED, not when queued
         failed) (( $(jq -r --arg k $key '.prs[$k].attempts // 0 | tonumber' $F) >= 3 )) && $PRW/bin/prwatch-notify.sh question $key;;
       esac; exit 0 ;;
  freeze) okkey ${2:-}; d=$(jq -r --arg k $2 '.prs[$k].archive // ""' $F); [[ -f $d/draft/review-body.md ]] || { print "no draft"; exit 64; }
       h=$(shasum -a 256 $d/draft/review-body.md | cut -c1-12); write --arg k $2 --arg h $h '.prs[$k].body_sha=$h'; print $h ;;
  get) okkey ${2:-}; jq --arg k $2 '.prs[$k]' $F ;;
  pause) [[ ${2:-} == [0-9]## ]] || exit 64; write --arg u "$(date -v+${2}M -Iseconds)" '.paused_until=$u' ;;
  stop-today) touch $S/stopped-$(date +%F) ;;
  go-ahead) okkey ${2:-}; [[ ${3:-} == [0-9a-f](#c40) ]] || exit 64; write --arg k $2 --arg s $3 '.go_ahead[$k]=$s' ;;
  daily-inc) write --arg d $(date +%F) '.daily[$d] = ((.daily[$d] // 0) + 1)' ;;
  miss) okkey ${2:-}; [[ ${3:-} == [0-9]## ]] || exit 64; write --arg k $2 --argjson m $3 'if .prs[$k] then .prs[$k].miss=$m else . end' ;;
  *) print "usage"; exit 64 ;;
esac
