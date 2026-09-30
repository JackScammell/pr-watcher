#!/bin/zsh
# prwatch-state.sh — the only writer of state.json.
#   set <key> <status> [k=v ...] | freeze <key> | get <key> | pause <min> | stop-today | go-ahead <key> <sha40>
#   | daily-inc (prep: take one of today's council slots; 65 = cap used up) | cap <1-12> (prompthook only: Jack's "cap N")
#   | miss <key> <n>   (withdrawn-pass counter; changes nothing else, no event, no notification)
#   | harness-abort <key>   (reviewers ran in the background: requeue, refund today's slot, stop today; needs agenthook markers)
# Values must match [A-Za-z0-9._/:@#+-]* — e.g. recommendation=request-changes (not "REQUEST CHANGES").
[[ -z "${PRWATCH_CLEAN:-}" ]] && exec /usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin LANG=en_GB.UTF-8 PRWATCH_CLEAN=1 \
  ${${(f)"$(/usr/bin/env | /usr/bin/grep '^PRWATCH_')"}:#} /bin/zsh "$0" "$@"
emulate -L zsh; set -u; setopt extendedglob
PRW=$HOME/prwatch; S=$PRW/state; td=$(date +%F)
CAP_DEFAULT=6 CAP_MAX=12            # councils a day; CAP_DEFAULT must match prwatch-tick.sh (the harness checks)
if [[ -n ${PRWATCH_TESTMODE:-} ]]; then S=${PRWATCH_STATE_DIR:-$PRW/test/state}; [[ -n ${PRWATCH_NOW:-} ]] && td=${PRWATCH_NOW[1,10]}; fi
mkdir -p $S; F=$S/state.json; [[ -f $F ]] || print '{"prs":{},"daily":{},"go_ahead":{}}' > $F
[[ "$(jq -r .session_id $S/session.lock 2>/dev/null)" == "${PRWATCH_SESSION_ID:-x}" ]] || { print superseded; exit 5; }
# one writer at a time (the cap check is read-then-write); fcntl lock, released when this process exits
zmodload zsh/system; : >> $S/state.lock
[[ ${1:-} == get ]] || zsystem flock -t 10 $S/state.lock 2>/dev/null || { print "state busy"; exit 75; }
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
  daily-inc) used=$(jq --arg d $td '.daily[$d] // 0' $F); cap=$(jq --arg d $td --argjson c $CAP_DEFAULT '.cap_override[$d] // $c' $F)
       (( used < cap )) || { print "daily cap reached ($used of $cap today)"; exit 65; }
       write --arg d $td '.daily[$d] = ((.daily[$d] // 0) + 1)' ;;
  cap) [[ ${2:-} == [1-9][0-9]# ]] && (( $2 <= CAP_MAX )) || { print "the cap must be 1 to $CAP_MAX"; exit 64; }
       # only Jack's typed prompt authorises this: prwatch-prompthook.sh writes the request moments before calling us,
       # and the model can't write state/ (sandbox denyWrite + permission deny). Single use, 60 s.
       R=$S/cap/request.json
       [[ "$(jq -r '"\(.session) \(.n)"' $R 2>/dev/null)" == "$PRWATCH_SESSION_ID $2" ]] && (( $(date +%s) - $(stat -f %m $R) <= 60 )) \
         || { print "only Jack can change the cap, by typing cap N"; exit 64; }
       rm -f $R
       write --arg d $td --argjson n $2 '.cap_override[$d] = $n'
       print -r -- "{\"t\":\"$now\",\"cap\":$2,\"day\":\"$td\"}" >> $S/events.jsonl
       $PRW/bin/prwatch-notify.sh cap $2
       jq -c --arg d $td --argjson c $CAP_DEFAULT '{cap:.cap_override[$d], cap_default:$c, used:(.daily[$d] // 0)}' $F ;;
  miss) okkey ${2:-}; [[ ${3:-} == [0-9]## ]] || exit 64; write --arg k $2 --argjson m $3 'if .prs[$k] then .prs[$k].miss=$m else . end' ;;
  harness-abort) okkey ${2:-}; key=$2; H=$S/harness; setopt nullglob   # authorised only by prwatch-agenthook.sh markers
       [[ "$(jq -r --arg k $key '.prs[$k].status // ""' $F)" == reviewing ]] || { print "not reviewing"; exit 64; }
       mine=(); live=0
       for m in $H/*.marker $H/*.stopped; do
         [[ "$(jq -r '"\(.session) \(.key)"' $m 2>/dev/null)" == "$PRWATCH_SESSION_ID $key" ]] || continue
         mine+=($m); [[ $m == *.marker ]] && (( live++ ))
       done
       (( ${#mine} )) || { print "no harness fault recorded"; exit 64; }
       (( live )) && { print "reviewers still running - TaskStop them first"; exit 64; }
       k=${key#ACT-Training/}; wt=${PRW:A}/work/${k%%\#*}-pr${k##*\#}-     # :A — lsof reports real paths
       # PR processes left behind: cwd inside the PR's worktrees (anyone's — only PR code works there), or the worktree
       # path on the command line of a descendant of this watcher's launcher (never Jack's own editor or pager)
       root=${PRWATCH_PID:-0}; [[ $root == <-> ]] || root=0
       for pid in ${(f)"$( { /usr/sbin/lsof -d cwd -Fpn 2>/dev/null | awk -v w=$wt '/^p/{p=substr($0,2)} /^n/{if(index(substr($0,2),w)==1)print p}'
                            (( root > 0 )) && /bin/ps -axo pid=,ppid=,command= | PW_WT=$wt awk -v r=$root '   # path via env: awk must not match itself
                              {pp[$1]=$2; if(index($0,ENVIRON["PW_WT"])) hit[$1]=1}
                              END{for(p in hit){q=p; while(q>1 && q!=r) q=pp[q]; if(q==r) print p}}'; } | sort -u )"}; do
         [[ $pid == <-> && $pid != $$ ]] && kill -9 $pid 2>/dev/null
       done
       $PRW/bin/prwatch-cleanup.sh $key
       mkdir -p $H/done; mv $mine $H/done/
       write --arg k $key --arg t $now --arg d $td \
         '.prs[$k] = (.prs[$k] | .status="queued" | .updated_at=$t | del(.step)) | .daily[$d] = ([((.daily[$d] // 0) - 1), 0] | max)'
       touch $S/stopped-$(date +%F)
       print -r -- "{\"t\":\"$now\",\"key\":\"$key\",\"status\":\"queued\",\"harness_abort\":true}" >> $S/events.jsonl ;;
  *) print "usage"; exit 64 ;;
esac
