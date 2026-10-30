# live-check.sh's engine decisions, kept apart so run.sh can test them offline (B3).
# l1_verdict <l9 passed 0|1> <review text> <fake key> → prints 1 (the PR diff was reviewed), 0 (the whole tree was),
#   or nothing (inconclusive: L9 failed, the text is empty, or it names neither file)
l1_verdict() { (( $1 )) && [[ -n ${2//[[:space:]]/} ]] || return 0
  if   grep -q "old\.py\|$3" <<<"$2";          then print 0
  elif grep -qi 'new\.py\|a - b\|subtract' <<<"$2"; then print 1; fi; }
# ba_next <l1 verdict> <previous builtin_agent: true|false|""> → 1 or 0; an inconclusive L1 keeps the previous value
ba_next() { case $1 in 1) print 0 ;; 0) print 1 ;; *) [[ $2 == true ]] && print 1 || print 0 ;; esac; }
