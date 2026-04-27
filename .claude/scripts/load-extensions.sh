#!/bin/bash
# load-extensions.sh — unified loader для suffix extensions (R4.4 fix, WP-273 Этап 2).
#
# Раньше каждый skill/loader читал точное имя файла (`extensions/day-close.after.md`,
# `extensions/protocol-close.checks.md`). Документация (extensions/README.md) обещает
# wildcard suffix loading (`day-close.after.health.md`, `day-close.after.linear.md`),
# но кода под это нет. Этот helper закрывает контракт: возвращает sorted list файлов
# по паттерну `<protocol>.<hook>*.md`.
#
# Usage:
#   bash load-extensions.sh <protocol> <hook>
#   bash load-extensions.sh day-close after
#   bash load-extensions.sh protocol-close checks
#
# Output: пути относительно $IWE_WORKSPACE/extensions/, по одному на строку, sorted.
# Exit: 0 — есть extensions; 1 — нет (skill пропускает шаг).
#
# Реализует contract из extensions/README.md:
#   "Suffix extensions (e.g. day-close.after.health.md, day-close.after.linear.md)
#    загружаются в алфавитном порядке."

set -eu

PROTOCOL="${1:-}"
HOOK="${2:-}"

if [ -z "$PROTOCOL" ] || [ -z "$HOOK" ]; then
    echo "Usage: load-extensions.sh <protocol> <hook>" >&2
    echo "Example: load-extensions.sh day-close after" >&2
    exit 2
fi

# Resolve workspace
WORKSPACE="${IWE_WORKSPACE:-${WORKSPACE_DIR:-}}"
if [ -z "$WORKSPACE" ]; then
    # Fallback: parent of script's grandparent (FMT-exocortex-template/.claude/scripts/)
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    WORKSPACE="$(dirname "$(dirname "$(dirname "$SCRIPT_DIR")")")"
fi

EXT_DIR="$WORKSPACE/extensions"
[ -d "$EXT_DIR" ] || { exit 1; }

# Glob pattern: <protocol>.<hook>.md OR <protocol>.<hook>.<suffix>.md
# Examples for protocol=day-close hook=after:
#   day-close.after.md
#   day-close.after.health.md
#   day-close.after.linear.md
FOUND=$(find "$EXT_DIR" -maxdepth 1 -type f -name "${PROTOCOL}.${HOOK}.md" -o -name "${PROTOCOL}.${HOOK}.*.md" 2>/dev/null | sort)

if [ -z "$FOUND" ]; then
    exit 1
fi

echo "$FOUND"
exit 0
