# prwatch-common.zsh — sourced by every script (after its `emulate -L zsh` line) and by the launcher, for the one grammar
# (keys, names, the repo gate) and the one clock (window, now_epoch); never executed, so it is correctly absent from
# the guard canon.
#   Window (integer seconds from the lock's started_epoch): new councils may start while elapsed < START_LIMIT (7 h 30);
#   the session ends at END (8 h). The launcher's watchdog arms at WATCHDOG_ARM and may run on up to END+WATCHDOG_EXTEND
#   while a review or question is live.
START_LIMIT=27000 END=28800 WATCHDOG_ARM=900 WATCHDOG_EXTEND=6000
PAUSE_MAX=480 REQUEST_MAX_AGE=120                 # `pause N` ceiling (minutes); a hook request file is fresh for this many seconds
# TZ: every script re-execs with `env -i` and passes TZ through on purpose. It changes only the HH:MM strings shown to
# Jack (the harness sets TZ=Europe/London so they are stable); every comparison is in epoch seconds.
# now_epoch → epoch seconds. The only place PRWATCH_NOW is honoured, and only in test mode: digits = epoch;
# %Y-%m-%dT%H:%M = local time (seconds pinned to :00 — macOS date -j -f otherwise takes them from the wall clock);
# anything else → "bad PRWATCH_NOW", 64. Callers use  now=$(now_epoch) || exit 64  so the 64 propagates.
now_epoch() {
  if [[ -n ${PRWATCH_TESTMODE:-} && -n ${PRWATCH_NOW:-} ]]; then
    if   [[ $PRWATCH_NOW == [0-9]## ]]; then print -r -- $PRWATCH_NOW
    elif [[ $PRWATCH_NOW == [0-9](#c4)-[0-9](#c2)-[0-9](#c2)T[0-9](#c2):[0-9](#c2) ]]; then date -j -f %Y-%m-%dT%H:%M:%S "$PRWATCH_NOW:00" +%s
    else print "bad PRWATCH_NOW"; return 1; fi
  else date +%s; fi
}
# started_epoch <state_dir> → the lock's started_epoch (digits), 0; missing lock/field or non-numeric → nothing, 1.
# Reads the lock only — never an environment variable — so the window is always measured from what the launcher wrote.
started_epoch() { local v; v=$(/usr/bin/jq -r '.started_epoch // ""' $1/session.lock 2>/dev/null) || return 1
  [[ $v == [0-9]## ]] || return 1; print -r -- $v; }
# session_id_ok <sid> — empty, or [A-Za-z0-9_-]+ : it is written into file names and JSON, so nothing else is accepted
session_id_ok() { emulate -L zsh; setopt extendedglob; [[ -z $1 || $1 == [A-Za-z0-9_-]## ]] }
# hhmm <epoch> — for humans: HH:MM, plus "tomorrow" / "yesterday" / "on <date>" when it is not the current day
hhmm() { local t d n nd; t=$(date -r $1 +%H:%M); d=$(date -r $1 +%F); n=$(now_epoch) || n=$(date +%s); nd=$(date -r $n +%F)
  if   [[ $d == $nd ]];                          then print -r -- $t
  elif [[ $d == $(date -r $((n+86400)) +%F) ]]; then print -r -- "$t tomorrow"
  elif [[ $d == $(date -r $((n-86400)) +%F) ]]; then print -r -- "$t yesterday"
  else print -r -- "$t on $d"; fi; }
# Keys and names — the one grammar (extendedglob patterns, which each matcher turns on for itself; callers match with [[ $x == ${~PAT} ]]).
#   key = <owner>/<repo>#<n>: owner is a GitHub login (1-39 chars, letters digits and hyphens, no leading or trailing
#   hyphen); repo never starts with "-" or "." (so never ".", ".." or an option); n has no leading zero.
OWNER_PAT='[A-Za-z0-9](|[A-Za-z0-9-](#c0,37)[A-Za-z0-9])'
REPO_PAT='[A-Za-z0-9_][A-Za-z0-9._-](#c0,99)'
NUM_PAT='[1-9][0-9](#c0,6)'
KEY_PAT="$OWNER_PAT/$REPO_PAT\\#$NUM_PAT"                 # \# : a literal hash, not the extendedglob repeat operator
okkey()   { emulate -L zsh; setopt extendedglob; [[ $1 == ${~KEY_PAT} ]] }                      # 0 = a well-formed key; prints nothing
okrepo()  { emulate -L zsh; setopt extendedglob; [[ $1 == ${~OWNER_PAT}/${~REPO_PAT} ]] }       # 0 = a well-formed <owner>/<repo>
oklogin() { emulate -L zsh; setopt extendedglob; [[ $1 == ${~OWNER_PAT} ]] }                    # 0 = a well-formed GitHub login (same grammar as an owner)
# key_split <key> — injects o, repo, n into the caller's scope (no local on purpose). Call only after okkey. A caller
# that uses those names must `local o repo n` first (as wt_* do) or they land in the script's scope.
key_split() { local rest; o=${1%%/*}; rest=${1#*/}; repo=${rest%%\#*}; n=${rest##*\#}; }
# Worktree and archive names are built here and nowhere else ("__" is unambiguous: an owner cannot contain "_").
#   wt_prefix <key>              → <owner>__<repo>-pr<n>-            (what cleanup and harness-abort match on)
#   wt_name <key> <sha>          → <owner>__<repo>-pr<n>-<sha7>      (callers add $PRW/work/ and -build)
#   archive_name <key> <round> [<date>] → <date>-<owner>-<repo>-pr<n>-round<round>, owner and repo lower-cased
wt_prefix()    { local o repo n; key_split $1; print -r -- "${o}__${repo}-pr${n}-"; }
wt_name()      { local o repo n; key_split $1; print -r -- "${o}__${repo}-pr${n}-${2[1,7]}"; }
archive_name() { local o repo n; key_split $1; print -r -- "${3:-$(date +%F)}-${o:l}-${repo:l}-pr${n}-round${2}"; }
WT_PAT="${OWNER_PAT}__${REPO_PAT}-pr${NUM_PAT}-[0-9a-f](#c7)"                  # a worktree basename, strictly (cleanup; the PR 4 skill hook)
WT_GLOB='*__*-pr[0-9]*-[0-9a-f]*'                                            # kill_strays only: $PRW/work/${~WT_GLOB} (loose on purpose)
# repo_status <state.json> <owner/repo> — prints one word, the one place the repos map is read:
#   allowed  repos[R] == "allowed"          blocked  a repos entry with any other value
#   seen     no repos entry, but some prs key starts with "R#" (day-1 rule: a tracked PR = seen; state set promotes it)
#   unseen   neither (an unreadable file prints unseen)
#   Case-insensitive: repos keys, prs keys and R are all compared lower-cased (GitHub owners and repos are).
repo_status() { /usr/bin/jq -r --arg r "${2:l}" '((.repos // {}) | with_entries(.key |= ascii_downcase)) as $rp
  | if ($rp | has($r)) then (if $rp[$r] == "allowed" then "allowed" else "blocked" end)
    elif ([(.prs // {}) | keys[] | ascii_downcase | select(startswith($r + "#"))] | length > 0) then "seen"
    else "unseen" end' "$1" 2>/dev/null || print unseen }
# repo_allowed <state.json> <owner/repo> — the one source gate (exit status is the predicate; prints nothing):
#   allowed or seen passes; blocked and unseen never do. prep, state set and tick all ask this and nothing else.
repo_allowed() { [[ $(repo_status "$1" "$2") == (allowed|seen) ]] }
# Review engine (plan D1–D4). The launcher decides it once and writes it into session.lock (engine.engine, one of
# ENGINES); the hooks and the tick read it from there. GRUMPS is the whole Parliament panel the review skill may
# dispatch (D9): the agent hook allows chaos:grumpy-<name> only for these names, and the launcher freezes the memory
# folder of exactly these, so a reviewer whose memory is not frozen can never be dispatched.
ENGINES=(parliament builtin builtin-agent)
GRUMPS=(security-nag code-reviewer privacy-paranoid testing-tyrant performance-troll accessibility-auditor
        architecture-skeptic maintainability-curmudgeon standards-enforcer documentation-pedant)
# PLUGIN_ID / MEMORY_PREFIX: what --plugin-dir names the plugin (chaos@inline) and where its reviewers keep memory
# (~/.claude/agent-memory/<MEMORY_PREFIX>-grumpy-<name>). Both follow from the plugin's name; live-check.sh L6 prints
# the folders a probe touches: if they differ, change these.
PLUGIN_ID=chaos@inline MEMORY_PREFIX=chaos
# engine_of <lock> <session_id> → the lock's engine.engine when the lock belongs to that session, else nothing.
engine_of() { /usr/bin/jq -r --arg s "$2" 'if .session_id == $s then (.engine.engine // "") else "" end' "$1" 2>/dev/null; }
# parliament_installed <installed_plugins.json> → "<install folder><TAB><version>" of Claude Code's chaos@ entry, 0;
# no such entry or an unreadable file → nothing, 1. The one reader of that file (launcher, install.sh, live-check).
parliament_installed() { local r; r=$(/usr/bin/jq -r '[.plugins // {} | to_entries[] | select(.key | startswith("chaos@")) | .value[0]
  | "\(.installPath // "")\t\(.version // "")"][0] // ""' "$1" 2>/dev/null); [[ -n ${r%%$'\t'*} ]] || return 1; print -r -- $r; }
# tree_sha256 <dir> → one SHA-256 over the tree (D3), names included, sorted bytewise so every Mac agrees:
#   a file    "F <mode> <sha256>  ./<path>"      a symlink  "L ./<path> -> <target>"  (never followed)
# Excluded: .git, and the top-level .in_use/ folder, where Claude Code drops a file per running process (it changes on
# every launch and is never loaded as plugin content). Fails (1, prints nothing) on a symlink to a directory or to
# anything outside <dir>, an unreadable file, or any other error: a tree it cannot hash completely never matches a pin.
tree_sha256() { emulate -L zsh; setopt pipefail; local d=${1:A} l f t tg h i; local -a files out ml sl
  [[ -d $d ]] || return 1
  l=$(cd $d && /usr/bin/find . \( -type f -o -type l \) -not -path './.git/*' -not -path './.in_use/*' -print0 | LC_ALL=C /usr/bin/sort -z) || return 1
  for f in ${(0)l}; do
    if [[ -L $d/$f ]]; then t=$(/usr/bin/readlink $d/$f) || return 1
      [[ $t == /* ]] && tg=$t || tg=$d/${f:h}/$t
      [[ -d $d/$f || ${tg:A} != "$d"/* ]] && return 1
      out+=("L $f -> $t")
    else files+=($f); fi
  done
  if (( ${#files} )); then                                       # one shasum and one stat for the whole tree
    ml=(${(f)"$(cd $d && /usr/bin/stat -f %Lp -- $files 2>/dev/null)"}) || return 1
    sl=(${(f)"$(cd $d && /usr/bin/shasum -a 256 -- $files 2>/dev/null)"}) || return 1
    (( ${#ml} == ${#files} && ${#sl} == ${#files} )) || return 1
    for i in {1..${#files}}; do out+=("F ${ml[i]} ${sl[i]}"); done
  fi
  h=$(print -rl -- $out | LC_ALL=C /usr/bin/sort | /usr/bin/shasum -a 256) || return 1
  print -r -- ${h%% *}; }
# pin_matches <parliament.lock> <dir> → 0 when <dir> hashes to the lock's tree_sha256 (a tree that cannot be hashed never does).
pin_matches() { local want got; want=$(/usr/bin/jq -r '.tree_sha256 // ""' "$1" 2>/dev/null); [[ -n $want ]] || return 1
  got=$(tree_sha256 "$2") || return 1; [[ $got == $want ]]; }
# decide_engine <forced> <engine-fallback.json> <parliament.lock> <installed_plugins.json> <claude version> — the
# launcher's engine choice (plan D1–D3, D22), one rule per line, first match wins. Sets ENGINE, REASON (plain English,
# shown to Jack and stored in the lock), PLUG (the pinned folder, parliament only), PVER, FOUND (the installed
# Parliament version, or "") and NOTES (lines for Jack). Returns 2 when the pinned tree has src/hooks/.env: refuse.
decide_engine() { local ein=$1 fb=$2 pl=$3 pins=$4 cv=$5 fbok=1 blocked=0 row pp pv fv
  local RP="~/Documents/GitHub/pr-watcher/install.sh --repin" LC="~/prwatch/test/harness/live-check.sh --engine"
  ENGINE=builtin PLUG="" PVER="" REASON="" FOUND="" NOTES=()
  row=$(parliament_installed "$pins") && FOUND=${row#*$'\t'}
  [[ -f $fb && $(/usr/bin/jq -r type "$fb" 2>/dev/null) != object ]] && fbok=0              # unreadable: fails closed
  [[ $(/usr/bin/jq -r '.parliament_blocked' "$fb" 2>/dev/null) == true ]] && blocked=1
  pp=$(/usr/bin/jq -r '.install_path // ""' "$pl" 2>/dev/null); pv=$(/usr/bin/jq -r '.version // ""' "$pl" 2>/dev/null)
  if   [[ -n $ein ]];                            then REASON="forced by PRWATCH_ENGINE=builtin"
  elif (( ! fbok ));                             then REASON="config/engine-fallback.json cannot be read"
                                                      NOTES+=("config/engine-fallback.json cannot be read, so Parliament is not loaded. Delete or fix it, then relaunch.")
  elif (( blocked ));                            then REASON="live-check found Parliament writing where it should not"
                                                      NOTES+=("Parliament was blocked by live-check under Claude Code $(/usr/bin/jq -r '.claude_version // "?"' "$fb"); you are on $cv. To clear it, run: $LC")
  elif [[ ! -f $pl ]];                           then REASON="Parliament is not set up for this watcher"
                                                      [[ -n $FOUND ]] && NOTES+=("Parliament $FOUND is installed but not pinned. Read it, then run: $RP")
  elif [[ -z $pp || ! -d $pp ]];                 then REASON="the pinned Parliament folder is missing"
  elif [[ -e $pp/src/hooks/.env || -L $pp/src/hooks/.env ]]; then return 2
  elif ! pin_matches "$pl" "$pp";                then REASON="Parliament's files differ from the pin"
    if [[ -n $FOUND && $FOUND != $pv ]];         then NOTES+=("Parliament $FOUND is installed but the watcher is pinned to $pv. Read what changed in the plugin (its release notes and hooks), then run: $RP")
    else                                              NOTES+=("Parliament ${pv}'s files differ from the pin. Read what changed in the plugin (its hooks especially), then run: $RP"); fi
  else ENGINE=parliament PLUG=$pp PVER=$pv REASON="its files match the pin"; fi
  # builtin-agent replaces builtin only when live-check recorded it for THIS Claude Code version, and never when forced
  (( fbok )) && [[ $ENGINE == builtin && -z $ein && $(/usr/bin/jq -r '.builtin_agent' "$fb" 2>/dev/null) == true ]] || return 0
  fv=$(/usr/bin/jq -r '.claude_version // ""' "$fb" 2>/dev/null)
  if [[ $fv == $cv ]]; then ENGINE=builtin-agent REASON="$REASON; Claude Code's /code-review cannot review a worktree on this version"
  else NOTES+=("config/engine-fallback.json is for Claude Code $fv, you are on $cv. To check this version, run: $LC"); fi; }
# engine_json → the lock's engine object from ENGINE, PLUG, PVER and REASON (the snapshot folder in plugin_dir).
engine_json() { /usr/bin/jq -nc --arg e $ENGINE --arg v "$PVER" --arg d "$PLUG" --arg r "$REASON" --arg id $PLUGIN_ID \
  '{engine:$e, plugin_id:(if $e == "parliament" then $id else null end), version:(if $v == "" then null else $v end),
    plugin_dir:(if $d == "" then null else $d end), reason:$r}'; }
# lock_frozen <session.lock> → the folders its frozen_memory lists, one per line (use as ${(f)"$(lock_frozen L)"}).
lock_frozen() { /usr/bin/jq -r '.frozen_memory[]? // empty' "$1" 2>/dev/null; }
# memdir_ok <root> <path> — 0 only for <root>/<MEMORY_PREFIX>-grumpy-<one of GRUMPS>; the only paths chflags touches.
memdir_ok() { local g; for g in $GRUMPS; do [[ $2 == $1/${MEMORY_PREFIX}-grumpy-$g ]] && return 0; done; return 1; }
# mem_thaw <root> <path>... — clear uchg (recursively) on every listed path that passes memdir_ok; prints how many.
mem_thaw() { local r=$1 p c=0; shift; for p in "$@"; do memdir_ok $r $p && [[ -d $p ]] && /usr/bin/chflags -R nouchg $p 2>/dev/null && (( ++c )); done; print $c; }
# watcher_pid_live <pid> — 0 when <pid> is alive and is a watcher window (the launcher), not a reused pid.
watcher_pid_live() { [[ $1 == <-> ]] && kill -0 $1 2>/dev/null && [[ "$(/bin/ps -p $1 -o command= 2>/dev/null)" == *"PR Watcher.command"* ]]; }
