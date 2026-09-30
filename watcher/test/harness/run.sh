#!/bin/zsh
# Background-agent backstop tests (test mode, stub osascript). Run: ~/prwatch/test/harness/run.sh
# Covers prwatch-agenthook.sh (post/pre), prwatch-state.sh harness-abort, cleanup --sweep marker pruning, notify
# templates, guard, settings, launcher, skill wording, the daily cap (prompt hook, cap, daily-inc, prep, tick, cron gate)
# and repo↔install sync. Runs the INSTALLED scripts.
#   PRWATCH_LAUNCHER=<repo>/launcher/PR\ Watcher.command  (default: the Desktop copy)
#   PRWATCH_REPO=<repo>/watcher                           (for the sync check; skipped visibly if missing)
emulate -L zsh; set -u; setopt nullglob
PRW=$HOME/prwatch; B=$PRW/bin; FX=${0:A:h}/fixtures; fail=0; n=0
T=$(mktemp -d /tmp/pwh.XXXXXX); W=$PRW/work/Zzzt-pr9-abc; pids=()
trap 'kill $pids 2>/dev/null; rm -rf $T $W $PRW/work/Zzzt-pr9-0123456-build' EXIT
export PRWATCH_TESTMODE=1 PRWATCH_STATE_DIR=$T PRWATCH_STUB_BIN=$PRW/test/stub PRWATCH_SESSION_ID=sid-A PRWATCH_PID=1
ok()   { (( n++ )); if eval "$2"; then print "ok   $1"; else print "FAIL $1"; (( fail++ )); fi; }
reset() { rm -rf $T/*(N) $T/.*(N); print '{"prs":{},"daily":{},"go_ahead":{}}' > $T/state.json
  print '{"session_id":"sid-A","pid":1}' > $T/session.lock; }
review() { $B/prwatch-state.sh set ACT-Training/Vision#1 reviewing sha=abc step=council attempts=1 >/dev/null; $B/prwatch-state.sh daily-inc; }
post() { $B/prwatch-agenthook.sh post < $FX/$1 2>$T/err; }
ended() { $B/prwatch-agenthook.sh ended < $FX/$1 2>/dev/null; }
tj()   { jq -nc --arg t "$1" --arg c "${2:-}" '{tool_name:$t, tool_input:(if $c=="" then {} else {command:$c} end)}'; }
pre()  { tj "$@" | $B/prwatch-agenthook.sh pre 2>/dev/null; }          # pre <tool> [bash command] → hook exit code
denied() { pre "$@"; (( $? == 2 )); }
abort() { $B/prwatch-state.sh harness-abort $1 >/dev/null; }
refused() { abort $1; (( $? == 64 )); }
st()   { jq -r ".prs[\"$1\"].$2" $T/state.json; }
gone() { local i; for i in {1..50}; do kill -0 $1 2>/dev/null || return 0; /bin/sleep 0.1; done; return 1; }
today=$(date +%F); cnt() { [[ -f $T/notify.log ]] && print $(( $(wc -l < $T/notify.log) )) || print 0; }
SS=$PRW/bin/prwatch-state.sh; S7=$PRW/.claude/skills

# --- agenthook post
reset; review
post agent-async.json; rc=$?
ok "async launch → exit 2"                 '(( rc == 2 ))'
ok "async launch → marker with key"        '[[ "$(jq -r .key $T/harness/a111.marker)" == ACT-Training/Vision#1 ]]'
ok "async launch → stop file"              '[[ -f $T/stopped-$today ]]'
ok "async launch → one harness notice"     '(( $(cnt) == 1 )) && grep -q "error harness :: Reviewers ran in the background" $T/notify.log'
ok "async launch → model told exact command" 'grep -q "PRWATCH HARNESS FAULT" $T/err && grep -qx "$SS harness-abort ACT-Training/Vision#1" $T/err'
ok "pre denial names the exact command"    '(tj AskUserQuestion | $B/prwatch-agenthook.sh pre 2>&1 >/dev/null | grep -qx "$SS harness-abort ACT-Training/Vision#1")'
post agent-async2.json
ok "2nd agent same dispatch: throttled"    '(( $(cnt) == 1 )) && [[ -f $T/harness/a222.marker ]]'
reset; post agent-isasync-only.json; rc=$?
ok "isAsync true, other status → fault"    '(( rc == 2 ))'
reset; post agent-status-only.json; rc=$?
ok "status async_launched only → fault"    '(( rc == 2 ))'
reset; post agent-unknown-status.json; rc=$?
ok "unknown status → fault (fail safe)"    '(( rc == 2 )) && grep -q "unknown Agent status .running." $T/harness/hook.log'
reset; post agent-completed.json; rc=$?
ok "foreground result → silent"            '(( rc == 0 )) && [[ ! -e $T/harness && ! -f $T/stopped-$today ]]'
reset; post agent-handback-withheld.json; rc=$?
ok "completed + handback withheld → silent" '(( rc == 0 )) && [[ ! -e $T/harness && ! -e $T/notify.log ]]'
reset; post agent-drift.json; rc=$?
ok "no status at all → exit 0 + hookdrift" '(( rc == 0 )) && grep -q "error hookdrift" $T/notify.log && [[ ! -f $T/stopped-$today ]]'
reset; post bash.json; rc=$?
ok "non-Agent tool → silent"               '(( rc == 0 )) && [[ ! -e $T/notify.log ]]'
reset; print -n | $B/prwatch-agenthook.sh post; rc=$?
ok "empty stdin → exit 0"                  '(( rc == 0 ))'
reset; print 'not json' | $B/prwatch-agenthook.sh post; rc=$?
ok "garbage stdin → exit 0"                '(( rc == 0 ))'
reset; post agent-async-badid.json; rc=$?
m=($T/harness/*.marker); strays=($T/**/x.marker(N) ${T:h}/x.marker(N) ${T:h:h}/x.marker(N))
ok "hostile agentId → no path escape"      '(( rc == 2 && ${#m} == 1 && ${#strays} == 0 )) && [[ ${m[1]:t} == unknown-*.marker ]]'
reset; PRWATCH_SESSION_ID= post agent-async.json; rc=$?
ok "no session id → still stops today"     '(( rc == 2 )) && [[ -f $T/stopped-$today ]]'
reset; post taskstop-ok.json; rc=$?
ok "TaskStop of unmarked agent → silent"   '(( rc == 0 )) && [[ ! -e $T/notify.log ]]'

