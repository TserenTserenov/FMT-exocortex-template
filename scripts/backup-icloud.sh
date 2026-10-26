#!/bin/bash
# routing: utility  deterministic=true
# see DP.SC.159, DP.ROLE.059
# backup-icloud.sh — Бэкап IWE в архив (без .git, node_modules, .venv)
# Использование: ./scripts/backup-icloud.sh
# Хранит последние 4 архива, удаляет старые.
# Цель: backup_dir из params.yaml (любая ОС) либо iCloud Drive на macOS по умолчанию.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.claude/lib/iwe-env-bootstrap.sh" || exit 1

IWE_DIR="${WORKSPACE_DIR}"
BACKUP_DIR="$IWE_ICLOUD_BACKUP_DIR"
DATE=$(date +%Y%m%d-%H%M)
ARCHIVE="IWE-backup-${DATE}.tar.gz"
MAX_BACKUPS=4

# issue #1349: the target is either the macOS iCloud default or backup_dir from
# params.yaml, which the bootstrap honours on any OS — so the backup runs on any
# OS once a target is set.
if [ -z "$BACKUP_DIR" ]; then
    echo "❌ Цель бэкапа не задана: iCloud Drive по умолчанию есть только на macOS (текущая платформа: $IWE_OS)." >&2
    echo "   Задайте backup_dir в params.yaml или отключите встроенный бэкап: backup_enabled: false." >&2
    exit 1
fi

# The iCloud mount check only applies to a target inside iCloud Drive; a
# backup_dir elsewhere is an ordinary directory (compared on normalised paths).
if iwe_path_inside "$BACKUP_DIR" "$IWE_ICLOUD_ROOT" && [ ! -d "$IWE_ICLOUD_ROOT" ]; then
    echo "❌ iCloud Drive не найден ($IWE_ICLOUD_ROOT). Убедитесь что iCloud Drive включён в System Settings." >&2
    exit 1
fi

if ! mkdir -p "$BACKUP_DIR"; then
    echo "❌ Не удалось создать папку бэкапа: $BACKUP_DIR — архив не создан." >&2
    exit 1
fi

# A backup_dir inside the workspace would otherwise archive its own archives
# (and GNU tar exits 1 on the growing file): exclude it from the snapshot.
SELF_EXCLUDE=()
if iwe_path_inside "$BACKUP_DIR" "$IWE_DIR"; then
    BACKUP_REL="$(iwe_normalize_path "$BACKUP_DIR")"
    BACKUP_REL="${BACKUP_REL#"$(iwe_normalize_path "$IWE_DIR")"/}"
    SELF_EXCLUDE=(--exclude="$(basename "$IWE_DIR")/$BACKUP_REL")
fi

echo "📦 Создаю архив $ARCHIVE..."
if ! tar ${SELF_EXCLUDE[@]+"${SELF_EXCLUDE[@]}"} --exclude='.git' \
    --exclude='node_modules' \
    --exclude='.venv' \
    --exclude='__pycache__' \
    --exclude='_backups' \
    --exclude='.DS_Store' \
    --exclude='.claude/worktrees' \
    --exclude='.iwe-runtime/isolated-worktrees' \
    -czf "$BACKUP_DIR/$ARCHIVE" \
    -C "$(dirname "$IWE_DIR")" "$(basename "$IWE_DIR")/"; then
    # Drop the partial file so the freshness check does not count it as a backup.
    rm -f "$BACKUP_DIR/$ARCHIVE"
    echo "❌ Не удалось создать архив в $BACKUP_DIR — бэкап не выполнен." >&2
    exit 1
fi

SIZE=$(du -h "$BACKUP_DIR/$ARCHIVE" | cut -f1)
echo "✅ Архив создан: $BACKUP_DIR/$ARCHIVE ($SIZE)"

# Удалить старые архивы (оставить последние MAX_BACKUPS)
cd "$BACKUP_DIR"
TOTAL=$(ls -1 IWE-backup-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')
if [ "$TOTAL" -gt "$MAX_BACKUPS" ]; then
    TO_DELETE=$((TOTAL - MAX_BACKUPS))
    ls -1t IWE-backup-*.tar.gz | tail -n "$TO_DELETE" | while read old; do
        echo "🗑  Удаляю старый: $old"
        rm "$old"
    done
fi

echo "📊 Текущие бэкапы в $BACKUP_DIR:"
ls -lh IWE-backup-*.tar.gz 2>/dev/null
