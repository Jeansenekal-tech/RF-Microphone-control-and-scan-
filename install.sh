#!/bin/bash
# Builds "Unique AV RF Scan Co-ord" and installs it into /Applications.
#   ./install.sh            install and open
#   ./install.sh --demo     install and open with a demo receiver + simulated analyzer
set -euo pipefail
cd "$(dirname "$0")"
NAME="Unique AV RF Scan Co-ord"

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Apple's developer tools are needed. A window will open – click Install, wait for it to finish,"
  echo "then run ./install.sh again."
  xcode-select --install || true
  exit 1
fi

./build_app.sh

echo "▸ Installing to /Applications…"
osascript -e "quit app \"$NAME\"" >/dev/null 2>&1 || true
rm -rf "/Applications/$NAME.app"
cp -R "build/$NAME.app" /Applications/
xattr -dr com.apple.quarantine "/Applications/$NAME.app" 2>/dev/null || true

echo "✓ Installed: /Applications/$NAME.app"
if [ "${1:-}" = "--demo" ]; then
  open "/Applications/$NAME.app" --args --demo
else
  open "/Applications/$NAME.app"
fi
