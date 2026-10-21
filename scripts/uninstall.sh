#!/usr/bin/env bash
# Stops and removes the LaunchAgent and installed binaries.
# Keeps your screenshots, config (~/.config/shots) and index (~/.local/share/shots/shots.db).
set -euo pipefail

LABEL="com.shots.agent"
BIN_DIR="$HOME/.local/share/shots/bin"
LINK="$HOME/.local/bin/shots"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null && echo "→ stopped $LABEL" || echo "→ $LABEL was not loaded"
rm -f "$PLIST"
[ -L "$LINK" ] && rm -f "$LINK"
rm -f "$BIN_DIR/shots" "$BIN_DIR/shots-helper"
rmdir "$BIN_DIR" 2>/dev/null || true

cat <<EOF
Removed the agent and binaries. Left in place:
  screenshots   ~/Screenshots (or your configured outputRoot)
  config        ~/.config/shots/config.json
  index + logs  ~/.local/share/shots, ~/Library/Logs/shots
To restore the default screenshot location:
  defaults delete com.apple.screencapture location
Also remove the shots entry from System Settings → Privacy & Security → Accessibility.
EOF
