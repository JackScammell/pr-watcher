#!/bin/zsh
# prwatch-tick.sh [--dry-run] [--window]  → prints ONE JSON object; non-dry runs record queue/draft/withdrawn state.
#   --window → in_window (08:00-15:29 weekdays: a new council may start) | start_closed (15:30-15:59) | outside_window
[[ -z "${PRWATCH_CLEAN:-}" ]] && exec /usr/bin/env -i HOME="$HOME" PATH=/opt/homebrew/bin:/usr/bin:/bin LANG=en_GB.UTF-8 PRWATCH_CLEAN=1 \
  ${${(f)"$(/usr/bin/env | /usr/bin/grep '^PRWATCH_')"}:#} /bin/zsh "$0" "$@"
emulate -L zsh; set -u; setopt extendedglob
PRW=$HOME/prwatch; S=$PRW/state; NOW=""; ONLY=""; DRY=0; WONLY=0
if [[ -n ${PRWATCH_TESTMODE:-} ]]; then
  S=${PRWATCH_STATE_DIR:-$PRW/test/state}; NOW=${PRWATCH_NOW:-}; ONLY=${PRWATCH_ONLY_PR:-}
  [[ -n ${PRWATCH_STUB_BIN:-} ]] && path=($PRWATCH_STUB_BIN $path)
fi
for x in "$@"; do case $x in --dry-run) DRY=1;; --window) WONLY=1;; *) exit 64;; esac; done
out() { print -r -- "$1"; exit 0; }
ST=$PRW/bin/prwatch-state.sh
mkdir -p $S; F=$S/state.json; [[ -f $F ]] || print '{"prs":{},"daily":{},"go_ahead":{}}' > $F
touch $PRW/state/activity 2>/dev/null
# 1. lock (skipped in --dry-run so Jack can test from any Terminal)
if (( ! DRY )); then
  lk=$(jq -r '.session_id // ""' $S/session.lock 2>/dev/null)
  if [[ -z $lk ]]; then jq -n --arg t "${PRWATCH_SESSION_ID:-}" --argjson p ${PRWATCH_PID:-0} '{session_id:$t,pid:$p,recreated:true}' > $S/session.lock
  elif [[ $lk != "${PRWATCH_SESSION_ID:-x}" ]]; then $PRW/bin/prwatch-notify.sh error superseded; out '{"status":"superseded"}'; fi