# --- agent finished on its own (SubagentStop): TaskStop would be refused before any hook runs
reset; review; post agent-async.json; ended subagentstop-a111.json; rc=$?
ok "ended: marked agent → stopped, exit 0" '(( rc == 0 )) && [[ -f $T/harness/a111.stopped && ! -e $T/harness/a111.marker ]]'
ok "ended: gate stays shut until abort"    'denied AskUserQuestion && denied Skill'
ok "ended: abort then succeeds"            'abort ACT-Training/Vision#1 && [[ $(st ACT-Training/Vision#1 status) == queued ]]'
ok "ended: gate opens after abort"         'pre AskUserQuestion'
reset; review; ended subagentstop-a111.json; rc=$?
ok "ended before marker: note, exit 0"     '(( rc == 0 )) && [[ -f $T/harness/a111.ended ]]'
post agent-async.json; rc=$?
ok "race: fault still raised"              '(( rc == 2 )) && [[ -f $T/stopped-$today ]] && (( $(cnt) == 1 ))'
ok "race: marker born stopped, note gone"  '[[ -f $T/harness/a111.stopped && ! -e $T/harness/a111.marker && ! -e $T/harness/a111.ended ]]'
ok "race: gated until abort, then open"    'denied AskUserQuestion && abort ACT-Training/Vision#1 && pre AskUserQuestion'
reset; ended subagentstop-a111.json; post agent-completed-real.json; rc=$?   # real recorded foreground shape
ok "foreground agent: note removed"        '(( rc == 0 )) && [[ ! -e $T/harness/a111.ended ]] && [[ ! -f $T/stopped-$today ]]'
reset; print "not json" | $B/prwatch-agenthook.sh ended; rc=$?
ok "ended: garbage stdin → exit 0"         '(( rc == 0 )) && [[ ! -e $T/harness ]]'
reset; jq -nc '{hook_event_name:"SubagentStop",agent_id:"../../x"}' | $B/prwatch-agenthook.sh ended; rc=$?
ok "ended: hostile id → nothing written"   '(( rc == 0 )) && [[ ! -e $T/harness/x.ended && -z $(print $T/harness/*.ended) ]]'
reset; jq -nc '{hook_event_name:"SubagentStop",agent_type:"general-purpose"}' | $B/prwatch-agenthook.sh ended; rc=$?
ok "ended: no agent_id → exit 0 + hookdrift" '(( rc == 0 )) && grep -q "error hookdrift" $T/notify.log'

# --- startup probe fault (no reviewing item → key none): gated while live, open once stopped (no abort for probes)
reset; post agent-async.json
ok "probe fault: key none, gated while live" '[[ "$(jq -r .key $T/harness/a111.marker)" == none ]] && denied AskUserQuestion'
ok "probe fault: told to report PROBLEM"   'grep -q "report PROBLEM (this is the start-up probe)" $T/err && ! grep -q harness-abort $T/err'
post taskstop-ok.json
ok "probe fault: open once stopped"        'pre AskUserQuestion'

# --- agenthook pre gate
reset; review; post agent-async.json
for t in AskUserQuestion Agent Write Edit Skill WebFetch; do ok "live marker: $t denied (exit 2)" "denied $t"; done
ok "live marker: post denied"              'denied Bash "$PRW/bin/prwatch-post.sh x"'
ok "live marker: buildrun denied"          'denied Bash "$PRW/bin/prwatch-buildrun.sh x"'
ok "live marker: other Bash denied"        'denied Bash ls'
ok "live marker: state.sh set denied"      'denied Bash "$SS set ACT-Training/Vision#1 asking"'
for c in "stop-today" "get ACT-Training/Vision#1" "harness-abort ACT-Training/Vision#1"; do
ok "live marker: state.sh ${c%% *} allowed" "pre Bash '$SS $c'"; done
ok "live marker: state.sh piped denied"    'denied Bash "$SS stop-today; ls"'
ok "live marker: garbage stdin denied"     '(print "not json" | $B/prwatch-agenthook.sh pre 2>/dev/null; (( $? == 2 )))'
for t in Read Glob Grep CronList CronDelete TaskStop TaskList ToolSearch; do ok "live marker: $t allowed" "pre $t"; done
ok "other session's marker: not gated"     '(PRWATCH_SESSION_ID=sid-B pre AskUserQuestion)'
reset
ok "no marker: everything allowed"        'pre AskUserQuestion && pre Agent && pre Bash ls && pre Write'

