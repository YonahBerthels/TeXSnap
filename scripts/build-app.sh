#!/bin/bash
# Builds build/TeXSnap.app. Pass --install to also copy it to /Applications.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/TeXSnap.app"

swift build --package-path "$ROOT" -c release --product TeXSnap
BIN_DIR="$(swift build --package-path "$ROOT" -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/TeXSnap" "$APP/Contents/MacOS/TeXSnap"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
cp -R "$ROOT/Resources/web" "$ROOT/Resources/prompts" "$APP/Contents/Resources/"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"

# A stable signature (an Apple Development identity, if there is one) lets macOS remember the
# Screen Recording permission across rebuilds. Otherwise sign ad hoc.
IDENTITY="${TEXSNAP_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')}"
if [ -n "$IDENTITY" ] && codesign --force --timestamp=none --sign "$IDENTITY" "$APP" 2>/dev/null; then
  echo "Signed with: $IDENTITY"
else
  codesign --force --sign - "$APP"
  echo "Signed ad hoc"
fi
codesign --verify --strict "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
  DEST="/Applications/TeXSnap.app"
  if pgrep -xq TeXSnap; then
    osascript -e 'tell application id "com.texsnap.TeXSnap" to quit' >/dev/null 2>&1 || true
    sleep 1
  fi
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  echo "Installed $DEST"
fi
