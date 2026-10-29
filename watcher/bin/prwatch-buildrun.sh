#!/bin/zsh
# prwatch-buildrun.sh <key> <recipe> [<probe-id>]  — Jack-approved, UNSANDBOXED run in the -build copy.
# Behind an `ask` rule AND its own macOS dialog; recipes are fixed here. Call with Bash timeout 2400000.
#   recipe: dotnet-test | ng-test | ng-probe | dotnet-probe | python-unittest
#   *-probe applies <archive>/reviews/probes/<probe-id>.patch (written by testing-build); its first line is "# run: <filter>"
NODE_BIN=( "$HOME/Library/Application Support/Herd/config/nvm/versions/node/"*/bin(N-/nOn) ); NODE_BIN=${NODE_BIN[1]:-}
[[ -z "${PRWATCH_CLEAN:-}" ]] && exec /usr/bin/env -i HOME="$HOME" PATH="/opt/homebrew/bin:/usr/local/share/dotnet:${NODE_BIN:+$NODE_BIN:}/usr/bin:/bin" \
  LANG=en_GB.UTF-8 PRWATCH_CLEAN=1 ${${(f)"$(/usr/bin/env | /usr/bin/grep '^PRWATCH_' | /usr/bin/grep -v -e '^PRWATCH_LOGIN=' -e '^PRWATCH_LOCK_JSON=')"}:#} /bin/zsh "$0" "$@"
# PR code runs under this script: PRWATCH_LOGIN and PRWATCH_LOCK_JSON are filtered out of the re-exec above on purpose.
emulate -L zsh; set -u; setopt extendedglob
PRW=$HOME/prwatch; source $PRW/bin/prwatch-common.zsh
S=$PRW/state
if [[ -n ${PRWATCH_TESTMODE:-} ]]; then S=${PRWATCH_STATE_DIR:-$PRW/test/state}; [[ -n ${PRWATCH_STUB_BIN:-} ]] && path=($PRWATCH_STUB_BIN $path); fi
key=${1:-}; recipe=${2:-}; probe=${3:-}
okkey "$key" && [[ $recipe == (dotnet-test|ng-test|ng-probe|dotnet-probe|python-unittest) ]] || exit 64
[[ $recipe == *-probe ]] && { [[ $probe == [a-z0-9-]## ]] || exit 64; }
[[ "$(jq -r .session_id $S/session.lock 2>/dev/null)" == "${PRWATCH_SESSION_ID:-x}" ]] || { print superseded; exit 6; }
sha=$(jq -r --arg k $key '.prs[$k].sha // ""' $S/state.json); arch=$(jq -r --arg k $key '.prs[$k].archive // ""' $S/state.json)
[[ $sha == [0-9a-f](#c40) && -d $arch ]] || { print "no state for $key"; exit 65; }
bw=$PRW/work/$(wt_name $key $sha)-build; [[ -d $bw ]] || exit 65
sln=$(sed -n 's/^dotnet_solutions=//p' $arch/input/base-merge.txt | cut -d, -f1)
filter=""; patchinfo=""
if [[ $recipe == *-probe ]]; then
  p=$arch/reviews/probes/$probe.patch; [[ -s $p ]] || exit 64
  filter=$(head -1 $p | sed -n 's/^# run: //p'); [[ $filter == [A-Za-z0-9*./_~=-]# ]] || { print "bad run filter"; exit 64; }
  patchinfo="Applies probe $probe ($(wc -l < $p | tr -d ' ') lines; files: $(grep '^+++ b/' $p | cut -c7- | tr '\n' ' ')) to the throwaway copy. "
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
kill_strays >/dev/null
ans=$(osascript -e 'on run argv' -e 'try' \
  -e 'set r to display dialog (item 1 of argv) with title "PR Watcher - run PR code outside the sandbox?" buttons {"Cancel", "Run"} default button "Cancel" cancel button "Cancel" with icon caution giving up after 840' \
  -e 'on error number -128' -e 'return "Cancel"' -e 'end try' -e 'if gave up of r then return "Timeout"' -e 'return button returned of r' -e 'end run' \
  -- "${patchinfo}Run '$recipe' for $k (commit ${sha[1,7]}) on your Mac WITHOUT the sandbox? The PR's code will run as you, with network access." 2>/dev/null)
[[ $ans == Run ]] || { print "Not run (${ans:-Cancel})."; exit 11; }
log=$arch/input/unsandboxed-$recipe${probe:+-$probe}.log
export TMPDIR=$PRW/cache/tmp/ DOTNET_CLI_HOME=$PRW/cache/dotnet-home NUGET_PACKAGES=$PRW/cache/nuget DOTNET_NOLOGO=1 MSBUILDDISABLENODEREUSE=1
export CHROME_BIN="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" KARMA_PORT=9877
dn() { for tz in UTC Europe/London; do print "== TZ=$tz"; TZ=$tz dotnet test $sln --no-restore -p:UseAppHost=false ${filter:+--filter "$filter"}; done; }
ngrun() { for app in frontend learner; do [[ -d $bw/$app ]] || continue; print "== $app"
         (cd $bw && npm -w $app run test -- --watch=false --browsers=ChromeHeadless ${filter:+--include="$filter"}); done; }
{
  case $recipe in
    dotnet-test) (cd $bw && dn) ;;
    ng-test) ngrun ;;
    python-unittest) (cd $bw && PYTHONDONTWRITEBYTECODE=1 ${bw}/.pw-venv/bin/python -m unittest discover) ;;
    *-probe) (cd $bw && git apply --check $p && git apply $p) || { print "probe does not apply"; exit 66; }
             if [[ $recipe == dotnet-probe ]]; then (cd $bw && dn); else ngrun; fi
             (cd $bw && git checkout -- . && git clean -fdq -- frontend learner api) ;;
  esac
} > $log 2>&1; rc=$?
print -r -- "exit=$rc log=$log   (judge by spec/test results, not the exit code: Karma coverage thresholds can fail a green run)"