# --- harness-abort
reset; review; post agent-async.json
ok "abort refused while reviewer running"  'refused ACT-Training/Vision#1'
post taskstop-fail.json
ok "failed TaskStop keeps marker live"     '[[ -f $T/harness/a111.marker ]]'
ok "TaskStop wording drift → hookdrift"    'grep -q "error hookdrift :: Claude Code changed" $T/notify.log'
post taskstop-ok.json
ok "TaskStop → marker stopped"             '[[ -f $T/harness/a111.stopped ]]'
ok "stopped but not aborted: still gated"  'denied AskUserQuestion && denied Agent'
ok "stopped: harness-abort allowed"        'pre Bash "$SS harness-abort ACT-Training/Vision#1"'
ok "abort: wrong session → 5"              '(PRWATCH_SESSION_ID=sid-B $SS harness-abort ACT-Training/Vision#1 >/dev/null; (( $? == 5 )))'
ok "abort: bad key → 64"                   '($SS harness-abort "x; rm" >/dev/null; (( $? == 64 )))'
ok "abort: other PR → refused"             'refused ACT-Training/Vision#2 && [[ $(st ACT-Training/Vision#2 status) == null ]]'
ok "abort succeeds"                        'abort ACT-Training/Vision#1'
ok "gate open after abort"                 'pre AskUserQuestion && pre Agent'
ok "abort → queued, attempts kept, no step" '[[ "$(jq -c ".prs[\"ACT-Training/Vision#1\"]|[.status,.attempts,.step,.sha]" $T/state.json)" == "[\"queued\",\"1\",null,\"abc\"]" ]]'
ok "abort → daily refunded"                '(( $(jq ".daily[\"$today\"]" $T/state.json) == 0 ))'
left=($T/harness/*.marker $T/harness/*.stopped)
ok "abort → markers archived"              '(( ${#left} == 0 )) && [[ -f $T/harness/done/a111.stopped ]]'
ok "abort twice → refused, no 2nd refund"  'refused ACT-Training/Vision#1 && (( $(jq ".daily[\"$today\"]" $T/state.json) == 0 ))'
reset; $SS set ACT-Training/Vision#1 posted sha=abc >/dev/null
ok "abort on posted item → refused"        'refused ACT-Training/Vision#1 && [[ $(st ACT-Training/Vision#1 status) == posted ]]'
reset; $SS set ACT-Training/Vision#1 reviewing sha=abc >/dev/null
print '{"session":"sid-A","key":"ACT-Training/Vision#1","agent":"z"}' > $T/z.stopped   # not in harness/: ignored
ok "abort without hook marker → refused"   'refused ACT-Training/Vision#1 && [[ $(st ACT-Training/Vision#1 status) == reviewing ]]'
reset; review; post agent-async.json; post taskstop-ok.json
jq '.daily={}' $T/state.json > $T/s && mv $T/s $T/state.json; abort ACT-Training/Vision#1
ok "abort: daily floor 0"                  '(( $(jq ".daily[\"$today\"]" $T/state.json) == 0 ))'
reset; mkdir -p $T/harness; print '{"session":"sid-OLD","key":"ACT-Training/Vision#1","agent":"old"}' > $T/harness/old.marker
ok "old-session marker: gate open"         'pre AskUserQuestion'
reset; review; post agent-async.json; post taskstop-ok.json
print '{"session":"sid-OLD","key":"ACT-Training/Vision#1","agent":"old"}' > $T/harness/old.marker
ok "old-session marker: abort still works" 'abort ACT-Training/Vision#1 && [[ -f $T/harness/old.marker ]]'

# --- leftover PR processes: cwd in worktree (always) / path in args (descendants of the launcher only)
killcase() {   # $1 = PRWATCH_PID for the abort
  reset; mkdir -p $W; : > $W/f; $SS set ACT-Training/Zzzt#9 reviewing sha=abc >/dev/null
  (cd $W && exec /bin/sleep 300) & p1=$!; /usr/bin/tail -f $W/f >/dev/null & p2=$!; (cd /tmp && exec /bin/sleep 302) & p3=$!
  pids+=($p1 $p2 $p3)
  jq -n '{tool_name:"Agent",tool_response:{status:"async_launched",isAsync:true,agentId:"z9"}}' | $B/prwatch-agenthook.sh post 2>/dev/null
  jq -n '{tool_name:"TaskStop",tool_response:{message:"Successfully stopped task: z9",task_id:"z9"}}' | $B/prwatch-agenthook.sh post
  ok "kill fixtures alive before abort ($1)" "kill -0 $p1 && kill -0 $p2 && kill -0 $p3"
  PRWATCH_PID=$1 abort ACT-Training/Zzzt#9
}
killcase $$
ok "abort kills cwd-in-worktree process"   'gone $p1'
ok "abort kills path-in-args descendant"   'gone $p2'
ok "abort spares unrelated process"        'kill -0 $p3 2>/dev/null'
ok "abort removed the worktree"            '[[ ! -e $W ]]'
kill $p1 $p2 $p3 2>/dev/null
/bin/sleep 600 & other=$!; pids+=($other)
killcase $other                            # launcher pid that is NOT an ancestor of the tail
ok "non-descendant: cwd process still killed" 'gone $p1'
ok "non-descendant: path-in-args spared"   'kill -0 $p2 2>/dev/null'
kill $p1 $p2 $p3 $other 2>/dev/null; wait 2>/dev/null

# --- cleanup --sweep archives other days' markers (test mode: never touches real worktrees)
reset; mkdir -p $T/harness
print '{}' > $T/harness/old1.marker; print '{}' > $T/harness/old2.stopped; print '{}' > $T/harness/new.marker; : > $T/harness/old3.ended
touch -t $(date -v-2d +%Y%m%d%H%M) $T/harness/old1.marker $T/harness/old2.stopped $T/harness/old3.ended
$B/prwatch-cleanup.sh --sweep
ok "sweep archives old markers and notes"  '[[ -f $T/harness/done/old1.marker && -f $T/harness/done/old2.stopped && -f $T/harness/done/old3.ended ]]'
ok "sweep keeps today's marker"            '[[ -f $T/harness/new.marker ]]'

# --- throttle window
reset; $B/prwatch-notify.sh error harness; $B/prwatch-notify.sh error harness
ok "notify throttled within 30 min"        '(( $(cnt) == 1 ))'
touch -t $(date -v-31M +%Y%m%d%H%M) $T/notify-throttle/error-harness; $B/prwatch-notify.sh error harness
ok "notify again after 30 min"             '(( $(cnt) == 2 ))'
reset; $B/prwatch-notify.sh error hookdrift; $B/prwatch-notify.sh error hookdrift
ok "hookdrift wording + throttle"          '(( $(cnt) == 1 )) && grep -q "error hookdrift :: Claude Code changed how it reports subagents" $T/notify.log'

# --- guard, settings, launcher
g() { jq -nc --arg c "$1" '{tool_input:{command:$c}}' | $B/prwatch-guard.sh >/dev/null 2>&1; print $?; }
ok "guard: canonical harness-abort"        '[[ $(g "$SS harness-abort ACT-Training/Vision#1") == 0 ]]'
ok "guard: env-prefixed harness-abort"     '[[ $(g "PRWATCH_SESSION_ID=x $SS harness-abort ACT-Training/Vision#1") == 2 ]]'
ok "guard: piped harness-abort"            '[[ $(g "$SS harness-abort ACT-Training/Vision#1 | cat") == 2 ]]'
ok "guard: model cannot run agenthook"     '[[ $(g "$PRW/bin/prwatch-agenthook.sh post") == 2 ]]'
C=$PRW/config/settings.json
ok "settings: env var set"                 '[[ "$(jq -r .env.CLAUDE_CODE_DISABLE_BACKGROUND_TASKS $C)" == 1 ]]'
ok "settings: post hook on Agent|TaskStop" 'jq -e ".hooks.PostToolUse[]|select(.matcher==\"Agent|TaskStop\")|.hooks[0].command|endswith(\"agenthook.sh post\")" $C >/dev/null'
ok "settings: SubagentStop → ended"        'jq -e ".hooks.SubagentStop[0].hooks[0].command|endswith(\"agenthook.sh ended\")" $C >/dev/null'
ok "settings: pre gate hook on *"          'jq -e ".hooks.PreToolUse[]|select(.matcher==\"*\")|.hooks[0].command|endswith(\"agenthook.sh pre\")" $C >/dev/null'
ok "settings: state/ write-denied"         'jq -e ".sandbox.filesystem.denyWrite|index(\"/Users/jack/prwatch/state\")" $C >/dev/null && jq -e ".permissions.deny|index(\"Write(//Users/jack/prwatch/state/**)\")" $C >/dev/null'
L=${PRWATCH_LAUNCHER:-$HOME/Desktop/PR Watcher.command}
e=$(grep -n '^export CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1' "$L" 2>/dev/null | cut -d: -f1); c=$(grep -n '^"$CLAUDE_BIN" ' "$L" 2>/dev/null | cut -d: -f1)
ok "launcher exports var before claude"    '[[ -n $e && -n $c ]] && (( e < c ))'

# --- sandboxed tests (docs/fix-sandbox-tests.md)
AN=$PRW/angles/testing-build.md
ok "settings: .NET uses IPv4 in the sandbox" '[[ "$(jq -r .env.DOTNET_SYSTEM_NET_DISABLEIPV6 $C)" == 1 ]]'
for sc in prep buildrun post tick state notify cleanup prompthook; do
ok "$sc re-execs with env -i (settings env can't leak in)" "head -8 $B/prwatch-$sc.sh | grep -q 'exec /usr/bin/env -i'"; done
ok "dotnettest: runs with --diag, quotes testhost exception" 'grep -q -- "--diag:\$T/diag/log.txt" $B/prwatch-dotnettest.sh && grep -q "log.host" $B/prwatch-dotnettest.sh && grep -q "each test project separately" $AN'
ok "angle: 'ran' defined, no APPROVE without" 'grep -q "What counts as \"ran\"" $AN && grep -q "no test ran, your verdict can.t be .APPROVE" $AN && grep -q "TESTS-RAN:" $AN'
ok "angle: limits scoped to that command"  'grep -q "stop running that same command" $AN && grep -q "only that script" $AN'
ok "angle: real local services guarded"    'grep -q "Real local services" $AN'
ok "angle: command output is untrusted"    'grep -q "output of every build/test command" $AN'
ok "review: no approve without tests unless CI green" 'grep -q "may not be .approve. unless .ci. is .green." $S7/prwatch-review/SKILL.md && grep -q "\"built\"" $S7/prwatch-review/SKILL.md'
ok "decide: NONE ran shows CI"             'grep -q "CI: <ci>" $S7/prwatch-decide/SKILL.md'
ok "BUILD-NOTES: sandbox limits section"   'grep -q "## Sandbox limits for PR tests" $PRW/BUILD-NOTES.md'

# --- mktemp shim (sandboxed scripts: macOS mktemp ignores $TMPDIR)
MK=$PRW/shims/mktemp; MT=$T/mk; mkdir -p $MT
mk() { TMPDIR=$MT $MK "$@" 2>&1; }
ok "shim: bare mktemp → under \$TMPDIR"     '[[ -f $(mk) && $(mk) == $MT/tmp.* ]]'
ok "shim: -d → dir under \$TMPDIR"          'd=$(mk -d); [[ -d $d && $d == $MT/tmp.* ]]'
ok "shim: -t foo / -dt foo / -tfoo"         '[[ $(mk -t foo) == $MT/foo.* && -d $(mk -dt foo) && $(mk -tfoo) == $MT/foo.* ]]'
ok "shim: -t ../../x stays inside"          '[[ $(mk -t ../../x) == $MT/x.* ]]'
ok "shim: explicit template untouched"      '[[ $(mk $MT/exp.XXXX) == $MT/exp.???? ]]'
ok "shim: unknown option passed through"    '[[ "$(mk --bogus)" == *unrecognized* || "$(mk --bogus)" == *illegal* || "$(mk --bogus)" == *usage* ]]'

# --- prwatch-ngtest.sh: arguments, state, and the sandbox profile it generates
NG=$B/prwatch-ngtest.sh; NSHA=0123456789abcdef0123456789abcdef01234567; NBW=$PRW/work/Zzzt-pr9-0123456-build
reset; mkdir -p $T/arch/input $T/arch/reviews $NBW/frontend; : > $NBW/frontend/karma.conf.js; print '{"is_laravel":false}' > $T/arch/input/profile.json
$SS set ACT-Training/Zzzt#9 reviewing sha=$NSHA archive=$T/arch >/dev/null
ng() { $NG "$@" >/dev/null 2>&1; print $?; }
ok "ngtest: bad key / app → 64"             '[[ $(ng "x" frontend) == 64 && $(ng ACT-Training/Zzzt#9 admin) == 64 ]]'
ok "ngtest: bad spec-dir → 64"              '[[ $(ng ACT-Training/Zzzt#9 frontend ../x) == 64 && $(ng ACT-Training/Zzzt#9 frontend /etc) == 64 && $(ng ACT-Training/Zzzt#9 frontend "a*b") == 64 ]]'
ok "ngtest: wrong session → 6"              '[[ $(PRWATCH_SESSION_ID=sid-B ng ACT-Training/Zzzt#9 frontend) == 6 ]]'
ok "ngtest: untracked PR → 65"              '[[ $(ng ACT-Training/Zzzt#8 frontend) == 65 ]]'
ok "ngtest: no karma config → 65"           '[[ $(ng ACT-Training/Zzzt#9 learner) == 65 ]]'
PROF=$(PRWATCH_NGTEST_PRINT=1 $NG ACT-Training/Zzzt#9 frontend 2>&1)
ok "ngtest profile: deny by default"        '[[ $PROF == *"(deny default)"* ]]'
ok "ngtest profile: /Users reads denied"    '[[ $PROF == *"(deny file-read* (subpath \"/Users\")"* ]]'
ok "ngtest profile: outbound only to Karma/Chrome ports" '[[ $PROF != *"(allow network*)"* && $PROF != *"(allow network-outbound)"* && $PROF != *"remote ip \"*:"* && $PROF != *"remote ip \"localhost:*\""* && $PROF == *"(remote ip \"localhost:9876\")"* ]]'
ok "ngtest profile: writes only build copy + private dir" '[[ $(print -r -- $PROF | grep -c "allow file-write") == 1 ]] && print -r -- $PROF | grep "allow file-write" | grep -q "subpath \"$NBW:A\") (subpath \"$PRW:A/cache/ngtest/"'
nv() { PRWATCH_NGTEST_VERDICT="$1" $NG ACT-Training/Zzzt#9 frontend >/dev/null 2>&1; print $?; }
ok "ngtest verdict: real SUCCESS summary → 0" '[[ $(nv "Executed 3749 of 3749 SUCCESS (6.46 secs / 4.931 secs)") == 0 ]]'
ok "ngtest verdict: FAILED → 1"             '[[ $(nv "Executed 3749 of 3749 (2 FAILED) (7.1 secs / 5 secs)") == 1 && $(nv "Executed 3 of 3749 (1 FAILED) ERROR") == 1 ]]'
ok "ngtest verdict: disconnected/none → 2"  '[[ $(nv "Executed 100 of 3749 DISCONNECTED (30 secs)") == 2 && $(nv "") == 2 ]]'
ok "ngtest verdict: 0 of 0 ERROR (empty) → 2, not failed" '[[ $(nv "Executed 0 of 0 ERROR (0.002 secs / 0 secs)") == 2 ]]'
ns() { PRWATCH_NGTEST_SUMMARY=$FX/$1 $NG ACT-Training/Zzzt#9 frontend 2>/dev/null; }
ok "ngtest summary: real Karma log (ANSI) → SUCCESS" '[[ "$(ns karma-success.txt)" == "Executed 3749 of 3749 SUCCESS (7.135 secs / 5.329 secs)" ]]'
ok "ngtest summary: real log, 2 FAILED → verdict 1" '[[ $(nv "$(ns karma-failed.txt)") == 1 ]]'
ok "ngtest summary: empty suite → verdict 2" '[[ $(nv "$(ns karma-empty.txt)") == 2 ]]'
# the generated profile, compiled and exercised for real (no Chrome needed)
PF=$T/p.sb; print -r -- "$PROF" > $PF; SBW=$NBW:A
sb() { /usr/bin/sandbox-exec -f $PF "$@" >/dev/null 2>&1; }
ok "profile compiles and runs a command"   'sb /usr/bin/true'
ok "profile: build copy writable"          'sb /usr/bin/touch $SBW/frontend/w.txt'
ok "profile: ~/.ssh unreadable"            '! sb /bin/ls $HOME/.ssh'
ok "profile: home not writable"            '! sb /usr/bin/touch $HOME/prwatch-profile-probe && [[ ! -e $HOME/prwatch-profile-probe ]]'
ok "profile: no remote network"            '! sb /usr/bin/curl -s -m 5 -o /dev/null https://example.com'
ok "profile: local MySQL port unreachable" '! sb /usr/bin/python3 -c "import socket; socket.create_connection((\"127.0.0.1\",3306),2)"'
ok "profile: clipboard blocked"            '[[ -z "$(/usr/bin/sandbox-exec -f $PF /usr/bin/pbpaste 2>/dev/null)" ]]'
# the run itself, with a fake command in place of Karma (test mode only)
nf() { PRWATCH_NGTEST_FAKE="$1" PRWATCH_NGTEST_LIMIT=${2:-60} $NG ACT-Training/Zzzt#9 frontend >$T/nf.out 2>&1; print $?; }
ok "run: fake SUCCESS summary → 0, log in archive" '[[ $(nf "echo Executed 5 of 5 SUCCESS \(1 secs / 1 secs\)") == 0 ]] && grep -q "Executed 5 of 5" $T/arch/reviews/ng-test-frontend.log'
ok "run: fake FAILED → 1"                  '[[ $(nf "echo Executed 5 of 5 \(1 FAILED\)") == 1 ]]'
ok "run: timeout → 2, says timed out"      '[[ $(nf "sleep 30" 2) == 2 ]] && grep -q "timed out after 2s" $T/nf.out'
ok "run: nothing left after timeout"       '! /usr/bin/pgrep -f "^sleep 30$" >/dev/null'
ok "run: escaped process group still swept" '[[ $(nf "/usr/bin/perl -e \"use POSIX; POSIX::setsid(); exec q(sleep), 41\" & echo Executed 1 of 1 SUCCESS") == 0 ]] && /bin/sleep 1 && ! /usr/bin/pgrep -f "^sleep 41$" >/dev/null'
# --- prwatch-dotnettest.sh (same pattern: own profile, because Claude's sandbox refuses the domain-name sysctl)
DT=$B/prwatch-dotnettest.sh; mkdir -p $NBW/api/X.Tests; : > $NBW/api/X.Tests/X.Tests.csproj
dt() { $DT "$@" >/dev/null 2>&1; print $?; }
ok "dotnettest: bad key / tz → 64"          '[[ $(dt x api/X.Tests/X.Tests.csproj UTC) == 64 && $(dt ACT-Training/Zzzt#9 api/X.Tests/X.Tests.csproj Paris) == 64 ]]'
ok "dotnettest: bad project path → 64"      '[[ $(dt ACT-Training/Zzzt#9 ../x.csproj UTC) == 64 && $(dt ACT-Training/Zzzt#9 /etc/x.csproj UTC) == 64 && $(dt ACT-Training/Zzzt#9 api/x.sln UTC) == 64 && $(dt ACT-Training/Zzzt#9 -x.csproj UTC) == 64 ]]'
ok "dotnettest: bad test-name → 64"         '[[ $(dt ACT-Training/Zzzt#9 api/X.Tests/X.Tests.csproj UTC "a~b") == 64 ]]'
ok "dotnettest: wrong session → 6"          '[[ $(PRWATCH_SESSION_ID=sid-B dt ACT-Training/Zzzt#9 api/X.Tests/X.Tests.csproj UTC) == 6 ]]'
ok "dotnettest: missing project → 65"       '[[ $(dt ACT-Training/Zzzt#9 api/Y.Tests/Y.Tests.csproj UTC) == 65 ]]'
dv() { print -r -- "$1" > $T/dv.txt; PRWATCH_DTEST_VERDICT=$T/dv.txt $DT ACT-Training/Zzzt#9 api/X.Tests/X.Tests.csproj UTC >/dev/null 2>&1; print $?; }
ok "dotnettest verdict: Passed! → 0"        '[[ $(dv "Passed!  - Failed:     0, Passed:   243, Skipped:    57, Total:   300, Duration: 3 m 24 s - X.dll (net8.0)") == 0 ]]'
ok "dotnettest verdict: Failed! → 1"        '[[ $(dv "Failed!  - Failed:   220, Passed:    23, Skipped:    57, Total:   300, Duration: 115 ms - X.dll (net8.0)") == 1 ]]'
ok "dotnettest verdict: 2 frameworks, one failed → 1" '[[ $(dv "Failed!  - Failed:     1, Passed:     4, Skipped:     0, Total:     5 - X.dll (net8.0)"$'"'"'\n'"'"'"Passed!  - Failed:     0, Passed:     5, Skipped:     0, Total:     5 - X.dll (net9.0)") == 1 ]]'
ok "dotnettest verdict: failure on the later framework → 1" '[[ $(dv "Passed!  - Failed:     0, Passed:     5, Skipped:     0, Total:     5 - X.dll (net8.0)"$'"'"'\n'"'"'"Failed!  - Failed:     2, Passed:     3, Skipped:     0, Total:     5 - X.dll (net9.0)") == 1 ]]'
ok "dotnettest verdict: 0 tests / none → 2" '[[ $(dv "Passed!  - Failed:     0, Passed:     0, Skipped:     0, Total:     0, Duration: 1 ms - X.dll") == 2 && $(dv "") == 2 ]]'
DPROF=$(PRWATCH_DTEST_PRINT=1 $DT ACT-Training/Zzzt#9 api/X.Tests/X.Tests.csproj UTC 2>&1); DPF=$T/d.sb; print -r -- "$DPROF" > $DPF
db() { /usr/bin/sandbox-exec -f $DPF "$@" >/dev/null 2>&1; }
ok "dotnettest profile compiles; domain-name lookup works" 'db /usr/sbin/sysctl kern.nisdomainname'
ok "dotnettest profile: ~/.ssh unreadable, home unwritable" '! db /bin/ls $HOME/.ssh && ! db /usr/bin/touch $HOME/prwatch-profile-probe'
ok "dotnettest profile: no remote network"  '! db /usr/bin/curl -s -m 5 -o /dev/null https://example.com && [[ $DPROF != *"remote ip \"*:"* ]]'
ok "dotnettest profile: local MySQL port unreachable" '! db /usr/bin/python3 -c "import socket; socket.create_connection((\"127.0.0.1\",3306),2)"'
ok "dotnettest profile: clipboard blocked"  '[[ -z "$(/usr/bin/sandbox-exec -f $DPF /usr/bin/pbpaste 2>/dev/null)" ]]'
df() { PRWATCH_DTEST_FAKE="$1" PRWATCH_DTEST_LIMIT=${2:-60} $DT ACT-Training/Zzzt#9 api/X.Tests/X.Tests.csproj UTC >$T/df.out 2>&1; print $?; }
ok "dotnettest run: fake Passed! → 0, log in archive" '[[ $(df "echo Passed!  - Failed:     0, Passed:     5, Skipped:     0, Total:     5") == 0 ]] && [[ -f $T/arch/reviews/dotnet-test-api_X.Tests_X.Tests-UTC.log ]]'
ok "dotnettest run: timeout → 2, nothing left" '[[ $(df "sleep 31" 2) == 2 ]] && grep -q "timed out after 2s" $T/df.out && ! /usr/bin/pgrep -f "^sleep 31$" >/dev/null'
ok "dotnettest run: escaped process group still swept" '[[ $(df "/usr/bin/perl -e \"use POSIX; POSIX::setsid(); exec q(sleep), 42\" & echo Passed!  - Failed:     0, Passed:     1, Skipped:     0, Total:     1") == 0 ]] && /bin/sleep 1 && ! /usr/bin/pgrep -f "^sleep 42$" >/dev/null'
print '{"is_laravel":true}' > $T/arch/input/profile.json
ok "dotnettest: Laravel refused"            '[[ $(dt ACT-Training/Zzzt#9 api/X.Tests/X.Tests.csproj UTC) == 64 ]]'
print '{"is_laravel":false}' > $T/arch/input/profile.json
ok "guard: canonical dotnettest allowed"    '[[ $(g "$B/prwatch-dotnettest.sh ACT-Training/Vision#1 api/X.Tests/X.Tests.csproj UTC") == 0 ]]'
ok "settings: dotnettest allowed + unsandboxed" 'jq -e ".permissions.allow|index(\"Bash($B/prwatch-dotnettest.sh *)\")" $C >/dev/null && jq -e ".sandbox.excludedCommands|index(\"$B/prwatch-dotnettest.sh *\")" $C >/dev/null'
ok "angle: .NET only via prwatch-dotnettest" 'grep -q "Never run .dotnet test. yourself" $AN && grep -q "prwatch-dotnettest.sh <key>" $AN'
print '{"is_laravel":true}' > $T/arch/input/profile.json
ok "ngtest: Laravel refused"                '[[ $(ng ACT-Training/Zzzt#9 frontend) == 64 ]]'
rm -rf $NBW
ok "guard: canonical ngtest allowed"        '[[ $(g "$B/prwatch-ngtest.sh ACT-Training/Vision#1 frontend") == 0 ]]'
ok "guard: ngtest with a glob denied"       '[[ $(g "$B/prwatch-ngtest.sh ACT-Training/Vision#1 frontend src/**") == 2 ]]'
ok "settings: ngtest allowed + unsandboxed" 'jq -e ".permissions.allow|index(\"Bash($B/prwatch-ngtest.sh *)\")" $C >/dev/null && jq -e ".sandbox.excludedCommands|index(\"$B/prwatch-ngtest.sh *\")" $C >/dev/null'
ok "settings: shims write-denied"           'jq -e ".sandbox.filesystem.denyWrite|index(\"$PRW/shims\")" $C >/dev/null && jq -e ".permissions.deny|index(\"Write(/$PRW/shims/**)\")" $C >/dev/null'
e2=$(grep -n '^export PATH="$PRW/shims:$PATH"' "$L" 2>/dev/null | cut -d: -f1)
ok "launcher: shims first on PATH before claude" '[[ -n $e2 && -n $c ]] && (( e2 < c ))'
ok "angle: Angular only via prwatch-ngtest" 'grep -q "never run .ng test" $AN && grep -q "prwatch-ngtest.sh <key> frontend" $AN'

# --- shared wording: the hook's sentinel and the hand-back rules must stay in the texts the model reads
SENT=$(grep -o 'PRWATCH HARNESS FAULT' $B/prwatch-agenthook.sh | head -1)
ok "sentinel present in hook"              '[[ $SENT == "PRWATCH HARNESS FAULT" ]]'
for f in $PRW/CLAUDE.md $S7/prwatch-review/SKILL.md $S7/prwatch-start/SKILL.md; do
ok "sentinel in ${f#$PRW/}"                "grep -q '$SENT' $f"; done
ok "skills: 'not running' counts as stopped" 'grep -q "not running" $S7/prwatch-review/SKILL.md && grep -q "not running" $S7/prwatch-start/SKILL.md && grep -q "not running" $B/prwatch-agenthook.sh'
ok "review skill: harness-abort step"      'grep -q "prwatch-state.sh harness-abort <key>" $S7/prwatch-review/SKILL.md'
ok "review skill: failure excludes fault"  'grep -q "except a harness fault" $S7/prwatch-review/SKILL.md'
ok "tick skill: stop after harness fault"  'grep -q "harness fault" $S7/prwatch-tick/SKILL.md'
ok "hand-back named in start/review/CLAUDE" 'grep -q "Subagent hand-back" $S7/prwatch-start/SKILL.md && grep -q "Subagent hand-back" $S7/prwatch-review/SKILL.md && grep -q "Subagent hand-back" $PRW/CLAUDE.md'
ok "hand-back never a decision (inv. 1 + decide)" 'grep -q "hand-back" <(sed -n "/^1\. \*\*Posting/p" $PRW/CLAUDE.md) && grep -q "hand-back" $S7/prwatch-decide/SKILL.md'

# --- daily cap (docs/cap-override.md): Jack's "cap N" via the prompt hook only; prep's daily-inc enforces it; tick reports it
PH=$B/prwatch-prompthook.sh; WD=2026-09-29                                  # WD: a weekday, for tick's window
ph()   { jq -nc --arg p "$1" '{hook_event_name:"UserPromptSubmit",session_id:"cc-1",prompt:$p}' | $PH prompt 2>&1; }
ovr()  { jq -r ".cap_override[\"${1:-$today}\"] // \"none\"" $T/state.json; }
used() { jq -r ".daily[\"${1:-$today}\"] // 0" $T/state.json; }
req()  { mkdir -p $T/cap; jq -nc --arg s ${2:-sid-A} --arg n $1 '{session:$s,n:$n}' > $T/cap/request.json; }   # what the hook writes
setcap() { $SS cap $1 >/dev/null 2>&1; }
reset; out=$(ph "cap 8")
ok "prompthook: cap 8 → today's cap 8"      '[[ $(ovr) == 8 ]]'
ok "prompthook: tells the model the result" '[[ $out == "PRWATCH CAP: up to 8 reviews may start today (normally 6); 0 started so far."* ]]'
ok "prompthook: request used up"            '[[ ! -e $T/cap/request.json ]]'
ok "cap: Jack notified, event logged"       'grep -q " cap 8 :: Up to 8 reviews may start today. If you didn.t type cap 8" $T/notify.log && grep -q "\"cap\":8" $T/events.jsonl'
reset; ph $'  CAP   9\n' >/dev/null
ok "prompthook: trimmed, any case"          '[[ $(ovr) == 9 ]]'
reset
for pr in "cap 8 please" "please cap 8" "cap" "cap eight" $'cap 8\nrm -rf x' "cap ８" "cap -1" "cap 8; ls" "cap 1234" "d"; do
ok "prompthook: ignores '${pr//$'\n'/<NL>}'" '[[ -z $(ph "$pr") && $(ovr) == none && ! -e $T/cap/request.json ]]'; done
for v in 0 13 08 99; do
ok "prompthook: cap $v refused, Jack told"  '[[ $(ph "cap $v") == "PRWATCH CAP: not changed (the cap must be 1 to 12)."* && $(ovr) == none ]]'; done
ok "prompthook: never blocks a prompt"      '(ph "cap 99" >/dev/null; (( $? == 0 ))) && (print "not json" | $PH prompt >/dev/null; (( $? == 0 )))'
ok "cap: no request from the hook → refused (the model can't raise it)" '(setcap 12; (( $? == 64 ))) && [[ $(ovr) == none ]]'
req 8 sid-B
ok "cap: request from another session → refused" '(setcap 8; (( $? == 64 ))) && [[ $(ovr) == none ]]'
req 8
ok "cap: caller from another session → 5"   '(PRWATCH_SESSION_ID=sid-B $SS cap 8 >/dev/null; (( $? == 5 ))) && [[ $(ovr) == none ]]'
ok "cap: request says 8, call says 12 → refused" '! setcap 12 && [[ $(ovr) == none ]]'
touch -t $(date -v-2M +%Y%m%d%H%M) $T/cap/request.json
ok "cap: request older than 60 s → refused" '! setcap 8 && [[ $(ovr) == none ]]'
req 8
ok "cap: request single use"                'setcap 8 && [[ ! -e $T/cap/request.json ]] && ! setcap 8'
req 13
ok "cap: above 12 refused even with a request" '(setcap 13; (( $? == 64 ))) && [[ $(ovr) == 8 ]]'
ok "cap: bad argument → 64"                 '($SS cap "8; rm" >/dev/null; (( $? == 64 ))) && ($SS cap x >/dev/null; (( $? == 64 )))'
req 3
ok "cap: lowering allowed"                  'setcap 3 && [[ $(ovr) == 3 ]]'
reset; for i in {1..6}; do $SS daily-inc >/dev/null; done; c=$($SS daily-inc); rc=$?
ok "daily-inc: 7th refused at the default 6 (65)" '(( rc == 65 )) && [[ $(used) == 6 && $c == "daily cap reached (6 of 6 today)" ]]'
ph "cap 8" >/dev/null; $SS daily-inc >/dev/null; rc=$?
ok "daily-inc: allowed again after cap 8"   '(( rc == 0 )) && [[ $(used) == 7 ]]'
$SS daily-inc >/dev/null; $SS daily-inc >/dev/null; rc=$?
ok "daily-inc: refused at 8 of 8"           '(( rc == 65 )) && [[ $(used) == 8 ]]'
reset; jq --arg d $today '.cap_override["2000-01-01"]=12 | .daily[$d]=6' $T/state.json > $T/s && mv $T/s $T/state.json
ok "daily-inc: another day's cap ignored"   '! $SS daily-inc >/dev/null && [[ $(used) == 6 ]]'
reset; for i in {1..10}; do $SS daily-inc >/dev/null 2>&1 & done; wait
ok "daily-inc: 10 at once → exactly 6 (locked)" '[[ $(used) == 6 ]]'
reset; ph "cap 8" >/dev/null; review; post agent-async.json; post taskstop-ok.json; abort ACT-Training/Vision#1
ok "harness-abort refund keeps today's cap" '[[ $(used) == 0 && $(ovr) == 8 ]]'
reset; review; post agent-async.json
ok "live marker: state.sh cap denied"       'denied Bash "$SS cap 8"'
# prep takes the slot before doing anything (no archive, no network); a failing clone source keeps the rest local
reset; jq --arg d $today '.daily[$d]=6' $T/state.json > $T/s && mv $T/s $T/state.json
pp() { PRWATCH_ARCHIVE_DIR=$T/archive PRWATCH_GIT_BASE=$T/nogit $B/prwatch-prep.sh Zzzt 9 0123456789abcdef0123456789abcdef01234567 1 2>&1; }
out=$(pp); rc=$?
ok "prep: cap used up → 24, nothing done"   '(( rc == 24 )) && [[ $out == "daily cap reached (6 of 6 today)" && ! -e $T/archive ]] && [[ $(used) == 6 ]]'
reset; out=$(pp); rc=$?
ok "prep: counts the review first"          '(( rc == 20 )) && [[ $(used) == 1 ]]'
reset; out=$(PRWATCH_SESSION_ID=sid-B pp); rc=$?
ok "prep: other session → 25, not counted"  '(( rc == 25 )) && [[ $(used) == 0 && ! -e $T/archive ]]'
reset; out=$(PRWATCH_SESSION_ID= pp); rc=$?
ok "prep: test mode, no session (T2) → not counted" '(( rc == 20 )) && [[ $(used) == 0 ]]'
# tick reports the cap (dry run, stub gh, fixed weekday)
tk() { mkdir -p $T/stub; ln -sf $PRW/test/stub/osascript $T/stub/osascript
  cat > $T/stub/gh <<'EOF'
#!/bin/zsh
[[ "$1 $2" == "pr view" ]] && print '{"headRefOid":"abc","isDraft":false,"state":"OPEN","title":"t","author":{"login":"x"},"files":[]}'
exit 0
EOF
  chmod +x $T/stub/gh
  PRWATCH_STUB_BIN=$T/stub PRWATCH_ONLY_PR=ACT-Training/Zzzt#9 PRWATCH_NOW=${WD}T10:00 $B/prwatch-tick.sh --dry-run | jq -c '[.cap,.cap_default,.councils_today,.cap_left]'; }
reset
ok "tick: default cap 6"                    '[[ $(tk) == "[6,6,0,6]" ]]'
jq --arg d $WD '.cap_override[$d]=8 | .daily[$d]=3 | .cap_override["2026-09-28"]=12' $T/state.json > $T/s && mv $T/s $T/state.json
ok "tick: today's cap 8, 3 used, 5 left"    '[[ $(tk) == "[8,6,3,5]" ]]'
jq --arg d $WD '.cap_override[$d]=3 | .daily[$d]=5' $T/state.json > $T/s && mv $T/s $T/state.json
ok "tick: nothing left never below 0"       '[[ $(tk) == "[3,6,5,0]" ]]'
reset; PRWATCH_NOW=${WD}T10:00 ph "cap 10" >/dev/null
ok "tick: reads the cap the hook set (same day in test mode)" '[[ $(ovr $WD) == 10 && $(tk) == "[10,6,0,10]" ]]'
# CronCreate gate: a scheduled prompt could look like Jack's typing, so only the two real jobs may exist
cj() { jq -nc --arg c "$1" --arg p "$2" --argjson r ${3:-null} '{tool_name:"CronCreate",tool_input:({cron:$c,prompt:$p}+(if $r==null then {} else {recurring:$r} end))}' | $PH cron 2>/dev/null; print $?; }
ok "cron gate: tick job allowed"            '[[ $(cj "*/15 8-15 * * 1-5" /prwatch-tick) == 0 && $(cj "*/15 8-15 * * 1-5" /prwatch-tick true) == 0 ]]'
ok "cron gate: eod job allowed"             '[[ $(cj "3 16 * * 1-5" /prwatch-eod) == 0 ]]'
ok "cron gate: 'cap 12' denied"             '[[ $(cj "*/15 8-15 * * 1-5" "cap 12") == 2 ]]'
ok "cron gate: tick plus extra text denied" '[[ $(cj "*/15 8-15 * * 1-5" "/prwatch-tick then cap 12") == 2 ]]'
ok "cron gate: one-shot / other time denied" '[[ $(cj "*/15 8-15 * * 1-5" /prwatch-tick false) == 2 && $(cj "* * * * *" /prwatch-tick) == 2 ]]'
ok "cron gate: garbage → denied"            '[[ $(print "not json" | $PH cron 2>/dev/null; print $?) == 2 ]]'
ok "settings: UserPromptSubmit → prompthook" 'jq -e ".hooks.UserPromptSubmit[0].hooks|map(.command)|index(\"$PH prompt\")" $C >/dev/null'
ok "settings: CronCreate gate hook"         'jq -e ".hooks.PreToolUse[]|select(.matcher==\"CronCreate\")|.hooks[0].command == \"$PH cron\"" $C >/dev/null'
ok "guard: model cannot run prompthook"     '[[ $(g "$PH prompt") == 2 && $(g "echo cap 12 | $PH prompt") == 2 ]]'
ok "tick and state agree on the default"    '[[ $(grep -o "CAP_DEFAULT=[0-9]*" $B/prwatch-tick.sh) == $(grep -o "CAP_DEFAULT=[0-9]*" $B/prwatch-state.sh) ]]'
ok "tick skill: cap from the JSON, no '6'"  '! grep -q "(6)\|cap of 6" $S7/prwatch-tick/SKILL.md && grep -q "Daily cap of <cap>" $S7/prwatch-tick/SKILL.md && grep -q "exit 24" $S7/prwatch-tick/SKILL.md'
ok "review skill: prep counts, exit 24 requeues" '! grep -q "daily-inc" $S7/prwatch-review/SKILL.md && grep -q "Exit 24" $S7/prwatch-review/SKILL.md'
ok "CLAUDE.md: cap N row, never run cap yourself" 'grep -q "^| .cap N. |" $PRW/CLAUDE.md && grep -q "Never run .prwatch-state.sh cap. yourself" $PRW/CLAUDE.md'
ok "start skill: only the two jobs"         'grep -q "A hook allows only these two jobs" $S7/prwatch-start/SKILL.md'

# --- installed copy must match the repo (tests run the installed scripts)
REPO=${PRWATCH_REPO:-/Users/jack/Herd/Shuffle/pr-watcher/watcher}
if [[ -d $REPO ]]; then
  drift=$(cd $REPO && for f in bin/*.sh shims/* config/settings.json CLAUDE.md BUILD-NOTES.md angles/*.md .claude/skills/*/SKILL.md test/harness/*.sh; do cmp -s $f $PRW/$f || print $f; done)
  ok "installed copy matches repo"         '[[ -z $drift ]]'; [[ -n $drift ]] && print "  drift: ${(f)drift}"
else print "skip installed copy matches repo (no repo at $REPO; set PRWATCH_REPO)"; fi
print "$((n-fail))/$n passed"; (( fail == 0 ))
