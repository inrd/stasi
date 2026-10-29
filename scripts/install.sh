#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."

./scripts/build.sh

DEST="/Applications/Stasi.app"

# Quit a running copy so the bundle can be replaced cleanly.
osascript -e 'tell application id "com.ineardisplay.stasi" to quit' >/dev/null 2>&1 || true
sleep 1

rm -rf "$DEST"
ditto "build/Stasi.app" "$DEST"

codesign --verify --strict --verbose=2 "$DEST"
echo "installed: $DEST"

open "$DEST"
