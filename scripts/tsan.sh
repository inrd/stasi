#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."

if ! defaults read com.ineardisplay.stasi outputFolderBookmark >/dev/null 2>&1; then
	echo "No output folder configured; launch Stasi once and choose one first." >&2
	exit 1
fi

CONFIG=debug
swift build -c "$CONFIG" --sanitize=thread
BIN="$(swift build -c "$CONFIG" --sanitize=thread --show-bin-path)"

# Sanitizer builds need a bundle of their own; do not touch build/Stasi.app.
APP="build/Stasi-TSan.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN/Stasi" "$APP/Contents/MacOS/Stasi"
codesign --force --sign - --identifier com.ineardisplay.stasi "$APP" >/dev/null 2>&1

SECONDS_TO_RECORD="${1:-15}"
REPORT_DIR="${TMPDIR:-/tmp}/stasi-tsan"
mkdir -p "$REPORT_DIR"
rm -f "$REPORT_DIR"/report.*(N)

# In testing, the tap delivered no callbacks at all while the output was
# silent, so without this the audio path is never exercised and TSan has
# nothing to see.
for _ in {1..60}; do
	afplay /System/Library/Sounds/Submarine.aiff >/dev/null 2>&1
done &
PLAYER_PID=$!

TSAN_OPTIONS="log_path=$REPORT_DIR/report halt_on_error=0" \
	"$APP/Contents/MacOS/Stasi" --auto-record "$SECONDS_TO_RECORD" &
APP_PID=$!

# Start-up, recording, normalization, and a little slack.
sleep $((SECONDS_TO_RECORD + 12))
kill "$APP_PID" 2>/dev/null || true
kill "$PLAYER_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true

reports=("$REPORT_DIR"/report.*(N))
if (( $#reports )); then
	echo "Thread Sanitizer found races (reports in $REPORT_DIR):"
	cat "${reports[@]}"
	exit 1
fi

echo "Thread Sanitizer: no reports."
echo "Check the saved take and ~/Library/Logs/Stasi/stasi.log to confirm capture ran."
