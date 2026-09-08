#!/bin/bash
# install-launchd.sh — auto-start Hindsight on macOS login (or systemd --user on Linux)
# Usage: bash install-launchd.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# start.sh sources ~/.iwe/hindsight.env itself (set -a; . "$ENV_FILE"; set +a) —
# the generated unit/plist no longer carries OPENAI_API_KEY in plaintext
# (peer-session 2026-08-03-03-wp149-hindsight-fixes: a world-readable plist
# was found holding the key verbatim). Warn here instead of failing silently
# at next autostart.
ENV_FILE="$HOME/.iwe/hindsight.env"
if [ ! -f "$ENV_FILE" ]; then
    echo "WARNING: $ENV_FILE not found — start.sh will fail at next autostart"
    echo "until it exists with OPENAI_API_KEY=sk-... (chmod 600 recommended)."
elif perm=$(stat -c '%a' "$ENV_FILE" 2>/dev/null || stat -f '%Lp' "$ENV_FILE" 2>/dev/null) \
     && [ "$perm" != "600" ]; then
    echo "WARNING: $ENV_FILE permissions are $perm, not 600 — tighten with:"
    echo "  chmod 600 $ENV_FILE"
fi

# launchd/systemd --user give the launch agent a minimal PATH that skips
# wherever Docker Desktop actually installed its CLI — the install location
# varies a lot across machines (Apple Silicon vs Intel Homebrew, ~/.docker/bin,
# Nix profiles, rootless installs, ...). Resolve THIS install's real docker
# location instead of guessing a fixed list: a hardcoded PATH fixes one
# machine and silently drifts on every other.
DOCKER_BIN="$(command -v docker || true)"
BASE_PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
if [ -z "$DOCKER_BIN" ]; then
    echo "WARNING: docker not found in PATH right now — autostart PATH will fall"
    echo "back to a generic list; if that doesn't cover your docker install, re-run"
    echo "this script after 'docker' resolves in your shell."
    RESOLVED_PATH="$BASE_PATH"
else
    DOCKER_DIR="$(dirname "$DOCKER_BIN")"
    case ":$BASE_PATH:" in
        *":$DOCKER_DIR:"*) RESOLVED_PATH="$BASE_PATH" ;;
        *) RESOLVED_PATH="$DOCKER_DIR:$BASE_PATH" ;;
    esac
fi

# WP-5 Ubuntu-audit факт #4: this used to write a macOS plist unconditionally
# on any OS, then `launchctl load ... || true` swallowed the "command not
# found" (launchctl doesn't exist on Linux) and printed "Installed" anyway —
# a false success with no autostart actually configured.
if [ "$(uname -s)" = "Linux" ]; then
    UNIT_DIR="$HOME/.config/systemd/user"
    mkdir -p "$UNIT_DIR"
    cat > "$UNIT_DIR/iwe-hindsight.service" <<EOF
[Unit]
Description=IWE Hindsight (docker compose up -d)
[Service]
Type=oneshot
WorkingDirectory=$SCRIPT_DIR
Environment=PATH=$RESOLVED_PATH
ExecStart=/bin/bash $SCRIPT_DIR/start.sh
RemainAfterExit=yes
[Install]
WantedBy=default.target
EOF
    chmod 600 "$UNIT_DIR/iwe-hindsight.service"
    systemctl --user daemon-reload
    systemctl --user enable iwe-hindsight.service
    echo "Installed: $UNIT_DIR/iwe-hindsight.service"
    echo "Hindsight will start automatically on next login (systemd --user)."
    echo "To start now: systemctl --user start iwe-hindsight.service"
    echo "To disable: systemctl --user disable --now iwe-hindsight.service"
    exit 0
fi

if ! command -v launchctl >/dev/null 2>&1; then
    echo "ERROR: neither launchctl (macOS) nor a recognized Linux systemd --user setup found." >&2
    echo "Start Hindsight manually: bash $SCRIPT_DIR/start.sh" >&2
    exit 1
fi

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
        <key>PATH</key>
        <string>$RESOLVED_PATH</string>
    </dict>
</dict>
</plist>
EOF

chmod 600 "$PLIST_PATH"
launchctl load "$PLIST_PATH" 2>/dev/null || true

echo "Installed: $PLIST_PATH"
echo "Hindsight will start automatically on next login."
echo "To start now: launchctl start com.iwe.hindsight"
echo "To unload: launchctl unload $PLIST_PATH"
