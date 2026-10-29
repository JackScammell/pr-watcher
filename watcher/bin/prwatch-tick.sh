#!/bin/zsh
# prwatch-tick.sh [--dry-run] [--window]  → prints ONE JSON object; non-dry runs record queue/draft/withdrawn state.
#   Needs PRWATCH_LOGIN (the launcher's export) for anything but --window: without it → error no_login, nothing searched.
#   --window → pure read of the session window from the lock's started_epoch (no heartbeat, no lock check, no
#              notification, no state write): in_window (elapsed < 7 h 30: a new council may start) | start_closed
#              (< 8 h) | session_over (+ eod_due) | error no_session_start / clock_before_start.
[[ -z "${PRWATCH_CLEAN:-}" ]] && exec /usr/bin/env -i HOME="$HOME" PATH=/opt/homebrew/bin:/usr/bin:/bin LANG=en_GB.UTF-8 ${TZ:+TZ=$TZ} PRWATCH_CLEAN=1 \
  ${${(f)"$(/usr/bin/env | /usr/bin/grep '^PRWATCH_')"}:#} /bin/zsh "$0" "$@"
emulate -L zsh; set -u; setopt extendedglob
PRW=$HOME/prwatch; source $PRW/bin/prwatch-common.zsh
S=$PRW/state; ONLY=""; DRY=0; WONLY=0
if [[ -n ${PRWATCH_TESTMODE:-} ]]; then
  S=${PRWATCH_STATE_DIR:-$PRW/test/state}; ONLY=${PRWATCH_ONLY_PR:-}
  [[ -n ${PRWATCH_STUB_BIN:-} ]] && path=($PRWATCH_STUB_BIN $path)
fi
for x in "$@"; do case $x in --dry-run) DRY=1;; --window) WONLY=1;; *) exit 64;; esac; done
out() { print -r -- "$1"; exit 0; }
ST=$PRW/bin/prwatch-state.sh; SID=${PRWATCH_SESSION_ID:-}
session_id_ok "$SID" || { print "bad session id"; exit 64; }
mkdir -p $S; F=$S/state.json; [[ -f $F ]] || print '{"prs":{},"go_ahead":{},"repos":{}}' > $F
# 1. lock recreation (full ticks only): a lock without a session_id is rebuilt from the launcher's own lock object,
#    which must name this session — so started_epoch always comes from what the launcher wrote, never "start now".
if (( ! DRY && ! WONLY )) && [[ -z "$(jq -r '.session_id // ""' $S/session.lock 2>/dev/null)" ]]; then
  [[ "$(jq -r '.session_id // ""' <<<"${PRWATCH_LOCK_JSON:-}" 2>/dev/null)" == "${SID:-x}" ]] || out '{"status":"error","kind":"no_session_start"}'
  jq -c '. + {recreated:true}' <<<"$PRWATCH_LOCK_JSON" > $S/session.lock.tmp && mv $S/session.lock.tmp $S/session.lock
fi
# 2. window: integer seconds from the lock's started_epoch (M1 deletes the read; M2/M3 move the boundaries)
se=$(started_epoch $S) || out '{"status":"error","kind":"no_session_start"}'
now=$(now_epoch) || { print -r -- "$now"; exit 64; }
elapsed=$(( now - se ))
(( elapsed < 0 )) && out '{"status":"error","kind":"clock_before_start"}'
if   (( elapsed < START_LIMIT )); then wst=in_window
elif (( elapsed < END ));         then wst=start_closed
else wst=session_over; fi
W=$(jq -nc --arg s "$(date -r $se -Iseconds)" --arg sh "$(hhmm $se)" --argjson m $(( elapsed / 60 )) --arg su "$(hhmm $(( se + START_LIMIT )))" --arg ea "$(hhmm $(( se + END )))" \
  '{started:$s,started_hm:$sh,elapsed_min:$m,starts_until:$su,ends_at:$ea}')
win() { jq -c --arg st $1 --argjson x "${2:-{\}}" '{status:$st} + . + $x' <<<$W; }
eod_due() { [[ -f $S/eod-done-$SID ]] && print false || print true; }
if (( WONLY )); then [[ $wst == session_over ]] && out "$(win $wst "{\"eod_due\":$(eod_due)}")"; out "$(win $wst)"; fi
# login: the launcher's PRWATCH_LOGIN is the only identity used (never the lock, never gh); no login → nothing is searched
oklogin "${PRWATCH_LOGIN:-}" || out '{"status":"error","kind":"no_login"}'
touch $PRW/state/activity 2>/dev/null      # heartbeat: below the --window exit (M13 moves it above → the watchdog refreshes itself)
# 3. lock ownership (skipped in --dry-run so Jack can test from any Terminal)
if (( ! DRY )); then
  lk=$(jq -r '.session_id // ""' $S/session.lock 2>/dev/null)
  [[ $lk == "${SID:-x}" ]] || { $PRW/bin/prwatch-notify.sh error superseded; out '{"status":"superseded"}'; }
