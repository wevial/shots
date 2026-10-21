#!/usr/bin/env bash
# Builds shots + shots-helper, installs them under ~/.local/share/shots/bin, and loads the LaunchAgent.
# Re-run after pulling changes; it replaces the binaries and restarts the agent.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="com.shots.agent"
BIN_DIR="$HOME/.local/share/shots/bin"
LINK="$HOME/.local/bin/shots"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/shots"
DOMAIN="gui/$(id -u)"

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need bun
need swift

echo "→ building shots-helper (Swift)"
(cd "$ROOT/native" && swift build -c release >/dev/null)

echo "→ building shots (bun --compile)"
(cd "$ROOT" && bun install --frozen-lockfile >/dev/null 2>&1 || bun install >/dev/null)
mkdir -p "$BIN_DIR" "$(dirname "$LINK")" "$LOG_DIR" "$(dirname "$PLIST")"
(cd "$ROOT" && bun build --compile --minify src/cli.ts --outfile "$BIN_DIR/shots" >/dev/null)
cp "$ROOT/native/.build/release/shots-helper" "$BIN_DIR/shots-helper"

# Stable identifiers make the binaries recognisable in System Settings. Ad-hoc signatures are
# still tied to the binary's hash, so macOS may ask for permissions again after a rebuild.
codesign --force --sign - --identifier "$LABEL" "$BIN_DIR/shots" 2>/dev/null || true
codesign --force --sign - --identifier "com.shots.helper" "$BIN_DIR/shots-helper"
ln -sf "$BIN_DIR/shots" "$LINK"

# Writes the default config on first run; also validates an existing one.
"$BIN_DIR/shots" config >/dev/null

# launchd starts with a bare PATH; include wherever claude/codex/node live right now.
path_dirs=()
for b in claude codex node bun; do
  if p="$(command -v "$b" 2>/dev/null)"; then path_dirs+=("$(dirname "$p")"); fi
done
AGENT_PATH="$(printf '%s\n' "${path_dirs[@]}" /usr/local/bin /usr/bin /bin /usr/sbin /sbin | awk '!seen[$0]++' | paste -sd: -)"

cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN_DIR/shots</string>
    <string>run</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$AGENT_PATH</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Standard</string>
  <key>StandardOutPath</key><string>$LOG_DIR/shots.log</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/shots.err.log</string>
</dict>
</plist>
EOF
plutil -lint "$PLIST" >/dev/null

echo "→ (re)loading $LABEL"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl kickstart -k "$DOMAIN/$LABEL" >/dev/null

INBOX="$("$BIN_DIR/shots" config | sed -n 's/^  "inbox": "\(.*\)",$/\1/p')"
cat <<EOF

Installed. Binary: $BIN_DIR/shots   Logs: $LOG_DIR

Next steps:
  1. Point screenshots at the inbox:
       defaults write com.apple.screencapture location "$INBOX"
  2. Recommended — turn off the floating thumbnail so files land immediately and the
     captured app context matches the moment you took the shot:
       defaults write com.apple.screencapture show-thumbnail -bool false
  3. Grant Accessibility to $BIN_DIR/shots
       System Settings → Privacy & Security → Accessibility → + → ⇧⌘G → paste the path
     then: launchctl kickstart -k $DOMAIN/$LABEL
  4. Check everything:  shots doctor
EOF
