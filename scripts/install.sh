#!/usr/bin/env bash
# Builds Shots.app, installs it to ~/Applications, links the `shots` CLI and launches the app.
# Re-run after pulling changes. The app itself watches the inbox and offers to start at login.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HOME/Applications/Shots.app"
LINK="$HOME/.local/bin/shots"
OLD_LABEL="com.shots.agent"

# The pre-Swift daemon ran as a LaunchAgent; two watchers on one inbox would race.
if launchctl print "gui/$(id -u)/$OLD_LABEL" >/dev/null 2>&1; then
  echo "→ removing the old $OLD_LABEL LaunchAgent"
  launchctl bootout "gui/$(id -u)/$OLD_LABEL" || true
fi
rm -f "$HOME/Library/LaunchAgents/$OLD_LABEL.plist"
rm -rf "$HOME/.local/share/shots/bin"

# Quit a running copy so the bundle can be replaced; it finishes the job in flight first.
osascript -e 'tell application id "com.shots.app" to quit' >/dev/null 2>&1 || true

"$ROOT/scripts/build-app.sh" --install
mkdir -p "$(dirname "$LINK")"
ln -sf "$APP/Contents/Helpers/shots" "$LINK"
open "$APP"

cat <<EOF

Installed $APP and linked $LINK.

If you haven't already:
  1. defaults write com.apple.screencapture location ~/Screenshots/_inbox
  2. defaults write com.apple.screencapture show-thumbnail -bool false
  3. Grant Accessibility to Shots.app (the app's Status window has a button for it).
  4. shots doctor
EOF
