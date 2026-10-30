#!/bin/zsh
# Run after every Claude Code update: ~/prwatch/test/harness/live-check.sh   (about 15 model runs, 5–10 min; L1 and
# L2/L6 start reviewer subagents of their own, which do not follow --model haiku). Close every watcher window and
# unlock ~/prwatch/config first: L6 freezes and thaws the real reviewer memory folders, and L1, L5/L6 write
# config/engine-fallback.json.
# Checks, against the REAL claude, the behaviour prwatch-agenthook.sh and self-test 7 depend on:
#   A. auto mode + CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 → Agent tool_response.status == "completed" (foreground)
#   B. without the variable, a background launch still looks like the fixtures (status async_launched, isAsync,
#      agentId), the installed hook records it, and TaskStop still answers "Successfully stopped task: <id>"
#   C. without the variable, a background agent that FINISHES on its own fires SubagentStop with its agent_id,
#      and the installed hook marks it stopped (TaskStop would be refused before any hook runs)
#   D. in the watcher's REAL sandbox (its settings.json): IPv4 loopback connects; reports whether dual-stack
#      (::ffff:127.0.0.1) is still refused (why DOTNET_SYSTEM_NET_DISABLEIPV6=1 is set); and, if a Vision build copy
#      exists in ~/prwatch/work, a small `dotnet test` there must pass (otherwise SKIP, shown in the summary)
#   L. the review engine (plan §7 L1–L9): /code-review on a worktree, Parliament probes, the skill gate, plugin hooks'
#      writes, reviewer-memory freeze, spawn depth, the CronCreate fields. Writes config/engine-fallback.json (below).
#      `live-check.sh --engine` runs only L.
# Uses test mode (temp state dir, stub osascript); touches nothing real except L6's brief freeze of the reviewer memory
# folders (thawed on exit) and L1's fixture worktree under ~/prwatch/work, and kills its own leftovers on exit.
emulate -L zsh; set -u; setopt nullglob
PRW=$HOME/prwatch; fail=0; SLP=47          # distinctive sleep length so leftovers can be found and killed
CLAUDE=${PRWATCH_CLAUDE:-${commands[claude]:-}}
for c in "$HOME/Library/Application Support/Herd/config/nvm/versions/node/"*/bin/claude(N-nOn); do [[ -z $CLAUDE ]] && CLAUDE=$c; done
[[ -x $CLAUDE ]] || { print "claude not found (set PRWATCH_CLAUDE)"; exit 2; }
T=$(mktemp -d /tmp/pwl.XXXXXX)
trap '/usr/bin/pkill -f "^sleep $SLP\$" 2>/dev/null; rm -rf $T' EXIT
export PRWATCH_TESTMODE=1 PRWATCH_STATE_DIR=$T/state PRWATCH_STUB_BIN=$PRW/test/stub PRWATCH_SESSION_ID=sid-live PRWATCH_PID=$$
fresh() { rm -rf $T/state; mkdir -p $T/state; print '{"prs":{},"go_ahead":{},"repos":{}}' > $T/state/state.json
  print "{\"session_id\":\"sid-live\",\"pid\":1,\"started_epoch\":$(date +%s)}" > $T/state/session.lock; }
jq '{hooks:{PreToolUse:[.hooks.PreToolUse[]|select(.hooks[0].command|test("agenthook"))],
            PostToolUse:[.hooks.PostToolUse[]|select(.hooks[0].command|test("agenthook"))],
            SubagentStop:[.hooks.SubagentStop[]|select(.hooks[0].command|test("agenthook"))]}}' $PRW/config/settings.json > $T/hooks.json
chk() { if eval "$2"; then print "ok   $1"; else print "FAIL $1${3:+ — $3}"; (( ++fail )); return 1; fi; }
run() { "$CLAUDE" -p --output-format stream-json --verbose --model haiku --settings $T/hooks.json --setting-sources "" \
          --strict-mcp-config "$@" < /dev/null 2>/dev/null | grep '^{' > $T/out.jsonl; }
