#!/bin/bash
# install-launchd.sh — auto-start Hindsight on macOS login
# Usage: bash install-launchd.sh

set -euo pipefail

if [ -z "${OPENAI_API_KEY:-}" ]; then
    echo "WARNING: OPENAI_API_KEY is not set."
    echo "Launchd plist will contain empty key. Set it before running start.sh."
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST_NAME="com.iwe.hindsight.plist"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_NAME"

mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.iwe.hindsight</string>
    <key>WorkingDirectory</key>
    <string>$SCRIPT_DIR</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SCRIPT_DIR/start.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>$HOME/.iwe/hindsight-launchd.out</string>
    <key>StandardErrorPath</key>
    <string>$HOME/.iwe/hindsight-launchd.err</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>OPENAI_API_KEY</key>
        <string>${OPENAI_API_KEY:-}</string>
    </dict>
</dict>
</plist>
EOF

launchctl load "$PLIST_PATH" 2>/dev/null || true

echo "Installed: $PLIST_PATH"
echo "Hindsight will start automatically on next login."
echo "To start now: launchctl start com.iwe.hindsight"
echo "To unload: launchctl unload $PLIST_PATH"
