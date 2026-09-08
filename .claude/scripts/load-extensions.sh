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
# Output: абсолютные пути к extension-файлам, по одному на строку, sorted.
# Exit: 0 — есть extensions; 1 — совпадений нет; 2 — неверный вызов;
#       3 — loader/workspace/extension повреждён или недоступен.
#
# Реализует contract из extensions/README.md:
#   "Suffix extensions (e.g. day-close.after.health.md, day-close.after.linear.md)
#    загружаются в алфавитном порядке."

set -euo pipefail

PROTOCOL="${1:-}"
HOOK="${2:-}"

if [ -z "$PROTOCOL" ] || [ -z "$HOOK" ]; then
    echo "Usage: load-extensions.sh <protocol> <hook>" >&2
    echo "Example: load-extensions.sh day-close after" >&2
    exit 2
fi
case "$PROTOCOL" in
    *[!a-z0-9-]*)
        echo "[extension_loader_error] protocol/hook contains unsupported characters" >&2
        exit 2
        ;;
esac
case "$HOOK" in
    *[!a-z0-9-]*)
        echo "[extension_loader_error] protocol/hook contains unsupported characters" >&2
        exit 2
        ;;
esac

# Resolve workspace — пробуем несколько переменных, проверяя существование директории.
# Фикс bug-2026-05-14: ранее IWE_WORKSPACE мог указывать на несуществующую tmp-директорию
# (остаток smoke-test), и fallback не срабатывал из-за лишнего dirname.
resolve_workspace() {
    local candidates=("${IWE_WORKSPACE:-}" "${WORKSPACE_DIR:-}" "${IWE_ROOT:-}" "${IWE:-}")
    for c in "${candidates[@]}"; do
        [ -n "$c" ] || continue
        # A stale nonexistent candidate may fall through. An existing explicit
        # root is authoritative: missing/unreadable extensions/ is corruption,
        # not permission to load a different workspace through fallback.
        if [ -e "$c" ] || [ -L "$c" ]; then
            echo "$c"
            return 0
        fi
    done

    # Fallback: определяем директорию скрипта через BASH_SOURCE[0] (надёжнее $0).
    local script_source="${BASH_SOURCE[0]:-$0}"
    local script_dir
    script_dir="$(cd "$(dirname "$script_source")" && pwd)"
    # script_dir = .../IWE/.claude/scripts  →  workspace = .../IWE
    local ws
    ws="$(dirname "$(dirname "$script_dir")")"
    [ -d "$ws/extensions" ] && { echo "$ws"; return 0; }

    return 1
}

if ! WORKSPACE="$(resolve_workspace)"; then
    echo "[extension_loader_error] workspace with extensions/ was not found" >&2
    exit 3
fi

EXT_DIR="$WORKSPACE/extensions"
if [ ! -d "$EXT_DIR" ] || [ ! -r "$EXT_DIR" ] || [ ! -x "$EXT_DIR" ]; then
    echo "[extension_loader_error] extensions directory is unavailable: $EXT_DIR" >&2
    exit 3
fi

# Glob pattern: <protocol>.<hook>.md OR <protocol>.<hook>.<suffix>.md
# Examples for protocol=day-close hook=after:
#   day-close.after.md
#   day-close.after.health.md
#   day-close.after.linear.md
if ! FOUND="$(
    find "$EXT_DIR" -mindepth 1 -maxdepth 1 \
        \( -name "${PROTOCOL}.${HOOK}.md" \
        -o -name "${PROTOCOL}.${HOOK}.*.md" \) \
        -print | LC_ALL=C sort
)"; then
    echo "[extension_loader_error] cannot enumerate extensions in: $EXT_DIR" >&2
    exit 3
fi

if [ -z "$FOUND" ]; then
    exit 1
fi

LOADER_DAMAGED=false
while IFS= read -r extension; do
    [ -n "$extension" ] || continue
    if [ -L "$extension" ] && [ ! -e "$extension" ]; then
        echo "[extension_loader_error] extension symlink target is missing: $extension" >&2
        LOADER_DAMAGED=true
        continue
    fi
    if [ ! -f "$extension" ]; then
        echo "[extension_loader_error] extension is not a regular file: $extension" >&2
        LOADER_DAMAGED=true
        continue
    fi
    if [ ! -r "$extension" ]; then
        echo "[extension_loader_error] extension is unreadable: $extension" >&2
        LOADER_DAMAGED=true
        continue
    fi
    # Trusted local extension linter, not a shell sandbox: reject every direct,
    # human-readable re-entry independent of case. The skill contract separately
    # forbids executing commands assembled through eval/decoding/concatenation.
    if [ "$PROTOCOL" = "archgate" ] && \
       { grep -Eqi 'load-extensions\.sh[[:space:]]+['\''"]?archgate['\''"]?[[:space:]]+['\''"]?(before|checks|after)['\''"]?' "$extension" || \
         grep -Eqi '(^|[^[:alnum:]_./-])/archgate([^[:alnum:]_./-]|$)' "$extension"; }; then
        if [ "$HOOK" = "after" ]; then
            echo "[extension_loader_warning] ARCHGATE_EXTENSION: WARN — recursive archgate lifecycle instruction is forbidden: $extension" >&2
        else
            echo "[extension_loader_error] ARCHGATE_EXTENSION: BLOCK — recursive archgate lifecycle instruction is forbidden: $extension" >&2
        fi
        LOADER_DAMAGED=true
        continue
    fi
    printf '%s\n' "$extension"
done <<< "$FOUND"

$LOADER_DAMAGED && exit 3
exit 0
