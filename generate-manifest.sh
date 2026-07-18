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
    "update-manifest.local.json"
    "seed/"
    "templates/"
)

# === Исключения, которые идут в excluded_paths (dev-only, не раздаются пользователям) ===
# issue #247 (корень #246): раньше здесь стоял общий "scripts/" — весь каталог
# считался dev-only, и update.sh никогда не доставлял ни один из 92 файлов
# пользователям, вопреки docs/DATA-POLICY.md. Полный анализ графа ссылок
# (peer-session 2026-07-11-11) показал, что это неверно: большинство скриптов
# зовутся из доставляемых skills/hooks (иногда транзитивно — day-open-pipeline.sh
# запускается через launchd, а не напрямую из skill, и это не ловится grep-ом).
# Решение по итогам ЭМОГССБ: default = доставлять scripts/ целиком; explicit
# exclude только для скриптов, у которых НЕТ ни одной ссылки из доставляемого
# артефакта (проверено — только .github/workflows/* или ничего). Ошибка в эту
# сторону (лишний dev-скрипт доставлен) безвредна; обратная (нужный скрипт не
# доставлен) — воспроизводит #246. EXCLUDED_SCRIPTS ниже — короткий список,
# не растущий с каждым новым skill (в отличие от прежнего allow-list на *доставку*).
EXCLUDED_PATTERNS=(
    "scripts/tests/"
    "docs/developer/"
)

EXCLUDED_SCRIPTS=(
    "scripts/check-component-parity.sh"        # CI-only: validate-template.yml + verify-template-integrity.sh
    "scripts/check-manifest-rename-coverage.py" # CI-only: validate-template.yml
    "scripts/verify-template-integrity.sh"      # локальное зеркало CI-гейта для контрибьюторов шаблона, не для пользователей
    "scripts/translate.py"                      # CI-only: translate-sync.yml (синхронизация EN-доков автором шаблона)
    "scripts/delivery_checks.py"                # CI-only: translate-sync.yml
    "scripts/audit-ad-hoc-roles.py"             # нет ссылок ни из одного доставляемого артефакта
    "scripts/agent-dashboard.py"                # только scripts/tests/, нет ссылок из доставляемого
    "scripts/generate-helper-catalog.py"        # нет ссылок из доставляемого
    "scripts/iwe-trace.py"                      # нет ссылок из доставляемого
    "scripts/session-dispatcher-tsekh.py"       # нет ссылок из доставляемого
    "scripts/iwe-catalog-list.py"               # ссылается только docs/maintaining-skills.md (сам dev-only)
    "scripts/guide-kit-sync.sh"                 # author-only: заносит релиз iwesys/guide-kit в дерево шаблона (WP-483 Ф4)
)

EXCLUDED_EXACT=(
    "promotion-status.yaml"
    "scripts/guide-kit-sync-state.yaml"         # provenance vendored-копии guide-kit/ — нужен CI drift-check, не пользователям
    "AGENTS-agent-blocks.md"
    "docs/BROWSER-CI-TEMPLATE.md"
    "docs/maintaining-skills.md"
    "docs/release-audit-log.md"
    "${EXCLUDED_SCRIPTS[@]}"
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
    "CODE_OF_CONDUCT.md"
    "SECURITY.md"
    "PRIVACY.md"
    "CODEOWNERS"
    "CITATION.cff"
    "params.yaml"
    "extensions/day-close.after.md"
    "extensions/mcp-user.json"
)

# Codex runtime is deliberately not excluded: AGENTS.md, .agents/skills/,
# .codex/ and their scripts are L1 platform assets and must reach existing
# installations through update.sh. User-owned .codex config is protected by
# update.sh's seed-only policy rather than omitted from the manifest.

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
# LC_ALL=C pins byte-order collation so the manifest is reproducible across
# contributor locales (CI sorts under C.UTF-8). Without it, a UTF-8 locale
# reorders entries like README.md / sync_feedback_to_memory.py and breaks the
# manifest-completeness check (issue #207).
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
