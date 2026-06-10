#!/bin/bash
# Builds anf and assembles a runnable anf.app bundle.
#   ./build.sh        release build + bundle
#   ./build.sh run    build, bundle, then launch
set -euo pipefail
cd "$(dirname "$0")"

CONFIG=release
APP="anf.app"
BIN_DIR="$APP/Contents/MacOS"
RES_DIR="$APP/Contents/Resources"

echo "▸ Compiling ($CONFIG)…"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/anf"

echo "▸ Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$BIN_DIR" "$RES_DIR"
cp "$BIN" "$BIN_DIR/anf"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$RES_DIR/AppIcon.icns"

# Ad-hoc sign so Quick Look / file access work without Gatekeeper friction.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "✓ Built $APP"

if [[ "${1:-}" == "run" ]]; then
    echo "▸ Launching…"
    open "$APP"
fi