res() { jq -c "select(.type==\"user\") | .tool_use_result? // empty | select(type==\"object\") | $1" $T/out.jsonl; }
called() { jq -e "select(.type==\"assistant\")|.message.content[]?|select(.type==\"tool_use\" and .name==\"$1\")" $T/out.jsonl >/dev/null; }
print "claude: $("$CLAUDE" --version)"
skipD=""
if [[ ${1:-} != --engine ]]; then

fresh; CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 run --permission-mode auto \
  'Make one Agent call (subagent_type general-purpose, model haiku, prompt "Reply with exactly PONG. Use no tools."). Then stop.'
chk "A: foreground with the variable (status completed)" '[[ "$(res "select(.status!=null)|.status" | head -1)" == \"completed\" ]]'
chk "A: no fault recorded, no leftover note"             '[[ -z $(print $T/state/harness/*.(marker|stopped|ended)) && ! -e $T/state/stopped-sid-live ]]' \
    "a leftover .ended means the foreground result no longer carries agentId"
print "     A shape: $(res 'select(.status!=null)|{status,isAsync,handback,agentId}' | head -1)"

fresh; ( unset CLAUDE_CODE_DISABLE_BACKGROUND_TASKS; run --permission-mode bypassPermissions \
  "Make one Agent call (subagent_type general-purpose, model haiku, prompt \"Run the shell command: sleep $SLP ; then reply DONE\"). As soon as it launches, call TaskStop on it (load TaskStop with ToolSearch first if needed). Then stop." )
launch=$(res 'select(.status=="async_launched")|{s:.status,a:.isAsync,id:(.agentId|type)}' | head -1)
stop=$(res 'select(.task_id!=null)|.message' | head -1)
chk "B: background launch shape matches fixtures"  '[[ $launch == "{\"s\":\"async_launched\",\"a\":true,\"id\":\"string\"}" ]]'
chk "B: hook recorded the fault (model-independent)" '[[ -n $(print $T/state/harness/*.(marker|stopped)) && -f $T/state/stopped-sid-live ]]'
if called TaskStop; then
  chk "B: TaskStop wording matches hook"           '[[ $stop == \"Successfully\ stopped\ task:* ]]'
  chk "B: hook marked the stopped agent"           '[[ -n $(print $T/state/harness/*.stopped) ]]'
else chk "B: model called TaskStop" false "the model skipped it; re-run live-check (wording not verified)"; fi
print "     B launch: $launch"; print "     B stop:   $stop"
/usr/bin/pkill -f "^sleep $SLP\$" 2>/dev/null

fresh; ( unset CLAUDE_CODE_DISABLE_BACKGROUND_TASKS; run --permission-mode bypassPermissions \
  'Make one Agent call (subagent_type general-purpose, model haiku, prompt "Reply with exactly PONG. Use no tools."). Do NOT call TaskStop. Wait until you are told it has completed, then stop.' )
chk "C: background agent finished on its own → hook marked it stopped" \
    '[[ -n $(print $T/state/harness/*.stopped) && -z $(print $T/state/harness/*.marker) ]] && ! called TaskStop' \
    "SubagentStop may no longer fire or carry agent_id (or the model called TaskStop anyway: re-run)"

# D — the watcher's own sandbox, driven exactly as reviewers are (sandboxed Bash under its settings.json)
skipD=""; VB=( $PRW/work/Vision-pr*-build(N/om) )
cat > $T/d.sh <<'DSH'
#!/bin/zsh
d=$(mktemp -d 2>&1); [[ -d $d && $d == $TMPDIR* ]] && print "MKTEMP=ok" || print "MKTEMP=bad $d"
print "IPV6VAR=${DOTNET_SYSTEM_NET_DISABLEIPV6:-unset}"
/usr/bin/python3 - <<'PY'
import socket
srv=socket.socket(socket.AF_INET); srv.bind(("127.0.0.1",0)); srv.listen(5); port=srv.getsockname()[1]
for name,fam,addr in [("IPV4",socket.AF_INET,("127.0.0.1",port)),("DUAL",socket.AF_INET6,("::ffff:127.0.0.1",port,0,0))]:
    s=socket.socket(fam)
    if fam==socket.AF_INET6: s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
    try: s.connect(addr); print(name+"=ok")
    except OSError as e: print(name+"=refused", e.errno)
