#!/bin/zsh
# Install / update the PR watcher from this repo into ~/prwatch and put the launcher on the Desktop.
# Safe to re-run: never touches state/, repos/, cache/ or work/, nor config/engine-fallback.json (live-check.sh's).
#   install.sh           install
#   install.sh --repin   pin the Parliament of Chaos plugin as installed now: write watcher/config/parliament.lock
#                        ({version, install_path, tree_sha256}), then install. Read the plugin's changes first; commit
#                        the new lock in a re-pin PR (CONTRIBUTING.md). Never installs or updates the plugin itself.
#   install.sh --thaw    unfreeze the reviewer memory folders a dead watcher window left frozen (its session.lock's
#                        frozen_memory list) and unlock its Parliament snapshots (cache/parliament-*); refused while a
#                        watcher window is still running. Installs nothing.
# Neither flag is something the watcher session can run: install.sh is never a canonical watcher script.
set -euo pipefail
REPO="${0:A:h}"
SRC="$REPO/watcher"
DEST="$HOME/prwatch"
source "$SRC/bin/prwatch-common.zsh"                 # tree_sha256, mem_thaw, parliament_installed: the launcher's own functions

case "${1:-}" in
  "") ;;
  --thaw)
    LOCK="$DEST/state/session.lock"
    [[ -f "$LOCK" ]] || { echo "No session lock: nothing to thaw. A folder still frozen can be unfrozen by hand: chflags -R nouchg <folder>"; exit 0; }
    pid=$(/usr/bin/jq -r '.pid // ""' "$LOCK" 2>/dev/null || true)
    if watcher_pid_live "$pid"; then
      echo "A watcher window is still running (pid $pid). Close it (it unfreezes its own folders), then run --thaw only if needed."
      exit 1
    fi
    c=$(mem_thaw "$HOME/.claude/agent-memory" ${(f)"$(lock_frozen "$LOCK" || true)"})
    for s in "$DEST"/cache/parliament-*(N/); do /usr/bin/chflags -R nouchg "$s"; done
    echo "Unfroze $c reviewer memory folder(s)."
    exit 0 ;;
  --repin)
    PINS="$HOME/.claude/plugins/installed_plugins.json"
    row=$(parliament_installed "$PINS") || { echo "Parliament of Chaos is not installed (no chaos@ entry in $PINS). Nothing pinned."; exit 1; }
    ip=${row%%$'\t'*}; ver=${row#*$'\t'}
    [[ -d "$ip" ]] || { echo "The installed plugin folder $ip does not exist. Nothing pinned."; exit 1; }
    [[ -e "$ip/src/hooks/.env" || -L "$ip/src/hooks/.env" ]] && { echo "$ip/src/hooks/.env exists: the watcher never loads a plugin with secrets beside its hooks. Nothing pinned."; exit 1; }
    sha=$(tree_sha256 "$ip") || { echo "Could not hash $ip: it has an unreadable file, or a symlink to a folder or to somewhere outside it. Nothing pinned."; exit 1; }
    /usr/bin/jq -n --arg v "$ver" --arg p "$ip" --arg s "$sha" '{version:$v, install_path:$p, tree_sha256:$s}' > "$SRC/config/parliament.lock"
    echo "Pinned Parliament $ver at $ip (tree ${sha[1,12]}…) in watcher/config/parliament.lock. Commit it in a re-pin PR." ;;
  *) echo "usage: install.sh [--repin | --thaw]"; exit 64 ;;
esac

# Files locked with `chflags uchg` (README "Lock") can't be overwritten — unlock first.
if ls -lO "$DEST/bin" "$DEST/shims" 2>/dev/null | grep -q uchg; then
  echo "~/prwatch is locked. Unlock first:  chflags -R nouchg ~/prwatch/{bin,shims,config,.claude,angles,CLAUDE.md}"
  exit 1
fi

mkdir -p "$DEST"/{state,repos,cache,work,gh-empty,test/state}
# parliament.lock is included before the *.lock exclusion (rsync: first match wins); engine-fallback.json is excluded,
# so --delete-after never removes the one live-check.sh wrote.
rsync -a --delete-after \
  --include '/config/parliament.lock' --exclude '/config/engine-fallback.json' \
  --exclude '*.lock' --exclude '*.log' \
  --exclude state --exclude repos --exclude cache --exclude work --exclude gh-empty \
  --exclude 'test/archive' --exclude 'test/builder-evidence' --exclude 'test/state' \
  "$SRC/" "$DEST/"
chmod +x "$DEST"/bin/*.sh "$DEST"/shims/* "$DEST"/test/harness/*.sh "$DEST"/test/stub/osascript "$DEST"/test/sim2/*.sh 2>/dev/null || true

# A launcher you have double-clicked gets macOS's com.apple.macl protection: it can't be overwritten, only replaced.
L="$HOME/Desktop/PR Watcher.command"
rm -f "$L" 2>/dev/null || true
if ! cp "$REPO/launcher/PR Watcher.command" "$L"; then
  echo "~/prwatch is updated, but macOS blocked replacing the Desktop launcher."
  echo "Drag 'PR Watcher' from the Desktop to the Bin in Finder, then run install.sh again."
  exit 1
fi
chmod +x "$L"

echo "Installed to $DEST and ~/Desktop/PR Watcher.command"
echo "Re-lock when done testing:  chflags -R uchg ~/prwatch/{bin,shims,config,.claude,angles,CLAUDE.md}"
