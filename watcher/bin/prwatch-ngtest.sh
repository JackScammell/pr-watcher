#!/bin/zsh
# prwatch-ngtest.sh <key> <app> [<spec-dir>]  — Angular/Karma tests for testing-build, fully automatic (allow rule,
# excluded from Claude's sandbox) because Chrome cannot run inside Claude Code's sandbox (it must register Mach
# services). Instead the whole run is confined by THIS script's own sandbox-exec profile:
#   reads: everything except /Users, /private/tmp, /private/var/folders, keychains — back in: the build copy, node,
#          chrome-headless-shell and a private per-run dir;  writes: the build copy + the private dir only;
#   network: loopback only (Karma) — no remote hosts;  Chrome runs --no-sandbox (its inner sandbox cannot nest in
#   sandbox-exec; Jack's decision 2026-09-29, docs/fix-sandbox-tests.md) — the outer profile confines it.
#   app: frontend | learner      spec-dir: optional folder under <app>/ for mutation runs, e.g. src/app/foo
#   (the script adds /**/*.spec.ts; plain path only — the guard forbids globs in arguments)
# Exit: 0 all specs passed · 1 specs failed · 2 could not start / timed out · 6 superseded · 64 bad args · 65 no state
# Log: <archive>/reviews/ng-test-<app>.log (untrusted PR output). Call with Bash timeout 2400000.
NODE_BIN=( "$HOME/Library/Application Support/Herd/config/nvm/versions/node/"*/bin(N-/nOn) ); NODE_BIN=${NODE_BIN[1]:-}
[[ -z "${PRWATCH_CLEAN:-}" ]] && exec /usr/bin/env -i HOME="$HOME" PATH="${NODE_BIN:+$NODE_BIN:}/usr/bin:/bin" \
  LANG=en_GB.UTF-8 PRWATCH_CLEAN=1 NODE_BIN="$NODE_BIN" ${${(f)"$(/usr/bin/env | /usr/bin/grep '^PRWATCH_')"}:#} /bin/zsh "$0" "$@"
emulate -L zsh; set -u; setopt extendedglob nullglob
PRW=$HOME/prwatch; S=$PRW/state; LIMIT=1500                     # seconds before the whole run is killed
[[ -n ${PRWATCH_TESTMODE:-} ]] && S=${PRWATCH_STATE_DIR:-$PRW/test/state}
key=${1:-}; app=${2:-}; inc=${3:-}
[[ $key == ACT-Training/[A-Za-z0-9._-]##\#[0-9]## && $app == (frontend|learner) ]] || { print "bad arguments"; exit 64; }
[[ -z $inc || $inc == [A-Za-z0-9/._-]## && $inc != *..* && $inc != /* ]] || { print "bad spec-dir"; exit 64; }
[[ "$(jq -r .session_id $S/session.lock 2>/dev/null)" == "${PRWATCH_SESSION_ID:-x}" ]] || { print superseded; exit 6; }
sha=$(jq -r --arg k $key '.prs[$k].sha // ""' $S/state.json); arch=$(jq -r --arg k $key '.prs[$k].archive // ""' $S/state.json)
[[ $sha == [0-9a-f](#c40) && -d $arch ]] || { print "no state for $key"; exit 65; }
[[ "$(jq -r '.is_laravel // false' $arch/input/profile.json 2>/dev/null)" == true ]] && { print "Laravel: not run"; exit 64; }
k=${key#ACT-Training/}; bw=$PRW/work/${k%%\#*}-pr${k##*\#}-${sha[1,7]}-build
[[ -f $bw/$app/karma.conf.js && -n $NODE_BIN ]] || { print "no $app karma config or node"; exit 65; }
bw=${bw:A}; NB=${NODE_BIN:A}
HS=( $HOME/.cache/puppeteer/chrome-headless-shell/*/chrome-headless-shell-mac*/chrome-headless-shell(N-*nOn) ); HS=${HS[1]:-}
[[ -n $HS ]] || { print "chrome-headless-shell not found in ~/.cache/puppeteer (Jack: npx @puppeteer/browsers install chrome-headless-shell)"; exit 2; }
HS=${HS:A}; HSROOT=${HS:h:h:h}                                  # …/chrome-headless-shell (every installed version)
[[ -n ${PRWATCH_TESTMODE:-} ]] && LIMIT=${PRWATCH_NGTEST_LIMIT:-$LIMIT}
T=${PRW:A}/cache/ngtest/${bw:t}-$app; rm -rf $T; mkdir -p $T/tmp; log=$arch/reviews/ng-test-$app.log
# Karma listens on 9876 (next free port if busy) and karma-chrome-launcher's headless Chrome on 9222; outbound
# loopback is limited to those, so PR code can't talk to Jack's local MySQL, nginx sites or IDE helpers.
profile() { cat <<EOF
(version 1)
(deny default)
(allow process* signal sysctl* mach* ipc* iokit* system-socket pseudo-tty file-ioctl)
(deny mach-lookup (global-name "com.apple.pasteboard.1") (global-name "com.apple.cfprefsd.daemon") (global-name "com.apple.cfprefsd.agent"))
(allow file-read-metadata)
(allow file-read*)
(deny file-read* (subpath "/Users") (subpath "/private/tmp") (subpath "/private/var/folders") (subpath "/Library/Keychains") (subpath "/private/var/root"))
(allow file-read* (subpath "$bw") (subpath "${NB:h}") (subpath "$HSROOT") (subpath "$T"))
(allow file-write* (subpath "$bw") (subpath "$T") (literal "/dev/null") (literal "/dev/tty") (literal "/dev/dtracehelper"))
(allow network-bind network-inbound (local ip "localhost:*"))
(allow network-outbound (remote ip "localhost:9876") (remote ip "localhost:9877") (remote ip "localhost:9878") (remote ip "localhost:9879") (remote ip "localhost:9222"))
(allow network-bind network-inbound network-outbound (local unix-socket (subpath "$T")) (remote unix-socket (subpath "$T")))
EOF
}
[[ -n ${PRWATCH_TESTMODE:-} && -n ${PRWATCH_NGTEST_PRINT:-} ]] && { profile; exit 0; }   # tests inspect the profile
# 0 passed · 1 specs failed/errored · 2 nothing usable ran (never started, 0 specs, disconnected, timed out)
verdict() { [[ $1 == Executed\ ([1-9][0-9]#)\ of* ]] || return 2
  [[ $1 == *FAILED* || $1 == *ERROR* ]] && return 1; [[ $1 == *\ SUCCESS* ]] && return 0; return 2; }
summary() { sed $'s/\x1b\\[[0-9;]*[A-Za-z]//g' $1 | grep -Eo 'Executed [0-9]+ of [0-9]+[^)]*\)?( ERROR| SUCCESS| FAILED)?' | tail -1; }
[[ -n ${PRWATCH_TESTMODE:-} && -n ${PRWATCH_NGTEST_VERDICT:-} ]] && { verdict "$PRWATCH_NGTEST_VERDICT"; exit $?; }
[[ -n ${PRWATCH_TESTMODE:-} && -n ${PRWATCH_NGTEST_SUMMARY:-} ]] && { summary $PRWATCH_NGTEST_SUMMARY; exit 0; }
profile > $T/profile.sb
print -r -- "#!/bin/sh"$'\n'"exec \"$HS\" --no-sandbox --disable-gpu --disable-dev-shm-usage --disable-crash-reporter --no-first-run \"\$@\"" > $T/chrome
chmod +x $T/chrome
incarg=(); [[ -n $inc ]] && incarg=("--include=${inc%/}/**/*.spec.ts")   # quoted: a glob for Karma, not for zsh
run=($NB/npx ng test --watch=false --browsers=ChromeHeadless "${incarg[@]}")
[[ -n ${PRWATCH_TESTMODE:-} && -n ${PRWATCH_NGTEST_FAKE:-} ]] && run=(/bin/sh -c "$PRWATCH_NGTEST_FAKE")   # tests only
pid=0 wd=0
sweep() {                                        # nothing started by the run may outlive it, even if it left the group
  (( pid )) && kill -KILL -$pid 2>/dev/null; (( wd )) && kill $wd 2>/dev/null
  local p; for p in ${(f)"$( { /usr/bin/pgrep -f "$bw/" ; /usr/sbin/lsof -d cwd -Fpn 2>/dev/null | awk -v w="$bw/" '/^p/{p=substr($0,2)} /^n/{if(index(substr($0,2)"/",w)==1)print p}'; } | sort -u)"}; do
    [[ $p == <-> && $p != $$ ]] && kill -KILL $p 2>/dev/null; done; }
trap 'sweep; print "ng test $app: interrupted"; exit 2' INT TERM HUP
touch $PRW/state/activity 2>/dev/null
( cd $bw/$app && exec /usr/bin/perl -e 'setpgrp(0,0); exec @ARGV or die' /usr/bin/env -i HOME=$T PATH="$NB:/usr/bin:/bin" \
    TMPDIR=$T/tmp CHROME_BIN=$T/chrome LANG=en_GB.UTF-8 NG_CLI_ANALYTICS=false \
    /usr/bin/sandbox-exec -f $T/profile.sb "${run[@]}" ) > $log 2>&1 &
pid=$!
/usr/bin/perl -e '$SIG{TERM}=sub{exit 0}; sleep shift; open(F,">",shift); close F; kill "KILL", -shift' $LIMIT $T/timed-out $pid &
wd=$!
wait $pid; rc=$?; sweep
touch $PRW/state/activity 2>/dev/null
if [[ -e $T/timed-out ]]; then print "ng test $app: timed out after ${LIMIT}s · log: $log"; exit 2; fi
sum=$(summary $log)
print -r -- "ng test $app: ${sum:-no summary} (exit $rc) · log: $log"
verdict "$sum"; v=$?                              # judged by Karma's summary: coverage thresholds can fail a green run
if (( v == 0 )); then exit 0
elif (( v == 1 )); then exit 1
else sed $'s/\x1b\\[[0-9;]*[A-Za-z]//g' $log | grep -Ei 'Cannot start|FATAL|Disconnected|ERROR \[' | tail -3; exit 2; fi