PY
if [[ -n ${1:-} ]]; then
  cd $1 && VSTEST_CONNECTION_TIMEOUT=60 TZ=UTC dotnet test api/VisionApi.UnitTests/VisionApi.UnitTests.csproj --no-restore -m:1 -p:UseAppHost=false \
    --filter FullyQualifiedName~SignInTypeTests > $TMPDIR/live-d.txt 2>&1; print "DOTNET_EXIT=$?"; grep -E '^(Passed|Failed)!' $TMPDIR/live-d.txt
fi
DSH
[[ -z ${VB[1]:-} ]] && skipD="no Vision build copy in ~/prwatch/work"
( cd $PRW && PATH="$PRW/shims:$PATH" BASH_DEFAULT_TIMEOUT_MS=1800000 CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 GH_CONFIG_DIR=$PRW/gh-empty \
  "$CLAUDE" -p --output-format stream-json --verbose --model haiku --settings $PRW/config/settings.json --setting-sources "" \
  --strict-mcp-config "Run this exact Bash command once (sandboxed, as normal; timeout 1800000): zsh $T/d.sh ${VB[1]:-}
Do not retry or run anything else." < /dev/null 2>/dev/null | grep '^{' > $T/d.jsonl )
dout=$(jq -r 'select(.type=="user")|.message.content[]?|select(.type=="tool_result")|.content|if type=="array" then map(.text? // "")|join("\n") else . end' $T/d.jsonl)
chk "D: IPv4 loopback works in the watcher sandbox" '[[ $dout == *IPV4=ok* ]]' "local test servers can't be reached at all"
chk "D: mktemp -d works (shim, under \$TMPDIR)"    '[[ $dout == *MKTEMP=ok* ]]' "repo scripts using mktemp will be refused"
chk "D: DOTNET_SYSTEM_NET_DISABLEIPV6 reaches sandboxed Bash" '[[ $dout == *IPV6VAR=1* ]]'
# E — the allow-listed test scripts still run without a prompt or a checker block in auto mode (bad args → exit 64)
( cd $PRW && PATH="$PRW/shims:$PATH" CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 GH_CONFIG_DIR=$PRW/gh-empty \
  "$CLAUDE" -p --output-format stream-json --verbose --model haiku --settings $PRW/config/settings.json --setting-sources "" \
  --strict-mcp-config "Run exactly these two Bash commands, one at a time, and nothing else: $PRW/bin/prwatch-ngtest.sh ACT-Training/Vision#0 nothing   then   $PRW/bin/prwatch-dotnettest.sh ACT-Training/Vision#0 x.csproj Nowhere" < /dev/null 2>/dev/null | grep '^{' > $T/e.jsonl )
eout=$(jq -r 'select(.type=="user")|.message.content[]?|select(.type=="tool_result")|.content|if type=="array" then map(.text? // "")|join(" ") else . end' $T/e.jsonl)
chk "E: ngtest + dotnettest reachable in auto mode (both said bad arguments)" '(( ${#${(M)${(f)eout}:#*bad arguments*}} >= 2 ))' "a Claude Code update may be blocking the allow-listed test scripts"
if [[ $dout == *DUAL=refused* ]]; then print "     D: dual-stack still refused → DOTNET_SYSTEM_NET_DISABLEIPV6=1 still needed"
else print "     D: dual-stack now allowed → the variable could be dropped (Claude Code changed the sandbox)"; fi
if [[ -n $skipD ]]; then print "SKIP D dotnet test ($skipD)"
else chk "D: dotnet test passes in the watcher sandbox" '[[ $dout == *DOTNET_EXIT=0* && $dout == *Passed!* ]]' "see docs/fix-sandbox-tests.md"; fi
fi   # end of A–E

# L — the review engine. Two results decide the launcher's engine and are written to config/engine-fallback.json, the
# only place the launcher reads them (config/ must be unlocked to write it; nothing else ever writes this file):
#   L1 fails → builtin_agent: true for this Claude Code version; passes → false; inconclusive (SKIP) → unchanged
#   L5 or L6 fails → parliament_blocked: true; both pass → false (only a passing run clears it)
# L2, L3, L5, L6 need Parliament installed exactly as pinned (config/parliament.lock); otherwise they are skipped and
# parliament_blocked keeps its previous value.
source $PRW/bin/prwatch-common.zsh
CV=$("$CLAUDE" --version); CV=${CV%% *}; SET=$PRW/config/settings.json; PLK=$PRW/config/parliament.lock; FBF=$PRW/config/engine-fallback.json
PIN=$(jq -r '.install_path // ""' $PLK 2>/dev/null); pinned=0
[[ -n $PIN && -d $PIN ]] && pin_matches $PLK $PIN && pinned=1
MR=$HOME/.claude/agent-memory; FZ=(); LW=$PRW/work/prwatch__livecheck-pr1-0000000
trap '/usr/bin/pkill -f "^sleep $SLP\$" 2>/dev/null; (( ${#FZ} )) && mem_thaw $MR $FZ >/dev/null; rm -rf $T $LW' EXIT
englock() { fresh; jq --arg e $1 '. + {engine:{engine:$e}}' $T/state/session.lock > $T/l && mv $T/l $T/state/session.lock; }
wrun() {   # wrun <name> <cwd> [claude args…] — the watcher's REAL settings and hooks, test-mode state, launcher env
  local o=$1 d=$2; shift 2
  ( cd $d && PATH="$PRW/shims:$PATH" CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1 GH_CONFIG_DIR=$PRW/gh-empty \
    "$CLAUDE" -p --output-format stream-json --verbose --model haiku --settings $SET --setting-sources "" --strict-mcp-config "$@" \
    < /dev/null 2>/dev/null | grep '^{' > $T/$o.jsonl ) }
# Readers of a run's stream-json ($T/<name>.jsonl), each with an example of what it prints:
#   uses l9 Bash   → {"command":"ls"}           the input of every <tool> call, one per line
#   rerr l4 Skill  → true true false            is_error of each <tool> result, in call order
#   pong l2x       → (exit 0)                   an Agent completed and its report (hand-back or inline) says PONG
#   rtext l7       → NESTED-OK                  the text of every tool result
#   atext l9       → The PR adds new.py …       the assistant's own words and the final result, never tool output
#   memsnap        → 1730000000 /…/chaos-grumpy-code-reviewer/m.md   mtime and path under the memory root
uses()  { jq -c --arg n $2 'select(.type=="assistant")|.message.content[]?|select(.type=="tool_use" and .name==$n)|.input' $T/$1.jsonl 2>/dev/null; }
rerr()  { jq -rs --arg n $2 '[.[] | select(.type=="assistant") | .message.content[]? | select(.type=="tool_use" and .name==$n) | .id] as $ids
  | [.[] | select(.type=="user") | .message.content[]? | select(.type=="tool_result") | select(.tool_use_id as $t | $ids | index($t)) | (.is_error // false | tostring)] | join(" ")' $T/$1.jsonl 2>/dev/null; }   # is_error of each <tool> result, in order
pong()  { jq -se '[.[] | select(.type=="user") | .tool_use_result? | objects | select(.status=="completed") | ((.handbackReport.text? // "") + (.content? | tostring))] | any(test("PONG"))' $T/$1.jsonl >/dev/null 2>&1; }   # completed, report says PONG (handback or inline)
rtext() { jq -r 'select(.type=="user") | .message.content[]? | select(.type=="tool_result") | .content | if type=="array" then map(.text? // "") | join(" ") else tostring end' $T/$1.jsonl 2>/dev/null; }
atext() { jq -r 'if .type=="result" then (.result // empty) elif .type=="assistant" then (.message.content[]? | select(.type=="text") | .text) else empty end' $T/$1.jsonl 2>/dev/null; }
trues() { local i o=(); for i in {1..$1}; do o+=(true); done; print -r -- ${(j: :)o}; }   # trues 3 → true true true
gatelog() { (( $(wc -l < $T/state/harness/skillgate.log 2>/dev/null || print 0) == $1 )); }  # the skill gate saw exactly N calls
skprompt() { local c o=(); for c in "$@"; do o+=("skill ${c%%|*}${${c#*|}:+ with args '${c#*|}'}"); done   # "<skill>|<args>" …
  print -r -- "Make these $# Skill calls, one at a time, and nothing else (each may be refused; that is expected): ${(j:; :)o}."; }
memsnap() { find $MR -path '*grumpy*' \( -type f -o -type d \) -exec stat -f '%m %N' {} + 2>/dev/null | sort; }
PONG='Make one Agent call (subagent_type %s, description Probe, prompt "Reply with exactly PONG. Use no tools."). Then stop.'
(( pinned )) && print "L: engine checks (Parliament installed as pinned)" || print "L: engine checks (Parliament not installed as pinned: L2, L3, L5, L6 skipped)"

# L1 + L9 + L4 (builtin): a fixture shaped like prep's worktree: a clone with origin/main, a PR branch adding new.py with
# an obvious bug, while old.py (unchanged, on main) holds a committed secret. Reviewing the PR diff names new.py only.
G=(/usr/bin/git -c user.name=prwatch -c user.email=prwatch@localhost -c init.defaultBranch=main -c commit.gpgsign=false)
rm -rf $LW; mkdir -p $T/origin
FAKEKEY=FAKE-prwatch-livecheck-0123456789abcdef                  # obviously fake: only a whole-tree review would mention it
( cd $T/origin && $G init -q && print -l "API_KEY = \"$FAKEKEY\"" 'def ratio(a, b):' '    return a / b' > old.py && $G add . && $G commit -qm base ) >/dev/null 2>&1
$G clone -q $T/origin $LW >/dev/null 2>&1 && ( cd $LW && $G checkout -qb pr && print -l 'def add(a, b):' '    """Return the sum of a and b."""' '    return a - b' > new.py && $G add . && $G commit -qm 'Add add()' ) >/dev/null 2>&1
englock builtin; wrun l9 $PRW "Call the Skill tool exactly once: skill code-review, args 'low $LW'. When it returns, repeat its findings in one short paragraph and stop. Do not post, fix or run anything else."
l9=0; chk "L9: code-review returned in the foreground (no background launch, no fault marker)" \
    '[[ $(rerr l9 Skill) == false ]] && ! grep -q async_launched $T/l9.jsonl && [[ -z $(print $T/state/harness/*.marker) ]]' && l9=1
chk "L4: code-review low ran no gh command and posted nothing" '! uses l9 Bash | grep -Eq "(^|[^a-z])gh |gh\"" && ! atext l9 | grep -qi "posted to github\|comment posted"'
print "     L9 SubagentStop: $(print -l $T/state/harness/*.ended(N:t) | head -3 | tr "\n" " ")(an .ended note means SubagentStop carried an agent_id the post hook did not clear)"
# L1 is decided only on a conclusive run: L9 passed and the review said something. Naming old.py or the fake key means
# the whole tree was reviewed (fail); naming new.py or its bug means the PR diff was (pass); anything else is a SKIP
# that leaves builtin_agent as it was (one bad haiku run must not switch engines).
l1=""; a9=$(atext l9)
if (( l9 )) && [[ -n ${a9//[[:space:]]/} ]]; then
  if   grep -q "old\.py\|$FAKEKEY" <<<$a9;            then l1=0
  elif grep -qi 'new\.py\|a - b\|subtract' <<<$a9;   then l1=1; fi; fi
if [[ -n $l1 ]]; then chk "L1: /code-review on a worktree path reviews the PR diff (new.py), not the whole tree (old.py)" '(( l1 ))' "the launcher will use builtin-agent on this Claude Code version"
else print "SKIP L1 (inconclusive: L9 failed, or the review named neither file; builtin_agent left as it was)"; fi
L4C=("code-review|--comment $LW" "code-review|1803" "code-review|ultra $LW" "code-review|medium $PRW/bin" "review|low $LW")   # every one must be refused
englock builtin; wrun l4 $T "$(skprompt $L4C)"
chk "L4: ${#L4C} disallowed code-review/review forms all refused, by the skill gate (each call is in its log)" '[[ $(rerr l4 Skill) == "$(trues ${#L4C})" ]] && gatelog ${#L4C}' "a refusal that is not in the gate's log came from an override or deny rule, not the hook"
print "     L4 gate saw: $(sort -u $T/state/harness/skillgate.log 2>/dev/null | jq -r 'keys|join(",")' 2>/dev/null | sort -u | tr "\n" " ")"

pb_fail=0; pb_ran=0
if (( pinned )); then pb_ran=1
  act=$HOME/.claude/plugins/data/chaos-inline/agent-logs/activity.jsonl; a0=$(wc -l < $act 2>/dev/null || print 0); : > $T/since
  for g in code-reviewer security-nag; do englock parliament; wrun l2$g $T --plugin-dir $PIN "$(printf "$PONG" chaos:grumpy-$g)"
    chk "L2: chaos:grumpy-$g foreground (completed), replied PONG, no fault marker" \
        'pong l2$g && [[ -z $(print $T/state/harness/*.marker) ]]' \
        "self-test 7b would stop every session: relaunch with PRWATCH_ENGINE=builtin"; done
  L3C=("chaos:parliament-loop|" "chaos:commit-and-push|" "chaos:ci-watch|")                    # every one must be refused
  englock parliament; wrun l3 $T --plugin-dir $PIN "$(skprompt $L3C)"
  nchaos=$(jq -s '[.[] | select(.type=="system" and .subtype=="init") | (.slash_commands // [])[] | select(startswith("chaos:"))] | length' $T/l3.jsonl 2>/dev/null)
  chk "L3: --plugin-dir loaded Parliament (${nchaos:-0} chaos: commands) and all ${#L3C} commands refused by the skill gate" '(( ${nchaos:-0} > 0 )) && [[ $(rerr l3 Skill) == "$(trues ${#L3C})" ]] && gatelog ${#L3C}'
  englock parliament; wrun l5 $T --plugin-dir $PIN "Run these three Bash commands one at a time, sandboxed as normal (each is expected to fail; do not retry or work around it): /usr/bin/touch $PIN/src/hooks/.env ; /usr/bin/touch $HOME/.claude/prwatch-live-x ; /usr/bin/touch /opt/homebrew/bin/prwatch-live-x"
  made=($PIN/src/hooks/.env(N) $HOME/.claude/prwatch-live-x(N) /opt/homebrew/bin/prwatch-live-x(N)); (( ${#made} )) && rm -f $made
  chk "L5: sandboxed writes to the plugin's hooks, ~/.claude and /opt/homebrew all refused" '(( $(uses l5 Bash | wc -l) >= 3 && ${#made} == 0 ))' || pb_fail=1
  a1=$(wc -l < $act 2>/dev/null || print 0)   # Claude Code itself runs `npm root --global` at start (cache/npm/_logs): not the plugin
  new=$(find $PRW -newer $T/since -not -path "$PRW/state/activity" -not -path "$LW*" -not -path "$PRW/work" -not -path "$PRW/cache/npm/_logs*" 2>/dev/null)
  chk "L5: the plugin's activity log grew and holds no tool_input/tool_response" '(( a1 > a0 )) && ! tail -n $(( a1 - a0 )) $act | grep -q "\"tool_input\"\|\"tool_response\""' || pb_fail=1
  chk "L5: nothing new under ~/prwatch but state/activity and Claude Code's npm logs" '[[ -z $new ]]' "new: ${new//$'\n'/ }" || pb_fail=1
  m0=$(memsnap); englock parliament; wrun l6a $T --plugin-dir $PIN "$(printf "$PONG" chaos:grumpy-code-reviewer)"; m1=$(memsnap)
  print "     L6 unfrozen probe touched: $(diff <(print -r -- $m0) <(print -r -- $m1) | sed -n 's/^> [0-9]* //p' | tr "\n" " ")(MEMORY_PREFIX is '$MEMORY_PREFIX')"
  for g in $GRUMPS; do FZ+=($MR/${MEMORY_PREFIX}-grumpy-$g); mkdir -p $FZ[-1]; chflags -R uchg $FZ[-1]; done
  m2=$(memsnap); englock parliament; wrun l6b $T --plugin-dir $PIN "$(printf "$PONG" chaos:grumpy-code-reviewer)"; m3=$(memsnap)
  mem_thaw $MR $FZ >/dev/null; FZ=()
  chk "L6: with memory frozen the probe still completes and replies PONG" 'pong l6b' "the parliament engine is not usable with frozen memory" || pb_fail=1
  chk "L6: with memory frozen no grumpy memory file or folder changed" '[[ $m2 == $m3 ]]' "changed: $(diff <(print -r -- $m2) <(print -r -- $m3) | sed -n 's/^> [0-9]* //p' | tr "\n" " ")" || pb_fail=1
else print "SKIP L2 L3 L5 L6 (Parliament not installed as pinned)"; fi
englock builtin; wrun l7 $T "Make one Agent call (subagent_type general-purpose, model haiku, description Nest, prompt \"Make one Agent call yourself (subagent_type general-purpose, prompt: Reply PONG). Then reply NESTED-OK if it returned PONG, or NESTED-REFUSED if you could not.\"). Then stop."
if rtext l7 | grep -q NESTED-OK; then print "WARN L7: CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1 did not stop a nested spawn (the agent hook's type allow-list still refuses the spawning types)"
else print "ok   L7: no nested spawn"; fi
L8C=("*/15 * * * *|false" "*/10 * * * *|true")            # "<cron>|<expected is_error>": the tick job allowed, another cadence refused
c8=(); for c in $L8C; do c8+=("call CronCreate with cron \"${c%%|*}\", prompt \"/prwatch-tick\", recurring true"); done
wrun l8 $T "${(j:. Then :)c8}. Then stop. (Load CronCreate with ToolSearch first if it is deferred.)"
if (( $(uses l8 CronCreate | wc -l) >= ${#L8C} )); then
  chk "L8: the sched gate parses CronCreate (the tick job allowed, another cadence refused)" '[[ $(rerr l8 CronCreate) == "${(j: :)${(@)L8C#*|}}" ]]' "the field names changed: the gate fails closed and nothing can be scheduled"
else print "SKIP L8 (the model made no CronCreate calls; re-run)"; fi
pb=$(jq -r '.parliament_blocked // false' $FBF 2>/dev/null); (( pb_ran )) && { (( pb_fail )) && pb=true || pb=false; }
[[ $pb == (true|false) ]] || pb=true
case $l1 in 1) ba=0 ;; 0) ba=1 ;; *) [[ $(jq -r '.builtin_agent // false' $FBF 2>/dev/null) == true ]] && ba=1 || ba=0 ;; esac   # SKIP keeps it
if [[ -f $FBF || $ba == 1 || $pb == true ]]; then
  case $l1 in 1) r1=passed ;; 0) r1=failed ;; *) r1="inconclusive (kept)" ;; esac; r5="not run"; (( pb_ran )) && { r5=passed; (( pb_fail )) && r5=failed; }
  why="live-check under Claude Code $CV: L1 $r1; L5/L6 $r5"
  jq -n --argjson a $(( ba ? 1 : 0 )) --argjson b $pb --arg r "$why" --arg v $CV '{builtin_agent:($a == 1), parliament_blocked:$b, reason:$r, claude_version:$v}' > $FBF.tmp 2>/dev/null && mv $FBF.tmp $FBF \
    && print "     wrote config/engine-fallback.json: $(jq -c . $FBF)" || { rm -f $FBF.tmp 2>/dev/null; print "FAIL could not write $FBF (config/ locked? unlock it and re-run)"; (( ++fail )); }
fi

(( fail == 0 )) && print "live check passed${skipD:+ (D dotnet skipped: $skipD)}" || print "live check FAILED: update fixtures/hook before relying on the watcher"
(( fail == 0 ))
