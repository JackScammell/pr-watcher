#!/bin/zsh
# Background-agent backstop tests (test mode, stub osascript). Run: ~/prwatch/test/harness/run.sh
# Covers prwatch-agenthook.sh (post/pre), prwatch-state.sh harness-abort, cleanup --sweep marker pruning, notify
# templates, guard, settings, launcher, skill wording, the 8-hour session window (B1), hook-owned stop/pause (B2),
# the launcher exit notice (B2.7/B2.8), the key grammar (B4), owner-bearing paths and prep/post arguments (B5), the
# PRWATCH_LOGIN plumbing (B6), the scheduling gate (B8), prose values (B9), legacy inputs (B10), the state lock on set
# (B11), the first-sighting repo gate and the allow/block gate on prep, set and tick (B12), the review engine record,
# Parliament pin and reviewer-memory freeze (B3), the skill gate and subagent types (B7) and repo↔install sync.
# Runs the INSTALLED scripts.
#   PRWATCH_LAUNCHER=<repo>/launcher/PR\ Watcher.command  (default: the Desktop copy)
#   PRWATCH_REPO=<repo>/watcher                           (for the sync check; skipped visibly if missing)
# Mutations (plan §7, applied to the installed copy; each must fail the named check):
#   M1  delete the started_epoch read in tick            → "B1: T+0 → in_window" (error no_session_start instead)
#   M2  START_LIMIT compare < → <=                        → "B1: T+7h30 → start_closed"
#   M3  END compare >= → >                                → "B1: T+8h → session_over"
#   M4  state.sh stop skips the request check            → "B2: stop with no request → 64, nothing stopped"
#   M5  wt_name drops the owner                          → "ngtest profile: writes only build copy + private dir" + "dotnettest run: fake Passed! → 0, log in archive"
#       (the -build copy is wt_name); cleanup matches on wt_prefix: dropping the owner THERE → "B5: cleanup of one owner's key removes its worktree, spares the other owner's"
#   M6  launcher stops exporting PRWATCH_LOGIN           → "B6: launcher writes login into the lock and exports PRWATCH_LOGIN"
#   M7  JackScammell hard-coded back into tick            → "B6: the stub login → rerequested_same_sha, requeued" (the filter would want JackScammell, the stub says stubuser → ignore) + "B5: no JackScammell in bin, .claude, CLAUDE.md"
#   M8  owner charset widened (e.g. admits '.')           → "B4: refuse '../x#1'"
#   M9  skill gate exits 0 on an empty skill field       → "B7: skill '' (no args) → 2"
#   M10 --comment dropped from the gate's refused words  → "B7: code-review high <a--comment worktree> → 2"
#   M11 sched gate accepts any cron with /prwatch-tick   → "B8: other cadence (*/10) denied"
#   M12 engine parliament but no --plugin-dir in argv    → "B3: pinned tree matches → parliament, --plugin-dir (right after --setting-sources) is the locked snapshot"
#   M13 --window touches the heartbeat                   → "B1.18: --window leaves the heartbeat alone"
#   M14 prep skips the window check                      → "B1.18: prep at T+7h31 → window closed, nothing done"
#   M15 post defaults the owner (Vision#1 → ACT-Training) → "B5: post --key Vision#1 → 64 bad arguments (no default owner)"
#   M16 prep skips the repo gate                         → "B12: prep on a repo with no repos entry and no prs key → 25 repo not allowed, nothing cloned"
#   M17 state set skips the repo gate                    → "B12: set on a key whose repo is absent → 64 repo not allowed, repo_not_allowed event, no prs entry"
#   M18 tick's new_repo notification sent per PR again   → "B12: two PRs of one unseen repo → two new_repo rows, one notice, one newrepo notification"
#   M19 settings drops "|| exit 2" from the skill hook  → "B7: a skill hook that crashes (WT_PAT unset) still refuses: raw exit 1, settings command 2"
#   M20 launcher passes the live folder, not the snapshot → "B3: pinned tree matches → parliament, --plugin-dir (right after --setting-sources) is the locked snapshot"
emulate -L zsh; set -u; setopt nullglob
export TZ=Europe/London
PRW=$HOME/prwatch; B=$PRW/bin; FX=${0:A:h}/fixtures; fail=0; n=0
T=$(mktemp -d /tmp/pwh.XXXXXX); W=$PRW/work/ACT-Training__Zzzt-pr9-0123456; W2=$PRW/work/Some-Org__Zzzt-pr9-0123456; RZL=$PRW/repos/ACT-Training__Zzzt; PA=$PRW/test/harness-post-$$; pids=()
P3=$(mktemp -d /tmp/pwh3.XXXXXX); WC=$PRW/work/Some-Org__a--comment-pr1-0123456; WL=$PRW/work/Some-Org__Link-pr1-0123456   # B3 fixtures (launch() wipes $T); B7 worktrees
trap 'kill $pids 2>/dev/null; chflags -R nouchg $T $P3 2>/dev/null; rm -rf $T $P3 $W $W2 $WC $PA $W-build $PRW/work/prwatch__selftest-pr1-0000000; rm -f $WL; [[ -L $RZL ]] && rm -f $RZL' EXIT   # RZL: the B5 derivation check's symlinked clone; B3 freezes files under $T/$P3
export PRWATCH_TESTMODE=1 PRWATCH_STATE_DIR=$T PRWATCH_STUB_BIN=$PRW/test/stub PRWATCH_SESSION_ID=sid-A PRWATCH_PID=1
export PRWATCH_LOGIN=stubuser                           # what the launcher exports from `gh api user` (the stub gh answers the same; B6 varies it)
SE=$(date -j -f %Y-%m-%dT%H:%M:%S 2026-09-29T09:00:00 +%s)        # session start: a Tuesday, BST. Ticks use PRWATCH_NOW=$((SE+offset))
ok()   { (( n++ )); if eval "$2"; then print "ok   $1"; else print "FAIL $1"; (( fail++ )); fi; }
lockfor() { jq -nc --arg s ${1:-sid-A} --argjson e ${2:-$SE} '{session_id:$s,pid:1,started_epoch:$e}' > $T/session.lock; }
reset() { chflags -R nouchg $T 2>/dev/null; rm -rf $T/*(N) $T/.*(N); print '{"prs":{},"go_ahead":{},"repos":{"ACT-Training/Vision":"allowed","ACT-Training/Zzzt":"allowed"}}' > $T/state.json; lockfor sid-A $SE; }   # repos seeded: an unseen repo is new_repo (B12)
norepos() { jq -c '.repos={}' $T/state.json > $T/s && mv $T/s $T/state.json; }
seedrepo() { jq -c --arg r $1 --arg v $2 '.repos[$r]=$v' $T/state.json > $T/s && mv $T/s $T/state.json; }      # seedrepo <owner/repo> allowed|blocked (as given: the scripts look up case-insensitively)
rp() { jq -r --arg r ${1:l} '[.repos|to_entries[]|select(.key|ascii_downcase==$r)|.value]|first // "null"' $T/state.json; }   # repos[<repo>] in any case
review() { $B/prwatch-state.sh set ACT-Training/Vision#1 reviewing sha=abc step=council attempts=1 >/dev/null; }
post() { $B/prwatch-agenthook.sh post < $FX/$1 2>$T/err; }
ended() { $B/prwatch-agenthook.sh ended < $FX/$1 2>/dev/null; }
tj()   { jq -nc --arg t "$1" --arg c "${2:-}" '{tool_name:$t, tool_input:(if $t=="Agent" then {subagent_type:"general-purpose"} elif $c=="" then {} else {command:$c} end)}'; }   # an Agent call names its type (B7)
pre()  { tj "$@" | $B/prwatch-agenthook.sh pre 2>/dev/null; }          # pre <tool> [bash command] → hook exit code
denied() { pre "$@"; (( $? == 2 )); }
abort() { $B/prwatch-state.sh harness-abort $1 >/dev/null; }
refused() { abort $1; (( $? == 64 )); }
st()   { jq -r ".prs[\"$1\"].$2" $T/state.json; }
gone() { local i; for i in {1..50}; do kill -0 $1 2>/dev/null || return 0; /bin/sleep 0.1; done; return 1; }
cnt() { [[ -f $T/notify.log ]] && print $(( $(wc -l < $T/notify.log) )) || print 0; }
STOPF=$T/stopped-sid-A                                   # this session's stop file (stopped-<session_id>)
SS=$PRW/bin/prwatch-state.sh; S7=$PRW/.claude/skills

# --- agenthook post
reset; review
post agent-async.json; rc=$?
ok "async launch → exit 2"                 '(( rc == 2 ))'
ok "async launch → marker with key"        '[[ "$(jq -r .key $T/harness/a111.marker)" == ACT-Training/Vision#1 ]]'
ok "async launch → session stop file"      '[[ -f $STOPF ]]'
ok "async launch → one harness notice, 'off for this session'" '(( $(cnt) == 1 )) && grep -q "error harness :: Reviewers ran in the background" $T/notify.log && grep -q "off for this session" $T/notify.log'
ok "async launch → model told exact command" 'grep -q "PRWATCH HARNESS FAULT" $T/err && grep -qx "$SS harness-abort ACT-Training/Vision#1" $T/err && grep -q "stopped for this session" $T/err'
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
ok "foreground result → silent"            '(( rc == 0 )) && [[ ! -e $T/harness && ! -f $STOPF ]]'
reset; post agent-handback-withheld.json; rc=$?
ok "completed + handback withheld → silent" '(( rc == 0 )) && [[ ! -e $T/harness && ! -e $T/notify.log ]]'
reset; post agent-drift.json; rc=$?
ok "no status at all → exit 0 + hookdrift" '(( rc == 0 )) && grep -q "error hookdrift" $T/notify.log && [[ ! -f $STOPF ]]'
reset; post bash.json; rc=$?
ok "non-Agent tool → silent"               '(( rc == 0 )) && [[ ! -e $T/notify.log ]]'
reset; print -n | $B/prwatch-agenthook.sh post; rc=$?
ok "empty stdin → exit 0"                  '(( rc == 0 ))'
reset; print 'not json' | $B/prwatch-agenthook.sh post; rc=$?
ok "garbage stdin → exit 0"                '(( rc == 0 ))'
reset; post agent-async-badid.json; rc=$?
m=($T/harness/*.marker); strays=($T/**/x.marker(N) ${T:h}/x.marker(N) ${T:h:h}/x.marker(N))
ok "hostile agentId → no path escape"      '(( rc == 2 && ${#m} == 1 && ${#strays} == 0 )) && [[ ${m[1]:t} == unknown-*.marker ]]'
reset; PRWATCH_SESSION_ID= post agent-async.json; rc=$?; sf=($T/stopped-*)
ok "no session id → still writes a stop file" '(( rc == 2 && ${#sf} == 1 ))'
ok "no session id → marker is valid JSON with an empty session" '[[ $(jq -r .session $T/harness/*.marker(N) 2>/dev/null) == "" ]] && jq -e . $T/harness/*.marker(N) >/dev/null'
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
ok "race: fault still raised"              '(( rc == 2 )) && [[ -f $STOPF ]] && (( $(cnt) == 1 ))'
ok "race: marker born stopped, note gone"  '[[ -f $T/harness/a111.stopped && ! -e $T/harness/a111.marker && ! -e $T/harness/a111.ended ]]'
ok "race: gated until abort, then open"    'denied AskUserQuestion && abort ACT-Training/Vision#1 && pre AskUserQuestion'
reset; ended subagentstop-a111.json; post agent-completed-real.json; rc=$?   # real recorded foreground shape
ok "foreground agent: note removed"        '(( rc == 0 )) && [[ ! -e $T/harness/a111.ended ]] && [[ ! -f $STOPF ]]'
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
for c in "get ACT-Training/Vision#1" "harness-abort ACT-Training/Vision#1"; do
ok "live marker: state.sh ${c%% *} allowed" "pre Bash '$SS $c'"; done
ok "live marker: state.sh stop / pause denied (B2)" 'denied Bash "$SS stop" && denied Bash "$SS pause 30" && denied Bash "$SS stop-today"'
ok "live marker: state.sh piped denied"    'denied Bash "$SS get ACT-Training/Vision#1; ls"'
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
rm -f $STOPF
ok "abort succeeds, stop file is the session's" 'abort ACT-Training/Vision#1 && [[ -f $STOPF ]] && [[ -z "$(print -l $T/stopped-2*(N))" ]]'
ok "gate open after abort"                 'pre AskUserQuestion && pre Agent'
ok "abort → queued, attempts kept, no step" '[[ "$(jq -c ".prs[\"ACT-Training/Vision#1\"]|[.status,.attempts,.step,.sha]" $T/state.json)" == "[\"queued\",\"1\",null,\"abc\"]" ]]'
ok "abort → event carries the session"     'jq -e "select(.harness_abort==true and .session==\"sid-A\")" $T/events.jsonl | grep -q harness_abort'
left=($T/harness/*.marker $T/harness/*.stopped)
ok "abort → markers archived"              '(( ${#left} == 0 )) && [[ -f $T/harness/done/a111.stopped ]]'
ok "abort twice → refused"                 'refused ACT-Training/Vision#1'
reset; $SS set ACT-Training/Vision#1 posted sha=abc >/dev/null
ok "abort on posted item → refused"        'refused ACT-Training/Vision#1 && [[ $(st ACT-Training/Vision#1 status) == posted ]]'
reset; $SS set ACT-Training/Vision#1 reviewing sha=abc >/dev/null
print '{"session":"sid-A","key":"ACT-Training/Vision#1","agent":"z"}' > $T/z.stopped   # not in harness/: ignored
ok "abort without hook marker → refused"   'refused ACT-Training/Vision#1 && [[ $(st ACT-Training/Vision#1 status) == reviewing ]]'
reset; mkdir -p $T/harness; print '{"session":"sid-OLD","key":"ACT-Training/Vision#1","agent":"old"}' > $T/harness/old.marker
ok "old-session marker: gate open"         'pre AskUserQuestion'
reset; review; post agent-async.json; post taskstop-ok.json
print '{"session":"sid-OLD","key":"ACT-Training/Vision#1","agent":"old"}' > $T/harness/old.marker
ok "old-session marker: abort still works" 'abort ACT-Training/Vision#1 && [[ -f $T/harness/old.marker ]]'
hold() { : >> $T/state.lock; zsh -c "zmodload zsh/system; zsystem flock $T/state.lock; sleep $1" & pids+=($!); /bin/sleep 0.3; }   # someone else holds the lock
reset; review; post agent-async.json; post taskstop-ok.json; hold 2
ok "harness-abort: busy lock → 75, markers kept for a retry" '(PRWATCH_LOCK_WAIT=1 $SS harness-abort ACT-Training/Vision#1 >/dev/null; (( $? == 75 ))) && [[ -f $T/harness/a111.stopped && ! -e $T/harness/done/a111.stopped && $(st ACT-Training/Vision#1 status) == reviewing ]]'
ok "harness-abort: retry succeeds once the lock is free" 'abort ACT-Training/Vision#1 && [[ -f $T/harness/done/a111.stopped && $(st ACT-Training/Vision#1 status) == queued ]]'
reset; review; post agent-async.json; post taskstop-ok.json; mkdir $T/state.json.tmp        # the requeue write can't happen
out=$($SS harness-abort ACT-Training/Vision#1 2>/dev/null); rc=$?
ok "harness-abort: failed write → 70, markers kept, nothing else done" '(( rc == 70 )) && [[ $out == "state write failed" && -f $T/harness/a111.stopped && $(st ACT-Training/Vision#1 status) == reviewing ]] && ! grep -q harness_abort $T/events.jsonl'
rmdir $T/state.json.tmp
ok "harness-abort: retry after the failed write succeeds" 'abort ACT-Training/Vision#1 && [[ $(st ACT-Training/Vision#1 status) == queued && -f $T/harness/done/a111.stopped ]]'

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

# --- cleanup --sweep archives other days' markers and drops old session files (test mode: never touches real worktrees)
reset; mkdir -p $T/harness
print '{}' > $T/harness/old1.marker; print '{}' > $T/harness/old2.stopped; print '{}' > $T/harness/new.marker; : > $T/harness/old3.ended
touch -t $(date -v-2d +%Y%m%d%H%M) $T/harness/old1.marker $T/harness/old2.stopped $T/harness/old3.ended
: > $T/stopped-sid-OLD; : > $T/eod-done-sid-OLD; : > $T/eod-done-sid-A; touch -t $(date -v-3d +%Y%m%d%H%M) $T/stopped-sid-OLD $T/eod-done-sid-OLD
$B/prwatch-cleanup.sh --sweep
ok "sweep archives old markers and notes"  '[[ -f $T/harness/done/old1.marker && -f $T/harness/done/old2.stopped && -f $T/harness/done/old3.ended ]]'
ok "sweep keeps today's marker"            '[[ -f $T/harness/new.marker ]]'
ok "sweep drops stopped-/eod-done- older than two days, keeps this session's" '[[ ! -e $T/stopped-sid-OLD && ! -e $T/eod-done-sid-OLD && -f $T/eod-done-sid-A ]]'

# --- throttle window
reset; $B/prwatch-notify.sh error harness; $B/prwatch-notify.sh error harness
ok "notify throttled within 30 min"        '(( $(cnt) == 1 ))'
touch -t $(date -v-31M +%Y%m%d%H%M) $T/notify-throttle/error-harness; $B/prwatch-notify.sh error harness
ok "notify again after 30 min"             '(( $(cnt) == 2 ))'
reset; $B/prwatch-notify.sh error hookdrift; $B/prwatch-notify.sh error hookdrift
ok "hookdrift wording + throttle"          '(( $(cnt) == 1 )) && grep -q "error hookdrift :: Claude Code changed how it reports subagents" $T/notify.log'
reset; $B/prwatch-notify.sh error session-ended; $B/prwatch-notify.sh cap 8 2>/dev/null; rc=$?
ok "session-ended wording; cap kind gone (64)" 'grep -q "error session-ended :: The PR watcher stopped before the end of its session" $T/notify.log && (( rc == 64 )) && ! grep -q " cap " $T/notify.log'

# --- guard, settings, launcher
g() { jq -nc --arg c "$1" '{tool_input:{command:$c}}' | $B/prwatch-guard.sh >/dev/null 2>&1; print $?; }
ok "guard: canonical harness-abort"        '[[ $(g "$SS harness-abort ACT-Training/Vision#1") == 0 ]]'
ok "guard: env-prefixed harness-abort"     '[[ $(g "PRWATCH_SESSION_ID=x $SS harness-abort ACT-Training/Vision#1") == 2 ]]'
ok "guard: piped harness-abort"            '[[ $(g "$SS harness-abort ACT-Training/Vision#1 | cat") == 2 ]]'
ok "guard: model cannot run agenthook"     '[[ $(g "$PRW/bin/prwatch-agenthook.sh post") == 2 ]]'
ok "guard: test/guard-cases.txt and test/sec/guard-cases.tsv identical" 'cmp -s $PRW/test/guard-cases.txt $PRW/test/sec/guard-cases.tsv'
C=$PRW/config/settings.json
ok "settings: env var set"                 '[[ "$(jq -r .env.CLAUDE_CODE_DISABLE_BACKGROUND_TASKS $C)" == 1 ]]'
ok "settings: post hook on Agent|TaskStop" 'jq -e ".hooks.PostToolUse[]|select(.matcher==\"Agent|TaskStop\")|.hooks[0].command|endswith(\"agenthook.sh post\")" $C >/dev/null'
ok "settings: SubagentStop → ended"        'jq -e ".hooks.SubagentStop[0].hooks[0].command|endswith(\"agenthook.sh ended\")" $C >/dev/null'
ok "settings: pre gate hook on *, fails closed" 'jq -e ".hooks.PreToolUse[]|select(.matcher==\"*\")|.hooks[0].command|endswith(\"agenthook.sh pre || exit 2\")" $C >/dev/null'
ok "settings: state/ write-denied"         'jq -e ".sandbox.filesystem.denyWrite|index(\"/Users/jack/prwatch/state\")" $C >/dev/null && jq -e ".permissions.deny|index(\"Write(//Users/jack/prwatch/state/**)\")" $C >/dev/null'
L=${PRWATCH_LAUNCHER:-$HOME/Desktop/PR Watcher.command}
e=$(grep -n '^export CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1' "$L" 2>/dev/null | cut -d: -f1); c=$(grep -n '^"$CLAUDE_BIN" ' "$L" 2>/dev/null | cut -d: -f1)
ok "launcher exports var before claude"    '[[ -n $e && -n $c ]] && (( e < c ))'

# --- sandboxed tests (docs/fix-sandbox-tests.md)
AN=$PRW/angles/testing-build.md
ok "settings: .NET uses IPv4 in the sandbox" '[[ "$(jq -r .env.DOTNET_SYSTEM_NET_DISABLEIPV6 $C)" == 1 ]]'
for sc in prep buildrun post tick state notify cleanup prompthook skillhook; do
ok "$sc re-execs with env -i (settings env can't leak in)" "head -20 $B/prwatch-$sc.sh | grep -q 'exec /usr/bin/env -i'"; done
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
NG=$B/prwatch-ngtest.sh; NSHA=0123456789abcdef0123456789abcdef01234567; NBW=$W-build
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
ok "review skill: harness-abort retried when state busy" 'grep -q "for \"state busy\", run it again" $S7/prwatch-review/SKILL.md'

# ============================================================================================================
# B1 — the 8-hour window from the lock's started_epoch (plan D18). Stub gh: every PR is open at sha abc, 0 lines;
# `api user` answers ${PRWATCH_STUB_LOGIN-stubuser} (the launcher's login capture, B6), `api user/orgs` nothing, a
# timeline call the raw JSON of one review_requested event for that same login (dated 2099, so it is always after
# posted_at; the tick pipes it into jq --arg me); `search prs` (the inbox search, taken only when PRWATCH_ONLY_PR is unset:
# tks) answers the rows in $T/search.json, or [] without that file; every call is appended to $T/gh-calls.log (B6/B12
# assert that no `pr view` happened). Env lookups happen at run time (quoted heredoc).
mkstub() { mkdir -p $T/stub; ln -sf $PRW/test/stub/osascript $T/stub/osascript
  cat > $T/stub/gh <<'EOF'
#!/bin/zsh
print -r -- "$*" >> "${PRWATCH_STATE_DIR:-/tmp}/gh-calls.log"
case "$1 $2" in
  "pr view") print '{"headRefOid":"abc","isDraft":false,"state":"OPEN","title":"t","author":{"login":"x"},"files":[]}' ;;
  "search prs") sj="${PRWATCH_STATE_DIR:-/tmp}/search.json"; if [[ -f $sj ]]; then /bin/cat "$sj"; else print '[]'; fi ;;
  "api user") print -r -- "${PRWATCH_STUB_LOGIN-stubuser}" ;;
  api\ repos/*/timeline) /usr/bin/jq -nc --arg l "${PRWATCH_STUB_LOGIN-stubuser}" '[{event:"review_requested",requested_reviewer:{login:$l},created_at:"2099-01-01T00:00:00Z"}]' ;;
