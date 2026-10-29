#!/bin/zsh
# prwatch-notify.sh <kind> <ref>  — fixed templates + state; untrusted text only ever passed as argv.
[[ -z "${PRWATCH_CLEAN:-}" ]] && exec /usr/bin/env -i HOME="$HOME" ${TZ:+TZ=$TZ} PATH=/usr/bin:/bin LANG=en_GB.UTF-8 PRWATCH_CLEAN=1 \
  ${${(f)"$(/usr/bin/env | /usr/bin/grep '^PRWATCH_')"}:#} /bin/zsh "$0" "$@"
emulate -L zsh; set -u; setopt extendedglob
PRW=$HOME/prwatch; S=$PRW/state
if [[ -n ${PRWATCH_TESTMODE:-} ]]; then S=${PRWATCH_STATE_DIR:-$PRW/test/state}; [[ -n ${PRWATCH_STUB_BIN:-} ]] && path=($PRWATCH_STUB_BIN $path); fi
kind=${1:-}; ref=${2:-}
[[ $kind == (decision|question|stuck|error|eod|test) ]] || exit 64
[[ $ref == [A-Za-z0-9._#/-]## ]] || exit 64
clean() { print -r -- "$1" | LC_ALL=C tr -cd 'A-Za-z0-9 .,:#()_-' | cut -c1-${2:-60}; }
rec() { jq -r --arg k "$ref" ".prs[\$k].$1 // \"\"" "$S/state.json" 2>/dev/null; }
short=$ref                                         # the full key: the owner matters now that the inbox spans organisations
case $kind in
  decision) arch=$(rec archive); title=""; [[ -n $arch && -f $arch/input/pr.json ]] && title=$(jq -r '.title // ""' "$arch/input/pr.json" 2>/dev/null)
            sub=$short; snd=Glass
            msg="$(clean "$title") - reviewers suggest $(clean "$(rec recommendation)" 20) ($(clean "$(rec blockers)" 3) blockers). Your call: switch to Terminal, PR watcher window." ;;
  question) sub=$short; snd=Glass; msg="The watcher has a question for you. Switch to Terminal, PR watcher window." ;;
  stuck)    sub="Waiting on you"; snd=Funk; msg="No activity for 30+ min - the PR watcher window is probably waiting on a permission prompt or dialog." ;;
  error)    sub="Problem"; snd=Basso
            case $ref in
              gh_auth)       msg="GitHub login expired or missing - run gh auth login in Terminal.";;
              session-ended) msg="The PR watcher stopped before the end of its session - double-click PR Watcher to restart.";;
              superseded)    msg="This watcher window was replaced by a newer one. Please close this old window (it can't finish or post anything).";;
              launcher)      msg="PR Watcher could not start - see its Terminal window.";;
              harness)       msg="Reviewers ran in the background (Claude Code update?). Review stopped and the watcher is off for this session - see the window.";;
              hookdrift)     msg="Claude Code changed how it reports subagents - the background-agent check may not work. Check before relying on the watcher.";;
              state)         msg="The watcher can't read its state file (state/state.json) - no reviews will start. See the window.";;
              *)             msg="Problem: $(clean "$ref") - see the PR watcher window.";;
            esac ;;
  eod)      sub="Session summary"; snd=""; msg=$(clean "$ref" 80) ;;
  test)     sub="Test"; snd=Glass; msg="Test notification with a \"quote\" and it's fine." ;;
esac
mkdir -p "$S/notify-throttle"; t="$S/notify-throttle/$kind-${ref//[^A-Za-z0-9]/_}"
if [[ $kind != (decision|test) && -f $t ]] && (( $(date +%s) - $(stat -f %m $t) < 1800 )); then exit 0; fi
touch $t
print -r -- "$(date -Iseconds) $kind $ref :: $msg" >> "$S/notify.log"
if [[ -n $snd ]]; then
  osascript -e 'on run argv' \
    -e 'display notification (item 2 of argv) with title "PR Watcher" subtitle (item 1 of argv) sound name (item 3 of argv)' \
    -e 'end run' -- "$sub" "$msg" "$snd" >/dev/null
else
  osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title "PR Watcher" subtitle (item 1 of argv)' \
    -e 'end run' -- "$sub" "$msg" >/dev/null
fi
