#!/bin/bash
# Install Strategist Agent launchd jobs
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCHD_DIR="$SCRIPT_DIR/scripts/launchd"
TARGET_DIR="$HOME/Library/LaunchAgents"

echo "Installing Strategist Agent launchd jobs..."

# Unload old agents if present
launchctl unload "$TARGET_DIR/com.strategist.morning.plist" 2>/dev/null || true
launchctl unload "$TARGET_DIR/com.strategist.weekreview.plist" 2>/dev/null || true

# Copy new plist files
cp "$LAUNCHD_DIR/com.strategist.morning.plist" "$TARGET_DIR/"
cp "$LAUNCHD_DIR/com.strategist.weekreview.plist" "$TARGET_DIR/"

# Make script executable
chmod +x "$SCRIPT_DIR/scripts/strategist.sh"

# Load agents
launchctl load "$TARGET_DIR/com.strategist.morning.plist"
launchctl load "$TARGET_DIR/com.strategist.weekreview.plist"

echo "Done. Agents loaded:"
launchctl list | grep strategist
