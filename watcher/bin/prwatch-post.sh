#!/bin/zsh
# prwatch-post.sh — the ONLY path that writes to GitHub. Unsandboxed (excludedCommands), behind an `ask` rule,
# and raises its own macOS dialog. Call with Bash timeout 1200000.
# Usage: prwatch-post.sh --repo Vision --pr 1812 --sha <40hex> --event request-changes|approve|comment
#                        --body-sha <12hex> [--tech yes|no] [--allow-stale]
[[ -z "${PRWATCH_CLEAN:-}" ]] && exec /usr/bin/env -i HOME="$HOME" PATH=/opt/homebrew/bin:/usr/bin:/bin LANG=en_GB.UTF-8 PRWATCH_CLEAN=1 \
  ${${(f)"$(/usr/bin/env | /usr/bin/grep '^PRWATCH_')"}:#} /bin/zsh "$0" "$@"
emulate -L zsh; set -u; setopt extendedglob
PRW=$HOME/prwatch; S=$PRW/state; DRY=""
if [[ -n ${PRWATCH_TESTMODE:-} ]]; then
  S=${PRWATCH_STATE_DIR:-$PRW/test/state}; DRY=${PRWATCH_DRY_POST:-1}; [[ $DRY == 0 ]] && DRY=""   # test mode: dry unless PRWATCH_DRY_POST=0
  [[ -n ${PRWATCH_STUB_BIN:-} ]] && path=($PRWATCH_STUB_BIN $path)
fi
kill_strays() {
  emulate -L zsh; setopt extendedglob
  local -A par; local l a c="" x k cmd cwd; local -a anc q desc; local n=0 W=$HOME/prwatch/work
  for l in ${(f)"$(ps -axo pid=,ppid=)"}; do l=${l## #}; par[${l%% *}]=${${l##* }## #}; done
  a=$$
  while [[ -n ${par[$a]:-} && $a != 1 ]]; do
    anc+=$a
    [[ "$(ps -p $a -o command= 2>/dev/null)" == (|*/)claude(| *) ]] && { c=$a; break; }
    a=${par[$a]}
  done
  [[ -n $c ]] || { print "killed_strays=0"; return 0; }
  q=($c)
  while (( $#q )); do x=$q[1]; shift q; for k in ${(k)par}; do [[ ${par[$k]} == $x ]] && { q+=$k; desc+=$k; }; done; done
  for k in $desc; do
    (( ${anc[(Ie)$k]} )) && continue
    cmd=$(ps -p $k -o command= 2>/dev/null); cwd=$(lsof -a -d cwd -p $k -Fn 2>/dev/null | sed -n 's/^n//p')
    [[ $cmd == *$W/* || $cwd == $W(|/*) ]] || continue
    kill -TERM $k 2>/dev/null && (( n++ ))
  done
  print -r -- "killed_strays=$n"
}
die() { print -r -- "prwatch-post: $2"; exit $1; }
typeset -A a; stale=0
while (( $# )); do case $1 in
  --repo|--pr|--sha|--event|--body-sha|--tech) a[$1]=${2:-}; shift 2;;
  --allow-stale) stale=1; shift;; --dry-run) DRY=1; shift;; *) die 64 "unknown argument";; esac; done
repo=${a[--repo]:-}; n=${a[--pr]:-}; sha=${a[--sha]:-}; ev=${a[--event]:-}; bsha=${a[--body-sha]:-}; tech=${a[--tech]:-no}
[[ $repo == [A-Za-z0-9._-]## && $n == [0-9]## && $sha == [0-9a-f](#c40) && $bsha == [0-9a-f](#c12) ]] || die 64 "bad arguments"
[[ $ev == (request-changes|approve|comment) && $tech == (yes|no) ]] || die 64 "bad event/tech"
key="ACT-Training/$repo#$n"; R="ACT-Training/$repo"
# 1. session + double-post checks
[[ "$(jq -r .session_id $S/session.lock 2>/dev/null)" == "${PRWATCH_SESSION_ID:-x}" ]] || die 6 "superseded: another watcher window owns the state"
st=$(jq -r --arg k "$key" '.prs[$k].status // ""' $S/state.json); psha=$(jq -r --arg k "$key" '.prs[$k].posted_sha // ""' $S/state.json)
[[ $st == posted && $psha == $sha ]] && die 7 "already posted for this commit"
dir=$(jq -r --arg k "$key" '.prs[$k].archive // ""' $S/state.json)
[[ -n $dir && $dir != *..* && ( $dir == $HOME/Documents/vision-reviews/* || ( -n ${PRWATCH_TESTMODE:-} && $dir == $PRW/test/* ) ) ]] || die 64 "archive path not recognised"
[[ -s $dir/draft/review-body.md ]] || die 64 "missing draft"
# 2. snapshot exactly what will be posted; it must be what Jack was shown
mkdir -p $dir/post; snap=$dir/post/body-as-posted.md; cp $dir/draft/review-body.md $snap
h=$(shasum -a 256 $snap | cut -c1-12); [[ $h == $bsha ]] || die 8 "draft changed since you saw it (fingerprint $h, expected $bsha) - not posting"
if [[ $tech == yes ]]; then cp $dir/draft/technical-detail.md $dir/post/tech-as-posted.md 2>/dev/null || die 64 "no technical detail file"; fi
# 3. hidden-content checks: line 1 must BE the marker; no other HTML comment; no invisible/bidi chars; no /bot lines
head -1 $snap | grep -Eqx '<!-- prwatch round=[0-9]+ sha=[0-9a-f]{7} -->' || die 9 "first line must be the prwatch marker only"
tail -n +2 $snap | grep -q '<!--' && die 9 "body contains an HTML comment"
perl -CSD -ne 'exit 1 if /[\x{200B}-\x{200F}\x{202A}-\x{202E}\x{2066}-\x{2069}\x{FEFF}]/' $snap || die 9 "body contains invisible/bidi characters"
grep -q '^/' $snap && die 9 "body has a line starting with / (possible bot command) - edit it or say 'edited'"
(( $(wc -c < $snap) <= 65000 )) || die 9 "body too long"
mentions=$(grep -oE '@[A-Za-z0-9_-]+(/[A-Za-z0-9_-]+)?' $snap | sort -u | tr '\n' ' ')
links=$(grep -oE 'https?://[^ )>]+' $snap | sort -u | head -5 | tr '\n' ' ')
# 4. live PR check (dry run reports, doesn't fail, so merged fixtures work)
export GH_CONFIG_DIR=$HOME/.config/gh
pv=$(gh pr view $n -R $R --json state,headRefOid 2>/dev/null) || die 10 "could not read the PR from GitHub"
pst=$(jq -r .state <<<$pv); head=$(jq -r .headRefOid <<<$pv); note=""
[[ $pst == OPEN ]] || { [[ -n $DRY ]] && note="(PR is $pst - dry run)" || die 3 "PR is $pst"; }
[[ $head == $sha || $stale == 1 ]] || { [[ -n $DRY ]] && note="$note (head moved - dry run)" || die 4 "PR changed since review (head ${head[1,7]})"; }
# 5. no PR-controlled process may be alive while the dialog is up
kill_strays >/dev/null
# 6. Jack's own confirmation, outside Claude (Cancel default; gives up after 14 min, inside the 20-min Bash timeout)
label=${${ev:u}//-/ }
print -r -- "A Mac dialog 'PR Watcher - confirm post' is opening. Click Post to publish (Enter cancels). If you can't see it, Cmd-Tab to 'osascript'."
while :; do
  msg="Post ${label} on $repo #$n?  ${note}
Reviewed commit ${sha[1,7]} - PR head now ${head[1,7]}
Body: $(wc -l < $snap | tr -d ' ') lines, fingerprint $h$( [[ $tech == yes ]] && print -n ' + technical-detail comment')
Mentions: ${mentions:-none}
Links: ${links:-none}

$(head -c 600 $snap | LC_ALL=C tr -d '\000-\010\013-\037')"
  ans=$(osascript -e 'on run argv' -e 'try' \
    -e 'set r to display dialog (item 1 of argv) with title "PR Watcher - confirm post" buttons {"Cancel", "Show full text", "Post"} default button "Cancel" cancel button "Cancel" with icon caution giving up after 840' \
    -e 'on error number -128' -e 'return "Cancel"' -e 'end try' \
    -e 'if gave up of r then return "Timeout"' -e 'return button returned of r' -e 'end run' -- "$msg" 2>/dev/null)
  case $ans in
    Post) break;;
    "Show full text") open -e $snap;;
    *) print -r -- "Not posted (${ans:-Cancel})."; jq -n --arg a "${ans:-Cancel}" '{result:"not_posted",answer:$a}' > $dir/post/last-attempt.json; exit 11;;
  esac
done
# 7. post exactly the snapshot
if [[ -n $DRY ]]; then
  print -r -- "DRY RUN: gh pr review $n -R $R --$ev --body-file $snap (tech=$tech)" | tee $dir/post/dry-run.txt
  $PRW/bin/prwatch-state.sh set "$key" skipped dry_run=1 >/dev/null     # leaves the test PR non-asking
  exit 0
fi
gh pr review $n -R $R --$ev --body-file $snap >/dev/null || die 12 "gh pr review failed - nothing else posted"
[[ $tech == yes ]] && { gh pr comment $n -R $R --body-file $dir/post/tech-as-posted.md >/dev/null || print "Review posted; technical-detail comment FAILED."; }
url=$(gh api "repos/$R/pulls/$n/reviews" --jq '[.[]|select(.user.login=="JackScammell")]|last|.html_url' 2>/dev/null)
jq -n --arg e $ev --arg s $sha --arg h $h --arg u "$url" --arg t "$(date -Iseconds)" '{event:$e,sha:$s,body_sha:$h,url:$u,at:$t}' > $dir/post/receipt.json
$PRW/bin/prwatch-state.sh set "$key" posted posted_sha=$sha posted_event=$ev >/dev/null
$PRW/bin/prwatch-cleanup.sh "$key"
print -r -- "Posted: ${${url:#null}:-(link not found - check the PR page)}"
