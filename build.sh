#!/usr/bin/env bash
# Builds SimShake.app, ad-hoc signs it, installs it to ~/Applications and launches it.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="SimShake"
BUILD_APP="build/$APP_NAME.app"
INSTALL_APP="$HOME/Applications/$APP_NAME.app"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$BUILD_APP"
mkdir -p "$BUILD_APP/Contents/MacOS"
cp "$BIN_DIR/$APP_NAME" "$BUILD_APP/Contents/MacOS/$APP_NAME"
cp Support/Info.plist "$BUILD_APP/Contents/Info.plist"

# Menu bar and app icons, rendered from Support/Icon.svg.
RESOURCES="$BUILD_APP/Contents/Resources"
rm -rf build/icons
swift Support/make-icons.swift Support/Icon.svg build/icons
mkdir -p "$RESOURCES"
cp build/icons/MenuBarIcon.png build/icons/MenuBarIcon@2x.png "$RESOURCES/"
iconutil -c icns build/icons/AppIcon.iconset -o "$RESOURCES/AppIcon.icns"

codesign --force --sign - "$BUILD_APP"

# Quit a running copy by signal: `tell application ... to quit` would launch it if it weren't running.
if pgrep -x "$APP_NAME" >/dev/null; then
    pkill -x "$APP_NAME" || true
    for _ in $(seq 50); do
        pgrep -x "$APP_NAME" >/dev/null || break
        sleep 0.1
    done
    if pgrep -x "$APP_NAME" >/dev/null; then
        echo "error: $APP_NAME is still running; quit it and run this script again." >&2
        exit 1
    fi
fi

mkdir -p "$HOME/Applications"
rm -rf "$INSTALL_APP"
ditto "$BUILD_APP" "$INSTALL_APP"
open "$INSTALL_APP"
echo "Installed and launched $INSTALL_APP"
