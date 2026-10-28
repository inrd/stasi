#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/Stasi.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN/Stasi" "$APP/Contents/MacOS/Stasi"

# A stable signing identity keeps the TCC grant (and the app's identity) stable
# across rebuilds. Ad-hoc still works locally, but every build gets a new
# signature. Override with: SIGN_IDENTITY="Developer ID Application: ..."
IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
	IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
		| sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
fi

if [[ -n "$IDENTITY" ]]; then
	codesign --force --options runtime --timestamp \
		--sign "$IDENTITY" --identifier app.stasi.recorder "$APP"
	echo "signed: $IDENTITY"
else
	codesign --force --sign - --identifier app.stasi.recorder "$APP"
	echo "signed: ad-hoc (no identity found; set SIGN_IDENTITY to choose one)"
fi

echo "built: $(pwd)/$APP"
