#!/bin/bash
# build-runtime.sh — Generated runtime architecture (WP-273 Этап 2 Ф18)
#
# Idempotent rebuild $WORKSPACE_DIR/.iwe-runtime/ from FMT-exocortex-template + .exocortex.env.
# Аналог Nix derivation: одни и те же входы → identical output.
#
# Source-of-truth: настоящий FMT (immutable, regenerable).
# Output: $WORKSPACE_DIR/.iwe-runtime/ (regenerable, не в git).
# Trigger: setup.sh, update.sh, ручной запуск.
#
# Usage:
#   bash build-runtime.sh                   # rebuild + write
#   bash build-runtime.sh --dry-run         # показать что будет создано, без записи
#   bash build-runtime.sh --diff            # diff между текущим runtime и тем, что был бы создан
#   bash build-runtime.sh --workspace PATH  # явно указать workspace (default: parent of FMT)
#   bash build-runtime.sh --env-file PATH   # явно указать .exocortex.env
#   bash build-runtime.sh --quiet           # минимальный вывод (для setup/update.sh)
#
# Exit codes:
#   0 — успех (или dry-run/diff без блокеров)
#   1 — некорректные аргументы
#   2 — отсутствует .exocortex.env
#   3 — overlay-реестр не найден
#   4 — отсутствуют source-файлы из реестра
#   5 — drift detected (только в --diff режиме при найденных расхождениях)
#
# WP-273 Этап 2 Ф18. ArchGate v2 → F (Generated runtime).

set -eu

# === Cross-platform sed -i ===
if sed --version >/dev/null 2>&1; then
    sed_inplace() { sed -i "$@"; }
else
    sed_inplace() { sed -i '' "$@"; }
fi

# === Cross-platform hash ===
hash_file() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        sha256sum "$1" | cut -d' ' -f1
    fi
}

hash_dir() {
    local dir="$1"
    [ -d "$dir" ] || { echo "EMPTY"; return; }
    if command -v shasum >/dev/null 2>&1; then
        find "$dir" -type f -not -name '.build-hash' | sort | xargs shasum -a 256 2>/dev/null | shasum -a 256 | cut -d' ' -f1
    else
        find "$dir" -type f -not -name '.build-hash' | sort | xargs sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1
    fi
}

# === Detect directories ===
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="$(dirname "$SCRIPT_DIR")"  # FMT-exocortex-template/
DEFAULT_WORKSPACE="$(dirname "$TEMPLATE_DIR")"  # parent of FMT

WORKSPACE_DIR=""
ENV_FILE=""
DRY_RUN=false
DIFF_MODE=false
QUIET=false

# === Parse arguments ===
while [ $# -gt 0 ]; do
    case "$1" in
        --workspace)
            WORKSPACE_DIR="$2"
            shift 2
            ;;
        --env-file)
            ENV_FILE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --diff)
            DIFF_MODE=true
            shift
            ;;
        --quiet|-q)
            QUIET=true
            shift
            ;;
        --help|-h)
            grep '^#' "$0" | head -28
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            echo "Usage: bash build-runtime.sh [--dry-run|--diff] [--workspace PATH] [--env-file PATH] [--quiet]" >&2
            exit 1
            ;;
    esac
done

# === Resolve workspace + env-file ===
WORKSPACE_DIR="${WORKSPACE_DIR:-$DEFAULT_WORKSPACE}"
WORKSPACE_DIR="${WORKSPACE_DIR/#\~/$HOME}"

if [ -z "$ENV_FILE" ]; then
    # Поиск .exocortex.env: workspace → template (для миграции с старой раскладки)
    if [ -f "$WORKSPACE_DIR/.exocortex.env" ]; then
        ENV_FILE="$WORKSPACE_DIR/.exocortex.env"
    elif [ -f "$TEMPLATE_DIR/.exocortex.env" ]; then
        ENV_FILE="$TEMPLATE_DIR/.exocortex.env"
        $QUIET || echo "  ⚠ .exocortex.env найден в FMT (legacy location). Будет мигрирован в \$WORKSPACE_DIR/ при следующем setup."
    fi
fi

