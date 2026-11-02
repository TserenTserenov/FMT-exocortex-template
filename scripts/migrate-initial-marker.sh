#!/bin/bash
# routing: migration  one-time=true
# see DP.SC.159, DP.ROLE.059
# migrate-initial-marker.sh — add the IWE-INITIAL-NEEDED skeleton marker to Strategy.md
# for existing users (clone before 0.28.5).
#
# Scenario: old clone → the user updates to 0.28.5 → they already have
# Strategy.md without the marker. The /strategy-session skill goes into weekly mode,
# the initial flow does not fire.
#
# The script is safe:
#   1. If the marker is already there — exits without changes.
#   2. If Strategy.md contains a seed signature (placeholder dates `YYYY-MM-DD`
#      in the frontmatter) — adds the marker automatically.
#   3. If the content looks real (filled dates, custom blocks) —
#      asks for confirmation; skip by default.
#
# Usage:
#   bash migrate-initial-marker.sh                           # auto-detect path
#   bash migrate-initial-marker.sh /path/to/Strategy.md      # explicit path
#   bash migrate-initial-marker.sh --force /path/to/file     # without confirmation

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

# Auto-detect the path if not passed
if [ -z "$TARGET" ]; then
    # Try .exocortex.env
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    ENV_FILE="$(dirname "$SCRIPT_DIR")/.exocortex.env"
    if [ -f "$ENV_FILE" ]; then
        WS=$(grep -E '^WORKSPACE_DIR=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
        GOV=$(grep -E '^GOVERNANCE_REPO=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
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

# Is the marker already there?
if grep -qF 'IWE-INITIAL-NEEDED' "$TARGET"; then
    echo "✓ Маркер уже присутствует в $TARGET — миграция не нужна."
    exit 0
fi

# Heuristic: seed signature (placeholder dates in the frontmatter)
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

# Insert the marker after the frontmatter (after the second `---`).
# If there is no frontmatter OR it is broken (only one `---`) — insert at the start.
TMP=$(mktemp)
INSERTED_AFTER_FM=0
if head -1 "$TARGET" | grep -q '^---$'; then
    # frontmatter exists, look for the second ---
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
    # No frontmatter OR broken (one ---) — insert at the very beginning.
    {
        echo "$MARKER"
        echo ""
        cat "$TARGET"
    } > "$TMP"
fi

# Sanity check: TMP must not be empty (protection against silent corruption)
if [ ! -s "$TMP" ]; then
    echo "Ошибка: миграция произвела пустой результат — оригинал не тронут." >&2
    rm -f "$TMP"
    exit 1
fi

mv "$TMP" "$TARGET"
echo "✓ Маркер добавлен в $TARGET"
echo ""
echo "Теперь запустите /strategy-session — skill определит режим initial."