fi
# 4. session over / stop / pause (the window check is first, so END inside a pause still ends the session)
[[ $wst == session_over ]] && out "$(win session_over "{\"eod_due\":$(eod_due)}")"
[[ -f $S/stopped-$SID ]] && out '{"status":"stopped"}'      # legacy stopped-<date> files are ignored
pu=$(jq -r '.paused_until // ""' $F); [[ $pu == [0-9]## ]] && (( now < pu )) && out "{\"status\":\"paused\",\"until\":\"$(hhmm $pu)\"}"
$ST check >/dev/null || { $PRW/bin/prwatch-notify.sh error state; out '{"status":"error","kind":"state_unreadable"}'; }
# 5. GitHub, with the real config
export GH_CONFIG_DIR=$HOME/.config/gh
gh auth status >/dev/null 2>&1 || { $PRW/bin/prwatch-notify.sh error gh_auth; out '{"status":"error","kind":"gh_auth"}'; }
if [[ -n $ONLY ]]; then            # test mode: comma-separated direct lookups (may be merged PRs); split as the search would
  list=$(for one in ${(s:,:)ONLY}; do jq -nc --arg r ${one%%\#*} --arg n ${one##*\#} --arg a "${PRWATCH_ONLY_AUTHOR:-stub}" \
    '{number:($n|tonumber? // $n),repository:{nameWithOwner:$r},author:{login:$a}}'; done | jq -sc .)
else                               # every repo the login can see, no owner filter; author is for the new_repo notice
  list=$(gh search prs --state open --limit 100 --json number,repository,author -- "user-review-requested:@me" 2>/dev/null) \
    || { $PRW/bin/prwatch-notify.sh error network; out '{"status":"error","kind":"search_failed"}'; }
fi
trunc=0; (( $(jq 'length' <<<$list 2>/dev/null || print 0) == 100 )) && trunc=1     # exactly the limit: the page is partial
# 6. classify (first match wins) — table in plan §5.2. A search row is untrusted: the key is validated before it is
#    remembered, looked up or written; a repo that is blocked or never seen gets no gh pr view. The gate is
#    repo_allowed (prwatch-common.zsh), the same predicate prep and state set apply. A tracked PR of a repo Jack has
#    since blocked is withdrawn here (reason blocked_repo), so decide never sees it.
items=(); seen=(); notices=()
for pr in ${(f)"$(jq -c '.[]' <<<$list)"}; do
  n=$(jq -r '.number // ""' <<<$pr); R=$(jq -r '.repository.nameWithOwner // ""' <<<$pr); key="$R#$n"
  okkey "$key" || continue
  seen+=$key
  e() { jq -r --arg k $key ".prs[\$k].$1 // \"$2\"" $F; }
  st=$(e status absent)
  if repo_allowed $F $R; then r=""
  elif jq -e --arg r ${R:l} '(.repos // {})|with_entries(.key|=ascii_downcase)|has($r)' $F >/dev/null; then r=blocked_repo   # an entry that is not "allowed"
  else r=new_repo; fi
  if [[ -n $r ]]; then               # source gate: blocked, or first sighting (day-1 rule: any prs key for the repo = seen)
    au=""
    if [[ $r == new_repo ]]; then    # the author is read only here, and only its login characters survive
      au=$(jq -r '.author.login // ""' <<<$pr); au=${au//[^A-Za-z0-9-]/}
      notices+=("$(jq -nc --arg l "First PR from $R by $au: type allow $R or block $R" '$l')")
      (( ! DRY )) && $PRW/bin/prwatch-notify.sh question $key
    elif (( ! DRY )) && [[ $st != (absent|withdrawn|closed|posted|skipped) ]]; then
      $ST set $key withdrawn withdrawn_from=$st >/dev/null     # tracked, now blocked: out of the queue (an existing key may still be set)
    fi
    items+=("$(jq -nc --arg k $key --arg r $r --arg st $st --arg a "$au" '{key:$k,sha:"",reason:$r,prev:$st,size:0,title:"",author:$a}')")
    continue
  fi
  v=$(gh pr view $n -R $R --json headRefOid,isDraft,state,title,author,files 2>/dev/null) || continue
  sha=$(jq -r .headRefOid <<<$v); draft=$(jq -r .isDraft <<<$v)
  size=$(jq '[.files[] | select(.path | test("(lock\\.json|\\.lock|\\.Designer\\.cs)$|/generated/") | not) | .additions + .deletions] | add // 0' <<<$v)
  ssha=$(e sha ""); att=$(e attempts 0)
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
    rr=$(gh api "repos/$R/issues/$n/timeline" --paginate 2>/dev/null | jq -rs --arg me "$PRWATCH_LOGIN" '[.[][]|select(.event=="review_requested" and .requested_reviewer.login==$me)|.created_at]|last')
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
# 7. withdrawn pass: tracked in an active state but missing from the search on TWO consecutive ticks → withdrawn
#    (one notice each). The first miss only records miss=1, so an empty search result withdraws nothing; a search
#    that filled its 100-row page is partial and skips the pass altogether (one notice).
#    Not in ONLY test mode (new_repo notices above are added in every mode).
(( trunc )) && notices+=('"search truncated at 100; nothing withdrawn this check"')
if [[ -z $ONLY ]] && (( ! DRY && ! trunc )); then
  for kv in ${(f)"$(jq -r '.prs|to_entries[]|select(.value.status|test("^(queued|ready|asking|awaiting_decision|go_ahead_pending|reviewing|failed)$"))|"\(.key) \(.value.status) \(.value.miss // 0)"' $F)"}; do
    [[ -n $kv ]] || continue; k=${kv%% *}; kst=${${kv#* }%% *}; km=${kv##* }
    (( ${seen[(Ie)$k]} )) && continue
    if (( km < 1 )); then $ST miss $k 1 >/dev/null; continue; fi
    $ST set $k withdrawn withdrawn_from=$kst miss=0 >/dev/null; notices+=("\"$k no longer requested (withdrawn, merged or closed)\"")
  done
fi
cs=$( [[ $wst == in_window ]] && print true || print false )      # may a NEW council start now? (prep enforces the same rule: exit 27)
jq -c --argjson i "[${(j:,:)items}]" --argjson no "[${(j:,:)notices}]" --argjson cs $cs \
  '{status:"ok"} + . + {can_start:$cs,items:$i,notices:$no}' <<<$W