if [ -z "$ENV_FILE" ] || [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: .exocortex.env не найден. Искал:" >&2
    echo "  - $WORKSPACE_DIR/.exocortex.env" >&2
    echo "  - $TEMPLATE_DIR/.exocortex.env" >&2
    echo "Запустите setup.sh для первичной конфигурации." >&2
    exit 2
fi

OVERLAY_FILE="$TEMPLATE_DIR/.claude/runtime-overlay.yaml"
if [ ! -f "$OVERLAY_FILE" ]; then
    echo "ERROR: Overlay-реестр не найден: $OVERLAY_FILE" >&2
    exit 3
fi

RUNTIME_DIR="$WORKSPACE_DIR/.iwe-runtime"

if ! $QUIET; then
    echo "=== build-runtime ==="
    echo "  Template: $TEMPLATE_DIR"
    echo "  Workspace: $WORKSPACE_DIR"
    echo "  Env file: $ENV_FILE"
    echo "  Runtime: $RUNTIME_DIR"
    [ "$DRY_RUN" = true ] && echo "  Mode: DRY-RUN (no writes)"
    [ "$DIFF_MODE" = true ] && echo "  Mode: DIFF (compare existing vs new)"
    echo ""
fi

# === Load .exocortex.env ===
# Safe parse: только KEY=VALUE, никакого eval/source.
# Bash 3.2-compatible: используем функцию env_get вместо associative array.
env_get() {
    grep "^$1=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d'=' -f2-
}

# === Parse overlay-реестр ===
# Минимальный YAML-парсер: читает списки substituted/copied_to_workspace.
# Ожидаемый формат: ключ в начале строки + двоеточие, далее `  - path` для каждого файла.
parse_list() {
    local section="$1"
    awk -v sect="$section" '
        $0 ~ "^"sect":" { in_section=1; next }
        in_section && /^[a-z_]+:/ { in_section=0 }
        in_section && /^[[:space:]]+-[[:space:]]/ {
            sub(/^[[:space:]]+-[[:space:]]+/, "")
            sub(/[[:space:]]*#.*/, "")
            sub(/[[:space:]]+$/, "")
            if (length($0) > 0) print
        }
    ' "$OVERLAY_FILE"
}

# Bash 3.2-compatible array population (mapfile = bash 4+).
SUBSTITUTED_FILES=()
while IFS= read -r line; do SUBSTITUTED_FILES+=("$line"); done < <(parse_list "substituted")
COPIED_FILES=()
while IFS= read -r line; do COPIED_FILES+=("$line"); done < <(parse_list "copied_to_workspace")
PLACEHOLDERS=()
while IFS= read -r line; do PLACEHOLDERS+=("$line"); done < <(parse_list "placeholders")

if [ "${#SUBSTITUTED_FILES[@]}" -eq 0 ] && [ "${#COPIED_FILES[@]}" -eq 0 ]; then
    echo "ERROR: Overlay-реестр пуст или повреждён: $OVERLAY_FILE" >&2
    exit 3
fi

# === Verify source files exist in FMT ===
MISSING=()
for f in "${SUBSTITUTED_FILES[@]}" "${COPIED_FILES[@]}"; do
    [ -f "$TEMPLATE_DIR/$f" ] || MISSING+=("$f")
done

if [ "${#MISSING[@]}" -gt 0 ]; then
    echo "ERROR: Файлы из overlay-реестра отсутствуют в FMT:" >&2
    printf '  - %s\n' "${MISSING[@]}" >&2
    echo "Возможно: устаревший runtime-overlay.yaml или неполный clone." >&2
    exit 4
fi

# === Build runtime in temp directory (atomic swap on success) ===
if BUILD_DIR=$(mktemp -d 2>/dev/null); then
    :
else
    BUILD_DIR="/tmp/iwe-build-$$"
    mkdir -p "$BUILD_DIR"
fi
trap "rm -rf '$BUILD_DIR'" EXIT

# Hash inputs (FMT files + .exocortex.env) for build-stamp
INPUT_HASH=$(
    {
        for f in "${SUBSTITUTED_FILES[@]}" "${COPIED_FILES[@]}"; do
            hash_file "$TEMPLATE_DIR/$f"
            echo "$f"
        done
        hash_file "$ENV_FILE"
        hash_file "$OVERLAY_FILE"
    } | hash_file /dev/stdin 2>/dev/null || \
    {
        for f in "${SUBSTITUTED_FILES[@]}" "${COPIED_FILES[@]}"; do
            hash_file "$TEMPLATE_DIR/$f"
            echo "$f"
        done
        hash_file "$ENV_FILE"
        hash_file "$OVERLAY_FILE"
    } | (command -v shasum >/dev/null && shasum -a 256 || sha256sum) | cut -d' ' -f1
)

FMT_VERSION=$(grep -m1 '^## \[' "$TEMPLATE_DIR/CHANGELOG.md" | sed 's/.*\[\(.*\)\].*/\1/')

# === Apply substitutions ===
build_substituted_file() {
    local rel="$1"
    local src="$TEMPLATE_DIR/$rel"
    local dst="$BUILD_DIR/runtime/$rel"
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"

    # Build sed script from placeholders + .exocortex.env (env_get).
    local sed_args=()
    local ph val
    for ph in "${PLACEHOLDERS[@]}"; do
        val=$(env_get "$ph")
        sed_args+=(-e "s|{{$ph}}|$val|g")
    done

    if [ ${#sed_args[@]} -gt 0 ]; then
        sed_inplace "${sed_args[@]}" "$dst"
    fi

    # All .sh files must be executable in runtime regardless of source permissions
    case "$dst" in *.sh) chmod +x "$dst" ;; esac

    # Verify no unsubstituted placeholders remain
    if grep -qE '\{\{[A-Z_]+\}\}' "$dst" 2>/dev/null; then
        echo "  ⚠ $rel: остались незаменённые плейсхолдеры:" >&2
        grep -oE '\{\{[A-Z_]+\}\}' "$dst" | sort -u | sed 's/^/      /' >&2
    fi
}

copy_to_workspace_file() {
    local rel="$1"
    local src="$TEMPLATE_DIR/$rel"
    local dst="$BUILD_DIR/workspace/$rel"
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    case "$dst" in *.sh) chmod +x "$dst" ;; esac
}

# Process substituted
for f in "${SUBSTITUTED_FILES[@]}"; do
    build_substituted_file "$f"
done

# Process copied_to_workspace
for f in "${COPIED_FILES[@]}"; do
    copy_to_workspace_file "$f"
done

# === Stamp build hash + version ===
{
    echo "$INPUT_HASH"
    echo ""
    echo "FMT version: $FMT_VERSION"
    echo "Overlay version: $(grep -m1 '^version:' "$OVERLAY_FILE" | sed 's/version:[[:space:]]*//')"
    echo "Built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$BUILD_DIR/runtime/.build-hash"

# === Diff mode ===
if $DIFF_MODE; then
    if [ ! -d "$RUNTIME_DIR" ]; then
        echo "[diff] $RUNTIME_DIR не существует — будет создан с нуля."
        echo "  Substituted: ${#SUBSTITUTED_FILES[@]} файлов"
        echo "  Copied to workspace: ${#COPIED_FILES[@]} файлов"
        exit 0
    fi

    DRIFT_COUNT=0
    for f in "${SUBSTITUTED_FILES[@]}"; do
        existing="$RUNTIME_DIR/$f"
        new="$BUILD_DIR/runtime/$f"
        if [ ! -f "$existing" ]; then
            echo "[diff] NEW: $f"
            DRIFT_COUNT=$((DRIFT_COUNT + 1))
        elif ! cmp -s "$existing" "$new"; then
            echo "[diff] CHANGED: $f"
            diff -u "$existing" "$new" 2>/dev/null | head -20 | sed 's/^/  /'
            DRIFT_COUNT=$((DRIFT_COUNT + 1))
        fi
    done

    if [ "$DRIFT_COUNT" -eq 0 ]; then
        echo "[diff] runtime in sync (0 changes)"
        exit 0
    else
        echo ""
        echo "[diff] $DRIFT_COUNT файлов изменилось бы. Запустите без --diff для применения."
        exit 5
    fi
fi

# === Dry-run mode ===
if $DRY_RUN; then
    echo "[dry-run] Будет создано в $RUNTIME_DIR/:"
    for f in "${SUBSTITUTED_FILES[@]}"; do
        echo "  ~ $f (substituted)"
    done
    echo ""
    echo "[dry-run] Будет скопировано в $WORKSPACE_DIR/:"
    for f in "${COPIED_FILES[@]}"; do
        echo "  + $f"
    done
    echo ""
    echo "[dry-run] Build hash (для drift detection): ${INPUT_HASH:0:16}..."
    echo "[dry-run] Без изменений на диске."
    exit 0
fi

# === Atomic swap: replace runtime + copy workspace files ===
# WP-273 0.29.4 R6.3 fix: flock на $WORKSPACE_DIR/.iwe-runtime.lock — предотвращает
# race window между двумя одновременными build-runtime ИЛИ build-runtime + scheduler.
# scheduler.sh тоже берёт shared lock на этот файл перед чтением runner-путей.
mkdir -p "$WORKSPACE_DIR"
LOCK_FILE="${WORKSPACE_DIR}/.iwe-runtime.lock"

# Используем flock если доступен (Linux всегда; macOS — через util-linux brew, optional)
if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    if ! flock -x -w 30 9; then
        echo "ERROR: build-runtime: не удалось получить exclusive lock на $LOCK_FILE за 30 сек" >&2
        exit 6
    fi
fi

# 1. Replace .iwe-runtime/ atomically (под lock'ом — никто не читает в этот момент)
RUNTIME_OLD="${RUNTIME_DIR}.old.$$"
if [ -d "$RUNTIME_DIR" ]; then
    mv "$RUNTIME_DIR" "$RUNTIME_OLD"
fi

mv "$BUILD_DIR/runtime" "$RUNTIME_DIR"

# Cleanup old runtime
[ -d "$RUNTIME_OLD" ] && rm -rf "$RUNTIME_OLD"

# Lock освобождается автоматически при exit (FD 9 закрывается)

# 2. Copy workspace files (НЕ atomic — это не критично, файлы независимы)
COPIED_COUNT=0
for f in "${COPIED_FILES[@]}"; do
    src="$BUILD_DIR/workspace/$f"
    dst="$WORKSPACE_DIR/$f"
    mkdir -p "$(dirname "$dst")"
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
        : # skip — identical
    else
        cp "$src" "$dst"
        COPIED_COUNT=$((COPIED_COUNT + 1))
    fi
done

if ! $QUIET; then
    echo "✓ runtime: ${#SUBSTITUTED_FILES[@]} файлов в $RUNTIME_DIR/"
    echo "✓ workspace: $COPIED_COUNT файлов обновлено / ${#COPIED_FILES[@]} проверено"
    echo "  Build hash: ${INPUT_HASH:0:16}..."
    echo "  FMT version: $FMT_VERSION"
fi

exit 0
