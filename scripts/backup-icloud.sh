#!/bin/bash
# routing: utility  deterministic=true
# see DP.SC.159, DP.ROLE.059
# backup-icloud.sh — Бэкап IWE в iCloud Drive (без .git, node_modules, .venv)
# Использование: ./scripts/backup-icloud.sh
# Хранит последние 4 архива, удаляет старые.
# Платформа: macOS с iCloud Drive.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../.claude/lib/iwe-env-bootstrap.sh" || exit 1

IWE_DIR="${WORKSPACE_DIR}"
ICLOUD_DIR="$IWE_ICLOUD_BACKUP_DIR"
DATE=$(date +%Y%m%d-%H%M)
ARCHIVE="IWE-backup-${DATE}.tar.gz"
MAX_BACKUPS=4

# Проверка платформы и iCloud
if [ "$IWE_OS" != "macos" ] || [ -z "$ICLOUD_DIR" ]; then
    echo "❌ backup-icloud.sh требует macOS с iCloud Drive (текущая платформа: $IWE_OS)."
    exit 1
fi

if [ ! -d "$IWE_ICLOUD_ROOT" ]; then
    echo "❌ iCloud Drive не найден ($IWE_ICLOUD_ROOT). Убедитесь что iCloud Drive включён в System Settings."
    exit 1
fi

# Создать папку в iCloud если нет
mkdir -p "$ICLOUD_DIR"

echo "📦 Создаю архив $ARCHIVE..."
tar --exclude='.git' \
    --exclude='node_modules' \
    --exclude='.venv' \
    --exclude='__pycache__' \
    --exclude='_backups' \
    --exclude='.DS_Store' \
    -czf "$ICLOUD_DIR/$ARCHIVE" \
    -C "$(dirname "$IWE_DIR")" "$(basename "$IWE_DIR")/"

SIZE=$(du -h "$ICLOUD_DIR/$ARCHIVE" | cut -f1)
echo "✅ Архив создан: $ICLOUD_DIR/$ARCHIVE ($SIZE)"

# Удалить старые архивы (оставить последние MAX_BACKUPS)
cd "$ICLOUD_DIR"
TOTAL=$(ls -1 IWE-backup-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')
if [ "$TOTAL" -gt "$MAX_BACKUPS" ]; then
    TO_DELETE=$((TOTAL - MAX_BACKUPS))
    ls -1t IWE-backup-*.tar.gz | tail -n "$TO_DELETE" | while read old; do
        echo "🗑  Удаляю старый: $old"
        rm "$old"
    done
fi

echo "📊 Текущие бэкапы в iCloud:"
ls -lh IWE-backup-*.tar.gz 2>/dev/null
