#!/usr/bin/env bash
# Quits and removes Shots.app and the `shots` symlink.
# Keeps your screenshots, config (~/.config/shots) and index (~/.local/share/shots).
set -euo pipefail

APP="/Applications/Shots.app"
LINK="$HOME/.local/bin/shots"

osascript -e 'tell application id "com.shots.app" to quit' >/dev/null 2>&1 || true
[ -L "$LINK" ] && rm -f "$LINK"
rm -rf "$APP"

cat <<EOF
Removed Shots.app and the shots symlink. Left in place:
  screenshots   ~/Screenshots (or your configured outputRoot)
  config        ~/.config/shots/config.json
  index         ~/.local/share/shots
To restore the default screenshot location:
  defaults delete com.apple.screencapture location
Also remove Shots from System Settings → General → Login Items and
Privacy & Security → Accessibility.
EOF
