#!/usr/bin/env bash
# Renders the made-up demo screenshots into <inbox> and marks them as screen captures, so a
# Shots instance watching that inbox files them like real ones. Used for README images.
#   scripts/demo/seed-inbox.sh /tmp/shots-demo/inbox
set -euo pipefail

INBOX="${1:?usage: seed-inbox.sh <inbox-dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Compiled rather than interpreted: ImageRenderer needs a real main actor.
cp "$HERE/make-demo-shots.swift" "$WORK/main.swift"
swiftc -O "$WORK/main.swift" -o "$WORK/make-demo-shots"
"$WORK/make-demo-shots" "$WORK/out"

# The same xattrs macOS's screencapture writes; Shots reads them to recognise screenshots.
plist() { plutil -convert binary1 -o - - <<<"<?xml version=\"1.0\"?><plist version=\"1.0\">$1</plist>" | xxd -p | tr -d '\n'; }
IS_CAPTURE="$(plist '<true/>')"
CAPTURE_TYPE="$(plist '<string>selection</string>')"

mkdir -p "$INBOX"
minute=0
for f in "$WORK"/out/*.png; do
  minute=$((minute + 7))
  name="Screenshot 2026-10-22 at 9.$(printf %02d $((minute % 60))).$(printf %02d $((minute * 3 % 60))) AM.png"
  cp "$f" "$INBOX/$name"
  xattr -wx com.apple.metadata:kMDItemIsScreenCapture "$IS_CAPTURE" "$INBOX/$name"
  xattr -wx com.apple.metadata:kMDItemScreenCaptureType "$CAPTURE_TYPE" "$INBOX/$name"
done
echo "seeded $(ls "$WORK"/out/*.png | wc -l | tr -d ' ') demo screenshots into $INBOX"
