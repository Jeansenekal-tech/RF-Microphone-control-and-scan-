#!/bin/bash
# Builds WaveDesk.app (native macOS app) into ./build
# Requirements: macOS 13+ and Xcode or the Xcode Command Line Tools (xcode-select --install)
set -euo pipefail
cd "$(dirname "$0")"

echo "▸ Building release binary…"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/WaveDesk"
APP="build/WaveDesk.app"

echo "▸ Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/WaveDesk"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

echo "▸ Signing (ad-hoc, for this Mac)…"
codesign --force --deep --sign - "$APP"

echo "✓ Done: $APP"
echo "  Open it with:  open \"$APP\"   (or drag it to /Applications)"
