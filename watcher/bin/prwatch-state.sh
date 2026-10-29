#!/bin/zsh
# prwatch-state.sh — the only writer of state.json.
#   set <key> <status> [k=v ...] | freeze <key> | get <key> | go-ahead <key> <sha40> | miss <key> <n>
#   | check    (read-only, no session needed: 0 = state.json readable with an object "prs", 70 = unreadable)
#   | stop     (prompthook only: needs a fresh state/stop/request.json; touches stopped-<session_id>)
#   | pause <1-480>  (prompthook only: needs a fresh state/pause/request.json; stores paused_until as epoch seconds)
#   | eod-done (after the 8-hour END only: prints this session's counts {posted,waiting,not_started,failed}; idempotent)
#   | harness-abort <key>  (reviewers ran in the background: requeue, stop this session; needs agenthook markers)
#   | repo-allow <owner/repo> | repo-block <owner/repo>  (prompthook only: needs a fresh state/repo/request.json whose n
#     is "allow <owner/repo>" / "block <owner/repo>"; stores repos[<owner/repo, lower-cased>] = allowed | blocked)
# set of a key not yet in prs passes the repo gate first (repo_allowed in prwatch-common.zsh): refused → "repo not
#   allowed", 64, event repo_not_allowed. A key seen only through another tracked PR of its repo promotes the repo to
#   repos[]=allowed on its first set. Keys already in prs are always updatable (withdrawn, closed).
# Exit codes: 0 ok | 5 another session's lock (everything but check) | 64 refused stop/pause/eod-done/repo-allow/
#   repo-block, repo not allowed, bad arguments, retired words | 70 check unreadable or failed write | 75 state lock busy.
# Values must match [A-Za-z0-9._/:@#+-]* — e.g. recommendation=request-changes (not "REQUEST CHANGES").
[[ -z "${PRWATCH_CLEAN:-}" ]] && exec /usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin LANG=en_GB.UTF-8 ${TZ:+TZ=$TZ} PRWATCH_CLEAN=1 \
  ${${(f)"$(/usr/bin/env | /usr/bin/grep '^PRWATCH_')"}:#} /bin/zsh "$0" "$@"
emulate -L zsh; set -u; setopt extendedglob
PRW=$HOME/prwatch; source $PRW/bin/prwatch-common.zsh
S=$PRW/state; lw=10
[[ -n ${PRWATCH_TESTMODE:-} ]] && { S=${PRWATCH_STATE_DIR:-$PRW/test/state}; lw=${PRWATCH_LOCK_WAIT:-$lw}; }
mkdir -p $S; F=$S/state.json; [[ -f $F ]] || print '{"prs":{},"go_ahead":{},"repos":{}}' > $F
# check: an empty or corrupt state.json is an error (70), never "nothing tracked"
[[ ${1:-} == check ]] && { jq -e '.prs|type=="object"' $F >/dev/null 2>&1 && exit 0; print "state unreadable"; exit 70; }
SID=${PRWATCH_SESSION_ID:-}
session_id_ok "$SID" || { print "bad session id"; exit 64; }     # it is written into file names and JSON
[[ "$(jq -r .session_id $S/session.lock 2>/dev/null)" == "${SID:-x}" ]] || { print superseded; exit 5; }
# One writer at a time: fcntl lock; unlock before slow side effects (notify, cleanup) so nothing waits on them.
# Not taken by subcommands that never write state.json (harness-abort locks only around its final write).
zmodload zsh/system; : >> $S/state.lock
lock()   { zsystem flock -t $lw -f lfd $S/state.lock 2>/dev/null || { print "state busy"; exit 75; } }
unlock() { zsystem flock -u $lfd; }
[[ ${1:-} == (get|stop|harness-abort|eod-done) ]] || lock
STATUSES='(queued|reviewing|ready|asking|awaiting_decision|posted|skipped|failed|draft_seen|closed|withdrawn|go_ahead_pending|go_ahead_declined)'
# every write drops the retired cap fields; run.sh "failed write → 70" relies on the .tmp name
# MIGRATION (remove after v1.0.0): del(.daily,.cap_override) drops the v1 cap fields the first time a v1 state file is written.
write() { local f=${@[-1]}; jq "${@[1,-2]}" "del(.daily,.cap_override) | $f" $F > $F.tmp && mv $F.tmp $F; }
now=$(date -Iseconds); ne=$(now_epoch) || { print -r -- "$ne"; exit 64; }
ev() { print -r -- "{\"t\":\"$now\",\"session\":\"$SID\"$1}" >> $S/events.jsonl; }     # $1 = ",\"k\":v..." (validated values only)
# fresh_request <kind> <value>: state/<kind>/request.json names this session and this value and is under 2 minutes
# old (real file age, real clock). Only prwatch-prompthook.sh writes one, moments before calling us, and the model
# can't write state/ (sandbox denyWrite + permission deny): the request is Jack's typed prompt, by mechanism.
fresh_request() { local R=$S/$1/request.json
  [[ "$(jq -r '"\(.session) \(.n)"' $R 2>/dev/null)" == "$SID $2" ]] || return 1
  (( $(date +%s) - $(stat -f %m $R) < REQUEST_MAX_AGE )) }
case ${1:-} in
  set) okkey "${2:-}" || { print "bad key"; exit 64; }; key=$2; stt=${3:-}; [[ $stt == ${~STATUSES} ]] || { print "bad status"; exit 64; }; shift 3
       args=(--arg k $key --arg s $stt --arg t $now); f='.prs[$k] = ((.prs[$k] // {}) + {status:$s, updated_at:$t}'
       promote=""
       if ! jq -e --arg k $key '.prs|has($k)' $F >/dev/null; then      # a new key: the repo gate, then promotion
         key_split $key; R=$o/$repo
         repo_allowed $F $R || { ev ",\"repo_not_allowed\":\"$R\""; print "repo not allowed"; exit 64; }
         jq -e --arg r ${R:l} '(.repos // {})|with_entries(.key|=ascii_downcase)|has($r)' $F >/dev/null \
           || { args+=(--arg rl ${R:l}); promote=' | .repos[$rl]="allowed"'; }
       fi
       i=0; for kv in "$@"; do [[ $kv == [a-z_]##=[A-Za-z0-9._/:@#+-]# ]] || { print "bad field $kv"; exit 64; }
         args+=(--arg v$i ${kv#*=}); f+=" + {\"${kv%%=*}\": \$v$i}"; (( i++ )); done
       [[ $stt == reviewing ]] && { args+=(--arg sid $SID --arg pid ${PRWATCH_PID:-0}); f+=' + {owner:$sid, owner_pid:$pid}'; }
       [[ $stt == posted ]] && { args+=(--arg tu "$(date -u +%Y-%m-%dT%H:%M:%SZ)"); f+=' + {posted_at:$tu}'; }   # UTC, same form as GitHub timeline
       [[ $stt == (posted|skipped) ]] && f+=' + {last_reviewed_sha: (.prs[$k].sha // "")}'                        # round>=2 delta base
       write "${args[@]}" "$f)$promote"
       ev ",\"key\":\"$key\",\"status\":\"$stt\""
       unlock
       case $stt in   # notifications are side effects of state changes, not model memory
         asking) $PRW/bin/prwatch-notify.sh decision $key;;
         go_ahead_pending) [[ " $* " == *" asked=1 "* ]] && $PRW/bin/prwatch-notify.sh question $key;;   # ping when the question is ASKED, not when queued
         failed) (( $(jq -r --arg k $key '.prs[$k].attempts // 0 | tonumber' $F) >= 3 )) && $PRW/bin/prwatch-notify.sh question $key;;
       esac; exit 0 ;;
  freeze) okkey "${2:-}" || { print "bad key"; exit 64; }; d=$(jq -r --arg k $2 '.prs[$k].archive // ""' $F); [[ -f $d/draft/review-body.md ]] || { print "no draft"; exit 64; }
       h=$(shasum -a 256 $d/draft/review-body.md | cut -c1-12); write --arg k $2 --arg h $h '.prs[$k].body_sha=$h'; print $h ;;
  get) okkey "${2:-}" || { print "bad key"; exit 64; }; jq --arg k $2 '.prs[$k]' $F ;;
  stop) fresh_request stop stop || { ev ',"stop_refused":true'; print "only Jack can stop the watcher, by typing stop at the prompt"; exit 64; }
       rm -f $S/stop/request.json; touch $S/stopped-$SID; ev ',"stop":true'; print stopped ;;
  pause) [[ ${2:-} == [1-9][0-9]# ]] && (( $2 <= PAUSE_MAX )) || { print "pause must be 1 to $PAUSE_MAX"; exit 64; }
       fresh_request pause $2 || { ev ",\"pause_refused\":$2"; print "only Jack can pause the watcher, by typing pause N at the prompt"; exit 64; }
       rm -f $S/pause/request.json; u=$(( ne + $2 * 60 ))
       write --argjson u $u '.paused_until=$u'; ev ",\"pause\":$2,\"until\":$u"
       print -r -- "{\"paused_until\":$u,\"until\":\"$(hhmm $u)\"}" ;;
  repo-allow|repo-block) verb=${1#repo-}; r=${2:-}; okrepo "$r" || { print "bad repo"; exit 64; }
       fresh_request repo "$verb $r" || { ev ",\"repo_refused\":\"$r\""
         print "only Jack can allow or block a repo, by typing allow <owner>/<repo> or block <owner>/<repo> at the prompt"; exit 64; }
       rm -f $S/repo/request.json; val=${verb}ed; rl=${r:l}        # stored lower-cased; the hook echoes what Jack typed
       write --arg r $rl --arg v $val '.repos = ((.repos // {}) | with_entries(.key |= ascii_downcase)) | .repos[$r]=$v'
       ev ",\"repo_$verb\":\"$rl\""; print $val ;;
  go-ahead) okkey "${2:-}" || { print "bad key"; exit 64; }; [[ ${3:-} == [0-9a-f](#c40) ]] || exit 64; write --arg k $2 --arg s $3 '.go_ahead[$k]=$s' ;;
  # miss: the withdrawn-pass counter; changes nothing else, no event, no notification
  miss) okkey "${2:-}" || { print "bad key"; exit 64; }; [[ ${3:-} == [0-9]## ]] || exit 64; write --arg k $2 --argjson m $3 'if .prs[$k] then .prs[$k].miss=$m else . end' ;;
  eod-done) se=$(started_epoch $S) || { print "no session start"; exit 64; }
       (( ne - se >= END )) || { print "session not over"; exit 64; }
       [[ -f $S/events.jsonl ]] || : > $S/events.jsonl
       # last status per key for this session: posted | waiting (ready…go_ahead_pending) | not_started (queued) | failed
       c=$(jq -sc --arg s $SID '[.[] | select(.session == $s and .key != null and .status != null)]
         | reduce .[] as $e ({}; .[$e.key] = $e.status) | [.[]]
         | {posted: map(select(. == "posted")) | length,
            waiting: map(select(. == "ready" or . == "asking" or . == "awaiting_decision" or . == "go_ahead_pending")) | length,
            not_started: map(select(. == "queued")) | length, failed: map(select(. == "failed")) | length}' $S/events.jsonl) \
         || { print "events unreadable"; exit 70; }
       if [[ ! -f $S/eod-done-$SID ]]; then ev ",\"eod_done\":true,${${c#\{}%\}}"; touch $S/eod-done-$SID; fi
       print -r -- "$c" ;;
  harness-abort) okkey "${2:-}" || { print "bad key"; exit 64; }; key=$2; H=$S/harness; setopt nullglob   # authorised only by prwatch-agenthook.sh markers
       [[ "$(jq -r --arg k $key '.prs[$k].status // ""' $F)" == reviewing ]] || { print "not reviewing"; exit 64; }
       mine=(); live=0
       for m in $H/*.marker $H/*.stopped; do
         [[ "$(jq -r '"\(.session) \(.key)"' $m 2>/dev/null)" == "$SID $key" ]] || continue
         mine+=($m); [[ $m == *.marker ]] && (( live++ ))
       done
       (( ${#mine} )) || { print "no harness fault recorded"; exit 64; }
       (( live )) && { print "reviewers still running - TaskStop them first"; exit 64; }
       wt=${PRW:A}/work/$(wt_prefix $key)     # :A — lsof reports real paths
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
       # requeue under the lock; markers are archived only after that, so a busy lock (75) can simply be retried
       lock; [[ "$(jq -r --arg k $key '.prs[$k].status // ""' $F)" == reviewing ]] || { print "not reviewing"; exit 64; }
       write --arg k $key --arg t $now '.prs[$k] = (.prs[$k] | .status="queued" | .updated_at=$t | del(.step))' \
         || { print "state write failed"; exit 70; }
       mkdir -p $H/done; mv $mine $H/done/
       touch $S/stopped-$SID
       ev ",\"key\":\"$key\",\"status\":\"queued\",\"harness_abort\":true" ;;
  *) print "usage"; exit 64 ;;
esac
