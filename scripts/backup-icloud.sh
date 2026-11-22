#!/bin/bash
# routing: utility  deterministic=true
# see DP.SC.159, DP.ROLE.059
# backup-icloud.sh — Backup IWE to iCloud Drive (excluding .git, node_modules, .venv)
# Usage: ./scripts/backup-icloud.sh
# Keeps the last 4 archives, removes older ones.
# Platform: macOS with iCloud Drive.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.claude/lib/iwe-env-bootstrap.sh" || exit 1

IWE_DIR="${WORKSPACE_DIR}"
ICLOUD_DIR="$IWE_ICLOUD_BACKUP_DIR"
DATE=$(date +%Y%m%d-%H%M)
ARCHIVE="IWE-backup-${DATE}.tar.gz"
MAX_BACKUPS=4

# Platform and iCloud check iCloud
if [ "$IWE_OS" != "macos" ] || [ -z "$ICLOUD_DIR" ]; then
    echo "❌ backup-icloud.sh requires macOS with iCloud Drive (current platform: $IWE_OS)."
    exit 1
fi

if [ ! -d "$IWE_ICLOUD_ROOT" ]; then
    echo "❌ iCloud Drive not found ($IWE_ICLOUD_ROOT). Make sure that iCloud Drive is enabled in System Settings."
    exit 1
fi

# Create folder in iCloud if absent
mkdir -p "$ICLOUD_DIR"

echo "📦 Creating archive $ARCHIVE..."
tar --exclude='.git' \
    --exclude='node_modules' \
    --exclude='.venv' \
    --exclude='__pycache__' \
    --exclude='_backups' \
    --exclude='.DS_Store' \
    --exclude='.claude/worktrees' \
    --exclude='.iwe-runtime/isolated-worktrees' \
    -czf "$ICLOUD_DIR/$ARCHIVE" \
    -C "$(dirname "$IWE_DIR")" "$(basename "$IWE_DIR")/"

SIZE=$(du -h "$ICLOUD_DIR/$ARCHIVE" | cut -f1)
echo "✅ Archive created: $ICLOUD_DIR/$ARCHIVE ($SIZE)"

# Delete old archives (keep the most recent MAX_BACKUPS)
cd "$ICLOUD_DIR"
TOTAL=$(ls -1 IWE-backup-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')
if [ "$TOTAL" -gt "$MAX_BACKUPS" ]; then
    TO_DELETE=$((TOTAL - MAX_BACKUPS))
    ls -1t IWE-backup-*.tar.gz | tail -n "$TO_DELETE" | while read old; do
        echo "🗑  Deleting old: $old"
        rm "$old"
    done
fi

echo "📊 Current backups in iCloud:"
ls -lh IWE-backup-*.tar.gz 2>/dev/null
