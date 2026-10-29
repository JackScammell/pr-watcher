# prwatch-common.zsh — sourced by the scripts that need the clock or the window (after their `emulate -L zsh` line) and
# by the launcher; never
# executed, so it is correctly absent from the guard canon. One definition of the session window and the clock.
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
# hhmm <epoch> — for humans: HH:MM, plus "tomorrow" / "yesterday" / "on <date>" when it is not the current day
# session_id_ok <sid> — empty, or [A-Za-z0-9_-]+ : it is written into file names and JSON, so nothing else is accepted
session_id_ok() { [[ -z $1 || $1 == [A-Za-z0-9_-]## ]] }
hhmm() { local t d n nd; t=$(date -r $1 +%H:%M); d=$(date -r $1 +%F); n=$(now_epoch) || n=$(date +%s); nd=$(date -r $n +%F)
  if   [[ $d == $nd ]];                          then print -r -- $t
  elif [[ $d == $(date -r $((n+86400)) +%F) ]]; then print -r -- "$t tomorrow"
  elif [[ $d == $(date -r $((n-86400)) +%F) ]]; then print -r -- "$t yesterday"
  else print -r -- "$t on $d"; fi; }