fi
# 2. window / stop / pause
if [[ -n $NOW ]]; then dow=$(date -j -f %Y-%m-%dT%H:%M $NOW +%u); hm=$(date -j -f %Y-%m-%dT%H:%M $NOW +%H%M); today=${NOW[1,10]}
else dow=$(date +%u); hm=$(date +%H%M); today=$(date +%F); fi
(( dow <= 5 && 10#$hm >= 800 && 10#$hm < 1600 )) || out "{\"status\":\"outside_window\",\"hm\":\"$hm\"}"
# Jack's answer 1 (2026-09-29): new councils only START 08:00-15:30; ticks still run to 16:00 for decisions.
if (( WONLY )); then (( 10#$hm < 1530 )) && out '{"status":"in_window"}'; out "{\"status\":\"start_closed\",\"hm\":\"$hm\"}"; fi
[[ -f $S/stopped-$today ]] && out '{"status":"stopped_for_today"}'
pu=$(jq -r '.paused_until // ""' $F); [[ -n $pu && $(date -Iseconds) < $pu ]] && out "{\"status\":\"paused\",\"until\":\"$pu\"}"
# today's count and cap (default, or Jack's "cap N") from the state script, which defines them and prep enforces
ct=$($ST today) || { $PRW/bin/prwatch-notify.sh error state; out '{"status":"error","kind":"state_unreadable"}'; }
# 3. GitHub, with the real config
export GH_CONFIG_DIR=$HOME/.config/gh
gh auth status >/dev/null 2>&1 || { $PRW/bin/prwatch-notify.sh error gh_auth; out '{"status":"error","kind":"gh_auth"}'; }
if [[ -n $ONLY ]]; then            # test mode: comma-separated direct lookups (may be merged PRs)
  list=$(for one in ${(s:,:)ONLY}; do jq -nc --arg r ${one%%\#*} --argjson n ${one##*\#} '{number:$n,repository:{nameWithOwner:$r}}'; done | jq -sc .)
else
  list=$(gh search prs --owner ACT-Training --state open --limit 100 --json number,repository -- "user-review-requested:@me" 2>/dev/null) \
    || { $PRW/bin/prwatch-notify.sh error network; out '{"status":"error","kind":"search_failed"}'; }
fi
# 4. classify (first match wins) — table in plan §5.2
items=(); seen=()
for pr in ${(f)"$(jq -c '.[]' <<<$list)"}; do
  n=$(jq -r .number <<<$pr); R=$(jq -r .repository.nameWithOwner <<<$pr); key="$R#$n"; seen+=$key
  v=$(gh pr view $n -R $R --json headRefOid,isDraft,state,title,author,files 2>/dev/null) || continue
  sha=$(jq -r .headRefOid <<<$v); draft=$(jq -r .isDraft <<<$v)
  size=$(jq '[.files[] | select(.path | test("(lock\\.json|\\.lock|\\.Designer\\.cs)$|/generated/") | not) | .additions + .deletions] | add // 0' <<<$v)
  e() { jq -r --arg k $key ".prs[\$k].$1 // \"$2\"" $F; }
  st=$(e status absent); ssha=$(e sha ""); att=$(e attempts 0)
  (( ! DRY )) && [[ $(e miss 0) != 0 ]] && $ST miss $key 0 >/dev/null     # seen again: reset the withdrawn-miss counter
  ga=$(jq -r --arg k $key '.go_ahead[$k] // ""' $F)
  if   [[ $draft == true ]]; then r=ignored_draft
  elif [[ $st == reviewing ]] && (( att >= 3 )); then r=needs_jack
  elif [[ $st == reviewing ]]; then r=orphaned_requeue      # only the lock owner ticks; others can't write state
  elif [[ $st == (ready|asking|awaiting_decision) ]]; then [[ $sha != $ssha ]] && r=stale_requeue || r=pending_decision
  elif [[ $st == go_ahead_pending ]]; then [[ $sha != $ssha ]] && r=updated || r=pending_go_ahead
  elif [[ $st == failed ]] && (( att < 3 )); then r=retry
  elif [[ $st == failed ]]; then r=needs_jack
  elif [[ $st == (posted|skipped|closed|draft_seen|queued|go_ahead_declined|withdrawn) && $sha != $ssha ]]; then r=updated
  elif [[ $st == posted ]]; then
    pa=$(e posted_at "")          # UTC Z (prwatch-state.sh), same format as timeline created_at
    rr=$(gh api "repos/$R/issues/$n/timeline" --paginate --jq '[.[]|select(.event=="review_requested" and .requested_reviewer.login=="JackScammell")|.created_at]|last' 2>/dev/null)
    [[ -n $rr && $rr != null && $rr > $pa ]] && r=rerequested_same_sha || r=ignore
  elif [[ $st == (skipped|go_ahead_declined) ]]; then r=ignore
  elif [[ $st == withdrawn && $(e withdrawn_from "") == (ready|asking|awaiting_decision) && -f $(e archive "")/draft/review-body.md ]]; then
    r=pending_decision            # came back at the same SHA with a finished draft: re-present it, no second council
  elif [[ $st == (queued|draft_seen|closed|withdrawn|absent) ]]; then r=new
  else r=unknown_status; fi
  if [[ $r == (new|updated|retry|orphaned_requeue|stale_requeue) ]] && (( size > 3000 )) && [[ $ga != $sha ]]; then r=needs_go_ahead; fi
  if (( ! DRY )); then
    case $r in
      ignored_draft) [[ $st == (absent|queued) ]] && $ST set $key draft_seen sha=$sha >/dev/null ;;   # never overwrite posted (keeps posted_sha)
      orphaned_requeue) $ST set $key queued sha=$sha attempts=$(( att + 1 )) >/dev/null ;;   # a PR that keeps crashing stops after 3
      new|updated|retry|stale_requeue|rerequested_same_sha) $ST set $key queued sha=$sha >/dev/null ;;
      needs_go_ahead) [[ $st != go_ahead_pending ]] && $ST set $key go_ahead_pending sha=$sha >/dev/null ;;   # silent; pinged when asked (§5.3)
      pending_decision) [[ $st == withdrawn ]] && $ST set $key awaiting_decision sha=$sha >/dev/null ;;
    esac
  fi
  items+=("$(jq -nc --arg k $key --arg s $sha --arg r $r --arg st $st --argjson z $size --argjson t "$(jq '{title:.title[0:120],author:.author.login}' <<<$v)" '{key:$k,sha:$s,reason:$r,prev:$st,size:$z}+$t')")
done
# 5. withdrawn pass: tracked in an active state but missing from the search on TWO consecutive ticks → withdrawn
#    (one notice each). The first miss only records miss=1, so an empty or partial search result withdraws nothing.
#    Not in ONLY test mode.
notices=()
if [[ -z $ONLY ]] && (( ! DRY )); then
  for kv in ${(f)"$(jq -r '.prs|to_entries[]|select(.value.status|test("^(queued|ready|asking|awaiting_decision|go_ahead_pending|reviewing|failed)$"))|"\(.key) \(.value.status) \(.value.miss // 0)"' $F)"}; do
    [[ -n $kv ]] || continue; k=${kv%% *}; kst=${${kv#* }%% *}; km=${kv##* }
    (( ${seen[(Ie)$k]} )) && continue
    if (( km < 1 )); then $ST miss $k 1 >/dev/null; continue; fi
    $ST set $k withdrawn withdrawn_from=$kst miss=0 >/dev/null; notices+=("\"$k no longer requested (withdrawn, merged or closed)\"")
  done
fi
ct=$($ST today) || { $PRW/bin/prwatch-notify.sh error state; out '{"status":"error","kind":"state_unreadable"}'; }   # after this tick's writes
cs=$( (( 10#$hm < 1530 )) && print true || print false )      # may a NEW council start now? (last start 15:29)
jq -nc --argjson i "[${(j:,:)items}]" --argjson ct $ct --arg hm $hm --argjson no "[${(j:,:)notices}]" --argjson cs $cs \
  '{status:"ok",hm:$hm,can_start:$cs,councils_today:$ct.used,cap:$ct.cap,cap_default:$ct.cap_default,cap_max:$ct.cap_max,
    cap_left:([$ct.cap-$ct.used,0]|max),items:$i,notices:$no}'
