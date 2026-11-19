#!/bin/bash
# Builds WaveDesk.app (native macOS app) into ./build
#
#   ./build_app.sh                      build for this Mac
#   UNIVERSAL=1 ./build_app.sh          Apple Silicon + Intel (needs full Xcode)
#   VERSION=1.2.0 ./build_app.sh        stamp a version (used by the release workflow)
#
# Requirements: macOS 13+ and Xcode or the Xcode Command Line Tools (xcode-select --install)
set -euo pipefail
cd "$(dirname "$0")"

ARCH_FLAGS=()
if [ "${UNIVERSAL:-0}" = "1" ]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi

echo "▸ Building release binary…"
swift build -c release "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}"
BIN="$(swift build -c release "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}" --show-bin-path)/WaveDesk"

APP="build/WaveDesk.app"
echo "▸ Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/WaveDesk"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER:-$VERSION}" "$APP/Contents/Info.plist"
fi

echo "▸ Signing (ad-hoc)…"
codesign --force --deep --sign - "$APP"

echo "✓ Done: $APP ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist"))"
echo "  Open it with:  open \"$APP\"   (or drag it to /Applications)"
