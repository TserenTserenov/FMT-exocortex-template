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
    # generate-manifest.sh is DELIVERED since WP-529 F6 (Evgenii defect #4,
    # 18.08): the shipped scripts/verify-manifest.sh hard-depends on the
    # repo-root generator, so an update-only install kept a stale copy and
    # the B2 completeness check exited 1 on the user's machine.
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
    "docs/developer/"    # never delivered since the first manifest commit (23b0494, WP-7 MFC4) —
                          # unrelated to the WP-401 Ф6.1 docs/ freeze below, keep excluded
    "sessions/2026-06/"    # WP-401 Ф6.1: archived transcript, not for delivery. NOTE: sessions/00-index.md
                            # stays OUT of this exclusion on purpose — it's a protected seed-once-then-never-
                            # touch file like memory/MEMORY.md (see is_protected_user_file() in update.sh),
                            # not a deprecated artifact. A future "sessions/YYYY-MM/" transcript must get its
                            # own dated exclusion here, not a blanket "sessions/".
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
    "params.yaml.example"
    "extensions/day-close.after.md"
    "extensions/mcp-user.json"
)

# issue #325: .github/ и setup/ are blanket-excluded below (CI-only / install-time),
# but cloud-scheduler is a documented, maintained feature living in both namespaces —
# its workflow and install script never reached users despite fix #188. Explicit
# per-file include, same technique as setup/validate-template.sh below.
GITHUB_EXPLICIT_INCLUDE=(
    ".github/workflows/cloud-scheduler.yml"
    ".github/workflows/notify-security.yml"
    ".github/workflows/notify-update.yml"
    ".github/workflows/post-release-audit.yml"
)
GITHUB_CI_ONLY_EXCLUDE=(
    ".github/workflows/nightly-template-audit.yml"
)
SETUP_EXPLICIT_INCLUDE=(
    "setup/build-runtime.sh"
    "setup/install-iwe-paths.sh"
    "setup/validate-template.sh"
    "setup/optional/setup-cloud-scheduler.sh"   # install-time, but requires one-time delivery — issue #325
    "setup/optional/setup-local-gateway.sh"     # referenced by delivered docs/AGENT-VENDOR-SETUP.md (WP-499 Ф16), same class as #325
)
# WP-7 Ф-script-contract-gate: EXCLUDED_PATTERNS below still blanket-excludes
# scripts/tests/ (correct default — it's mostly the author's own pytest suite,
# dev-only, same reasoning as issue #246/#247 above but scoped to this one
# directory instead of removed entirely). These paths are the exception —
# the verification gate itself, meant to ship so a user's own template copy
# can run it. Found live 03.08: without this list, generate-manifest.sh
# silently dropped all 11 back into excluded_paths on every real run, even
# though they'd been hand-added to files[] in an earlier commit — the next
# real release would have shipped a template without its own test gate and
# nobody would have noticed until a user hit the bug the gate exists to catch.
SCRIPT_CONTRACT_EXPLICIT_INCLUDE=(
    "scripts/tests/test_create_wp_registry_coherence.sh"
    "scripts/tests/test_check_orphan_hooks.sh"
    "scripts/tests/test_capture_bus_detector_timeout.sh"
    "scripts/tests/test_critical_alert_disabled_tracker.sh"
    "scripts/tests/test_create_wp_contract.sh"
    "scripts/tests/test_capture_bus_contract.sh"
    "scripts/tests/test_critical_alert_contract.sh"
    "scripts/tests/test_create_wp_number_padding.py"
    "scripts/tests/test_create_wp_weekplan_writer.py"
    "scripts/tests/validate_manifest_coverage.sh"
    "scripts/tests/lib/capture_fixture.sh"
    "scripts/tests/lib/seed_strategy_fixture.sh"
    "scripts/tests/test_critical_alert_failure_matrix.sh"
    "scripts/tests/test_create_wp_repeat_and_cwd.sh"
    "scripts/tests/test_create_wp_hypothesis_relation.sh"
    "scripts/tests/test_day_close_lock_timezone.sh"
    "scripts/tests/test_fresh_seed_reproduction.sh"
    "scripts/tests/test_hook_classification.sh"
    "scripts/tests/test_update_install_path_guard.sh"
    "scripts/tests/test_update_deprecated_mirror_guard.sh"
    "scripts/tests/test_update_settings_merge_drift.sh"
    "scripts/tests/test_update_delivery_ref.sh"
    "scripts/tests/test_upgrade_worktree_cleanup.sh"
    "scripts/tests/test_issues_413_418.py"
    "scripts/tests/test_hindsight_docs_contract.sh"
    "scripts/tests/test_launchd_identity_runtime.sh"
    "scripts/tests/test_session_guard_hypothesis_gate.sh"
    # WP-529 F6 (Evgenii 18.08): the whole test_issue_* family plus its runner
    # ship with the template — a user's copy must be able to run its own
    # issue-regression gate (same rationale as the 03.08 block above).
    "scripts/tests/run-issue-tests.sh"
    "scripts/tests/test_issue_434_pipeline_scaffold_only.sh"
    "scripts/tests/test_issue_453_calendar_private_visibility.sh"
    "scripts/tests/test_issue_455_scaffold_missing_lib_fatal.sh"
    "scripts/tests/test_issue_463_pyyaml_explicit_diagnostics.sh"
    "scripts/tests/test_issue_463_setup_reuses_resolved_python3.sh"
    "scripts/tests/test_issue_469_settings_merge_hook_identity.py"
    "scripts/tests/test_issue_471_drift_scan_status_boundary.py"
    "scripts/tests/test_issue_473_build_active_wp_columns.py"
    "scripts/tests/test_issue_473_wp_sync_bundle_status.sh"
    "scripts/tests/test_issue_calendar_api_error_named.sh"
    "scripts/tests/test_update_build_runtime_fail_closed.sh"
    "scripts/tests/test_update_delivers_python_resolver_before_roles.sh"
    "scripts/tests/test_role_runner_update_marker_guard.sh"
)

