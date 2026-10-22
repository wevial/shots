#!/usr/bin/env bash
# Builds the Shots.app viewer into app/build/Shots.app (ad-hoc signed).
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
BIN_DIR="$(swift build --package-path "$PKG" -c release --show-bin-path)"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Shots" "$APP/Contents/MacOS/Shots"

cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.shots.viewer</string>
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
</dict>
</plist>
PLIST

echo "==> codesign (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

if $install; then
  dest="$HOME/Applications/Shots.app"
  echo "==> installing to $dest"
  mkdir -p "$HOME/Applications"
  rm -rf "$dest"
  ditto "$APP" "$dest"
fi

echo "done: $APP"
