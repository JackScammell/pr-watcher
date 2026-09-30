#!/bin/zsh
# Run after every Claude Code update (a few cheap model calls, ~4 min): ~/prwatch/test/harness/live-check.sh
# Checks, against the REAL claude, the behaviour prwatch-agenthook.sh and self-test 7 depend on:
#   A. auto mode + CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 → Agent tool_response.status == "completed" (foreground)
#   B. without the variable, a background launch still looks like the fixtures (status async_launched, isAsync,
#      agentId), the installed hook records it, and TaskStop still answers "Successfully stopped task: <id>"
#   C. without the variable, a background agent that FINISHES on its own fires SubagentStop with its agent_id,
#      and the installed hook marks it stopped (TaskStop would be refused before any hook runs)
#   D. in the watcher's REAL sandbox (its settings.json): IPv4 loopback connects; reports whether dual-stack
#      (::ffff:127.0.0.1) is still refused (why DOTNET_SYSTEM_NET_DISABLEIPV6=1 is set); and, if a Vision build copy
#      exists in ~/prwatch/work, a small `dotnet test` there must pass (otherwise SKIP, shown in the summary)
# Uses test mode (temp state dir, stub osascript); touches nothing real, and kills its own leftovers on exit.
emulate -L zsh; set -u; setopt nullglob
PRW=$HOME/prwatch; fail=0; SLP=47          # distinctive sleep length so leftovers can be found and killed
CLAUDE=${PRWATCH_CLAUDE:-${commands[claude]:-}}
for c in "$HOME/Library/Application Support/Herd/config/nvm/versions/node/"*/bin/claude(N-nOn); do [[ -z $CLAUDE ]] && CLAUDE=$c; done
[[ -x $CLAUDE ]] || { print "claude not found (set PRWATCH_CLAUDE)"; exit 2; }
T=$(mktemp -d /tmp/pwl.XXXXXX)
trap '/usr/bin/pkill -f "^sleep $SLP\$" 2>/dev/null; rm -rf $T' EXIT
export PRWATCH_TESTMODE=1 PRWATCH_STATE_DIR=$T/state PRWATCH_STUB_BIN=$PRW/test/stub PRWATCH_SESSION_ID=sid-live PRWATCH_PID=$$
fresh() { rm -rf $T/state; mkdir -p $T/state; print '{"prs":{},"daily":{},"go_ahead":{}}' > $T/state/state.json
  print '{"session_id":"sid-live","pid":1}' > $T/state/session.lock; }
jq '{hooks:{PreToolUse:[.hooks.PreToolUse[]|select(.hooks[0].command|test("agenthook"))],
            PostToolUse:[.hooks.PostToolUse[]|select(.hooks[0].command|test("agenthook"))],
            SubagentStop:[.hooks.SubagentStop[]|select(.hooks[0].command|test("agenthook"))]}}' $PRW/config/settings.json > $T/hooks.json
chk() { if eval "$2"; then print "ok   $1"; else print "FAIL $1${3:+ — $3}"; (( fail++ )); fi; }
run() { "$CLAUDE" -p --output-format stream-json --verbose --model haiku --settings $T/hooks.json --setting-sources "" \
          --strict-mcp-config "$@" < /dev/null 2>/dev/null | grep '^{' > $T/out.jsonl; }
res() { jq -c "select(.type==\"user\") | .tool_use_result? // empty | select(type==\"object\") | $1" $T/out.jsonl; }
called() { jq -e "select(.type==\"assistant\")|.message.content[]?|select(.type==\"tool_use\" and .name==\"$1\")" $T/out.jsonl >/dev/null; }
print "claude: $("$CLAUDE" --version)"

fresh; CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 run --permission-mode auto \
  'Make one Agent call (subagent_type general-purpose, model haiku, prompt "Reply with exactly PONG. Use no tools."). Then stop.'
chk "A: foreground with the variable (status completed)" '[[ "$(res "select(.status!=null)|.status" | head -1)" == \"completed\" ]]'
chk "A: no fault recorded, no leftover note"             '[[ -z $(print $T/state/harness/*.(marker|stopped|ended)) && ! -e $T/state/stopped-$(date +%F) ]]' \
    "a leftover .ended means the foreground result no longer carries agentId"
print "     A shape: $(res 'select(.status!=null)|{status,isAsync,handback,agentId}' | head -1)"

fresh; ( unset CLAUDE_CODE_DISABLE_BACKGROUND_TASKS; run --permission-mode bypassPermissions \
  "Make one Agent call (subagent_type general-purpose, model haiku, prompt \"Run the shell command: sleep $SLP ; then reply DONE\"). As soon as it launches, call TaskStop on it (load TaskStop with ToolSearch first if needed). Then stop." )
launch=$(res 'select(.status=="async_launched")|{s:.status,a:.isAsync,id:(.agentId|type)}' | head -1)
stop=$(res 'select(.task_id!=null)|.message' | head -1)
chk "B: background launch shape matches fixtures"  '[[ $launch == "{\"s\":\"async_launched\",\"a\":true,\"id\":\"string\"}" ]]'
chk "B: hook recorded the fault (model-independent)" '[[ -n $(print $T/state/harness/*.(marker|stopped)) && -f $T/state/stopped-$(date +%F) ]]'
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

(( fail == 0 )) && print "live check passed${skipD:+ (D dotnet skipped: $skipD)}" || print "live check FAILED: update fixtures/hook before relying on the watcher"
(( fail == 0 ))
