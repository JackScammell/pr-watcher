#!/bin/zsh
# prwatch-prep.sh <key> <sha40> <round>  → prints the archive dir. Unsandboxed (excludedCommands); ALL network is here.
# <key> is <owner>/<repo>#<n>; every path (repo clone, worktrees, archive) is built from its parts by prwatch-common.zsh.
# Checks the session first (nothing else is done if it fails): 27 = window closed for new reviews (7 h 30 after the
# launcher's started_epoch), 25 = session, login or repo precondition failed (another session's lock, no started_epoch,
# unreadable state, no login, "repo not allowed" - repo_allowed in prwatch-common.zsh, checked before any network).
# 20-23 = clone/fetch problems below. 64 = bad arguments.
# Call with Bash timeout 2400000 (first clone + restore can take many minutes).
NODE_BIN=( "$HOME/Library/Application Support/Herd/config/nvm/versions/node/"*/bin(N-/nOn) ); NODE_BIN=${NODE_BIN[1]:-}
[[ -z "${PRWATCH_CLEAN:-}" ]] && exec /usr/bin/env -i HOME="$HOME" PATH="/opt/homebrew/bin:/usr/local/share/dotnet:${NODE_BIN:+$NODE_BIN:}/usr/bin:/bin" \
  LANG=en_GB.UTF-8 ${TZ:+TZ=$TZ} PRWATCH_CLEAN=1 ${${(f)"$(/usr/bin/env | /usr/bin/grep '^PRWATCH_')"}:#} /bin/zsh "$0" "$@"
emulate -L zsh; set -u; setopt extendedglob
PRW=$HOME/prwatch; source $PRW/bin/prwatch-common.zsh
S=$PRW/state; A=$HOME/Documents/vision-reviews; GITBASE=https://github.com
if [[ -n ${PRWATCH_TESTMODE:-} ]]; then
  S=${PRWATCH_STATE_DIR:-$PRW/test/state}; A=${PRWATCH_ARCHIVE_DIR:-$PRW/test/archive}; GITBASE=${PRWATCH_GIT_BASE:-$GITBASE}
  [[ -n ${PRWATCH_STUB_BIN:-} ]] && path=($PRWATCH_STUB_BIN $path)
fi
beat() { touch $PRW/state/activity 2>/dev/null; }          # watchdog heartbeat during long steps
key=${1:-}; sha=${2:-}; round=${3:-}
okkey "$key" && [[ $sha == [0-9a-f](#c40) && $round == [0-9]## ]] || { print "bad arguments"; exit 64; }
key_split $key; R=$o/$repo
# The 7 h 30 start window is enforced here, not by the model: a council's archive and worktrees come only from prep.
# Test mode from a plain Terminal (README T2) has no session and checks nothing.
if [[ -z ${PRWATCH_TESTMODE:-} || -n ${PRWATCH_SESSION_ID:-} ]]; then
  $PRW/bin/prwatch-state.sh check >/dev/null || { print "could not read state"; exit 25; }
  [[ "$(jq -r .session_id $S/session.lock 2>/dev/null)" == "${PRWATCH_SESSION_ID:-x}" ]] || { print "superseded"; exit 25; }
  oklogin "${PRWATCH_LOGIN:-}" || { print "no login"; exit 25; }
  se=$(started_epoch $S) || { print "no session start"; exit 25; }
  now=$(now_epoch) || { print -r -- "$now"; exit 64; }
  (( now - se < START_LIMIT )) || { print "window closed for new reviews"; exit 27; }
fi
# the source gate, in every mode: a repo Jack has not allowed (or has blocked) is never cloned or fetched
repo_allowed $S/state.json $R || { print "repo not allowed"; exit 25; }
export GH_CONFIG_DIR=$HOME/.config/gh
# git hardening: watcher-owned global config (gh credential helper only), no system config, no hooks, no fsmonitor
export GIT_CONFIG_GLOBAL=$PRW/config/gitconfig GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
G=(git -c core.hooksPath=/dev/null -c core.fsmonitor=false)
d0=$A/$(archive_name $key $round); dir=$d0; for sfx in b c d e f g; do [[ -e $dir ]] || break; dir=$d0-$sfx; done
mkdir -p $dir/{input,reviews,draft,post,input/linked-issues}
src=$PRW/repos/${o}__${repo}; wt=$PRW/work/$(wt_name $key $sha); bw=$wt-build
beat
[[ -d $src ]] || $G clone --quiet --no-checkout $GITBASE/${o}/${repo}.git $src || { print "clone failed"; exit 20; }     # FULL clone: sandboxed readers can't lazy-fetch
base=$(gh pr view $n -R $R --json baseRefName -q .baseRefName) || exit 21
beat
$G -C $src fetch --quiet origin "+refs/pull/$n/head:refs/prwatch/pr-$n" "+refs/heads/${base}:refs/remotes/origin/${base}" || exit 22
[[ $($G -C $src rev-parse refs/prwatch/pr-$n) == $sha ]] || { print "head moved during prep"; exit 23; }
base_sha=$($G -C $src rev-parse refs/remotes/origin/$base)
[[ -d $wt ]] || $G -C $src worktree add --quiet --detach $wt $sha
# fresh standalone copy every prep (agents may have written to the last one); point its origin/<base> at the fresh base
rm -rf -- $bw
$G clone --quiet --shared --no-checkout $src $bw && $G -C $bw checkout --quiet --detach $sha && $G -C $bw update-ref refs/remotes/origin/$base $base_sha
print -l .local/ .pw-venv/ node_modules/ >> $bw/.git/info/exclude          # tool droppings must not dirty the mutation baseline
# PR data (agents and the orchestrator never call gh)
gh pr view $n -R $R --json number,title,body,author,baseRefName,headRefName,headRefOid,files,labels,closingIssuesReferences > $dir/input/pr.json
gh api "repos/$R/issues/$n/comments" --paginate > $dir/input/comments.json
gh api "repos/$R/pulls/$n/reviews" --paginate > $dir/input/reviews.json
gh api "repos/$R/pulls/$n/comments" --paginate > $dir/input/review-comments.json
gh pr checks $n -R $R --json name,state,link > $dir/input/checks.json 2>/dev/null
$G -C $src diff origin/$base...$sha > $dir/input/diff.patch
$G -C $src log --no-merges --format='%H%x09%an%x09%s' origin/$base..$sha > $dir/input/commits.txt
behind=$($G -C $src rev-list --count $sha..origin/$base)
print -r -- "behind_base=$behind"$'\n'"base=$base"$'\n'"base_sha=$base_sha" > $dir/input/base-merge.txt
# linked issues: #N in body, commit subjects, and added lines of non-style files (skips #333333-style colours); cap 15
added=$(awk '/^\+\+\+ b\//{f=$0} /^\+[^+]/{ if (f !~ /\.(s?css|less|html|svg)$/) print }' $dir/input/diff.patch)
refs=( ${(u)${(f)"$( { jq -r .body $dir/input/pr.json; cut -f3 $dir/input/commits.txt; print -r -- $added; } | grep -oE '(^|[[:space:](])#[0-9]{1,5}([^0-9A-Za-z]|$)' | grep -oE '[0-9]+' | head -15)"}:#} )
for i in $refs; do [[ $i == $n ]] && continue
  gh issue view $i -R $R --json number,title,state,stateReason,body,comments,closedByPullRequestsReferences > $dir/input/linked-issues/$i.json 2>/dev/null || rm -f $dir/input/linked-issues/$i.json; done
# round >= 2: delta (no merges, excluding base) + remerge-diff for base merges
last=$(jq -r --arg k "$R#$n" '.prs[$k].last_reviewed_sha // ""' $S/state.json 2>/dev/null)
if [[ -n $last ]]; then
  if $G -C $src merge-base --is-ancestor $last $sha 2>/dev/null; then
    $G -C $src log -p --no-merges $last..$sha "^origin/$base" > $dir/input/delta.patch
    for m in ${(f)"$($G -C $src rev-list --merges $last..$sha)"}; do [[ -n $m ]] && $G -C $src show --remerge-diff $m >> $dir/input/merge-remerge.txt; done
  else print "force-pushed or rebased: full review; previous findings in prior-review.md" > $dir/input/delta.patch; fi
  jq -r --arg me "${PRWATCH_LOGIN:-}" '[.[]|select(.user.login==$me and (.body|length)>0)]|last|.body // ""' $dir/input/reviews.json > $dir/input/prior-review.md
fi
# stack profile (drives angles and build recipe)
files=$(jq -r '.files[].path' $dir/input/pr.json)
# Jack's answer 5 (2026-09-29): Laravel repos (composer.json requires laravel/framework) need Flux Pro credentials to
# install, which the locked-down restore must never see → static council only, no prebuild, no testing-build angle.
laravel=$($G -C $src show "$sha:composer.json" 2>/dev/null | jq -e '(.require // {}) | has("laravel/framework")' >/dev/null 2>&1 && print true || print false)
has() { print -r -- $files | grep -Eq "$1" && print true || print false; }
hasi() { print -r -- $files | grep -Eiq "$1" && print true || print false; }     # case-insensitive, anchored at a path or word start: has_pii only (advisory until a consumer reads it)
jq -n --argjson dotnet $(has '\.(cs|csproj|sln)$') --argjson sql $(has '\.sql$|/Migrations/|database/migrations/') \
  --argjson pii $(hasi '(^|[/_.-])(learner|student|apprentice|employer|employee|staff|person|people|user|contact|parent|guardian|candidate|applicant|attendance|safeguard|ehcp|medical|disabilit|address|dob|birth|nino|national.?insurance|uln|email|phone|payroll|salary)') \
  --argjson angular $(has '(^|/)(frontend|learner)/|\.component\.(ts|html)$|src/app/') --argjson php $(has '\.php$') --argjson python $(has '\.py$') \
  --argjson frontend $(has '(^|/)(frontend|learner)/|\.(ts|html|scss|vue|tsx|jsx)$|\.blade\.php$|resources/js/') \
  --argjson tests $(has '([Tt]ests?/|\.spec\.ts$|Tests?\.cs$|_test\.py$|test_.*\.py$)') \
  --argjson code $(has '\.(cs|csproj|sql|ts|html|scss|php|py|js|vue|tsx|jsx)$') \
  --argjson behind $behind --argjson laravel $laravel \
  '{has_dotnet:$dotnet,has_sql:$sql,has_angular:$angular,has_php:$php,has_python:$python,has_frontend:$frontend,has_tests:$tests,has_code:$code,has_pii:$pii,behind_base:$behind,is_laravel:$laravel}' > $dir/input/profile.json
# prebuild in the -build copy: dependency restore only, under a deny-by-default-for-home sandbox-exec profile
# PR code runs here (MSBuild props, lifecycle-free npm ci, pip): the session identity is kept out of its environment.
sbx() { env -u PRWATCH_LOGIN -u PRWATCH_LOCK_JSON -u GH_CONFIG_DIR sandbox-exec -p "$P" "$@"; }
mkdir -p $PRW/cache/{tmp,nuget,nuget-http,nuget-plugins,dotnet-home,npm}
export TMPDIR=$PRW/cache/tmp/ DOTNET_CLI_HOME=$PRW/cache/dotnet-home NUGET_PACKAGES=$PRW/cache/nuget \
       NUGET_HTTP_CACHE_PATH=$PRW/cache/nuget-http NUGET_PLUGINS_CACHE_PATH=$PRW/cache/nuget-plugins \
       DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 MSBUILDDISABLENODEREUSE=1 \
       DOTNET_CLI_USE_MSBUILD_SERVER=0 npm_config_cache=$PRW/cache/npm
P="(version 1)
(deny default)
(allow process*) (allow sysctl*) (allow mach*) (allow signal) (allow ipc*) (allow file-ioctl) (allow network*) (allow system*) (allow iokit*) (allow user-preference-read) (allow pseudo-tty)
(allow file-read*)
(allow file-read-metadata)
(deny file-read* (subpath \"/Users\") (subpath \"/private/tmp\") (subpath \"/private/var/folders\") (subpath \"/Library/Keychains\") (subpath \"/private/var/root\"))
(allow file-read* (subpath \"$bw\") (subpath \"$PRW/cache\") ${NODE_BIN:+(subpath \"${NODE_BIN:h}\")} (subpath \"/private/tmp/.dotnet\"))
(allow file-read-metadata)
(allow file-write* (subpath \"$bw\") (subpath \"$PRW/cache\") (subpath \"/private/tmp/.dotnet\") (literal \"/dev/null\") (literal \"/dev/tty\") (literal \"/dev/dtracehelper\"))"
if [[ $laravel == true ]]; then
  print "Laravel repo: prebuild skipped; tests NOT run (Laravel - Flux Pro credentials). Static council only." > $dir/input/prebuild.log
else
{
  beat
  if [[ $(jq .has_dotnet $dir/input/profile.json) == true ]]; then
    for f in ${(f)"$(cd $bw && $G ls-files '*appsettings.cd-template.json' 2>/dev/null)"}; do d=${f:h}
      for s in appsettings.json appsettings.Development.json appsettings.Production.json; do
        (cd $bw && $G ls-files --error-unmatch $d/$s >/dev/null 2>&1) || [[ -e $bw/$d/$s ]] || print '{}' > $bw/$d/$s; done; done
    slns=( ${(f)"$(cd $bw && $G ls-files '*.sln' | grep -v '^database/')"} )      # Vision: api/VisionApi.sln (skip SQL project)
    for s in $slns; do (cd $bw && sbx dotnet restore "$s" -m:1); done   # -m:1: MSBuild worker nodes bind a pipe under /tmp, which the profile denies -> endless node retries (BUILD-NOTES)
    print -r -- "dotnet_solutions=${(j:,:)slns}" >> $dir/input/base-merge.txt
  fi
  beat
  if [[ -f $bw/package-lock.json ]] && jq -e '.workspaces' $bw/package.json >/dev/null 2>&1; then
    (cd $bw && sbx npm ci --ignore-scripts --no-audit --no-fund)        # npm workspaces root (Vision: frontend, learner, packages/*)
  else
    for app in frontend learner; do [[ -f $bw/$app/package-lock.json ]] && (cd $bw/$app && sbx npm ci --ignore-scripts --no-audit --no-fund); done
  fi
  beat
  if [[ $(jq .has_python $dir/input/profile.json) == true ]]; then
    sbx /usr/bin/python3 -m venv $bw/.pw-venv && sbx $bw/.pw-venv/bin/pip install -q requests keyring
  fi
} > $dir/input/prebuild.log 2>&1 || print "prebuild had errors (see above)" >> $dir/input/prebuild.log
fi
beat
print -r -- $dir
