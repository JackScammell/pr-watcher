#!/bin/zsh
# prwatch-dotnettest.sh <key> <project.csproj> <UTC|London> [<test-name>]  — `dotnet test` for testing-build, fully
# automatic (allow rule, excluded from Claude's sandbox) because Claude Code's sandbox refuses the domain-name sysctl
# (getdomainname → EPERM), so System.Net.CookieContainer — used by every WebApplicationFactory test client — cannot
# initialise and integration tests fail. The whole run is confined by THIS script's own sandbox-exec profile:
#   reads: everything except /Users, /private/tmp, /private/var/folders, keychains — back in: the build copy, the
#          watcher's NuGet cache and a private per-run dir;  writes: the build copy + the private dir only (plus
#          /private/tmp/.dotnet, where .NET keeps named-mutex shared memory — prep's profile allows it too);
#   network: loopback only (vstest's testhost port is random) minus well-known local service ports (MySQL, Postgres,
#   Redis, SQL Server, Mongo, RabbitMQ, memcached, nginx 80/443, PHP-FPM 9000, 8080) — no remote hosts;
#   clipboard/preferences blocked. (/private/tmp/.dotnet is hard-coded by .NET for named mutexes; TMPDIR doesn't move it.)
#   project: path of a *.csproj inside the build copy, e.g. api/VisionApi.IntegrationTests/VisionApi.IntegrationTests.csproj
#   test-name: optional, for mutation runs → --filter FullyQualifiedName~<test-name>
# Exit: 0 passed · 1 tests failed · 2 nothing usable ran (build error, aborted, 0 tests, timed out) · 6 superseded
#       · 64 bad args / Laravel · 65 no state / no such project.  Log: <archive>/reviews/dotnet-test-<name>-<tz>.log
# Call with Bash timeout 2400000.
[[ -z "${PRWATCH_CLEAN:-}" ]] && exec /usr/bin/env -i HOME="$HOME" PATH="/usr/local/share/dotnet:/usr/bin:/bin" \
  LANG=en_GB.UTF-8 PRWATCH_CLEAN=1 ${${(f)"$(/usr/bin/env | /usr/bin/grep '^PRWATCH_' | /usr/bin/grep -v -e '^PRWATCH_LOGIN=' -e '^PRWATCH_LOCK_JSON=')"}:#} /bin/zsh "$0" "$@"
# PR code runs under this script: PRWATCH_LOGIN and PRWATCH_LOCK_JSON are filtered out of the re-exec above on purpose.
emulate -L zsh; set -u; setopt extendedglob nullglob
PRW=$HOME/prwatch; source $PRW/bin/prwatch-common.zsh
S=$PRW/state; LIMIT=2100; DOTNET=/usr/local/share/dotnet       # seconds before the run is killed
[[ -n ${PRWATCH_TESTMODE:-} ]] && { S=${PRWATCH_STATE_DIR:-$PRW/test/state}; LIMIT=${PRWATCH_DTEST_LIMIT:-$LIMIT}; }
key=${1:-}; proj=${2:-}; tz=${3:-}; name=${4:-}
okkey "$key" && [[ $tz == (UTC|London) ]] || { print "bad arguments"; exit 64; }
[[ $proj == [A-Za-z0-9][A-Za-z0-9/._-]#.csproj && $proj != *..* ]] || { print "bad project (use a path relative to the build copy, e.g. api/X.Tests/X.Tests.csproj)"; exit 64; }
[[ -z $name || $name == [A-Za-z0-9._]## ]] || { print "bad test-name"; exit 64; }
[[ "$(jq -r .session_id $S/session.lock 2>/dev/null)" == "${PRWATCH_SESSION_ID:-x}" ]] || { print superseded; exit 6; }
sha=$(jq -r --arg k $key '.prs[$k].sha // ""' $S/state.json); arch=$(jq -r --arg k $key '.prs[$k].archive // ""' $S/state.json)
[[ $sha == [0-9a-f](#c40) && -d $arch ]] || { print "no state for $key"; exit 65; }
[[ "$(jq -r '.is_laravel // false' $arch/input/profile.json 2>/dev/null)" == true ]] && { print "Laravel: not run"; exit 64; }
bw=$PRW/work/$(wt_name $key $sha)-build
[[ -f $bw/$proj && -x $DOTNET/dotnet ]] || { print "no such project (or no dotnet)"; exit 65; }
bw=${bw:A}; NU=${PRW:A}/cache/nuget
pname=${${proj%.csproj}//\//_}; T=${PRW:A}/cache/dotnettest/${bw:t}-$pname-$tz; rm -rf $T; mkdir -p $T/tmp $T/home
log=$arch/reviews/dotnet-test-$pname-$tz.log
profile() { cat <<EOF
(version 1)
(deny default)
(allow process* signal sysctl* mach* ipc* iokit* system-socket pseudo-tty file-ioctl)
(deny mach-lookup (global-name "com.apple.pasteboard.1") (global-name "com.apple.cfprefsd.daemon") (global-name "com.apple.cfprefsd.agent"))
(allow file-read-metadata)
(allow file-read*)
(deny file-read* (subpath "/Users") (subpath "/private/tmp") (subpath "/private/var/folders") (subpath "/Library/Keychains") (subpath "/private/var/root"))
(allow file-read* (subpath "$bw") (subpath "$NU") (subpath "$T") (subpath "/private/tmp/.dotnet"))
(allow file-write* (subpath "$bw") (subpath "$T") (subpath "/private/tmp/.dotnet") (literal "/dev/null") (literal "/dev/tty") (literal "/dev/dtracehelper"))
(allow network-bind network-inbound (local ip "localhost:*"))
(allow network-outbound (remote ip "localhost:*"))
(deny network-outbound (remote ip "localhost:3306") (remote ip "localhost:5432") (remote ip "localhost:6379") (remote ip "localhost:1433") (remote ip "localhost:27017") (remote ip "localhost:5672") (remote ip "localhost:11211") (remote ip "localhost:80") (remote ip "localhost:443") (remote ip "localhost:9000") (remote ip "localhost:8080"))
(allow network-bind network-inbound network-outbound (local unix-socket (subpath "$T")) (remote unix-socket (subpath "$T")))
EOF
}
[[ -n ${PRWATCH_TESTMODE:-} && -n ${PRWATCH_DTEST_PRINT:-} ]] && { profile; exit 0; }   # tests inspect the profile
# 0 passed · 1 failed · 2 nothing usable ran. Judged by the runner's own summary line ("Passed!"/"Failed!").
# one summary line per target framework: any failure fails; at least one line must have run tests
verdict() { local l f t ran=0; for l in ${(f)1}; do [[ $l == (Passed|Failed)!* ]] || continue
    f=0 t=0; [[ $l =~ 'Failed: *([0-9]+)' ]] && f=$match[1]; [[ $l =~ 'Total: *([0-9]+)' ]] && t=$match[1]
    [[ $l == Failed!* ]] || (( f > 0 )) && return 1; (( t > 0 )) && ran=1; done
  (( ran )) && return 0; return 2; }
summary() { grep -E '^(Passed|Failed)!' $1; }
[[ -n ${PRWATCH_TESTMODE:-} && -n ${PRWATCH_DTEST_VERDICT:-} ]] && { verdict "$(<$PRWATCH_DTEST_VERDICT)"; exit $?; }   # a file: multi-line input survives env -i
profile > $T/profile.sb
TZV=UTC; [[ $tz == London ]] && TZV=Europe/London
run=($DOTNET/dotnet test $proj --no-restore -m:1 -nodeReuse:false -p:UseAppHost=false -p:UseSharedCompilation=false
     --diag:$T/diag/log.txt ${name:+--filter} ${name:+FullyQualifiedName~$name})
[[ -n ${PRWATCH_TESTMODE:-} && -n ${PRWATCH_DTEST_FAKE:-} ]] && run=(/bin/sh -c "$PRWATCH_DTEST_FAKE")   # tests only
pid=0 wd=0
sweep() {                                        # nothing started by the run may outlive it, even if it left the group
  (( pid )) && kill -KILL -$pid 2>/dev/null; (( wd )) && kill $wd 2>/dev/null
  local p; for p in ${(f)"$( { /usr/bin/pgrep -f "$bw/" ; /usr/sbin/lsof -d cwd -Fpn 2>/dev/null | awk -v w="$bw/" '/^p/{p=substr($0,2)} /^n/{if(index(substr($0,2)"/",w)==1)print p}'; } | sort -u)"}; do
    [[ $p == <-> && $p != $$ ]] && kill -KILL $p 2>/dev/null; done; }
trap 'sweep; print "dotnet test $pname $tz: interrupted"; exit 2' INT TERM HUP
touch $PRW/state/activity 2>/dev/null
( cd $bw && exec /usr/bin/perl -e 'setpgrp(0,0); exec @ARGV or die' /usr/bin/env -i HOME=$T/home PATH="$DOTNET:/usr/bin:/bin" \
    TMPDIR=$T/tmp TZ=$TZV LANG=en_GB.UTF-8 DOTNET_CLI_HOME=$T/home NUGET_PACKAGES=$NU DOTNET_SYSTEM_NET_DISABLEIPV6=1 \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 MSBUILDDISABLENODEREUSE=1 \
    DOTNET_CLI_USE_MSBUILD_SERVER=0 VSTEST_CONNECTION_TIMEOUT=90 \
    /usr/bin/sandbox-exec -f $T/profile.sb "${run[@]}" ) > $log 2>&1 &
pid=$!
/usr/bin/perl -e '$SIG{TERM}=sub{exit 0}; sleep shift; open(F,">",shift); close F; kill "KILL", -shift' $LIMIT $T/timed-out $pid &
wd=$!
wait $pid; rc=$?; sweep
touch $PRW/state/activity 2>/dev/null
if [[ -e $T/timed-out ]]; then print "dotnet test $pname $tz: timed out after ${LIMIT}s · log: $log"; exit 2; fi
sum=$(summary $log)
print -r -- "dotnet test $proj TZ=$TZV: ${${sum:-no summary}//$'\n'/ | } (exit $rc) · log: $log"
verdict "$sum"; v=$?
if (( v == 2 )); then grep -E 'error [A-Z]+[0-9]+|Aborted|failed to connect|Unhandled exception' $log | tail -3
  hl=( $T/diag/log.host.*.txt ); (( ${#hl} )) && grep -m2 -hE 'Exception' $hl; fi
exit $v
