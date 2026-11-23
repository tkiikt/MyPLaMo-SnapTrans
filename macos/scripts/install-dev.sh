#!/bin/bash
# Copies the built app to a fixed place, ~/Applications/MyPLaMo SnapTrans.app, so macOS privacy permissions (which are
# keyed to the code identity and the app) keep applying across development builds. Run after build-app.sh.
# Refuses to replace a running copy (quit it from its menu first).
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="build/MyPLaMo SnapTrans.app"
DEST="$HOME/Applications/MyPLaMo SnapTrans.app"
[ -d "$SRC" ] || { echo "build first: scripts/build-app.sh" >&2; exit 1; }
if pgrep -f "^$DEST/Contents/MacOS/SnapTrans" >/dev/null; then echo "MyPLaMo SnapTrans is running from $DEST; quit it first." >&2; exit 1; fi
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$SRC" "$DEST"
codesign --verify --strict "$DEST"
echo "Installed: $DEST"
codesign -d -r- "$DEST" 2>&1 | sed -n 's/^designated => /Designated requirement: /p'