is_explicit_include() {
    local rel="$1"; shift
    local item
    for item in "$@"; do
        [ "$rel" = "$item" ] && return 0
    done
    return 1
}

# Собираем файлы.
FILES=()
EXCLUDED_PATHS=()
while IFS= read -r rel; do
    # Пропускаем мусор/инструментарий
    if is_explicit_include "$rel" \
        "${GITHUB_EXPLICIT_INCLUDE[@]}" \
        "${SCRIPT_CONTRACT_EXPLICIT_INCLUDE[@]}"; then
        FILES+=("$rel")
        continue
    fi
    # .github/ is normally outside the delivery manifest.  Keep every tracked
    # workflow explicitly classified, otherwise manifest-coverage correctly
    # reports a silent delivery gap (#423).
    if is_explicit_include "$rel" "${GITHUB_CI_ONLY_EXCLUDE[@]}"; then
        EXCLUDED_PATHS+=("$rel")
        continue
    fi
    skip=false
    for pattern in "${SKIP_PATTERNS[@]}"; do
        case "$rel" in
            $pattern*) skip=true; break ;;
        esac
    done
    [[ "$(basename "$rel")" == ".gitkeep" ]] && skip=true
    $skip && continue

    # setup/ contains install-time scripts; skip all except explicit includes
    # (validate-template.sh referenced by .githooks/pre-commit and update.sh
    # after delivery; setup-cloud-scheduler.sh — see SETUP_EXPLICIT_INCLUDE above).
    # Register in EXCLUDED_PATHS same as .github/ above (#423) — Evgenii's
    # Red Team review 2026-08-19 found setup/test-delivery-route-label.sh
    # (and every other setup/test-*.sh) as a silent manifest-coverage gap:
    # this branch's bare `continue` never recorded WHY the file was skipped,
    # so check-manifest-coverage.py had no way to distinguish it from a
    # forgotten delivery.
    if [[ "$rel" == setup/* ]] && ! is_explicit_include "$rel" "${SETUP_EXPLICIT_INCLUDE[@]}"; then
        EXCLUDED_PATHS+=("$rel")
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
import hashlib
import json
from pathlib import Path

files = [line.strip() for line in open('$TMPDIR/files.txt') if line.strip()]
excluded = [line.strip() for line in open('$TMPDIR/excluded.txt') if line.strip()]
root = Path('$SCRIPT_DIR')

def manifest_entry(path):
    digest = hashlib.sha256((root / path).read_bytes()).hexdigest()
    return {'path': path, 'sha256': digest}

data = {
    'schema_version': 2,
    'version': '$VERSION',
    'description': 'Манифест платформенных файлов FMT-exocortex-template. Используется update.sh для доставки обновлений.',
    'files': [manifest_entry(p) for p in files],
    'excluded_paths': excluded,
    'deprecated_files': json.loads('''$DEPRECATED_JSON'''),
}

# 2026-08-22 (external report): deprecated_files is hand-managed and carried
# over from the previous manifest — a path that came BACK into the delivered
# tree stayed listed as deprecated, and update.sh deleted 10 files HEAD still
# ships. A path cannot be delivered and deprecated at once: delivery wins,
# the stale deprecation entry is dropped with a warning.
import subprocess
import sys
delivered_now = {e['path'] for e in data['files']}
# Same class, wider net (the live 10-file incident): a path still TRACKED in
# git HEAD ships with every fresh clone — deprecating it makes update.sh
# delete what the canon still distributes, leaving clones with tracked
# deletions. Deprecated may only list paths git no longer carries.
tracked_now = set(subprocess.run(
    ['git', 'ls-files'], capture_output=True, text=True, cwd='$SCRIPT_DIR'
).stdout.splitlines())
kept, dropped = [], []
for entry in data['deprecated_files']:
    (dropped if entry.get('path') in delivered_now or entry.get('path') in tracked_now else kept).append(entry)
for entry in dropped:
    print('  ⚠ deprecated_files: %s снова в поставке — запись удалена из deprecated' % entry.get('path'), file=sys.stderr)
data['deprecated_files'] = kept

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
