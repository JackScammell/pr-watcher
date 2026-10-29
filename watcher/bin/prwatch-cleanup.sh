#!/bin/zsh
# prwatch-cleanup.sh <key> | --sweep   — removes both worktrees for a PR (or any older than 3 days; the sweep also
# archives old agenthook markers and deletes stopped-*/eod-done-* session files older than two days)
[[ -z "${PRWATCH_CLEAN:-}" ]] && exec /usr/bin/env -i HOME="$HOME" ${TZ:+TZ=$TZ} PATH=/opt/homebrew/bin:/usr/bin:/bin PRWATCH_CLEAN=1 \
  ${${(f)"$(/usr/bin/env | /usr/bin/grep '^PRWATCH_')"}:#} /bin/zsh "$0" "$@"
emulate -L zsh; set -u; setopt extendedglob nullglob
PRW=$HOME/prwatch; source $PRW/bin/prwatch-common.zsh
export GIT_CONFIG_GLOBAL=$PRW/config/gitconfig GIT_CONFIG_NOSYSTEM=1
if [[ ${1:-} == --sweep ]]; then targets=( $PRW/work/*(/Nm+3) ); [[ -n ${PRWATCH_TESTMODE:-} ]] && targets=()   # tests never sweep real worktrees
  SD=$PRW/state; [[ -n ${PRWATCH_TESTMODE:-} ]] && SD=${PRWATCH_STATE_DIR:-$PRW/test/state}; H=$SD/harness
  old=( $H/*.(marker|stopped|ended)(Nm+1) ); (( ${#old} )) && mkdir -p $H/done && mv $old $H/done/   # earlier sessions' agenthook markers
  old=( $SD/stopped-*(Nm+2) $SD/eod-done-*(Nm+2) ); (( ${#old} )) && rm -f $old                      # earlier sessions' stop / summary files
else okkey "${1:-}" || exit 64; targets=( $PRW/work/$(wt_prefix $1)*(/N) ); fi
for t in $targets; do
  if [[ $t == *-build ]]; then rm -rf -- $t            # standalone copy: never run git in it
  else r=${${t:t}%-pr[0-9]##-[0-9a-f](#c7)}            # <owner>__<repo> (old owner-less names: <repo>) = the clone under repos/
       git -c core.hooksPath=/dev/null -C $PRW/repos/$r worktree remove --force $t 2>/dev/null || rm -rf -- $t; fi
done
for r in $PRW/repos/*(/N); do git -c core.hooksPath=/dev/null -C $r worktree prune; done
