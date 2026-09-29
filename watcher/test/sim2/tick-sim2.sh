#!/bin/zsh
# Revision 2 classification table (plan §5.2 step 5), first match wins. Stubbed gh + pid/timeline.
set -u
S=${STATE:-./state.json}
MYPID=${PRWATCH_PID:-999}
gh() { case "$1 $2" in
  "search prs") cat search.json;;
  "pr view") jq --argjson n $3 '.[] | select(.number==$n)' view.json;; esac; }
pid_alive() { [[ $1 == LIVE ]]; }                    # stub for kill -0
rerequested_after_post() { [[ $1 == *"#11" ]]; }     # stub: timeline shows re-request after posted_at only for #11
gh search prs | jq -c '.[]' | while read -r pr; do
  n=$(jq -r .number <<<"$pr"); key="$(jq -r .repository.nameWithOwner <<<"$pr")#$n"
  v=$(gh pr view $n); sha=$(jq -r .headRefOid <<<"$v"); draft=$(jq -r .isDraft <<<"$v")
  size=$(( $(jq -r .additions <<<"$v") + $(jq -r .deletions <<<"$v") ))
  e() { jq -r --arg k "$key" ".prs[\$k].$1 // \"$2\"" $S; }
  st=$(e status absent); ssha=$(e sha ""); opid=$(e owner_pid ""); att=$(e attempts 0)
  ga=$(jq -r --arg k "$key" '.go_ahead[$k] // ""' $S)
  if   [[ $draft == true ]];                                            then r=ignored_draft
  elif [[ $st == reviewing ]];                                          then r=orphaned_requeue
  elif [[ $st == (ready|awaiting_decision|asking) ]]; then [[ $sha != $ssha ]] && r=stale_requeue || r=pending_decision
  elif [[ $st == go_ahead_pending ]]; then [[ $sha != $ssha ]] && r=updated || r=pending_go_ahead
  elif [[ $st == failed ]] && (( att < 3 ));                            then r=retry
  elif [[ $st == failed ]];                                             then r=needs_jack
  elif [[ $st == (posted|skipped|closed|draft_seen|queued|go_ahead_declined|withdrawn) && $sha != $ssha ]]; then r=updated
  elif [[ $st == posted ]]; then rerequested_after_post "$key" && r=rerequested_same_sha || r=ignore_index_lag
  elif [[ $st == (skipped|go_ahead_declined) ]];                        then r=ignore
  elif [[ $st == (queued|draft_seen|closed|withdrawn) ]];               then r=new
  elif [[ $st == absent ]];                                             then r=new
  else r="notice_unknown_status($st)"; fi
  if [[ $r == (new|updated|retry|orphaned_requeue|stale_requeue) ]] && (( size > 3000 )) && [[ $ga != $sha ]]; then r="$r->needs_go_ahead"; fi
  echo "$key st=$st draft=$draft size=$size -> $r"
done
