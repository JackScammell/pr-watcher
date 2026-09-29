#!/bin/zsh
# Background-agent backstop tests (test mode, stub osascript). Run: ~/prwatch/test/harness/run.sh
# Covers prwatch-agenthook.sh (post/pre), prwatch-state.sh harness-abort, cleanup --sweep marker pruning, notify
# templates, guard, settings, launcher, skill wording and repo↔install sync. Runs the INSTALLED scripts.
#   PRWATCH_LAUNCHER=<repo>/launcher/PR\ Watcher.command  (default: the Desktop copy)
#   PRWATCH_REPO=<repo>/watcher                           (for the sync check; skipped visibly if missing)
emulate -L zsh; set -u; setopt nullglob
PRW=$HOME/prwatch; B=$PRW/bin; FX=${0:A:h}/fixtures; fail=0; n=0
T=$(mktemp -d /tmp/pwh.XXXXXX); W=$PRW/work/Zzzt-pr9-abc; pids=()
trap 'kill $pids 2>/dev/null; rm -rf $T $W' EXIT
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
SS=$PRW/bin/prwatch-state.sh

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

# --- shared wording: the hook's sentinel and the hand-back rules must stay in the texts the model reads
S7=$PRW/.claude/skills; SENT=$(grep -o 'PRWATCH HARNESS FAULT' $B/prwatch-agenthook.sh | head -1)
ok "sentinel present in hook"              '[[ $SENT == "PRWATCH HARNESS FAULT" ]]'
for f in $PRW/CLAUDE.md $S7/prwatch-review/SKILL.md $S7/prwatch-start/SKILL.md; do
ok "sentinel in ${f#$PRW/}"                "grep -q '$SENT' $f"; done
ok "skills: 'not running' counts as stopped" 'grep -q "not running" $S7/prwatch-review/SKILL.md && grep -q "not running" $S7/prwatch-start/SKILL.md && grep -q "not running" $B/prwatch-agenthook.sh'
ok "review skill: harness-abort step"      'grep -q "prwatch-state.sh harness-abort <key>" $S7/prwatch-review/SKILL.md'
ok "review skill: failure excludes fault"  'grep -q "except a harness fault" $S7/prwatch-review/SKILL.md'
ok "tick skill: stop after harness fault"  'grep -q "harness fault" $S7/prwatch-tick/SKILL.md'
ok "hand-back named in start/review/CLAUDE" 'grep -q "Subagent hand-back" $S7/prwatch-start/SKILL.md && grep -q "Subagent hand-back" $S7/prwatch-review/SKILL.md && grep -q "Subagent hand-back" $PRW/CLAUDE.md'
ok "hand-back never a decision (inv. 1 + decide)" 'grep -q "hand-back" <(sed -n "/^1\. \*\*Posting/p" $PRW/CLAUDE.md) && grep -q "hand-back" $S7/prwatch-decide/SKILL.md'

# --- installed copy must match the repo (tests run the installed scripts)
REPO=${PRWATCH_REPO:-/Users/jack/Herd/Shuffle/pr-watcher/watcher}
if [[ -d $REPO ]]; then
  drift=$(cd $REPO && for f in bin/*.sh config/settings.json CLAUDE.md .claude/skills/*/SKILL.md test/harness/run.sh; do cmp -s $f $PRW/$f || print $f; done)
  ok "installed copy matches repo"         '[[ -z $drift ]]'; [[ -n $drift ]] && print "  drift: ${(f)drift}"
else print "skip installed copy matches repo (no repo at $REPO; set PRWATCH_REPO)"; fi
print "$((n-fail))/$n passed"; (( fail == 0 ))
