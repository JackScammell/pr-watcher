#!/bin/zsh
# PreToolUse(Bash) guard — tripwire only; the Bash sandbox is the boundary.
emulate -L zsh; setopt extendedglob
cmd=$(/usr/bin/jq -r '.tool_input.command // ""')
canon='^/Users/jack/prwatch/bin/prwatch-(tick|prep|state|notify|cleanup|post|buildrun)\.sh( [A-Za-z0-9/._@#:=+,-]+)*$'
if [[ "$cmd" == *prwatch-* ]]; then
  [[ "$cmd" =~ $canon ]] && exit 0
  print -u2 "prwatch guard: call watcher scripts only as /Users/jack/prwatch/bin/prwatch-<name>.sh with plain arguments"; exit 2
fi
norm=${cmd//[\'\"\\]/}                                   # strip quoting tricks: 'gh' "gh" g\h
if print -r -- "$norm" | /usr/bin/grep -Eiq '(^|[^[:alnum:]_])(gh|hub)([^[:alnum:]_-]|$)|(^|[^[:alnum:]_])nc[[:space:]]|github\.com|GH_[A-Z_]+|GITHUB_TOKEN|git[^|;&]*[[:space:]](push|credential)([[:space:]]|$)|alias\.[a-z]+=|security[[:space:]]+find-|osascript|System Events|sandbox-exec'; then
  print -u2 "prwatch guard: GitHub/credential access is only allowed via prwatch scripts"; exit 2
fi
exit 0
