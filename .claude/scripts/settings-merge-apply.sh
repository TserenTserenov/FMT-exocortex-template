#!/bin/bash
# settings-merge-apply.sh — stage B of the settings.json merge (WP-7 F71,
# peer-session 2026-08-14-05 consensus): apply the merged candidate to the real
# settings.json. Explicitly flag-gated by the caller (update.sh
# --apply-settings-merge) — never runs by default.
#
# Safety order: build candidate → backup current → replace → post-validate →
# restore backup on any failure. The workspace file is either untouched or
# fully replaced by a parse-validated merge; никогда не остаётся в рваном виде.
#
# Usage: settings-merge-apply.sh <template_settings> <workspace_settings> [py_bin]
# Exit: 0 = applied; 1 = failure, workspace settings.json untouched/restored.
set -uo pipefail

if [ $# -lt 2 ]; then
    echo "usage: settings-merge-apply.sh <template_settings> <workspace_settings> [py_bin]" >&2
    exit 1
fi
TEMPLATE="$1"
WORKSPACE="$2"
PY_BIN="${3:-python3}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MERGER="$SCRIPT_DIR/settings-merge-preview.py"
if [ ! -f "$MERGER" ]; then
    echo "settings-merge-apply: не найден $MERGER — применение отменено" >&2
    exit 1
fi
if [ ! -f "$WORKSPACE" ]; then
    echo "settings-merge-apply: нет рабочего файла $WORKSPACE — применять нечего (первичный посев делает update.sh)" >&2
    exit 1
fi

WS_DIR="$(cd "$(dirname "$WORKSPACE")" && pwd)"
PREVIEW="$WS_DIR/settings.merged.preview.json"

REPORT=$("$PY_BIN" "$MERGER" "$TEMPLATE" "$WORKSPACE" "$PREVIEW") || {
    echo "settings-merge-apply: кандидат слияния не построен (битый JSON во входе) — settings.json не тронут" >&2
    exit 1
}

BACKUP_ROOT="$(dirname "$WS_DIR")/.backups/settings-merge"
TS=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP_FILE="$BACKUP_ROOT/settings.json.$TS"
mkdir -p "$BACKUP_ROOT" && cp "$WORKSPACE" "$BACKUP_FILE" || {
    echo "settings-merge-apply: не удалось сохранить бэкап $BACKUP_FILE — применение отменено, settings.json не тронут" >&2
    exit 1
}

cp "$PREVIEW" "$WORKSPACE" || {
    echo "settings-merge-apply: запись не удалась — восстанавливаю из бэкапа" >&2
    cp "$BACKUP_FILE" "$WORKSPACE"
    exit 1
}

if ! "$PY_BIN" -c 'import json, sys; json.load(open(sys.argv[1]))' "$WORKSPACE" 2>/dev/null; then
    echo "settings-merge-apply: применённый файл не парсится — восстанавливаю из бэкапа" >&2
    cp "$BACKUP_FILE" "$WORKSPACE"
    exit 1
fi

rm -f "$PREVIEW"
printf '%s\n' "$REPORT"
echo "applied: $WORKSPACE (backup: $BACKUP_FILE)"
exit 0
