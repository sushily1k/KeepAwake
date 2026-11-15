#!/bin/bash
# Builds KeepAwake.app and installs it into Applications.
#   ./build.sh         build and install
#   ./build.sh --dmg   build KeepAwake.dmg in this folder instead of installing
# Requires Xcode Command Line Tools:  xcode-select --install
set -e
cd "$(dirname "$0")"

APP_NAME="KeepAwake"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT
BUNDLE="$BUILD_DIR/$APP_NAME.app"

mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp Info.plist "$BUNDLE/Contents/Info.plist"

echo "Compiling app..."
swiftc -O -o "$BUNDLE/Contents/MacOS/$APP_NAME" Sources/main.swift

echo "Generating icon..."
if swiftc -O -o "$BUILD_DIR/icongen" Tools/icongen.swift \
   && mkdir -p "$BUILD_DIR/AppIcon.iconset" \
   && "$BUILD_DIR/icongen" "$BUILD_DIR/AppIcon.iconset" \
   && iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$BUNDLE/Contents/Resources/AppIcon.icns"; then
    echo "Icon created."
else
    echo "Icon generation failed; continuing without a custom app icon."
fi

echo "Signing (ad-hoc)..."
codesign --force --sign - "$BUNDLE"

if [ "$1" = "--dmg" ]; then
    mkdir "$BUILD_DIR/dmg"
    cp -R "$BUNDLE" "$BUILD_DIR/dmg/"
    ln -s /Applications "$BUILD_DIR/dmg/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$BUILD_DIR/dmg" -ov -format UDZO "$PWD/$APP_NAME.dmg"
    echo "Created: $PWD/$APP_NAME.dmg"
    exit 0
fi

if [ -w "/Applications" ]; then
    DEST="/Applications"
else
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
fi

pkill -x "$APP_NAME" 2>/dev/null || true
rm -rf "$DEST/$APP_NAME.app"
cp -R "$BUNDLE" "$DEST/$APP_NAME.app"
touch "$DEST/$APP_NAME.app"   # refresh Finder/Launchpad icon cache

echo "Installed: $DEST/$APP_NAME.app"
open "$DEST/$APP_NAME.app"
