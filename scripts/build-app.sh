#!/usr/bin/env bash
# Builds Shots.app (menu bar app + daemon + bundled `shots` CLI) into app/build/Shots.app.
# Signed with the first "Apple Development" identity if there is one, otherwise ad-hoc.
#   scripts/build-app.sh            build only
#   scripts/build-app.sh --install  also copy it to ~/Applications/Shots.app
# It never launches the app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/app"
APP="$PKG/build/Shots.app"
VERSION="0.1"

install=false
for arg in "$@"; do
  case "$arg" in
    --install) install=true ;;
    *) echo "usage: $0 [--install]" >&2; exit 2 ;;
  esac
done

echo "==> swift build (release)"
swift build --package-path "$PKG" -c release --product Shots
swift build --package-path "$PKG" -c release --product shots-cli
BIN_DIR="$(swift build --package-path "$PKG" -c release --show-bin-path)"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN_DIR/Shots" "$APP/Contents/MacOS/Shots"
# Helpers/, not MacOS/: "Shots" and "shots" are the same file on a case-insensitive volume.
cp "$BIN_DIR/shots-cli" "$APP/Contents/Helpers/shots"

cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.shots.app</string>
  <key>CFBundleName</key><string>Shots</string>
  <key>CFBundleDisplayName</key><string>Shots</string>
  <key>CFBundleExecutable</key><string>Shots</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Shots reads the active browser tab's URL to file screenshots.</string>
</dict>
</plist>
PLIST

# A stable signing identity keeps the Accessibility/Automation grants across rebuilds;
# an ad-hoc signature changes with every build, so macOS forgets them.
IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
if [ -n "$IDENTITY" ]; then
  echo "==> codesign ($IDENTITY)"
  SIGN=(--force --sign "$IDENTITY" --timestamp=none)
else
  echo "!!! No 'Apple Development' signing identity found: signing ad-hoc." >&2
  echo "!!! Accessibility and Automation grants will NOT survive rebuilds." >&2
  SIGN=(--force --sign - --timestamp=none)
fi
codesign "${SIGN[@]}" "$APP/Contents/Helpers/shots"
codesign "${SIGN[@]}" "$APP"
codesign --verify --strict --deep "$APP"

if $install; then
  dest="$HOME/Applications/Shots.app"
  echo "==> installing to $dest"
  mkdir -p "$HOME/Applications"
  rm -rf "$dest"
  ditto "$APP" "$dest"
fi

echo "done: $APP"
