#!/bin/bash
# migrate-initial-marker.sh — добавить skeleton-marker IWE-INITIAL-NEEDED в Strategy.md
# для существующих пользователей (clone до 0.28.5).
#
# Сценарий: old clone → user делает update до 0.28.5 → у него уже есть
# Strategy.md без маркера. Skill /strategy-session уйдёт в weekly mode,
# initial flow не сработает.
#
# Скрипт безопасен:
#   1. Если маркер уже есть — выходит без изменений.
#   2. Если Strategy.md содержит seed-сигнатуру (placeholder dates `YYYY-MM-DD`
#      в frontmatter) — автоматически добавляет маркер.
#   3. Если контент выглядит реальным (заполненные даты, кастомные блоки) —
#      спрашивает confirmation; по умолчанию skip.
#
# Usage:
#   bash migrate-initial-marker.sh                           # auto-detect путь
#   bash migrate-initial-marker.sh /path/to/Strategy.md      # явный путь
#   bash migrate-initial-marker.sh --force /path/to/file     # без confirmation

set -euo pipefail

MARKER='<!-- IWE-INITIAL-NEEDED: маркер из seed-шаблона. Удаляется после первой стратегической сессии (skill `/strategy-session` initial flow §2.5). Если маркер на месте — Strategy.md содержит только заготовку, не реальную стратегию пользователя. -->'

FORCE=0
TARGET=""
while [ $# -gt 0 ]; do
    case "$1" in
        --force) FORCE=1; shift ;;
        -h|--help)
            grep '^#' "$0" | head -25
            exit 0 ;;
        --*)
            echo "Unknown flag: $1" >&2
            echo "Usage: $0 [--force] [/path/to/Strategy.md]" >&2
            exit 1 ;;
        *) TARGET="$1"; shift ;;
    esac
done

# Auto-detect путь, если не передан
if [ -z "$TARGET" ]; then
    # Try .exocortex.env
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    ENV_FILE="$(dirname "$SCRIPT_DIR")/.exocortex.env"
    if [ -f "$ENV_FILE" ]; then
        WS=$(grep -E '^WORKSPACE_DIR=' "$ENV_FILE" | head -1 | cut -d= -f2-)
        GOV=$(grep -E '^GOVERNANCE_REPO=' "$ENV_FILE" | head -1 | cut -d= -f2-)
        if [ -n "$WS" ] && [ -n "$GOV" ]; then
            TARGET="$WS/$GOV/docs/Strategy.md"
        fi
    fi
    if [ -z "$TARGET" ]; then
        echo "Usage: $0 [--force] /path/to/Strategy.md"
        echo "Auto-detect не сработал (нет .exocortex.env или WORKSPACE_DIR/GOVERNANCE_REPO)."
        exit 1
    fi
fi

if [ ! -f "$TARGET" ]; then
    echo "Strategy.md не найден: $TARGET"
    exit 1
fi

if [ ! -w "$TARGET" ]; then
    echo "Ошибка: $TARGET — read-only (нет прав на запись)." >&2
    echo "Снимите защиту: chmod u+w \"$TARGET\"" >&2
    exit 1
fi

# Уже есть маркер?
if grep -qF 'IWE-INITIAL-NEEDED' "$TARGET"; then
    echo "✓ Маркер уже присутствует в $TARGET — миграция не нужна."
    exit 0
fi

# Эвристика: seed-сигнатура (placeholder dates в frontmatter)
IS_SEED=0
if grep -qE '^created: YYYY-MM-DD$' "$TARGET" || \
   grep -qE '^updated: YYYY-MM-DD$' "$TARGET" || \
   grep -qE '\{месяц\} \{\{YEAR\}\}' "$TARGET"; then
    IS_SEED=1
fi

if [ "$IS_SEED" -eq 1 ]; then
    echo "Обнаружен seed-скелет (placeholder dates) — добавляю маркер автоматически."
elif [ "$FORCE" -eq 0 ]; then
    echo "⚠ Strategy.md выглядит как реально заполненный (нет seed-сигнатур)."
    echo "  Если initial-сессия уже была — маркер не нужен (skill пойдёт в weekly)."
    echo "  Если initial-сессия НЕ проводилась и вы хотите её запустить — добавьте --force."
    exit 0
fi

# Backup
BACKUP="${TARGET}.pre-marker.$(date +%Y%m%d-%H%M%S)"
cp "$TARGET" "$BACKUP"
echo "Backup: $BACKUP"

# Вставить маркер после frontmatter (после второго `---`).
# Если frontmatter нет ИЛИ broken (только один `---`) — вставить в начало.
TMP=$(mktemp)
INSERTED_AFTER_FM=0
if head -1 "$TARGET" | grep -q '^---$'; then
    # frontmatter есть, ищем второй ---
    if [ "$(grep -c '^---$' "$TARGET")" -ge 2 ]; then
        awk -v marker="$MARKER" '
            BEGIN { fm_count = 0; inserted = 0 }
            /^---$/ { fm_count++; print; if (fm_count == 2 && !inserted) { print ""; print marker; inserted = 1 } ; next }
            { print }
        ' "$TARGET" > "$TMP"
        INSERTED_AFTER_FM=1
    fi
fi

if [ "$INSERTED_AFTER_FM" -eq 0 ]; then
    # Нет frontmatter ИЛИ broken (один ---) — вставить в самое начало.
    {
        echo "$MARKER"
        echo ""
        cat "$TARGET"
    } > "$TMP"
fi

# Sanity check: TMP не должен быть пустым (защита от silent corruption)
if [ ! -s "$TMP" ]; then
    echo "Ошибка: миграция произвела пустой результат — оригинал не тронут." >&2
    rm -f "$TMP"
    exit 1
fi

mv "$TMP" "$TARGET"
echo "✓ Маркер добавлен в $TARGET"
echo ""
echo "Теперь запустите /strategy-session — skill определит режим initial."
