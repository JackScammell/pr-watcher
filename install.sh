#!/bin/zsh
# Install / update the PR watcher from this repo into ~/prwatch and put the launcher on the Desktop.
# Safe to re-run: never touches state/, repos/, cache/ or work/.
set -euo pipefail
SRC="${0:A:h}/watcher"
DEST="$HOME/prwatch"

# Files locked with `chflags uchg` (README "Lock") can't be overwritten — unlock first.
if ls -lO "$DEST/bin" "$DEST/shims" 2>/dev/null | grep -q uchg; then
  echo "~/prwatch is locked. Unlock first:  chflags -R nouchg ~/prwatch/{bin,shims,config,.claude,angles,CLAUDE.md}"
  exit 1
fi

mkdir -p "$DEST"/{state,repos,cache,work,gh-empty,test/state}
rsync -a --delete-after \
  --exclude '*.lock' --exclude '*.log' \
  --exclude state --exclude repos --exclude cache --exclude work --exclude gh-empty \
  --exclude 'test/archive' --exclude 'test/builder-evidence' --exclude 'test/state' \
  "$SRC/" "$DEST/"
chmod +x "$DEST"/bin/*.sh "$DEST"/shims/* "$DEST"/test/harness/*.sh "$DEST"/test/stub/osascript "$DEST"/test/sim2/*.sh 2>/dev/null || true

# A launcher you have double-clicked gets macOS's com.apple.macl protection: it can't be overwritten, only replaced.
L="$HOME/Desktop/PR Watcher.command"
rm -f "$L" 2>/dev/null || true
if ! cp "${0:A:h}/launcher/PR Watcher.command" "$L"; then
  echo "~/prwatch is updated, but macOS blocked replacing the Desktop launcher."
  echo "Drag 'PR Watcher' from the Desktop to the Bin in Finder, then run install.sh again."
  exit 1
fi
chmod +x "$L"

echo "Installed to $DEST and ~/Desktop/PR Watcher.command"
echo "Re-lock when done testing:  chflags -R uchg ~/prwatch/{bin,shims,config,.claude,angles,CLAUDE.md}"
