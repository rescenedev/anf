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
swift build -c "$CONFIG" --product anfapp
BIN="$(swift build -c "$CONFIG" --show-bin-path)/anfapp"

echo "▸ Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$BIN_DIR" "$RES_DIR"
cp "$BIN" "$BIN_DIR/anf"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$RES_DIR/AppIcon.icns"

# Sign with the stable self-signed identity if present (keeps TCC file-access
# permissions across rebuilds); fall back to ad-hoc otherwise.
# Set up once with: ./tools/setup-signing.sh
SIGN_ID="anf-dev"
if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_ID" \
   && codesign --force --deep --sign "$SIGN_ID" "$APP" >/dev/null 2>&1; then
    echo "▸ Signed with '$SIGN_ID' (stable identity)"
else
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
    echo "▸ Ad-hoc signed (run ./tools/setup-signing.sh for persistent permissions)"
fi

echo "✓ Built $APP"

if [[ "${1:-}" == "run" ]]; then
    echo "▸ Launching…"
    open "$APP"
fi
