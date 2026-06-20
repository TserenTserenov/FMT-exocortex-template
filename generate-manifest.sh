#!/bin/bash
# Генерирует update-manifest.json из текущего содержимого репо.
# Запускать перед релизом: bash generate-manifest.sh
#
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="$SCRIPT_DIR/update-manifest.json"

# Версия из CHANGELOG.md (первый ## [X.Y.Z])
VERSION=$(grep -m1 '^\#\# \[[0-9]' "$SCRIPT_DIR/CHANGELOG.md" | sed 's/.*\[\(.*\)\].*/\1/')

if [ -z "$VERSION" ]; then
    echo "ERROR: Не удалось извлечь версию из CHANGELOG.md"
    exit 1
fi

echo "Генерация манифеста v$VERSION..."

# === Исключения, которые НЕ попадают ни в files, ни в excluded_paths ===
SKIP_PATTERNS=(
    ".git/"
    ".github/"
    ".backups/"
    ".DS_Store"
    "generate-manifest.sh"
    "update-manifest.json"
    "seed/"
    "templates/"
)

# === Исключения, которые идут в excluded_paths (dev-only, не раздаются пользователям) ===
EXCLUDED_PATTERNS=(
    "scripts/"
    "scripts/tests/"
    "docs/developer/"
)

EXCLUDED_EXACT=(
    "promotion-status.yaml"
    "AGENTS-agent-blocks.md"
    "docs/BROWSER-CI-TEMPLATE.md"
    "docs/maintaining-skills.md"
    "docs/release-audit-log.md"
)

# === Исключения из files, но не в excluded_paths (пользовательское пространство) ===
FILES_EXCLUDE_PATTERNS=(
    "seed/"
    ".claude/settings.local.json"
)

FILES_EXCLUDE_EXACT=(
    "README.md"
    "README.en.md"
    "CONTRIBUTING.md"
    "LICENSE"
    "params.yaml"
    "extensions/day-close.after.md"
    "extensions/mcp-user.json"
)

# Собираем файлы.
FILES=()
EXCLUDED_PATHS=()
while IFS= read -r rel; do
    # Пропускаем мусор/инструментарий
    skip=false
    for pattern in "${SKIP_PATTERNS[@]}"; do
        case "$rel" in
            $pattern*) skip=true; break ;;
        esac
    done
    [[ "$(basename "$rel")" == ".gitkeep" ]] && skip=true
    $skip && continue

    # setup/ contains install-time scripts; skip all except validate-template.sh,
    # which is referenced by .githooks/pre-commit and update.sh after delivery.
    if [[ "$rel" == setup/* && "$rel" != "setup/validate-template.sh" ]]; then
        continue
    fi

    # Проверяем excluded_paths (dev-only)
    is_excluded=false
    for pattern in "${EXCLUDED_PATTERNS[@]}"; do
        case "$rel" in
            $pattern*) is_excluded=true; break ;;
        esac
    done
    for exact in "${EXCLUDED_EXACT[@]}"; do
        [ "$rel" = "$exact" ] && { is_excluded=true; break; }
    done

    if $is_excluded; then
        EXCLUDED_PATHS+=("$rel")
        continue
    fi

    # Проверяем files-исключения (пользовательское пространство)
    is_files_exclude=false
    for pattern in "${FILES_EXCLUDE_PATTERNS[@]}"; do
        case "$rel" in
            $pattern*) is_files_exclude=true; break ;;
        esac
    done
    for exact in "${FILES_EXCLUDE_EXACT[@]}"; do
        [ "$rel" = "$exact" ] && { is_files_exclude=true; break; }
    done

    $is_files_exclude && continue
    FILES+=("$rel")
done < <(git -C "$SCRIPT_DIR" ls-files | LC_ALL=C sort)

# Читаем существующий манифест для deprecated_files (ручное управление)
DEPRECATED_JSON="[]"
if [ -f "$MANIFEST" ]; then
    DEPRECATED_JSON=$(python3 -c "
import json
with open('$MANIFEST') as f:
    data = json.load(f)
print(json.dumps(data.get('deprecated_files', []), ensure_ascii=False))
")
fi

TMPDIR=$(mktemp -d)
# Через printf: построчная запись без bash-array-interpolation внутри строки
printf '%s\n' "${FILES[@]}" > "$TMPDIR/files.txt"
printf '%s\n' "${EXCLUDED_PATHS[@]}" > "$TMPDIR/excluded.txt"

# Генерируем JSON
python3 -c "
import json

files = [line.strip() for line in open('$TMPDIR/files.txt') if line.strip()]
excluded = [line.strip() for line in open('$TMPDIR/excluded.txt') if line.strip()]

data = {
    'version': '$VERSION',
    'description': 'Манифест платформенных файлов FMT-exocortex-template. Используется update.sh для доставки обновлений.',
    'files': [{'path': p} for p in files],
    'excluded_paths': excluded,
    'deprecated_files': json.loads('''$DEPRECATED_JSON'''),
}

# Убираем пустые массивы
if not data['excluded_paths']:
    del data['excluded_paths']
if not data['deprecated_files']:
    del data['deprecated_files']

with open('$MANIFEST', 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\n')
"

rm -rf "$TMPDIR"

echo "Готово: $MANIFEST"
echo "  Версия: $VERSION"
echo "  Файлов: ${#FILES[@]}"
echo "  Исключённых (excluded_paths): ${#EXCLUDED_PATHS[@]}"
echo ""
echo "Проверьте diff и закоммитьте:"
echo "  git diff update-manifest.json"