esac
exit 0
EOF
  chmod +x $T/stub/gh; }
ep()  { date -j -f %Y-%m-%dT%H:%M:%S "$1:00" +%s; }                                     # local wall clock → epoch (TZ=Europe/London)
win() { PRWATCH_NOW=$1 $B/prwatch-tick.sh --window ${2:-} 2>/dev/null; }      # the pure read; $2 may be --dry-run
wst() { win "$@" | jq -r '[.status, .kind // "-"] | join(" ")'; }
tko() { local o=$1; shift; mkstub; PRWATCH_STUB_BIN=$T/stub PRWATCH_ONLY_PR=$o PRWATCH_NOW=$1 $B/prwatch-tick.sh ${2:-} 2>/dev/null; }   # full tick for ONLY=$1 ($3 = --dry-run)
tk()  { tko ACT-Training/Zzzt#9 "$@"; }                                                                                  # full tick ($2 = --dry-run)
tks() { mkstub; PRWATCH_STUB_BIN=$T/stub PRWATCH_NOW=$1 env -u PRWATCH_ONLY_PR $B/prwatch-tick.sh ${2:-} 2>/dev/null; }   # full tick through the stub SEARCH (rows from $T/search.json; PRWATCH_LOGIN stays exported)
reset
ok "B1: T+0 → in_window"                   '[[ $(wst $SE) == "in_window -" ]]'
ok "B1: T+7h29m59s → in_window"            '[[ $(wst $((SE+26999))) == "in_window -" ]]'
ok "B1: T+7h30 → start_closed"             '[[ $(wst $((SE+27000))) == "start_closed -" ]]'
ok "B1: T+7h59m59s → start_closed"         '[[ $(wst $((SE+28799))) == "start_closed -" ]]'
ok "B1: T+8h → session_over"               '[[ $(wst $((SE+28800))) == "session_over -" ]]'
ok "B1: T-1m → error clock_before_start, never in_window" '[[ $(wst $((SE-60))) == "error clock_before_start" ]]'
ok "B1: common keys (started, elapsed_min, starts_until, ends_at)" '[[ $(win $((SE+600)) | jq -r "[.started[0:16], .elapsed_min, .starts_until, .ends_at] | join(\" \")") == "2026-09-29T09:00 10 16:30 17:00" ]]'
ok "B1: session_over carries eod_due"      '[[ $(win $((SE+28800)) | jq -c "[.status,.eod_due]") == "[\"session_over\",true]" ]]'
ok "B1: no cap/hm keys in --window"        '[[ $(win $SE | jq "has(\"hm\"),has(\"cap\"),has(\"councils_today\"),has(\"cap_left\")" | sort -u) == false ]]'
lockfor sid-A $(ep 2026-09-29T22:00)                                             # a session that crosses midnight
ok "B1: midnight crossed (wall-clock form) → in_window" '[[ $(wst 2026-09-30T01:00) == "in_window -" && $(win 2026-09-30T01:00 | jq .elapsed_min) == 180 ]]'
lockfor sid-A $(ep 2026-10-24T22:00)                                             # DST ends 2026-10-25 02:00 BST → 01:00 GMT
ok "B1: DST end: 22:00 BST → 05:00 GMT is 8 h → session_over (epoch pair)" '[[ $(wst $(( $(ep 2026-10-24T22:00) + 28800 ))) == "session_over -" ]]'
ok "B1: DST end: wall-clock form converts through the zone (7 h on the clock = 8 h real)" '[[ $(wst 2026-10-25T05:00) == "session_over -" && $(win 2026-10-25T05:00 | jq .elapsed_min) == 480 ]]'
lockfor sid-A $(ep 2026-03-28T22:00)                                             # DST starts 2026-03-29 01:00 GMT → 02:00 BST
ok "B1: DST start: 22:00 GMT → 06:30 BST is 7½ h → start_closed, not over" '[[ $(wst 2026-03-29T06:30) == "start_closed -" && $(win 2026-03-29T06:30 | jq .elapsed_min) == 450 ]]'
ok "B1: DST start: epoch pair agrees"      '[[ $(wst $(( $(ep 2026-03-28T22:00) + 27000 ))) == "start_closed -" ]]'
lockfor sid-A $(ep 2026-10-03T10:00)                                             # a Saturday
ok "B1: Saturday inside 8 h → in_window (no weekday test)" '[[ $(wst $(( $(ep 2026-10-03T10:00) + 3600 ))) == "in_window -" ]]'
print '{"session_id":"sid-A","pid":1}' > $T/session.lock
ok "B1: missing started_epoch → error no_session_start" '[[ $(wst $SE) == "error no_session_start" ]]'
print '{"session_id":"sid-A","pid":1,"started_epoch":"abc"}' > $T/session.lock
ok "B1: non-numeric started_epoch → error no_session_start" '[[ $(wst $SE) == "error no_session_start" ]]'
rm -f $T/session.lock
ok "B1: dry run without a lock → error, never 'start now'" '[[ $(wst $SE --dry-run) == "error no_session_start" && ! -e $T/session.lock ]]'
reset; j=$(tk $SE --dry-run)
ok "B1: full tick JSON: window keys present, cap keys gone" '[[ $(jq -r "[.status,.can_start,.elapsed_min,.starts_until,.ends_at]|join(\" \")" <<<$j) == "ok true 0 16:30 17:00" ]] && [[ $(jq "has(\"hm\"),has(\"cap\"),has(\"cap_default\"),has(\"cap_max\"),has(\"cap_left\"),has(\"councils_today\")" <<<$j | sort -u) == false ]]'
reset; j=$(tk $((SE+27600)))
ok "B1: start_closed still classifies (ok, can_start false, item queued)" '[[ $(jq -r "[.status,.can_start,.items[0].reason]|join(\" \")" <<<$j) == "ok false new" && $(st ACT-Training/Zzzt#9 status) == queued ]]'
reset; cp $T/state.json $T/state.before; j=$(tk $((SE+28800)))
ok "B1: session_over writes no state, no event" '[[ $(jq -c "[.status,.eod_due]" <<<$j) == "[\"session_over\",true]" ]] && cmp -s $T/state.json $T/state.before && [[ ! -e $T/events.jsonl ]]'
# B1.17 eod-done: once per session, counted from this session's event lines
reset; : > $T/eod-done-sid-A; : > $T/events.jsonl
ok "B1.17: eod-done-<sid> present → eod_due false, events untouched" '[[ $(tk $((SE+28800)) | jq .eod_due) == false ]] && [[ ! -s $T/events.jsonl ]]'
reset; for kv in "1 reviewing" "1 posted" "2 ready" "3 queued" "4 failed" "5 asking" "6 reviewing"; do $SS set ACT-Training/Vision#${kv% *} ${kv#* } sha=abc >/dev/null; done
print '{"t":"x","session":"sid-OLD","key":"ACT-Training/Vision#7","status":"posted"}' >> $T/events.jsonl   # another session's line
ok "B1.17: events carry the session"       '[[ $(jq -r .session $T/events.jsonl | sort -u | tr "\n" " ") == "sid-A sid-OLD " ]]'
ok "B1.17: eod-done before END → 64 'session not over'" '(out=$(PRWATCH_NOW=$((SE+28799)) $SS eod-done); (( $? == 64 )) && [[ $out == "session not over" ]]) && [[ ! -e $T/eod-done-sid-A ]]'
ok "B1.17: eod-done under another session → 5" '(PRWATCH_SESSION_ID=sid-B PRWATCH_NOW=$((SE+28800)) $SS eod-done >/dev/null; (( $? == 5 )))'
out=$(PRWATCH_NOW=$((SE+28800)) $SS eod-done); rc=$?
ok "B1.17: eod-done counts last status per key, this session only" '(( rc == 0 )) && [[ $out == "{\"posted\":1,\"waiting\":2,\"not_started\":1,\"failed\":1}" && -f $T/eod-done-sid-A ]] && [[ $(jq -c "select(.eod_done==true)|[.session,.posted,.waiting,.not_started,.failed]" $T/events.jsonl) == "[\"sid-A\",1,2,1,1]" ]]'
ne=$(wc -l < $T/events.jsonl); out2=$(PRWATCH_NOW=$((SE+28800)) $SS eod-done); rc=$?
ok "B1.17: eod-done twice → same counts, nothing written" '(( rc == 0 )) && [[ $out2 == $out ]] && (( $(wc -l < $T/events.jsonl) == ne ))'
ok "B1.17: unparseable PRWATCH_NOW → 64 'bad PRWATCH_NOW'" '(out=$(PRWATCH_NOW=yesterday $B/prwatch-tick.sh --window 2>&1); (( $? == 64 )) && [[ $out == *"bad PRWATCH_NOW"* ]]) && (PRWATCH_NOW=2026-13-99T99:99 $SS eod-done >/dev/null 2>&1; (( $? == 64 )))'
# B1.18 --window is a pure read; prep enforces the window; a recreated lock is PRWATCH_LOCK_JSON + recreated
reset; lockfor sid-B; HB=$PRW/state/activity; mkdir -p $PRW/state; touch -t 202601010000 $HB; hb0=$(stat -f %m $HB)
win $SE >/dev/null; win $SE --dry-run >/dev/null
ok "B1.18: --window leaves the heartbeat alone" '(( $(stat -f %m $HB) == hb0 ))'; touch $HB     # restore the live heartbeat
ok "B1.18: --window under another session's lock: no notice, no lock change" '[[ ! -e $T/notify.log && $(jq -r .session_id $T/session.lock) == sid-B && $(jq "has(\"recreated\")" $T/session.lock) == false ]]'
pk() { PRWATCH_ARCHIVE_DIR=$T/archive PRWATCH_GIT_BASE=$T/nogit $B/prwatch-prep.sh "$@" 2>&1; }   # prep <key> <sha40> <round> against a git base that cannot be cloned
pp() { pk ACT-Training/Zzzt#9 0123456789abcdef0123456789abcdef01234567 1; }
WX=$(grep 'window closed for new reviews' $B/prwatch-prep.sh | grep -oE 'exit [0-9]+' | grep -oE '[0-9]+' | sort -u)   # the one window exit code
ok "B1.18: prep defines one window exit code" '[[ $WX == <-> ]] && (( WX >= 20 && WX != 24 && WX != 26 ))'
reset; out=$(PRWATCH_NOW=$((SE+27060)) pp); rc=$?
ok "B1.18: prep at T+7h31 → window closed, nothing done" '(( rc == WX )) && [[ $out == "window closed for new reviews" && ! -e $T/archive ]]'
reset; print '{"session_id":"sid-A","pid":1}' > $T/session.lock; out=$(PRWATCH_NOW=$SE pp); rc=$?
ok "B1.18: prep without started_epoch → 25 no session start, nothing done" '(( rc == 25 )) && [[ $out == "no session start" && ! -e $T/archive ]]'
reset; out=$(PRWATCH_NOW=$((SE+26940)) pp); rc=$?
ok "B1.18: prep at T+7h29 goes ahead (then the stub clone fails: 20)" '(( rc == 20 )) && [[ -e $T/archive ]]'
reset; out=$(PRWATCH_NOW=$SE PRWATCH_SESSION_ID=sid-B pp); rc=$?
ok "B1.18: prep from another session → 25 superseded, nothing done" '(( rc == 25 )) && [[ $out == superseded && ! -e $T/archive ]]'
reset; : > $T/state.json; out=$(PRWATCH_NOW=$SE pp); rc=$?
ok "B1.18: prep with unreadable state → 25 'could not read state'" '(( rc == 25 )) && [[ $out == "could not read state" && ! -e $T/archive ]]'
reset; out=$(PRWATCH_SESSION_ID= pp); rc=$?
ok "B1.18: test mode, no session (T2) → not gated" '(( rc == 20 )) && [[ -e $T/archive ]]'
LJ=$(jq -nc --argjson e $SE '{session_id:"sid-A",pid:1,started_epoch:$e}')
halflock() { reset; jq -nc --argjson e $SE '{pid:1,started_epoch:$e}' > $T/session.lock; cp $T/session.lock $T/lock.before; }   # no session_id: the tick may recreate it
halflock; PRWATCH_LOCK_JSON=$LJ tk $SE >/dev/null
ok "B1.18: recreated lock = PRWATCH_LOCK_JSON + recreated, session_id is the caller's" '[[ $(jq -c . $T/session.lock) == $(jq -c ". + {recreated:true}" <<<$LJ) && $(jq -r .session_id $T/session.lock) == $PRWATCH_SESSION_ID ]]'
for bad in "unset" "not json" '{"session_id":"sid-B","pid":1,"started_epoch":1}'; do halflock
  if [[ $bad == unset ]]; then j=$(tk $SE); else j=$(PRWATCH_LOCK_JSON=$bad tk $SE); fi
  ok "B1.18: PRWATCH_LOCK_JSON $bad → error no_session_start, no lock written" '[[ $(jq -r "[.status,.kind]|join(\" \")" <<<$j) == "error no_session_start" ]] && cmp -s $T/session.lock $T/lock.before'; done

# B2 — stop / pause are hook-owned, session-scoped (D20)
PH=$B/prwatch-prompthook.sh
ph()  { jq -nc --arg p "$1" '{hook_event_name:"UserPromptSubmit",session_id:"cc-1",prompt:$p}' | $PH prompt 2>&1; }
req() { mkdir -p $T/$1; jq -nc --arg s ${3:-sid-A} --arg n $2 '{session:$s,n:$n}' > $T/$1/request.json; }   # what the hook writes: req stop stop | req pause 30 [sid]
reset; : > $STOPF
ok "B2: stopped-sid-A → tick says stopped"  '[[ $(tk $SE | jq -r .status) == stopped ]]'
ok "B2: stop file is session-scoped: sid-B does not see it" 'lockfor sid-B; [[ $(PRWATCH_SESSION_ID=sid-B tk $SE | jq -r .status) == ok ]]'
ok "B2: session_over wins over the stop file (eod still due)" 'lockfor sid-A; [[ $(tk $((SE+28800)) | jq -r .status) == session_over ]]'
reset; : > $T/stopped-2026-09-29; : > $T/stopped-$(date +%F)
ok "B2/B10: legacy stopped-<date> ignored"  '[[ $(tk $SE | jq -r .status) == ok ]]'
reset
ok "B2: stop from another session → 5"     '(PRWATCH_SESSION_ID=sid-B $SS stop >/dev/null; (( $? == 5 ))) && [[ ! -e $T/stopped-sid-B && ! -e $STOPF ]]'
out=$($SS stop); rc=$?
ok "B2: stop with no request → 64, nothing stopped" '(( rc == 64 )) && [[ $out == "only Jack can stop the watcher, by typing stop at the prompt" && ! -e $STOPF ]] && [[ $(jq -c "select(.stop_refused==true)|.session" $T/events.jsonl) == "\"sid-A\"" ]]'
req stop stop sid-B
ok "B2: request from sid-B → 64"           '($SS stop >/dev/null; (( $? == 64 ))) && [[ ! -e $STOPF ]]'
req stop stop; touch -t $(date -v-2M +%Y%m%d%H%M.%S) $T/stop/request.json
ok "B2: request 2 min old → 64"            '($SS stop >/dev/null; (( $? == 64 ))) && [[ ! -e $STOPF ]]'
req stop stop; touch -t $(date -v-30S +%Y%m%d%H%M.%S) $T/stop/request.json; out=$($SS stop); rc=$?
ok "B2: request 30 s old → accepted and consumed" '(( rc == 0 )) && [[ $out == stopped && -f $STOPF && ! -e $T/stop/request.json ]] && [[ $(jq -c "select(.stop==true)|.session" $T/events.jsonl) == "\"sid-A\"" ]]'
ok "B2: second stop → 64"                  '($SS stop >/dev/null; (( $? == 64 )))'
reset; out=$(ph "stop")
ok "B2: ph 'stop' → stopped, one PRWATCH STOP line" '[[ $out == "PRWATCH STOP: the watcher is stopped for this session - no more checks or reviews." && -f $STOPF && ! -e $T/stop/request.json ]]'
reset; out=$(PRWATCH_SESSION_ID=sid-B ph "stop")
ok "B2: ph 'stop' from a stale window → not done" '[[ $out == "PRWATCH STOP: not done (this window is not the current watcher)." && ! -e $STOPF && ! -e $T/stopped-sid-B ]]'
reset; out=$(PRWATCH_NOW=$((SE+600)) ph $'  PAUSE 30\n')
ok "B2: ph 'pause 30' (trimmed, any case) → paused_until = now + 30 min, told until HH:MM" '[[ $(jq .paused_until $T/state.json) == $((SE+2400)) && $out == "PRWATCH PAUSE: checks skipped for 30 minutes (until 09:40)." && ! -e $T/pause/request.json ]]'
ok "B2: pause event + tick says paused until 09:40" '[[ $(jq -c "select(.pause==30)|[.session,.until]" $T/events.jsonl) == "[\"sid-A\",$((SE+2400))]" && $(tk $((SE+1200)) | jq -c "[.status,.until]") == "[\"paused\",\"09:40\"]" ]]'
ok "B2: pause over → ticks again"          '[[ $(tk $((SE+2400)) | jq -r .status) == ok ]]'
reset; out=$(ph "pause 500")
ok "B2: pause 500 → not changed (1 to 480)" '[[ $out == "PRWATCH PAUSE: not changed (pause must be 1 to 480)." && $(jq .paused_until $T/state.json) == null ]] && [[ $(jq -c "select(.pause_refused!=null)|.pause_refused" $T/events.jsonl 2>/dev/null) == "" ]]'
reset; out=$(PRWATCH_SESSION_ID=sid-B ph "pause 30")
ok "B2: ph 'pause' from a stale window → not changed" '[[ $out == "PRWATCH PAUSE: not changed (this window is not the current watcher)." && $(jq .paused_until $T/state.json) == null ]]'
reset
for pr in "pause x" "stop please" "pause 9999" "pause" "stop; ls" "cap 8" "d" "" $'stop\nrm -rf x'; do out=$(ph "$pr"); rc=$?
  ok "B2/B10: ph ignores '${pr//$'\n'/<NL>}'" '(( rc == 0 )) && [[ -z $out && ! -e $STOPF && ! -e $T/stop && ! -e $T/pause && ! -e $T/cap && $(jq .paused_until $T/state.json) == null ]]'; done
out=$(print 'not json' | $PH prompt 2>&1); rc=$?
ok "B2: garbage stdin → exit 0, silent"    '(( rc == 0 )) && [[ -z $out ]]'
ok "B2: pause with no request → 64, pause_refused" '(out=$($SS pause 30); (( $? == 64 )) && [[ $out == "only Jack can pause the watcher, by typing pause N at the prompt" ]]) && [[ $(jq -c "select(.pause_refused==30)|.session" $T/events.jsonl) == "\"sid-A\"" && $(jq .paused_until $T/state.json) == null ]]'
req pause 30; ok "B2: pause 0 / 481 / x → 64 even with a request" '($SS pause 0 >/dev/null; (( $? == 64 ))) && ($SS pause 481 >/dev/null; (( $? == 64 ))) && ($SS pause x >/dev/null; (( $? == 64 ))) && [[ -e $T/pause/request.json ]]'
ok "B2: request says 30, call says 60 → 64" '($SS pause 60 >/dev/null; (( $? == 64 ))) && [[ $(jq .paused_until $T/state.json) == null ]]'
ok "B2: pause 30 with its request → accepted, consumed" '[[ $(PRWATCH_NOW=$SE $SS pause 30 | jq .paused_until) == $((SE+1800)) && ! -e $T/pause/request.json ]]'
reset; lockfor sid-A $(ep 2026-10-24T22:00); pu=$(( $(ep 2026-10-25T00:30) + 3600 ))   # pause 60 at 00:30 BST; clocks go back at 02:00 BST
jq --argjson u $pu '.paused_until=$u' $T/state.json > $T/s && mv $T/s $T/state.json
ok "B2: pause across the DST change → expired (epoch compare, not the wall clock)" '[[ $(tk $((pu+1800)) | jq -r .status) == ok ]]'
reset; jq --argjson u $((SE+30000)) '.paused_until=$u' $T/state.json > $T/s && mv $T/s $T/state.json
ok "B2: END inside a pause → session_over" '[[ $(tk $((SE+28800)) | jq -r .status) == session_over && $(tk $((SE+28000)) | jq -r .status) == paused ]]'

# B2.7 / B2.8 — the launcher's exit notice, driven by --window (D21): stub claude exits at once, launcher run with </dev/null
mkclaude() { mkdir -p $T/stub; cat > $T/stub/claude <<'EOF'
#!/bin/zsh
[[ ${1:-} == --version ]] && { print "2.1.300 (Claude Code)"; exit 0; }
cp "$PRWATCH_STATE_DIR/session.lock" "$PRWATCH_STATE_DIR/lock-seen.json"
print -r -- "PRWATCH_STARTED_EPOCH=${PRWATCH_STARTED_EPOCH:-}" > "$PRWATCH_STATE_DIR/env-seen.txt"
print -r -- "PRWATCH_LOCK_JSON=${PRWATCH_LOCK_JSON:-}" >> "$PRWATCH_STATE_DIR/env-seen.txt"
print -r -- "PRWATCH_LOGIN=${PRWATCH_LOGIN:-}" >> "$PRWATCH_STATE_DIR/env-seen.txt"
print -r -- "SCRUB=${TEAMS_WEBHOOK_URL-unset},${APP_NAME-unset},${CLAUDE_PLUGIN_DATA-unset},${PRWATCH_ENGINE-unset} DEPTH=${CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH:-}" >> "$PRWATCH_STATE_DIR/env-seen.txt"
print -rl -- "$@" > "$PRWATCH_STATE_DIR/argv.txt"
/bin/ls -lOd "${PRWATCH_TEST_MEMROOT:-/nonexistent}"/*-grumpy-*(N) 2>/dev/null | /usr/bin/grep -c uchg > "$PRWATCH_STATE_DIR/frozen-seen.txt"
pd=$(/usr/bin/grep -x -A1 -- --plugin-dir "$PRWATCH_STATE_DIR/argv.txt" | /usr/bin/tail -1)   # the snapshot: folder and a file locked, .in_use/ writable
[[ -n $pd ]] && print -r -- "$(/bin/ls -lOd $pd | /usr/bin/grep -c uchg),$(/bin/ls -lO $pd/agents/grumpy-code-reviewer.md | /usr/bin/grep -c uchg),$(: > $pd/.in_use/stub 2>/dev/null && print w || print ro)" > "$PRWATCH_STATE_DIR/snap-seen.txt"
[[ ${PWH_CLAUDE_STOP:-} == 1 ]] && : > "$PRWATCH_STATE_DIR/stopped-$PRWATCH_SESSION_ID"
[[ ${PWH_CLAUDE_TAKEOVER:-} == 1 ]] && { /usr/bin/jq '.session_id="sid-NEW" | .frozen_memory=[.frozen_memory[0]]' "$PRWATCH_STATE_DIR/session.lock" > "$PRWATCH_STATE_DIR/l.tmp" && /bin/mv "$PRWATCH_STATE_DIR/l.tmp" "$PRWATCH_STATE_DIR/session.lock"; }   # a newer window took the lock
[[ ${PWH_CLAUDE_HUP:-} == 1 ]] && kill -HUP $PPID                       # Jack closed the Terminal window
exit 0
EOF
chmod +x $T/stub/claude; }
launch() {   # launch <started_epoch|""> [extra env assignments]   (reset wipes $T, so the stubs are remade after it)
  reset; mkstub; mkclaude; runl "$@"; }
runl() {     # the launcher alone, on whatever $T holds; config, plugins list and memory root are always fixtures (B3)
  rm -f $T/notify-throttle/*(N); PRWATCH_STUB_BIN=$T/stub PRWATCH_TEST_STARTED_EPOCH=$1 env -u PRWATCH_LOGIN \
    PRWATCH_TEST_CONF=$P3/noconf PRWATCH_TEST_PINS=$P3/nopins.json PRWATCH_TEST_MEMROOT=$P3/mem PRWATCH_TEST_CACHE=$P3/cache "${@:2}" /bin/zsh "$L" </dev/null >$T/launch.out 2>&1; print $? > $T/launch.rc; }   # -u: the login must come from the launcher, not from this harness (M6)
if [[ -f $L ]]; then
  nowe=$(date +%s); launch $((nowe-32400))
  ok "B2.7: launcher ran the stub claude, passed the lock and the start epoch" '[[ -f $T/lock-seen.json && $(jq .started_epoch $T/lock-seen.json) == $((nowe-32400)) ]] && grep -q "^PRWATCH_STARTED_EPOCH=$((nowe-32400))$" $T/env-seen.txt && [[ $(sed -n "s/^PRWATCH_LOCK_JSON=//p" $T/env-seen.txt | jq -r .session_id) == $(jq -r .session_id $T/lock-seen.json) ]]'
  ok "B2.7: lock has started (ISO) derived from started_epoch" '[[ $(jq -r .started $T/lock-seen.json) == $(date -r $((nowe-32400)) -Iseconds) ]]'
  ok "B2.7: started 9 h ago → session over → no session-ended notice" '! grep -q session-ended $T/notify.log 2>/dev/null && ! grep -q "stopped before" $T/launch.out'
  nowe=$(date +%s); launch $nowe
  ok "B2.7: started now, claude exited → one session-ended notice" '[[ $(grep -c "error session-ended" $T/notify.log) == 1 ]]'
  launch $(date +%s) PWH_CLAUDE_STOP=1
  ok "B2.7: started now + stop file → no notice" '! grep -q session-ended $T/notify.log 2>/dev/null && [[ -f $T/stopped-$(jq -r .session_id $T/lock-seen.json) ]]'
  ok "B2.7: lock removed by its own launcher"  '[[ ! -e $T/session.lock ]]'
  nowe=$(date +%s); launch "" PRWATCH_STARTED_EPOCH=1
  ok "B2.8a: PRWATCH_STARTED_EPOCH in the environment is never read back" 'se8=$(jq .started_epoch $T/lock-seen.json 2>/dev/null); [[ $se8 == <-> ]] && (( se8 >= nowe && se8 <= nowe + 5 ))'
  ok "B2.7: banner has no weekday/cap/time-of-day lines" '! grep -Eiq "weekend|Mon.?Fri|cap [0-9]|office.hours|08:00.{0,3}1[56]:[03]0" $T/launch.out && grep -q "Runs for 8 hours from now" $T/launch.out'
else print "skip B2.7/B2.8a (no launcher at $L; set PRWATCH_LAUNCHER)"; fi
# B2.8b code shape: the override lives only in the launcher's PRWATCH_TESTMODE block; no script reads it
outside=$(awk '/PRWATCH_TESTMODE/{b=1} /PRWATCH_TEST_STARTED_EPOCH/ && !b {print NR} /^fi([ \t;]|$)/{b=0}' "$L" 2>/dev/null)
ok "B2.8b: PRWATCH_TEST_STARTED_EPOCH only inside the launcher's test-mode block" '[[ -z $outside ]] && (( $(grep -c PRWATCH_TEST_STARTED_EPOCH "$L" 2>/dev/null) >= 1 ))'
ok "B2.8b: no script reads PRWATCH_TEST_STARTED_EPOCH" '! grep -rq PRWATCH_TEST_STARTED_EPOCH $B'
ok "B2.8b: launcher never reads its own outputs" '! grep -v "^export PRWATCH_STARTED_EPOCH=" "$L" | sed "s/#.*//" | grep -Eq "[^A-Za-z_]PRWATCH_(STARTED_EPOCH|LOCK_JSON)"'
ok "B2.8b: launcher watchdog and exit path use --window, no clock of their own" '(( $(grep -c "prwatch-tick.sh\" --window\|prwatch-tick.sh --window" "$L") >= 2 )) && ! grep -Eq "date \+%u|date \+%H%M|10#\\\$hm" "$L"'

# B8 — scheduling gate: one job, one string
sg() { jq -nc --arg t "$1" --arg c "${2:-}" --arg p "${3:-}" --argjson r ${4:-null} '{tool_name:$t,tool_input:({cron:$c,prompt:$p}+(if $r==null then {} else {recurring:$r} end))}' | $PH sched 2>/dev/null; print $?; }
ok "B8: the tick job allowed (recurring absent or true)" '[[ $(sg CronCreate "*/15 * * * *" /prwatch-tick) == 0 && $(sg CronCreate "*/15 * * * *" /prwatch-tick true) == 0 ]]'
ok "B8: CronList / CronDelete allowed"     '[[ $(sg CronList) == 0 && $(sg CronDelete) == 0 ]]'
ok "B8: both old strings denied"           '[[ $(sg CronCreate "*/15 8-15 * * 1-5" /prwatch-tick) == 2 && $(sg CronCreate "3 16 * * 1-5" /prwatch-eod) == 2 ]]'
ok "B8: /prwatch-eod on any cron denied"   '[[ $(sg CronCreate "*/15 * * * *" /prwatch-eod) == 2 && $(sg CronCreate "3 17 * * *" /prwatch-eod) == 2 ]]'
ok "B8: other cadence (*/10) denied"       '[[ $(sg CronCreate "*/10 * * * *" /prwatch-tick) == 2 && $(sg CronCreate "* * * * *" /prwatch-tick) == 2 ]]'
ok "B8: extra field / string recurring denied" '[[ $(jq -nc "{tool_name:\"CronCreate\",tool_input:{cron:\"*/15 * * * *\",prompt:\"/prwatch-tick\",once:true}}" | $PH sched 2>/dev/null; print $?) == 2 && $(jq -nc "{tool_name:\"CronCreate\",tool_input:{cron:\"*/15 * * * *\",prompt:\"/prwatch-tick\",recurring:\"true\"}}" | $PH sched 2>/dev/null; print $?) == 2 ]]'
ok "B8: extra text / one-shot / 'stop' denied" '[[ $(sg CronCreate "*/15 * * * *" "/prwatch-tick then stop") == 2 && $(sg CronCreate "*/15 * * * *" /prwatch-tick false) == 2 && $(sg CronCreate "*/15 * * * *" "stop") == 2 ]]'
ok "B8: ScheduleWakeup / RemoteTrigger / unknown / garbage denied" '[[ $(sg ScheduleWakeup "" "stop") == 2 && $(sg RemoteTrigger) == 2 && $(sg CronCreateV2 "*/15 * * * *" /prwatch-tick) == 2 && $(print "not json" | $PH sched 2>/dev/null; print $?) == 2 ]]'
ok "B8: refusal names the one job"         '[[ "$(jq -nc "{tool_name:\"CronCreate\",tool_input:{cron:\"x\",prompt:\"y\"}}" | $PH sched 2>&1 >/dev/null)" == *"*/15 * * * *"* && "$(jq -nc "{tool_name:\"CronCreate\",tool_input:{cron:\"x\",prompt:\"y\"}}" | $PH sched 2>&1 >/dev/null)" == *"/prwatch-tick"* ]]'
jobs=0; for jb in ${(f)"$(grep -o 'CronCreate. recurring `[^`]*` with prompt `[^`]*`' $S7/prwatch-start/SKILL.md)"}; do
  sc=${${jb#*recurring \`}%%\`*}; sp=${${jb##*prompt \`}%\`}; (( jobs++ ))
  ok "B8: start skill's '$sp' job ($sc) allowed by the gate" '[[ $(sg CronCreate "$sc" "$sp") == 0 ]]'; done
ok "B8: start skill schedules exactly one job" '(( jobs == 1 ))'
M=".*(Cron|Schedule|Wakeup|Trigger).*"
ok "settings: UserPromptSubmit → prompthook" 'jq -e ".hooks.UserPromptSubmit[0].hooks|map(.command)|index(\"$PH prompt\")" $C >/dev/null'
ok "settings: scheduling gate hook"         'jq -e --arg m "$M" ".hooks.PreToolUse[]|select(.matcher==\$m)|.hooks[0].command == \"$PH sched\"" $C >/dev/null'
ok "settings: gate matcher covers the scheduling tools" '(for t in CronCreate CronList CronDelete ScheduleWakeup RemoteTrigger; do [[ $t =~ "^${M}\$" ]] || exit 1; done) && [[ ! Bash =~ "^${M}\$" ]]'
ok "settings: ScheduleWakeup denied"        'jq -e ".permissions.deny|index(\"ScheduleWakeup\")" $C >/dev/null'
ok "guard: model cannot run prompthook"     '[[ $(g "$PH prompt") == 2 && $(g "echo stop | $PH prompt") == 2 ]]'

# B9 — prose: the values the scripts own, in the texts the model and Jack read
MF=($PRW/CLAUDE.md $S7/prwatch-{start,tick,review,eod,decide}/SKILL.md)                     # model-facing
PF9=("$L" $PRW/README.md $MF); REPO=${PRWATCH_REPO:-$HOME/Documents/GitHub/pr-watcher/watcher}; [[ -f ${REPO:h}/README.md ]] && PF9+=(${REPO:h}/README.md)
ok "B9: no cap vocabulary anywhere Jack or the model reads" '! grep -Eiq "cap [0-9]|daily cap|review limit|at most 12|normally 6|PRWATCH CAP" $PF9'
ok "B9: no clock-of-day or weekday vocabulary" '! grep -Eiq "08:00|15:30|16:00|Mon.?Fri|weekday|1-5 " $PF9'
ok "B9: no 'today' in model-facing text"   '! grep -Eiqw "today" $MF'
STL=$(grep -o 'START_LIMIT=[0-9]*' $B/prwatch-common.zsh); STL=${STL#*=}; ENDS=$(grep -oE '(^| )END=[0-9]+' $B/prwatch-common.zsh | tr -d " "); ENDS=${ENDS#*=}
ok "B9: window constants defined once, in prwatch-common.zsh" '[[ $STL == <-> && $ENDS == <-> ]] && (( STL < ENDS )) && ! grep -lq "START_LIMIT=[0-9]" $B/*.sh "$L"'
ok "B9: '8 hours' and '7½' match END and START_LIMIT" '(( ENDS == 8*3600 && STL == 27000 )) && grep -q "8 hours" $PRW/CLAUDE.md && grep -q "8 hours" $S7/prwatch-start/SKILL.md && grep -Eq "7½|7 h 30" $PRW/CLAUDE.md && grep -Eq "7½|7 h 30" $S7/prwatch-start/SKILL.md'
ok "B9: no exit 24/26 in CLAUDE.md, tick and review skills" '! grep -Eq "with 24|exit 24|exit 26" $PRW/CLAUDE.md $S7/prwatch-tick/SKILL.md $S7/prwatch-review/SKILL.md'
ok "B9: the window exit number quoted equals prep's literal" '[[ -n $WX ]] && grep -q "exit $WX" $PRW/CLAUDE.md && grep -q "exit $WX" $S7/prwatch-tick/SKILL.md && grep -q "exit $WX" $S7/prwatch-review/SKILL.md && grep -q "exit 25" $S7/prwatch-review/SKILL.md'
ok "B9: CLAUDE.md stop/pause rows repeat the hook's line, model never runs them" 'grep -q "PRWATCH STOP:" $PRW/CLAUDE.md && grep -q "PRWATCH PAUSE:" $PRW/CLAUDE.md && grep -Eq "prwatch-state.sh stop.*yourself" $PRW/CLAUDE.md && ! grep -Eq "\| .(cap N|stop-today)" $PRW/CLAUDE.md'
ok "B9: status row reads --window; no state.sh today anywhere" 'grep -q "prwatch-tick.sh --window" $PRW/CLAUDE.md && ! grep -q "prwatch-state.sh today" $MF'
ok "B9: tick skill: session_over → eod_due → /prwatch-eod, Session finished, start_closed leaves queued" 'grep -q "session_over" $S7/prwatch-tick/SKILL.md && grep -q "eod_due" $S7/prwatch-tick/SKILL.md && grep -q "Session finished" $S7/prwatch-tick/SKILL.md && grep -q "start_closed" $S7/prwatch-tick/SKILL.md && ! grep -Eq "stopped_for_today|outside_window|councils_today|cap_max" $S7/prwatch-tick/SKILL.md'
ok "B9: eod skill repeats eod-done's counts" 'grep -q "prwatch-state.sh eod-done" $S7/prwatch-eod/SKILL.md && grep -q "Session summary: posted" $S7/prwatch-eod/SKILL.md && grep -q "at the next launch" $S7/prwatch-eod/SKILL.md'
ok "B9: review skill: 'off for this session', no refund sentence" 'grep -q "off for this session" $S7/prwatch-review/SKILL.md && ! grep -Eiq "refund|daily-inc" $S7/prwatch-review/SKILL.md'
ok "B9: decide skill: free-text stop/pause → awaiting_decision, type it at the prompt" 'grep -q "awaiting_decision" $S7/prwatch-decide/SKILL.md && grep -Eq "type .stop." $S7/prwatch-decide/SKILL.md'
ok "B9: start skill banner comes from --window JSON" 'grep -q "starts_until" $S7/prwatch-start/SKILL.md && grep -q "ends_at" $S7/prwatch-start/SKILL.md'
ok "B9: launcher banner: 8 hours, type stop to finish early" 'grep -q "Runs for 8 hours from now" "$L" && grep -Eq "type .stop. to finish early" "$L"'

# B10 — dead commands and legacy inputs tolerated
reset                                                                   # the launcher block above removed its lock
for c in "today" "daily-inc" "cap 8" "stop-today"; do
ok "B10: state.sh $c → 64 (usage)"          '(out=$($SS $c 2>/dev/null); (( $? == 64 )) && [[ $out == usage ]])'; done
reset; jq '.daily={"2026-09-28":3} | .cap_override={"2026-09-28":8}' $T/state.json > $T/s && mv $T/s $T/state.json
$SS set ACT-Training/Vision#1 queued sha=abc >/dev/null
ok "B10: old daily/cap_override fields dropped on first write" '[[ $(jq -c "[has(\"daily\"),has(\"cap_override\"),.prs[\"ACT-Training/Vision#1\"].status]" $T/state.json) == "[false,false,\"queued\"]" ]]'
ok "B10: tick's initial state literal has no daily" 'rm -f $T/state.json; tk $SE --dry-run >/dev/null; [[ $(jq -c "[has(\"daily\"),has(\"repos\")]" $T/state.json) == "[false,true]" ]]'
ok "B10: state.sh check: read-only, no session needed; unreadable → 70" 'reset; (PRWATCH_SESSION_ID=sid-B $SS check) && [[ ! -e $T/events.jsonl ]] && (: > $T/state.json; out=$($SS check); (( $? == 70 )) && [[ $out == "state unreadable" ]]) && (print "{\"prs\":[]}" > $T/state.json; $SS check >/dev/null 2>&1; (( $? == 70 )))'
reset; : > $T/state.json
ok "B10: tick: unreadable state → error, Jack notified" '[[ $(tk $SE --dry-run | jq -c "[.status,.kind]") == "[\"error\",\"state_unreadable\"]" ]] && grep -q "error state :: The watcher can.t read its state file" $T/notify.log'
# a failed harness-abort write, then the next session: its first real tick requeues the stuck PR with one attempt
reset; review; post agent-async.json; post taskstop-ok.json; mkdir $T/state.json.tmp
$SS harness-abort ACT-Training/Vision#1 >/dev/null 2>&1; rc=$?; rmdir $T/state.json.tmp
lockfor sid-B $SE; rm -f $T/stopped-*; mkstub                           # the next launch: a new session with its own lock (stub gh again: reset wiped it)
ok "failed write (70) leaves the PR reviewing with 1 attempt" '(( rc == 70 )) && [[ $(st ACT-Training/Vision#1 status) == reviewing && $(st ACT-Training/Vision#1 attempts) == 1 ]]'
r=$(PRWATCH_SESSION_ID=sid-B PRWATCH_STUB_BIN=$T/stub PRWATCH_ONLY_PR=ACT-Training/Vision#1 PRWATCH_NOW=$((SE+600)) $B/prwatch-tick.sh | jq -r ".items[0].reason")
ok "failed write, next session: tick requeues it (orphaned_requeue, attempt +1)" '[[ $r == orphaned_requeue && $(st ACT-Training/Vision#1 status) == queued && $(st ACT-Training/Vision#1 attempts) == 2 ]]'

# B11 — one writer at a time: the fcntl lock on set
reset; for i in {1..10}; do $SS set ACT-Training/Vision#$i queued sha=abc >/dev/null 2>&1 & done; wait
ok "B11: 10 parallel writers → valid JSON, all ten kept" 'jq -e ".prs|length==10" $T/state.json >/dev/null && (( $(grep -c "\"status\":\"queued\"" $T/events.jsonl) == 10 ))'
reset; hold 3; out=$(PRWATCH_LOCK_WAIT=1 $SS set ACT-Training/Vision#1 queued sha=abc); rc=$?
ok "B11: lock held elsewhere → 75, nothing written" '(( rc == 75 )) && [[ $out == "state busy" && $(st ACT-Training/Vision#1 status) == null && ! -e $T/events.jsonl ]]'
reset; hold 1; $SS set ACT-Training/Vision#1 queued sha=abc >/dev/null; rc=$?
ok "B11: waits for a short lock, then writes" '(( rc == 0 )) && [[ $(st ACT-Training/Vision#1 status) == queued ]]'

# B4 — one key grammar (D12) at three entry points: state get (0 / 64), cleanup (0 / 64), ngtest (past the key check / 64)
b4() { $B/prwatch-$1.sh "${@:2}" >/dev/null 2>&1; print $?; }
o256=$(printf 'a%.0s' {1..256}); o39=$(printf 'a%.0s' {1..39}); o40=${o39}a; r100=$(printf 'r%.0s' {1..100}); r101=${r100}r   # GitHub's limits: owner ≤ 39, repo ≤ 100, n ≤ 7 digits
reset
for k in 'ACT-Training/Vision#1803' 'Some-Org/repo#1' 'JackScammell/pr-watcher#1' 'a-b-c-d/e.f-g_h#99999' "$o39/y#1" "a/$r100#1" 'A/B#1234567'; do   # owner grammar has no . or _ (D12), so not the plan's a.b-c_d
ok "B4: accept '${k[1,40]}'"                '[[ $(b4 state get "$k") == 0 && $(b4 cleanup "$k") == 0 && $(b4 ngtest "$k" frontend) != 64 ]]'; done
for k in '../x#1' 'a/b/c#1' 'A/B#x' 'A/B#' 'A/B' '/B#1' 'A/#1' 'A/B#1#2' 'A/B#1 ' 'A/B#01' '-x/y#1' 'a/-y#1' 'a/.y#1' "$o256/y#1" "$o40/y#1" "a/$r101#1" 'A/B#12345678' 'ACT-Training/Vision#1;ls'; do
ok "B4: refuse '${k[1,40]}'"                '[[ $(b4 state get "$k") == 64 && $(b4 cleanup "$k") == 64 && $(b4 ngtest "$k" frontend) == 64 ]]'; done

# B5 — owner-bearing paths (D13/D14): names, prep/post argument validation, no hard-coded login or org
reset; seedrepo Some-Org/Zzzt allowed; PRWATCH_NOW=$SE pp >/dev/null; PRWATCH_NOW=$SE pk Some-Org/Zzzt#9 $NSHA 1 >/dev/null; D5=$(date +%F); arch=($T/archive/*(/N))
ok "B5: archive is <date>-<owner:l>-<repo:l>-pr<n>-round<k>; two owners, same repo → two archives" '(( ${#arch} == 2 )) && [[ -d $T/archive/$D5-act-training-zzzt-pr9-round1 && -d $T/archive/$D5-some-org-zzzt-pr9-round1 ]]'
mkdir -p $W $W2; $B/prwatch-cleanup.sh Some-Org/Zzzt#9
ok "B5: cleanup of one owner's key removes its worktree, spares the other owner's" '[[ ! -e $W2 && -d $W ]] && $B/prwatch-cleanup.sh "ACT-Training/Zzzt#9" && [[ ! -e $W ]]'
mkdir -p $PRW/work/Some-Org__Zzzt-pr9-junk $PRW/work/Some-Org__Zzzt-pr9-abc1234-build; $B/prwatch-cleanup.sh "Some-Org/Zzzt#9" >/dev/null 2>&1
ok "B5: cleanup removes a -build copy and a prefix-matching name that is not worktree-shaped (no git for either)" '[[ ! -e $PRW/work/Some-Org__Zzzt-pr9-junk && ! -e $PRW/work/Some-Org__Zzzt-pr9-abc1234-build ]]'
# a real worktree of a real clone: cleanup must derive <owner>__<repo> from the worktree name and remove it through THAT clone's
# git. The clone is reached only through a symlink under repos/ (git -C follows it; the prune glob's lstat does not), so if the
# derivation were wrong the rm -rf fallback would leave the worktree registered in the clone.
RZ=$T/rz; [[ -L $RZL ]] && rm -f $RZL
if [[ ! -e $RZL ]]; then
  git -c init.defaultBranch=main init -q $RZ && git -C $RZ -c user.name=h -c user.email=h@x -c core.hooksPath=/dev/null commit -q --allow-empty -m seed \
    && git -C $RZ -c core.hooksPath=/dev/null worktree add -q --detach $W && ln -s $RZ $RZL
  $B/prwatch-cleanup.sh ACT-Training/Zzzt#9; rm -f $RZL
  ok "B5: cleanup derives <owner>__<repo> from the worktree name: a real worktree goes through its clone's git, not the rm -rf fallback" '[[ ! -e $W ]] && (( $(git -C $RZ worktree list --porcelain | grep -c "^worktree ") == 1 ))'
else print "skip B5 derivation check ($RZL exists and is not a symlink)"; fi
for args in "Zzzt 9 $NSHA 1" "../x#1 $NSHA 1" "A/B#01 $NSHA 1" "ACT-Training/Zzzt#9 $NSHA"; do reset; out=$(PRWATCH_NOW=$SE pk ${=args}); rc=$?
ok "B5: prep '${args//$NSHA/<sha40>}' → 64 bad arguments, nothing done" '(( rc == 64 )) && [[ $out == "bad arguments" && ! -e $T/archive ]]'; done
P5=$B/prwatch-post.sh
po() { PRWATCH_STUB_BIN=$T/stub $P5 "$@" 2>&1; print "rc=$?"; }                 # dry post (test mode), stub gh + stub osascript (Cancel)
postsetup() { reset; mkstub; mkdir -p $PA/draft; print -- $'<!-- prwatch round=1 sha=0123456 -->\nLooks fine.' > $PA/draft/review-body.md
  BS=$(shasum -a 256 $PA/draft/review-body.md | cut -c1-12); $SS set ACT-Training/Vision#1 ready sha=$NSHA archive=${1:-$PA} >/dev/null; }
postsetup
ok "B5: post --repo/--pr (old shape) → 64"  '[[ "$(po --repo Vision --pr 1 --sha $NSHA --event approve --body-sha $BS)" == *"rc=64" ]]'
ok "B5: post without --key → 64 bad arguments" '[[ "$(po --sha $NSHA --event approve --body-sha $BS)" == *"bad arguments"*"rc=64" ]]'
ok "B5: post --key Vision#1 → 64 bad arguments (no default owner)" '[[ "$(po --key Vision#1 --sha $NSHA --event approve --body-sha $BS)" == *"bad arguments"*"rc=64" ]]'
ok "B5: post --key ../x#1 / 'ACT-Training/Vision#1;ls' → 64 bad arguments" '[[ "$(po --key ../x#1 --sha $NSHA --event approve --body-sha $BS)" == *"bad arguments"*"rc=64" && "$(po --key "ACT-Training/Vision#1;ls" --sha $NSHA --event approve --body-sha $BS)" == *"bad arguments"*"rc=64" ]]'
ok "B5: post with a valid --key and no login → 64 no login" '[[ "$(PRWATCH_LOGIN= po --key ACT-Training/Vision#1 --sha $NSHA --event approve --body-sha $BS)" == *"no login"*"rc=64" ]]'
ok "B5: the same call with a login reaches the dialog (stub Cancel → 11)" '[[ "$(po --key ACT-Training/Vision#1 --sha $NSHA --event approve --body-sha $BS)" == *"Not posted"*"rc=11" ]]'
postsetup $T/arch
ok "B5: post archive outside the allowed roots → 64 archive path not recognised" '[[ "$(po --key ACT-Training/Vision#1 --sha $NSHA --event approve --body-sha $BS)" == *"archive path not recognised"*"rc=64" ]]'
ok "B5: no JackScammell in bin, .claude, CLAUDE.md" '! grep -rq JackScammell $B $PRW/.claude $PRW/CLAUDE.md'
ok "B5: no ACT-Training in bin or config"   '! grep -rq ACT-Training $B $PRW/config'

# B6 — PRWATCH_LOGIN plumbing (D15): the re-request filter, fail-closed ticks and prep, launcher capture, query shape
reset; $SS set ACT-Training/Zzzt#9 posted sha=abc >/dev/null
ok "B6: timeline re-request filtered by PRWATCH_LOGIN (other → ignore)" '[[ $(PRWATCH_LOGIN=other tk $SE | jq -r ".items[0].reason") == ignore && $(st "ACT-Training/Zzzt#9" status) == posted ]]'
ok "B6: the stub login → rerequested_same_sha, requeued" '[[ $(tk $SE | jq -r ".items[0].reason") == rerequested_same_sha && $(st "ACT-Training/Zzzt#9" status) == queued ]]'
sk() { jq -r '[.status, .kind // "-"] | join(" ")'; }
reset; cp $T/state.json $T/state.before; : > $T/gh-calls.log
ok "B6: empty / unset / invalid login → error no_login before any classification (full and --dry-run)" '[[ $(PRWATCH_LOGIN= tk $SE | sk) == "error no_login" && $( (unset PRWATCH_LOGIN; tk $SE --dry-run) | sk) == "error no_login" && $(PRWATCH_LOGIN="bad login!" tk $SE | sk) == "error no_login" ]] && cmp -s $T/state.json $T/state.before && [[ ! -e $T/events.jsonl ]] && ! grep -q "pr view" $T/gh-calls.log'
ok "B6: no login → --window still answers"  '[[ $(PRWATCH_LOGIN= wst $SE) == "in_window -" ]]'
reset; out=$(PRWATCH_LOGIN= PRWATCH_NOW=$SE pp); rc=$?
ok "B6: prep without a login → 25 no login, nothing done" '(( rc == 25 )) && [[ $out == "no login" && ! -e $T/archive ]]'
if [[ -f $L ]]; then
  launch $(date +%s)
  ok "B6: launcher writes login into the lock and exports PRWATCH_LOGIN" '[[ $(jq -r .login $T/lock-seen.json) == stubuser ]] && grep -qx "PRWATCH_LOGIN=stubuser" $T/env-seen.txt'
  launch $(date +%s) PRWATCH_STUB_LOGIN=
  ok "B6: launcher refuses an empty login: non-zero exit, the harness lock untouched, claude not run, error notice" '(( $(<$T/launch.rc) != 0 )) && [[ $(jq -r .session_id $T/session.lock) == sid-A && ! -e $T/lock-seen.json ]] && grep -q "error launcher" $T/notify.log'
  launch $(date +%s) "PRWATCH_STUB_LOGIN=bad login!"
  ok "B6: launcher refuses an invalid login ('bad login!')" '(( $(<$T/launch.rc) != 0 )) && [[ $(jq -r .session_id $T/session.lock) == sid-A && ! -e $T/lock-seen.json ]] && grep -q "error launcher" $T/notify.log'
  ok "B6: launcher: one informational user/orgs line, no ACT-Training org check" '(( $(grep -c "gh api user/orgs" "$L") == 1 )) && ! grep -q "orgs/ACT-Training" "$L"'
else print "skip B6 launcher checks (no launcher at $L; set PRWATCH_LAUNCHER)"; fi
ok "B6: the three sandboxed test re-execs drop PRWATCH_LOGIN and PRWATCH_LOCK_JSON from the environment they pass on" '( for f in prwatch-buildrun.sh prwatch-ngtest.sh prwatch-dotnettest.sh; do head -20 $B/$f | grep -q "grep -v -e .\^PRWATCH_LOGIN=. -e .\^PRWATCH_LOCK_JSON=." || exit 1; done )'
ok "B6: prep's prebuild sandbox-exec runs without PRWATCH_LOGIN, PRWATCH_LOCK_JSON and GH_CONFIG_DIR" 'grep -q "env -u PRWATCH_LOGIN -u PRWATCH_LOCK_JSON -u GH_CONFIG_DIR sandbox-exec" $B/prwatch-prep.sh'
ok "B6: tick query: no --owner, user-review-requested:@me, author in --json" '! grep -q -- "--owner" $B/prwatch-tick.sh && grep -q "user-review-requested:@me" $B/prwatch-tick.sh && grep "gh search prs" $B/prwatch-tick.sh | grep -Eq -- "--json [A-Za-z,]*author"'
ok "B6: tick query: newest first (--sort updated --order desc)" 'grep "gh search prs" $B/prwatch-tick.sh | grep -q -- "--sort updated --order desc"'
for h in '../x#1' 'a/b;ls#1'; do reset; cp $T/state.json $T/state.before; : > $T/gh-calls.log; j=$(tko "$h" $SE)
ok "B6: hostile nameWithOwner '$h' → dropped: ok, items empty, no state write, no pr view" '[[ $(jq -c "[.status,.items]" <<<$j) == "[\"ok\",[]]" ]] && cmp -s $T/state.json $T/state.before && ! grep -q "pr view" $T/gh-calls.log'; done

# B12 — first-sighting gate (D16): an unseen repo is new_repo (no fetch, no write) until Jack types allow/block at the prompt
NL='First PR from Some-Org/Zzzt by someone: type allow Some-Org/Zzzt or block Some-Org/Zzzt'
reset; cp $T/state.json $T/state.before; : > $T/gh-calls.log; j=$(PRWATCH_ONLY_AUTHOR=someone tko Some-Org/Zzzt#9 $SE)
ok "B12: unseen repo → new_repo row with the search author, empty sha, no write, no pr view" '[[ $(jq -c ".items[0]|[.key,.reason,.sha,.size,.author]" <<<$j) == "[\"Some-Org/Zzzt#9\",\"new_repo\",\"\",0,\"someone\"]" ]] && cmp -s $T/state.json $T/state.before && ! grep -q "pr view" $T/gh-calls.log'
ok "B12: the notices line, verbatim, and one newrepo notification (ref = the repo)" '[[ $(jq -r ".notices[0]" <<<$j) == "$NL" ]] && grep -q " newrepo Some-Org/Zzzt " $T/notify.log && ! grep -q " question " $T/notify.log'
j2=$(PRWATCH_ONLY_AUTHOR=someone tko Some-Org/Zzzt#9 $((SE+900)))
ok "B12: next tick repeats the notice, notification throttled, still no write" '[[ $(jq -r ".notices[0]" <<<$j2) == "$NL" && $(jq -r ".items[0].reason" <<<$j2) == new_repo ]] && (( $(grep -c " newrepo " $T/notify.log) == 1 )) && cmp -s $T/state.json $T/state.before'
ok "B12: a notice, never a question: tick JSON and the tick skill's new_repo line carry no AskUserQuestion" '! grep -q AskUserQuestion <<<$j && grep new_repo $S7/prwatch-tick/SKILL.md | grep -q "never \`AskUserQuestion\`"'
reset; cp $T/state.json $T/state.before; j=$(PRWATCH_ONLY_AUTHOR=someone tko "Some-Org/Zzzt#9,Some-Org/Zzzt#10" $SE)   # M18: the notice and the notification are per repo, the rows per PR
ok "B12: two PRs of one unseen repo → two new_repo rows, one notice, one newrepo notification" '[[ $(jq -c "[.items[]|[.key,.reason]]" <<<$j) == "[[\"Some-Org/Zzzt#9\",\"new_repo\"],[\"Some-Org/Zzzt#10\",\"new_repo\"]]" && $(jq ".notices|length" <<<$j) == 1 && $(jq -r ".notices[0]" <<<$j) == "$NL" ]] && (( $(grep -c " newrepo " $T/notify.log) == 1 )) && cmp -s $T/state.json $T/state.before'
out=$(ph "allow Some-Org/Zzzt")
ok "B12: ph 'allow Some-Org/Zzzt' → reply line, repos allowed, repo_allow event, request consumed" '[[ $out == "PRWATCH REPO: Some-Org/Zzzt allowed - its pull requests will be picked up at the next check." && $(rp Some-Org/Zzzt) == allowed && ! -e $T/repo/request.json ]] && jq -e "select(has(\"repo_allow\") and .session==\"sid-A\")" $T/events.jsonl >/dev/null'
ok "B12: next tick → new, queued write"    '[[ $(tko "Some-Org/Zzzt#9" $((SE+1800)) | jq -r ".items[0].reason") == new && $(st "Some-Org/Zzzt#9" status) == queued ]]'
ok "B12: positive control: the allowed repo's tick did call pr view (the no-pr-view checks above can fail)" 'grep -q "pr view" $T/gh-calls.log'
out=$(ph "BLOCK Other-Org/Zzzt"); : > $T/gh-calls.log; j=$(PRWATCH_ONLY_AUTHOR=someone tko Other-Org/Zzzt#3 $((SE+1800)))
ok "B12: ph 'block' (any case) → blocked, repo_block event; its PR → blocked_repo with no author, no write, no pr view" '[[ $out == "PRWATCH REPO: Other-Org/Zzzt blocked - its pull requests are ignored." && $(rp Other-Org/Zzzt) == blocked ]] && jq -e "select(has(\"repo_block\"))" $T/events.jsonl >/dev/null && [[ $(jq -c ".items[0]|[.reason,.sha,.author]" <<<$j) == "[\"blocked_repo\",\"\",\"\"]" && $(st "Other-Org/Zzzt#3" status) == null ]] && ! grep -q "pr view" $T/gh-calls.log'
reset; out=$($SS repo-allow x/y); rc=$?
ok "B12: repo-allow with no request → 64, repo_refused event; bad repo → 64" '(( rc == 64 )) && jq -e "select(has(\"repo_refused\"))" $T/events.jsonl >/dev/null && ($SS repo-allow "../x" >/dev/null 2>&1; (( $? == 64 ))) && [[ $(jq ".repos|length" $T/state.json) == 2 ]]'
for pr in "allow ../x" "allow Some-Org/Zzzt#1" "allow please Some-Org/Zzzt" "allow" "block a/b; ls"; do out=$(ph "$pr"); rc=$?
ok "B12: ph ignores '$pr'"                  '(( rc == 0 )) && [[ -z $out && ! -e $T/repo && $(jq ".repos|length" $T/state.json) == 2 ]]'; done
ok "B12: ph 'allow' from a stale window → not changed" '[[ $(PRWATCH_SESSION_ID=sid-B ph "allow Some-Org/X") == "PRWATCH REPO: not changed ("* && $(jq ".repos|length" $T/state.json) == 2 ]]'
reset; $SS set ACT-Training/Zzzt#9 queued sha=abc >/dev/null; norepos
ok "B12: a repo with an existing prs key is seen: classified normally, not new_repo" '[[ $(tk $SE | jq -r ".items[0].reason") == new ]]'

# B12 gate (PR 3): repo_allowed in prwatch-common.zsh; prep refuses before any clone; state set refuses a NEW key of a repo
# that is neither allowed nor grandfathered by an existing prs key (and promotes a grandfathered repo to allowed); the tick
# withdraws a tracked key whose repo Jack blocked; a search of exactly 100 rows (gh's page) withdraws nothing.
ra() { (source $B/prwatch-common.zsh; repo_allowed $T/state.json "$1"); }
rs() { (source $B/prwatch-common.zsh; repo_status $T/state.json "$1"); }     # prints allowed|blocked|seen|unseen (the tick's blocked lookup, state's promotion lookup)
reset; $SS set ACT-Training/Zzzt#9 queued sha=abc >/dev/null; seedrepo Nope-Org/Zzzt blocked; seedrepo some-org/zzzt allowed
ok "B12: repo_allowed: allowed in any case / blocked never / unseen never / prs-key grandfather" 'ra Some-Org/Zzzt && ra SOME-ORG/ZZZT && ! ra Nope-Org/Zzzt && ! ra Other-Org/Zzzt && norepos && ra act-training/zzzt && ! ra Some-Org/Zzzt'
reset; $SS set ACT-Training/Zzzt#9 queued sha=abc >/dev/null; norepos; seedrepo Some-Org/Zzzt allowed; seedrepo Nope-Org/Zzzt blocked   # ACT-Training/Zzzt: a prs key, no repos entry
ok "B12: repo_status (lower-case query): allowed / blocked / seen (prs key only) / unseen" '[[ $(rs some-org/zzzt) == allowed && $(rs nope-org/zzzt) == blocked && $(rs act-training/zzzt) == seen && $(rs other-org/zzzt) == unseen ]]'
reset; norepos; out=$(PRWATCH_NOW=$SE pp); rc=$?
ok "B12: prep on a repo with no repos entry and no prs key → 25 repo not allowed, nothing cloned" '(( rc == 25 )) && [[ $out == "repo not allowed" && ! -e $T/archive && ! -e $RZL ]]'
reset; $SS set ACT-Training/Zzzt#9 queued sha=abc >/dev/null; seedrepo ACT-Training/Zzzt blocked; out=$(PRWATCH_NOW=$SE pp); rc=$?
ok "B12: prep on a blocked repo (even with a prs key) → 25 repo not allowed, nothing done" '(( rc == 25 )) && [[ $out == "repo not allowed" && ! -e $T/archive ]]'
reset; $SS set ACT-Training/Zzzt#9 queued sha=abc >/dev/null; norepos; out=$(PRWATCH_NOW=$SE pp); rc=$?
ok "B12: prep on a grandfathered repo (prs key, no repos entry) goes ahead (then the stub clone fails: 20)" '(( rc == 20 )) && [[ -e $T/archive ]]'
reset; out=$($SS set Some-Org/Zzzt#9 queued sha=abc); rc=$?
ok "B12: set on a key whose repo is absent → 64 repo not allowed, repo_not_allowed event, no prs entry" '(( rc == 64 )) && [[ $out == "repo not allowed" && $(st "Some-Org/Zzzt#9" status) == null && $(jq -r "select(.repo_not_allowed!=null)|.repo_not_allowed" $T/events.jsonl) == "Some-Org/Zzzt" ]]'
seedrepo Some-Org/Zzzt blocked; out=$($SS set Some-Org/Zzzt#9 queued sha=abc); rc=$?
ok "B12: set on a key whose repo is blocked → 64 repo not allowed, no prs entry" '(( rc == 64 )) && [[ $out == "repo not allowed" && $(st "Some-Org/Zzzt#9" status) == null ]]'
norepos; seedrepo some-org/zzzt allowed
ok "B12: set on a key whose repo is allowed in another case → written" '$SS set Some-Org/Zzzt#9 queued sha=abc >/dev/null && [[ $(st "Some-Org/Zzzt#9" status) == queued ]]'
reset; $SS set ACT-Training/Zzzt#9 queued sha=abc >/dev/null; norepos
ok "B12: grandfather: set on a new key of a repo with a prs key succeeds and promotes repos[<repo>]=allowed" '$SS set ACT-Training/Zzzt#10 queued sha=abc >/dev/null && [[ $(st "ACT-Training/Zzzt#10" status) == queued && $(rp ACT-Training/Zzzt) == allowed ]]'
ok "B12: an existing key stays updatable once its repo is blocked (the tick withdraws through set)" 'seedrepo ACT-Training/Zzzt blocked; $SS set ACT-Training/Zzzt#9 ready sha=abc >/dev/null && [[ $(st "ACT-Training/Zzzt#9" status) == ready ]]'
reset; ph "allow Some-Org/Zzzt" >/dev/null; tko Some-Org/Zzzt#9 $SE >/dev/null; $SS set Some-Org/Zzzt#9 ready sha=abc >/dev/null
out=$(ph "block Some-Org/Zzzt"); jd=$(tko Some-Org/Zzzt#9 $((SE+600)) --dry-run)
ok "B12: tracked key ready + ph 'block': a --dry-run tick classifies blocked_repo and writes nothing" '[[ $out == "PRWATCH REPO: Some-Org/Zzzt blocked - its pull requests are ignored." && $(jq -r ".items[0].reason" <<<$jd) == blocked_repo && $(st "Some-Org/Zzzt#9" status) == ready ]]'
: > $T/gh-calls.log; j=$(tko Some-Org/Zzzt#9 $((SE+900)))
ok "B12: tracked key ready + ph 'block' → next tick withdraws it (withdrawn_from=ready), blocked_repo row with an empty author, no pr view" '[[ $(jq -c ".items[0]|[.key,.reason,.prev,.author]" <<<$j) == "[\"Some-Org/Zzzt#9\",\"blocked_repo\",\"ready\",\"\"]" && $(st "Some-Org/Zzzt#9" status) == withdrawn && $(st "Some-Org/Zzzt#9" withdrawn_from) == ready ]] && ! grep -q "pr view" $T/gh-calls.log'
out=$(ph "allow some-org/zzzt")
ok "B12: ph 'allow some-org/zzzt' (lower case) → next tick on Some-Org/Zzzt#9 → new, queued" '[[ $out == "PRWATCH REPO: "*" allowed - "* && $(tko Some-Org/Zzzt#9 $((SE+1800)) | jq -r ".items[0].reason") == new && $(st "Some-Org/Zzzt#9" status) == queued ]]'
reset; seedrepo Some-Org/Zzzt allowed; $SS set Some-Org/Zzzt#9 posted sha=abc >/dev/null; $SS set Some-Org/Zzzt#10 queued sha=abc >/dev/null
ph "block Some-Org/Zzzt" >/dev/null; j=$(tko "Some-Org/Zzzt#9,Some-Org/Zzzt#10" $((SE+600)))
ok "B12: block with a posted and a queued key: posted is exempt (stays posted), queued → withdrawn (withdrawn_from=queued), both rows blocked_repo" '[[ $(jq -c "[.items[]|[.key,.reason]]" <<<$j) == "[[\"Some-Org/Zzzt#9\",\"blocked_repo\"],[\"Some-Org/Zzzt#10\",\"blocked_repo\"]]" && $(st "Some-Org/Zzzt#9" status) == posted && $(st "Some-Org/Zzzt#10" status) == withdrawn && $(st "Some-Org/Zzzt#10" withdrawn_from) == queued ]]'
reset; j=$(PRWATCH_ONLY_AUTHOR="ev;il" tko Other-Org/Zzzt#3 $SE)
ok "B12: new_repo row carries the author stripped to [A-Za-z0-9-] ('ev;il' → evil), the notice likewise" '[[ $(jq -c ".items[0]|[.reason,.author]" <<<$j) == "[\"new_repo\",\"evil\"]" && $(jq -r ".notices[0]" <<<$j) == "First PR from Other-Org/Zzzt by evil: type allow Other-Org/Zzzt or block Other-Org/Zzzt" ]]'
# the withdrawn pass only runs on the search path (PRWATCH_ONLY_PR unset: tks), so the page-size rule is checked there:
# $T/search.json holds N rows of one blocked repo (cheap: blocked_repo, no pr view, no write) and the tracked key is absent
flood() { jq -nc --argjson n $1 '[range(1;$n+1)|{number:.,repository:{nameWithOwner:"Flood-Org/x"},author:{login:"f"}}]' > $T/search.json; }   # flood <rows>
reset; $SS set ACT-Training/Zzzt#9 ready sha=abc miss=1 >/dev/null; seedrepo Flood-Org/x blocked; flood 100     # miss=1: one more miss would withdraw it
j=$(tks $SE); j2=$(tks $((SE+900)))
ok "B12: search of exactly 100 rows, twice → withdrawn pass skipped both times: the tracked key absent from the list stays ready (miss kept), notice present" '[[ $(jq ".items|length" <<<$j) == 100 && $(jq -r ".items[0].reason" <<<$j) == blocked_repo && $(st "ACT-Training/Zzzt#9" status) == ready && $(st "ACT-Training/Zzzt#9" miss) == 1 ]] && jq -r ".notices[]" <<<$j | grep -qx "search truncated at 100; nothing withdrawn this check" && jq -r ".notices[]" <<<$j2 | grep -qx "search truncated at 100; nothing withdrawn this check" && ! grep -q "pr view" $T/gh-calls.log'
reset; $SS set ACT-Training/Zzzt#9 ready sha=abc >/dev/null; seedrepo Flood-Org/x blocked; flood 99
j=$(tks $SE); s1=$(st "ACT-Training/Zzzt#9" status); m1=$(st "ACT-Training/Zzzt#9" miss); j2=$(tks $((SE+900)))
ok "B12: search of 99 rows → the pass runs: first miss recorded (still ready), second tick withdraws it (withdrawn_from=ready), no truncation notice" '[[ $(jq ".items|length" <<<$j) == 99 && $s1 == ready && $m1 == 1 && $(st "ACT-Training/Zzzt#9" status) == withdrawn && $(st "ACT-Training/Zzzt#9" withdrawn_from) == ready ]] && ! jq -r ".notices[]" <<<"$j$j2" | grep -q "search truncated" && jq -r ".notices[]" <<<$j2 | grep -q "ACT-Training/Zzzt#9 no longer requested"'
for sc in buildrun ngtest dotnettest; do
ok "$sc: sandbox re-exec excludes PRWATCH_LOGIN and PRWATCH_LOCK_JSON" "head -20 $B/prwatch-$sc.sh | grep -q PRWATCH_LOGIN && head -20 $B/prwatch-$sc.sh | grep -q PRWATCH_LOCK_JSON"; done

# ============================================================================================================
# B3 — engine record (plan D2–D4, D22). A fake plugin tree under $P3 is pinned with the shared tree_sha256; the stub
# claude records its argv, its environment and how many memory folders were frozen while it ran.
PD=$P3/plug/chaos/9.9.9; MEM=$P3/mem; CF=$P3/conf
mkplug() { chflags -R nouchg $P3 2>/dev/null; rm -rf $P3/plug $MEM $CF $P3/cache; mkdir -p $PD/.claude-plugin $PD/.claude/rules $PD/src/hooks $PD/agents $PD/.in_use $PD/.git $CF
  print '{"name":"chaos","version":"9.9.9"}' > $PD/.claude-plugin/plugin.json; print rule > $PD/.claude/rules/r.md
  print '#!/bin/sh' > $PD/src/hooks/log_event.sh; print grump > $PD/agents/grumpy-code-reviewer.md; print 1 > $PD/.in_use/111; print ref > $PD/.git/HEAD
  jq -nc --arg p $PD '{plugins:{"chaos@chaos":[{installPath:$p,version:"9.9.9"}]}}' > $P3/pins.json; }
pin() { jq -nc --arg p ${1:-$PD} --arg s "$(th $PD)" '{version:"9.9.9",install_path:$p,tree_sha256:$s}' > $CF/parliament.lock; }
th() { (source $B/prwatch-common.zsh; tree_sha256 $1); }                                     # the launcher's own hash
SNAPD() { print -r -- $P3/cache/parliament-$(jq -r .tree_sha256 $CF/parliament.lock); }
L3E=(PRWATCH_TEST_CONF=$CF PRWATCH_TEST_PINS=$P3/pins.json PRWATCH_TEST_MEMROOT=$MEM)
eng() { jq -r '.engine.engine // "none"' $T/lock-seen.json 2>/dev/null; }
afterss() { awk 'p { print; exit } /^project,local$/ { p = 1 }' $T/argv.txt; }                   # the argument after --setting-sources project,local
noplug() { ! grep -qx -- --plugin-dir $T/argv.txt; }
uchg() { ls -lOd $1 2>/dev/null | grep -q uchg; }
if [[ -f $L ]]; then
  mkplug; pin; launch $(date +%s) $L3E
  ok "B3: pinned tree matches → parliament, --plugin-dir (right after --setting-sources) is the locked snapshot" '[[ $(eng) == parliament && $(afterss) == --plugin-dir && $(grep -x -A1 -- --plugin-dir $T/argv.txt | tail -1) == $(SNAPD) && $(th $(SNAPD)) == $(th $PD) ]]'
  ok "B3: the snapshot was locked while claude ran (folder and files), its .in_use/ writable; unlocked after exit" '[[ $(<$T/snap-seen.txt) == 1,1,w ]] && ! uchg $(SNAPD) && ! uchg $(SNAPD)/agents/grumpy-code-reviewer.md'
  ok "B3: lock engine object: enum, plugin id, version, dir" '[[ $(jq -c ".engine|[.engine,.plugin_id,.version,.plugin_dir]" $T/lock-seen.json) == "[\"parliament\",\"chaos@inline\",\"9.9.9\",\"$(SNAPD)\"]" ]] && grep -q "Engine: parliament 9.9.9 (Parliament of Chaos reviewers). Why: its files match the pin." $T/launch.out'
  ok "B3: every GRUMPS memory folder frozen while claude ran, listed in the lock under MEMORY_PREFIX" '[[ $(<$T/frozen-seen.txt) == 10 && $(jq ".frozen_memory|length" $T/lock-seen.json) == 10 ]] && jq -r ".frozen_memory[]" $T/lock-seen.json | grep -qx "$MEM/chaos-grumpy-security-nag"'
  ok "B3: after a normal exit no uchg flag remains on the listed folders" '(( $(jq ".frozen_memory|length" $T/lock-seen.json) == 10 )) && (for d in $(jq -r ".frozen_memory[]" $T/lock-seen.json); do [[ -d $d ]] && ! uchg $d || exit 1; done)'
  print x >> $(SNAPD)/agents/grumpy-code-reviewer.md; launch $(date +%s) $L3E
  ok "B3: a snapshot that no longer matches the pin is replaced, not used" '[[ $(eng) == parliament && $(th $(SNAPD)) == $(th $PD) ]]'
  launch $(date +%s) $L3E PWH_CLAUDE_HUP=1
  ok "B3: Terminal window closed (HUP) → exit 129, memory and snapshot unfrozen" '[[ $(<$T/launch.rc) == 129 && $(<$T/frozen-seen.txt) == 10 ]] && (( $(jq ".frozen_memory|length" $T/lock-seen.json) == 10 )) && (for d in $(jq -r ".frozen_memory[]" $T/lock-seen.json); do ! uchg $d || exit 1; done) && ! uchg $(SNAPD)'
  launch $(date +%s) $L3E PWH_CLAUDE_TAKEOVER=1; KEPT=$(jq -r ".frozen_memory[0]" $T/session.lock)
  ok "B3: a newer window took the lock → its folder and the snapshot it runs from stay frozen, the other nine thawed" '[[ -n $KEPT ]] && uchg $KEPT && uchg $(SNAPD) && (for d in $(jq -r ".frozen_memory[]" $T/lock-seen.json); do [[ $d == $KEPT ]] || ! uchg $d || exit 1; done)'
  chflags -R nouchg $MEM $P3/cache
  mkplug; pin; mkdir -p $MEM; : > $MEM/chaos-grumpy-code-reviewer; launch $(date +%s) $L3E   # second GRUMPS folder cannot be made
  ok "B3: a folder that cannot be frozen → refused to start, claude not run, the one already frozen thawed" '(( $(<$T/launch.rc) != 0 )) && [[ ! -e $T/argv.txt ]] && grep -q "Could not freeze reviewer memory" $T/launch.out && ! uchg $MEM/chaos-grumpy-security-nag'
  mkplug; pin; launch $(date +%s) $L3E
  ok "B3: the launcher scrubs the plugin hooks' env, sets spawn depth 1, consumes PRWATCH_ENGINE" 'launch $(date +%s) $L3E TEAMS_WEBHOOK_URL=https://x APP_NAME=a CLAUDE_PLUGIN_DATA=/tmp/x; grep -qx "SCRUB=unset,unset,unset,unset DEPTH=1" $T/env-seen.txt'
  print 1 > $PD/.in_use/222; launch $(date +%s) $L3E
  ok "B3: a new .in_use/ entry (Claude Code's per-process file) does not break the pin" '[[ $(eng) == parliament ]]'
  for f in .claude-plugin/plugin.json .claude/rules/r.md src/hooks/log_event.sh; do mkplug; pin; print -n x >> $PD/$f; launch $(date +%s) $L3E
  ok "B3: one byte added to $f → builtin, 'files differ' line, no --plugin-dir, nothing frozen" '[[ $(eng) == builtin && $(<$T/frozen-seen.txt) == 0 ]] && noplug && grep -q "Parliament 9.9.9.s files differ from the pin. .* then run: ~/Documents/GitHub/pr-watcher/install.sh --repin" $T/launch.out && ! jq -e "has(\"frozen_memory\")" $T/lock-seen.json >/dev/null'; done
  mkplug; pin; jq -c '.plugins["chaos@chaos"][0].version="9.9.10"' $P3/pins.json > $P3/p && mv $P3/p $P3/pins.json; print -n x >> $PD/agents/grumpy-code-reviewer.md; launch $(date +%s) $L3E
  ok "B3: a newer version installed → 'installed but the watcher is pinned to' line, builtin" '[[ $(eng) == builtin ]] && grep -q "Parliament 9.9.10 is installed but the watcher is pinned to 9.9.9. Read what changed" $T/launch.out'
  mkplug; pin; ln -s $PD/agents $PD/agl; launch $(date +%s) $L3E
  ok "B3: a symlink to a folder in the pinned tree → cannot be hashed → builtin, no --plugin-dir" '[[ $(eng) == builtin && $(jq -r .engine.reason $T/lock-seen.json) == *differ* ]] && noplug'
  mkplug; pin $P3/gone; launch $(date +%s) $L3E
  ok "B3: the lock names a missing folder → builtin" '[[ $(eng) == builtin && $(jq -r .engine.reason $T/lock-seen.json) == *missing* ]] && noplug'
  mkplug; : > $PD/src/hooks/.env; pin; launch $(date +%s) $L3E
  ok "B3: src/hooks/.env beside the pinned hooks → refused to start, claude not run" '(( $(<$T/launch.rc) != 0 )) && [[ ! -e $T/lock-seen.json ]] && grep -q "src/hooks/.env" $T/launch.out && grep -q "error launcher" $T/notify.log'
  mkplug; pin; launch $(date +%s) $L3E PRWATCH_ENGINE=builtin
  ok "B3: PRWATCH_ENGINE=builtin with a matching pin → builtin, no plugin, no freeze, no nudge" '[[ $(eng) == builtin && $(<$T/frozen-seen.txt) == 0 ]] && noplug && grep -qx "Engine: builtin (Claude Code.s /code-review). Why: forced by PRWATCH_ENGINE=builtin." $T/launch.out && ! grep -q "claude plugin install" $T/launch.out'
  launch $(date +%s) $L3E PRWATCH_ENGINE=parliament
  ok "B3: PRWATCH_ENGINE=parliament (not an accepted value) → refused" '(( $(<$T/launch.rc) != 0 )) && [[ ! -e $T/lock-seen.json ]]'
  mkplug; rm -f $P3/pins.json; launch $(date +%s) $L3E
  NUDGE=("claude plugin marketplace add https://github.com/JackScammell/Parliament-Of-Chaos.git" "claude plugin install chaos@chaos")
  ok "B3: not installed, not pinned → builtin and the two install lines, verbatim" '[[ $(eng) == builtin ]] && grep -qx ${(q)NUDGE[1]} $T/launch.out && grep -qx ${(q)NUDGE[2]} $T/launch.out'
  PREADME=$(jq -r '[.plugins // {} | to_entries[] | select(.key|startswith("chaos@")) | .value[0].installPath][0] // ""' $HOME/.claude/plugins/installed_plugins.json 2>/dev/null)/README.md
  if [[ -f $PREADME ]]; then ok "B3: the install lines are byte-identical to the Parliament README's" 'grep -qx ${(q)NUDGE[1]} $PREADME && grep -qx ${(q)NUDGE[2]} $PREADME'
  else print "skip B3 README comparison (Parliament not installed here)"; fi
  ok "B3: watcher README shows the same two lines" 'grep -qx "  ${NUDGE[1]}" $PRW/README.md && grep -qx "  ${NUDGE[2]}" $PRW/README.md'
  mkplug; print '{"builtin_agent":true,"parliament_blocked":false,"claude_version":"2.1.300"}' > $CF/engine-fallback.json; launch $(date +%s) $L3E
  ok "B3: no pin + builtin_agent for this Claude Code → builtin-agent" '[[ $(eng) == builtin-agent ]] && noplug'
  pin; launch $(date +%s) $L3E
  ok "B3: matching pin + builtin_agent → parliament (the fallback only replaces builtin)" '[[ $(eng) == parliament ]]'
  rm -f $CF/parliament.lock; print '{"builtin_agent":true,"parliament_blocked":false,"claude_version":"2.1.299"}' > $CF/engine-fallback.json; launch $(date +%s) $L3E
  ok "B3: builtin_agent recorded under another Claude Code → ignored, live-check line, builtin" '[[ $(eng) == builtin ]] && grep -q "engine-fallback.json is for Claude Code 2.1.299, you are on 2.1.300. To check this version, run: ~/prwatch/test/harness/live-check.sh --engine" $T/launch.out'
  print '{"builtin_agent":true,"parliament_blocked":false,"claude_version":"2.1.300"}' > $CF/engine-fallback.json; launch $(date +%s) $L3E PRWATCH_ENGINE=builtin
  ok "B3: PRWATCH_ENGINE=builtin with builtin_agent for this Claude Code → still builtin (forced)" '[[ $(eng) == builtin ]] && noplug'
  pin; for v in 2.1.300 2.1.299; do print "{\"builtin_agent\":false,\"parliament_blocked\":true,\"claude_version\":\"$v\"}" > $CF/engine-fallback.json; launch $(date +%s) $L3E
  ok "B3: parliament_blocked (recorded under $v) + matching pin → builtin, never expires" '[[ $(eng) == builtin && $(<$T/frozen-seen.txt) == 0 ]] && noplug && grep -q "Parliament was blocked by live-check under Claude Code $v" $T/launch.out'; done
  print 'not json' > $CF/engine-fallback.json; launch $(date +%s) $L3E
  ok "B3: unreadable engine-fallback.json + matching pin → builtin (fails closed), says delete or fix it" '[[ $(eng) == builtin ]] && noplug && grep -q "Delete or fix it, then relaunch" $T/launch.out'
  # thaw-on-start: a dead window's lock lists frozen folders; only GRUMPS folders under the memory root are touched
  mkplug; reset; mkstub; mkclaude; mkdir -p $MEM/chaos-grumpy-security-nag $MEM/chaos-grumpy-budget-hawk; : > $MEM/chaos-grumpy-security-nag/m.md
  chflags -R uchg $MEM/chaos-grumpy-security-nag $MEM/chaos-grumpy-budget-hawk; /usr/bin/true & dead=$!; wait $dead
  jq -nc --argjson p $dead --arg a $MEM/chaos-grumpy-security-nag --arg b $MEM/chaos-grumpy-budget-hawk '{session_id:"sid-OLD",pid:$p,started_epoch:1,frozen_memory:[$a,$b]}' > $T/session.lock
  runl $(date +%s) $L3E PRWATCH_ENGINE=builtin
  ok "B3: stale lock → its folders thawed at start (files too), one line; a folder outside GRUMPS left alone" 'grep -q "Unfroze 1 reviewer memory folder(s) left frozen" $T/launch.out && ! uchg $MEM/chaos-grumpy-security-nag && ! uchg $MEM/chaos-grumpy-security-nag/m.md && uchg $MEM/chaos-grumpy-budget-hawk'
  chflags -R nouchg $MEM
  ok "B3: the launcher builds the folder list from GRUMPS and MEMORY_PREFIX, and checks each with memdir_ok" 'grep -q "for g in \$GRUMPS; do FROZEN+=(\"\$MEMROOT/\${MEMORY_PREFIX}-grumpy-\$g\")" "$L" && grep -q "memdir_ok \"\$MEMROOT\"" "$L"'
else print "skip B3 launcher checks (no launcher at $L; set PRWATCH_LAUNCHER)"; fi
IS=${REPO:-$HOME/Documents/GitHub/pr-watcher/watcher}; IS=${IS:h}/install.sh
if [[ -f $IS ]]; then
  H=$P3/home; HM=$H/.claude/agent-memory/chaos-grumpy-code-reviewer; mkdir -p $H/prwatch/state $H/prwatch/cache/parliament-abc $HM; chflags uchg $HM $H/prwatch/cache/parliament-abc
  mkdir -p $P3/w; print 'sleep 30' > "$P3/w/PR Watcher.command"; /bin/zsh "$P3/w/PR Watcher.command" & wpid=$!; pids+=($wpid)   # a live "watcher window"
  jq -nc --argjson p $wpid --arg a $HM '{session_id:"x",pid:$p,frozen_memory:[$a]}' > $H/prwatch/state/session.lock
  HOME=$H /bin/zsh $IS --thaw >/dev/null 2>&1; rc=$?
  ok "B3: install.sh --thaw while the lock's watcher window is alive → refused, flags remain" '(( rc != 0 )) && uchg $HM'
  jq --argjson p $$ '.pid=$p' $H/prwatch/state/session.lock > $H/l && mv $H/l $H/prwatch/state/session.lock   # alive, but not a watcher (a reused pid)
  out=$(HOME=$H /bin/zsh $IS --thaw 2>&1); rc=$?
  ok "B3: install.sh --thaw when the lock's pid is some other process → thawed (memory and snapshots), count printed, nothing installed" '(( rc == 0 )) && [[ $out == "Unfroze 1 reviewer memory folder(s)." ]] && ! uchg $HM && ! uchg $H/prwatch/cache/parliament-abc && [[ ! -e $H/prwatch/bin ]]'
  kill $wpid 2>/dev/null
  # --repin, on a copy of install.sh + prwatch-common.zsh (it writes the lock into its own watcher/config/)
  RP=$P3/rp; RH=$P3/rph; mkdir -p $RP/watcher/bin $RP/watcher/config $RP/launcher $RH/.claude/plugins $RH/Desktop
  cp $IS $RP/install.sh; cp $B/prwatch-common.zsh $RP/watcher/bin/; print '#!/bin/zsh' > "$RP/launcher/PR Watcher.command"
  repin() { print OLD > $RP/watcher/config/parliament.lock; cp $P3/pins.json $RH/.claude/plugins/installed_plugins.json; out=$(HOME=$RH /bin/zsh $RP/install.sh --repin 2>&1); rc=$?; }
  mkplug; : > $PD/src/hooks/.env; repin
  ok "B3: install.sh --repin with src/hooks/.env → refused, lock unchanged" '(( rc == 1 )) && [[ $(<$RP/watcher/config/parliament.lock) == OLD ]] && [[ $out == *src/hooks/.env* ]]'
  mkplug; ln -s $PD/agents $PD/agl; repin
  ok "B3: install.sh --repin on a tree it cannot hash (symlink to a folder) → clear refusal, lock unchanged" '(( rc == 1 )) && [[ $(<$RP/watcher/config/parliament.lock) == OLD && $out == "Could not hash "* ]]'
  mkplug; repin
  ok "B3: install.sh --repin → lock {version, install_path, tree_sha256} equal to the launcher's hash; 12-character hash shown" '(( rc == 0 )) && [[ $(jq -c "[.version,.install_path,.tree_sha256]" $RP/watcher/config/parliament.lock) == "[\"9.9.9\",\"$PD\",\"$(th $PD)\"]" && $out == *"(tree $(th $PD | cut -c1-12)…)"* ]]'
else print "skip B3 install.sh --thaw (no repo install.sh at $IS)"; fi
# tree_sha256 itself: modes and symlink targets count; a symlink to a folder or outside, or an unreadable file, fails
TD=$P3/td; mkdir -p $TD/s; print a > $TD/a; print b > $TD/s/b; ln -s a $TD/l; h0=$(th $TD)
ln -sfn s/b $TD/l; h1=$(th $TD); chmod +x $TD/a; h2=$(th $TD); chmod -x $TD/a
ok "B3: tree_sha256 changes when a symlink is re-pointed or a file mode changes" '[[ -n $h0 && $h0 != $h1 && $h1 != $h2 && $(th $TD) == $h1 ]]'
ok "B3: tree_sha256 fails on a symlink to a folder, a symlink outside the tree, an unreadable file" '(ln -s s $TD/d; ! th $TD >/dev/null); rm -f $TD/d; (ln -s /etc/hosts $TD/o; ! th $TD >/dev/null); rm -f $TD/o; (chmod 000 $TD/s/b; ! th $TD >/dev/null); r=$?; chmod 644 $TD/s/b; (( r == 0 ))'
englock() { jq -nc --arg e $1 --arg s ${2:-sid-A} --argjson t $SE '{session_id:$s,pid:1,started_epoch:$t,engine:{engine:$e,plugin_id:null,version:null,plugin_dir:null,reason:"test"}}' > $T/session.lock; }
reset; englock parliament
ok "B3: tick echoes the lock's engine (--window and a full tick)" '[[ $(win $SE | jq -r .engine) == parliament && $(tk $SE | jq -r .engine) == parliament ]]'
reset; ok "B3: no engine in the lock → engine null" '[[ $(win $SE | jq -c .engine) == null ]]'
halflock; LJ3=$(jq -nc --argjson e $SE '{session_id:"sid-A",pid:1,started_epoch:$e,engine:{engine:"builtin",reason:"x"}}'); PRWATCH_LOCK_JSON=$LJ3 tk $SE >/dev/null
ok "B3: a tick-recreated lock carries the launcher's engine object" '[[ $(jq -c .engine $T/session.lock) == $(jq -c .engine <<<$LJ3) && $(jq .recreated $T/session.lock) == true ]]'

# B7 — the skill gate (D5, D7): an allow-list that fails closed; and the agent hook's subagent types (D6)
SKH=$B/prwatch-skillhook.sh
sk7() { if (( $# >= 2 )); then jq -nc --arg s "$1" --arg a "$2" '{tool_name:"Skill",tool_input:{skill:$s,args:$a}}'; else jq -nc --arg s "$1" '{tool_name:"Skill",tool_input:{skill:$s}}'; fi | $SKH 2>/dev/null; print $?; }
b7() { local want=$1 r; shift; r=$(sk7 "$@"); ok "B7: skill '$1' ${2-(no args)} → $want" "(( $r == $want ))"; }
raw7() { local r; r=$(print -rn -- "$2" | $SKH 2>/dev/null; print $?); ok "B7: payload ${2[1,60]} → 2" "(( $r == 2 ))"; }
reset; englock builtin; mkdir -p $W $WC; ln -sfn $PRW/bin $WL
for s in prwatch-start prwatch-tick prwatch-eod; do b7 0 $s; b7 0 $s ""; b7 2 $s now; done
b7 0 prwatch-review ACT-Training/Vision#1803; b7 0 prwatch-decide JackScammell/pr-watcher#1
b7 2 prwatch-review; b7 2 prwatch-review '../x#1'; b7 2 prwatch-review 'ACT-Training/Vision#1803 extra'; b7 2 prwatch-decide 1803
for e in low medium high; do b7 0 code-review "$e $W"; done
for a in "xhigh $W" "ultra $W" "max $W" "high $W --comment" "--comment high $W" "high $W --post" "high $W --fix" "high --max-findings 3 $W" \
         1803 '#1803' "high 1803" "high ACT-Training/Vision#1803" "high $PRW/repos/ACT-Training__Zzzt" "high $PRW/bin" "high $PRW/work/../bin" \
         "high ~" "high $W; ls" "" "high  $W" "High $W" "high $W/" "high $PRW/work/Nobody__none-pr1-0123456" "high $WL" "high $WC"; do b7 2 code-review "$a"; done
b7 2 code-review
for e in parliament builtin-agent; do englock $e; b7 2 code-review "high $W"; done
englock builtin sid-B; b7 2 code-review "high $W"; rm -f $T/session.lock; b7 2 code-review "high $W"; englock builtin
for s in chaos:list-commands chaos:parliament-review security-review schedule loop review /prwatch-tick unknown-skill; do b7 2 $s; done
b7 2 chaos:parliament-loop "5m /chaos:parliament-review"; b7 2 ""; b7 2 "" prwatch-tick
for pl in '{"tool_name":"Skill","tool_input":{"name":"prwatch-tick"}}' '{"tool_name":"Skill","tool_input":{"skill":"prwatch-tick","extra":1}}' \
          '{"tool_name":"Skill"}' 'not json' '' '{"tool_name":"Bash","tool_input":{"command":"ls"}}' '{"tool_name":"Skill","tool_input":{"skill":1}}' \
          '{"tool_name":"Skill","tool_input":{"skill":"prwatch-tick","args":1}}' '[{"tool_name":"Skill","tool_input":{"skill":"prwatch-tick"}}]'; do raw7 x "$pl"; done
ok "B7: test mode logs the raw tool_input (live-check L4 reads it)" 'grep -qx "{\"skill\":\"prwatch-tick\"}" $T/harness/skillgate.log && grep -qx unparsable $T/harness/skillgate.log'
ok "B7: a refusal says why, on stderr" '[[ "$(jq -nc "{tool_name:\"Skill\",tool_input:{skill:\"chaos:ci-watch\"}}" | $SKH 2>&1 >/dev/null)" == "prwatch skill gate: Parliament commands are never run"* ]]'
ah() { local r; r=$(jq -nc --argjson i "$2" '{tool_name:"Agent",tool_input:$i}' | $B/prwatch-agenthook.sh pre 2>/dev/null; print $?); ok "B7: agent ${2[1,70]} (engine $3) → $1" "(( $r == $1 ))"; }
reset; englock builtin
ah 0 '{"subagent_type":"general-purpose"}' builtin; ah 2 '{}' builtin; ah 2 '{"subagent_type":"Explore"}' builtin
ah 2 '{"subagent_type":"chaos:senior-council"}' builtin; ah 2 '{"subagent_type":"chaos:grumpy-security-nag"}' builtin
ah 2 '{"subagent_type":"general-purpose","isolation":"worktree"}' builtin
englock parliament; for g in $(source $B/prwatch-common.zsh; print $GRUMPS); do ah 0 "{\"subagent_type\":\"chaos:grumpy-$g\"}" parliament; done
ah 2 '{"subagent_type":"chaos:grumpy-budget-hawk"}' parliament; ah 2 '{"subagent_type":"chaos:deliberation-conductor"}' parliament
ah 2 '{"subagent_type":"chaos:grumpy-security-nag","isolation":"remote"}' parliament; ah 2 '{"subagent_type":"chaos:grumpy-"}' parliament
englock parliament sid-B; ah 2 '{"subagent_type":"chaos:grumpy-security-nag"}' "parliament, another session's lock"
# fail closed: the settings.json commands, run as Claude Code runs them (a shell), on a HOME whose common.zsh is broken
HH=$P3/hh; mkdir -p $HH/prwatch/bin $HH/prwatch/work/Some-Org__Zzzt-pr9-0123456 $P3/hh2; grep -v '^WT_PAT=' $B/prwatch-common.zsh > $HH/prwatch/bin/prwatch-common.zsh
SKC=$(jq -r '.hooks.PreToolUse[]|select(.matcher=="Skill")|.hooks[0].command' $C); AGC=$(jq -r '.hooks.PreToolUse[]|select(.matcher=="*")|.hooks[0].command' $C)
reset; englock builtin; CRASH=$(jq -nc --arg a "high $HH/prwatch/work/Some-Org__Zzzt-pr9-0123456" '{tool_name:"Skill",tool_input:{skill:"code-review",args:$a}}')
r1=$(print -r -- $CRASH | HOME=$HH $SKH >/dev/null 2>&1; print $?); r2=$(print -r -- $CRASH | HOME=$HH /bin/sh -c "$SKC" >/dev/null 2>&1; print $?)
ok "B7: a skill hook that crashes (WT_PAT unset) still refuses: raw exit 1, settings command 2" '(( r1 == 1 && r2 == 2 ))'
ok "B7: common.zsh cannot be loaded → skill hook refuses even prwatch-tick; agent hook pre refuses even Read" '(( $(sk7 prwatch-tick | tail -1) == 0 )) && [[ $(jq -nc "{tool_name:\"Skill\",tool_input:{skill:\"prwatch-tick\"}}" | HOME=$P3/hh2 /bin/sh -c "$SKC" >/dev/null 2>&1; print $?) == 2 && $(tj Read | HOME=$P3/hh2 /bin/sh -c "$AGC" >/dev/null 2>&1; print $?) == 2 ]]'
tk7() { local r; r=$(jq -nc --arg t $2 --argjson i "$3" '{tool_name:$t,tool_input:$i}' | $B/prwatch-agenthook.sh pre 2>/dev/null; print $?); ok "B7: tool $2 ${3[1,60]} → $1" "(( $r == $1 ))"; }
reset; englock builtin; tk7 2 Task '{"subagent_type":"chaos:senior-council"}'; tk7 0 Task '{"subagent_type":"general-purpose"}'; tk7 2 Delegate '{"subagent_type":"Explore"}'
ok "guard: chflags and claude plugin refused" '[[ $(g "chflags -R nouchg $HOME/.claude/agent-memory") == 2 && $(g "claude plugin install chaos@chaos") == 2 && $(g "/opt/homebrew/bin/claude  plugin list") == 2 && $(g "$SKH") == 2 ]]'
ok "settings: Skill PreToolUse hook → skillhook, fails closed"  'jq -e ".hooks.PreToolUse[]|select(.matcher==\"Skill\")|.hooks[0].command == \"$SKH || exit 2\"" $C >/dev/null'
ok "settings: code-review allowed by rule, its posting/escalating forms denied" 'jq -e "(.permissions.allow|index(\"Skill(code-review *)\")) and ([\"Skill(code-review *--comment*)\",\"Skill(code-review *--post*)\",\"Skill(code-review *--fix*)\",\"Skill(code-review ultra*)\",\"Skill(code-review max*)\"] - .permissions.deny | length == 0) and (.permissions.deny|index(\"Skill(code-review *)\")|not) and (.permissions.deny|index(\"Skill(code-review)\")|not)" $C >/dev/null'
ok "settings: Skill(chaos:*), named chaos commands, claude and chflags denied" 'jq -e "[\"Skill(chaos:*)\",\"Skill(chaos:parliament-loop)\",\"Skill(chaos:commit-and-push)\",\"Skill(chaos:ci-watch)\",\"Bash(claude *)\",\"Bash(* claude plugin *)\",\"Bash(chflags *)\"] - .permissions.deny | length == 0" $C >/dev/null'
ok "settings: skillOverrides: code-review visible, eight chaos commands user-invocable-only, the rest off" 'jq -e "(.skillOverrides|has(\"code-review\")|not) and ([.skillOverrides|to_entries[]|select(.key|startswith(\"chaos:\"))|.value]|length == 8 and all(. == \"user-invocable-only\")) and ([.skillOverrides[\"security-review\"],.skillOverrides.schedule,.skillOverrides.loop]|all(. == \"off\"))" $C >/dev/null'
ok "settings: review (an alias of code-review) neither overridden nor denied; the hook refuses it" 'jq -e "(.skillOverrides|has(\"review\")|not) and ([.permissions.deny[]|select(test(\"^Skill\\\\(review\"))]|length == 0)" $C >/dev/null && [[ $(sk7 review) == 2 && $(sk7 review "high $W") == 2 ]] && jq -r ".[\"\$comment\"]" $C | grep -q "alias of .code-review."'
ok "settings: the user-invocable-only commands are also denied by name" 'jq -e "[.skillOverrides|keys[]|select(startswith(\"chaos:\"))|\"Skill(\(.))\"] - .permissions.deny | length == 0" $C >/dev/null'
ok "settings: ~/.claude and /opt/homebrew write-denied; spawn depth 1" 'jq -e "(.sandbox.filesystem.denyWrite|index(\"/Users/jack/.claude\") and index(\"/opt/homebrew\")) and .env.CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH == \"1\"" $C >/dev/null'
ok "settings: the comment names the hook as authoritative and deny-beats-allow" 'jq -r ".[\"\$comment\"]" $C | grep -q "prwatch-skillhook.sh .*authoritative" && jq -r ".[\"\$comment\"]" $C | grep -q "Deny beats allow"'
ok "launcher: --plugin-dir only from the pinned engine; spawn depth exported before claude" 'grep -q "PLUGARGS=(--plugin-dir \"\$PLUG\")" "$L" && grep -q "\"\${PLUGARGS\[@\]}\"" "$L" && d1=$(grep -n "^export CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1" "$L" | cut -d: -f1) && cl=$(grep -n "^\"\$CLAUDE_BIN\" " "$L" | cut -d: -f1) && (( d1 < cl ))'
# B9 for PR 4: the prose repeats what the scripts own
GR=($(source $B/prwatch-common.zsh; print $GRUMPS)); RS=$S7/prwatch-review/SKILL.md
ok "B9: review skill's Parliament table names exactly GRUMPS" '[[ "$(grep -o "grumpy-[a-z-]*[a-z]" $RS | sort -u)" == "$(print -l ${GR/#/grumpy-} | sort -u)" ]]'
ok "B9: review skill: the grump brief (six files, five findings, cannot run), transcription, derived code-review verdict" 'grep -q "at most six further files" $RS && grep -q "at most 5 findings" $RS && grep -q "You cannot run anything" $RS && grep -q "transcribed verbatim from the hand-back (untrusted)" $RS && grep -q "any Critical or High finding → .REJECT." $RS && grep -q "\"panel\"" $RS'
ok "B9: CLAUDE.md: invariant 8, and every engine named" 'grep -q "^8\. \*\*Parliament\.\*\*" $PRW/CLAUDE.md && grep -q "never a verdict mapping" $PRW/CLAUDE.md && (for e in $(source $B/prwatch-common.zsh; print $ENGINES); do grep -q "^- .$e. — " $PRW/CLAUDE.md || exit 1; done)'
ok "B9: start skill: 7b and 7c, the fixture path is the launcher's" 'grep -q "^7b\. \*\*Parliament probe" $S7/prwatch-start/SKILL.md && grep -q "^7c\. \*\*Built-in review probe" $S7/prwatch-start/SKILL.md && grep -q "$PRW/work/prwatch__selftest-pr1-0000000" $S7/prwatch-start/SKILL.md && grep -q "\$PRW/work/prwatch__selftest-pr1-0000000" "$L"'
ok "B9: start skill's Parliament command list equals the user-invocable-only skillOverrides" '[[ "$(grep "^6\. " $S7/prwatch-start/SKILL.md | grep -o "chaos:[a-z-]*[a-z]" | sort -u)" == "$(jq -r ".skillOverrides|keys[]|select(startswith(\"chaos:\"))" $C | sort -u)" ]]'
ok "B9: review skill: one size ladder, testing-tyrant never beside testing-build, four members on sonnet, code-review level by size" 'grep -q "The size ladder is the same for every engine" $RS && grep -q "never beside .testing-build." $RS && grep -q "model: sonnet. for .grumpy-documentation-pedant., .grumpy-standards-enforcer., .grumpy-accessibility-auditor. and .grumpy-maintainability-curmudgeon." $RS && grep -q "level is .low. under 150 counted lines, .medium. from 150 to 499 and .high. at 500 or more" $RS'
ok "B9: decide asks with the same subagent_type; eod prints the engine" 'grep -q "same .subagent_type." $S7/prwatch-decide/SKILL.md && grep -q "Engine: <engine.engine>" $S7/prwatch-eod/SKILL.md'

# --- installed copy must match the repo (tests run the installed scripts)
if [[ -d $REPO ]]; then
  drift=$(cd $REPO && for f in bin/*.sh bin/*.zsh shims/* config/settings.json config/parliament.lock(N) CLAUDE.md BUILD-NOTES.md angles/*.md .claude/skills/*/SKILL.md test/harness/*.sh; do cmp -s $f $PRW/$f || print $f; done)
  ok "installed copy matches repo"         '[[ -z $drift ]]'; [[ -n $drift ]] && print "  drift: ${(f)drift}"
else print "skip installed copy matches repo (no repo at $REPO; set PRWATCH_REPO)"; fi
print "$((n-fail))/$n passed"; (( fail == 0 ))
