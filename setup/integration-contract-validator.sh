#!/bin/bash
# integration-contract-validator.sh — детектор Spec↔State drift.
#
# # see VR.SC.006 (release-verification-protocol), VR.M.006 (5-layer verification, слой 1)
# # see AR.203 (release verification trigger)
#
# WP-273 R4.8 (proposal Евгения, Round 4 red-team). Закрывает 4-й системный корень:
# докуменация говорит А, код делает Б — нужен автоматический детектор расхождений
# до релиза.
#
# 11 детекторов:
#   1. manifest_paths    — пути из update-manifest.json существуют в дереве
#   2. seed_references   — protocol-*.md ссылки на seed/ существуют в seed/
#   3. extension_table   — extensions/README.md table ↔ реальное placement EXTENSION POINT в protocol-*/SKILL.md
#   4. hook_artifact     — .claude/hooks/*.sh не грепают TOOL_INPUT по artifact-именам (антипаттерн R4.5)
#   5. runner_readonly   — runners резолвят prompts/role.yaml/notify через $IWE_TEMPLATE (R5.1, 0.29.3)
#   6. install_failfast  — install.sh имеют grep '{{' check на PLIST_SRC (R5.2, 0.29.3)
#   7. prompts_python_coverage — нет hardcoded DS-strategy в prompts и .py (R6.1*, 0.29.5)
#   8. sed_placeholder_escape — substituted runners НЕ имеют bare {{X}} в sed (R6.1**, 0.29.6)
#   9. manifest_version  — update-manifest.json version == CHANGELOG.md version (prevent stale-manifest release)
#  10. deprecated_runner_usage — deprecated_files не содержат промптов, которые ещё вызывает runner
#  11. prompt_script_refs — bash-вызовы scripts/*.sh в промптах → файл существует в FMT/scripts/
#
# Usage:
#   bash setup/integration-contract-validator.sh [--verbose]
#
# Exit:
#   0 — все детекторы PASS
#   1 — некорректные аргументы
#   N>1 — N drift-нарушений найдено

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="$(dirname "$SCRIPT_DIR")"  # FMT-exocortex-template/
VERBOSE=false

# Detector regex'ы — shared source (0.29.19 DRY fix).
# shellcheck source=detector-regex.sh
. "$SCRIPT_DIR/detector-regex.sh"

while [ $# -gt 0 ]; do
    case "$1" in
        --verbose|-v) VERBOSE=true; shift ;;
        --help|-h)
            grep '^#' "$0" | head -22
            exit 0
            ;;
        *) echo "ERROR: Unknown arg: $1" >&2; exit 1 ;;
    esac
done

cd "$TEMPLATE_DIR"

VIOLATIONS=0
log() { echo "$@"; }
# SC2145 fix: используем $* (склеивает с IFS) внутри строки с literal-префиксом,
# чтобы не получать «mixes string and array» от shellcheck.
verbose() { if $VERBOSE; then echo "  $*"; fi; }

log "=== Integration Contract Validator (WP-273 R4.8) ==="
log ""

# === Detector 1: manifest paths existence ===
log "[1/11] manifest_paths — пути из update-manifest.json в дереве..."
if [ -f update-manifest.json ] && command -v python3 >/dev/null 2>&1; then
    MISSING=$(python3 -c "
import json, os
with open('update-manifest.json') as f:
    data = json.load(f)
for entry in data.get('files', []):
    p = entry.get('path') if isinstance(entry, dict) else entry
    if p and not os.path.isfile(p):
        print(p)
")
    if [ -n "$MISSING" ]; then
        log "  ❌ FAIL: manifest содержит пути, отсутствующие в дереве:"
        echo "$MISSING" | sed 's/^/      /'
        COUNT=$(echo "$MISSING" | wc -l | tr -d ' ')
        VIOLATIONS=$((VIOLATIONS + COUNT))
    else
        log "  ✅ PASS"
    fi
else
    log "  ⊘ SKIP (нет update-manifest.json или python3)"
fi
log ""

# === Detector 2: seed references in protocols ===
log "[2/11] seed_references — protocol-*.md ссылки на seed/ существуют..."
SEED_REFS_VIOLATIONS=0
if [ -d seed ]; then
    while IFS= read -r ref; do
        # ref like "seed/strategy/decisions/" or "seed/strategy/docs/Strategy.md"
        rel="${ref%/}"
        if [ ! -e "$rel" ]; then
            log "  ❌ Reference: '$ref' не существует в дереве"
            verbose "    upstream of seed/strategy/: $(ls seed/strategy/ 2>/dev/null | tr '\n' ' ')"
            SEED_REFS_VIOLATIONS=$((SEED_REFS_VIOLATIONS + 1))
        fi
    done < <(grep -hoE 'seed/[a-z][a-z/_-]*' memory/protocol-*.md 2>/dev/null | sort -u | grep -vE '\.\.\.$|/$' || true)

    if [ "$SEED_REFS_VIOLATIONS" -eq 0 ]; then
        log "  ✅ PASS"
    else
        log "  ❌ FAIL ($SEED_REFS_VIOLATIONS violations)"
        VIOLATIONS=$((VIOLATIONS + SEED_REFS_VIOLATIONS))
    fi
else
    log "  ⊘ SKIP (нет seed/)"
fi
log ""

# === Detector 3: extension table ↔ real EXTENSION POINT placement ===
log "[3/11] extension_table — extensions/README.md table ↔ EXTENSION POINT в protocol-*.md/SKILL.md..."
EXT_VIOLATIONS=0
if [ -f extensions/README.md ]; then
    # Parse extension table from README.md: lines like "| protocol-close | checks | ..."
    declare_table=$(grep -E '^\|\s*`?[a-z][a-z-]*`?\s*\|\s*`?[a-z]+`?\s*\|' extensions/README.md 2>/dev/null | head -20 || true)

    # Find actual EXTENSION POINT references in protocols/skills.
    # WP-273 R6 fix (Round 5 sub-agent assessment): regex терминировался на первом
    # backtick — пропускал EP'ы где в строке несколько backtick'ов (например
    # "ДО `git commit` проверить `extensions/X.md`"). Расширили: ищем
    # `extensions/X.md` отдельным regex, без зависимости от «EXTENSION POINT».
    real_eps=$(grep -hroE 'extensions/[a-z-]+\.[a-z]+\.md' \
        memory/protocol-*.md .claude/skills/*/SKILL.md \
        .claude/skills/*/scripts/*.sh 2>/dev/null | sort -u || true)

    # For each entry in declared_table, check that it's loaded somewhere
    while IFS= read -r line; do
        proto=$(echo "$line" | awk -F'|' '{gsub(/[` ]/, "", $2); print $2}')
        hook=$(echo "$line" | awk -F'|' '{gsub(/[` ]/, "", $3); print $3}')
        [ -z "$proto" ] && continue
        [ -z "$hook" ] && continue
        expected="extensions/${proto}.${hook}.md"
        if ! echo "$real_eps" | grep -q "^${expected}$"; then
            log "  ⚠ Table declared $expected, но EXTENSION POINT не найден в protocols/skills"
            EXT_VIOLATIONS=$((EXT_VIOLATIONS + 1))
        fi
    done <<< "$declare_table"

    if [ "$EXT_VIOLATIONS" -eq 0 ]; then
        log "  ✅ PASS"
    else
        log "  ⚠ WARN ($EXT_VIOLATIONS таблица-vs-код расхождений)"
        # extension table — это документация контракта, не критический drift
    fi
else
    log "  ⊘ SKIP (нет extensions/README.md)"
fi
log ""

# === Detector 4: hook trigger pattern (hooks-design.md принцип) ===
log "[4/11] hook_artifact — hooks не грепают TOOL_INPUT (R4.5 антипаттерн)..."
HOOK_VIOLATIONS=0
if [ -d .claude/hooks ]; then
    while IFS= read -r f; do
        # WP-273 R6 fix (Round 5 sub-agent assessment): уточнили regex до
        # КОНКРЕТНОГО антипаттерна (R4.5) — grep'ать TOOL_INPUT по artifact-именам
        # (DayPlan, WeekPlan, day-close, day-open). Раньше ловили любой grep TOOL_INPUT,
        # включая легитимный gating «это git commit вообще?» — false positive.
        if grep -qE 'TOOL_INPUT.*\|.*grep[^|]*(DayPlan|WeekPlan|day-close|day-open|week-close|week-open)' "$f" 2>/dev/null; then
            log "  ⚠ $f: grep TOOL_INPUT по artifact-именам (нарушает hooks-design.md, использовать staged-files)"
            HOOK_VIOLATIONS=$((HOOK_VIOLATIONS + 1))
        fi
    done < <(find .claude/hooks -name "*.sh" -type f 2>/dev/null)

    if [ "$HOOK_VIOLATIONS" -eq 0 ]; then
        log "  ✅ PASS"
    else
        log "  ⚠ WARN ($HOOK_VIOLATIONS hooks)"
        # WARN, не FAIL — есть валидные case'ы (debug logging)
    fi
else
    log "  ⊘ SKIP (нет .claude/hooks/)"
fi
log ""

# === Detector 5: runner read-only references resolve correctly (R5.1 regression) ===
log "[5/11] runner_readonly — runners резолвят prompts/role.yaml/notify через \$IWE_TEMPLATE..."
RUNNER_VIOLATIONS=0
# Антипаттерн (Round 5 R5.1): PROMPTS_DIR="\$REPO_DIR/prompts" без fallback на \$IWE_TEMPLATE.
# Runner работает только если все read-only данные дублированы в runtime.
for runner in roles/strategist/scripts/strategist.sh roles/extractor/scripts/extractor.sh; do
    [ -f "$runner" ] || continue
    if ! grep -q 'IWE_TEMPLATE.*roles/.*prompts' "$runner" 2>/dev/null; then
        log "  ⚠ $runner: PROMPTS_DIR не резолвится через \$IWE_TEMPLATE (antipattern R5.1)"
        RUNNER_VIOLATIONS=$((RUNNER_VIOLATIONS + 1))
    fi
done
# scheduler.sh: проверка ROLES_DIR_TEMPLATE для role.yaml lookup
if [ -f roles/synchronizer/scripts/scheduler.sh ]; then
    if ! grep -q 'ROLES_DIR_TEMPLATE.*IWE_TEMPLATE' roles/synchronizer/scripts/scheduler.sh 2>/dev/null; then
        log "  ⚠ scheduler.sh: role.yaml lookup не использует \$IWE_TEMPLATE (R5.1)"
        RUNNER_VIOLATIONS=$((RUNNER_VIOLATIONS + 1))
    fi
fi
if [ "$RUNNER_VIOLATIONS" -eq 0 ]; then
    log "  ✅ PASS"
else
    log "  ❌ FAIL ($RUNNER_VIOLATIONS runners без правильного \$IWE_TEMPLATE-резолва)"
    VIOLATIONS=$((VIOLATIONS + RUNNER_VIOLATIONS))
fi
log ""

# === Detector 6: install.sh fail-fast при literal {{...}} в plist (R5.2 regression) ===
log "[6/11] install_failfast — install.sh имеют grep '{{' check на PLIST_SRC..."
FAILFAST_VIOLATIONS=0
for install_sh in roles/strategist/install.sh roles/extractor/install.sh roles/synchronizer/install.sh; do
    [ -f "$install_sh" ] || continue
    # Антипаттерн: install.sh без grep на плейсхолдеры → может скопировать
    # plist с literal {{IWE_RUNTIME}} в ~/Library/LaunchAgents/.
    if ! grep -qE "grep -qE? '\\\\\{\\\\\{|grep -qE? '\{\{" "$install_sh" 2>/dev/null; then
        log "  ⚠ $install_sh: нет fail-fast grep на {{...}} в plist (antipattern R5.2)"
        FAILFAST_VIOLATIONS=$((FAILFAST_VIOLATIONS + 1))
    fi
done
if [ "$FAILFAST_VIOLATIONS" -eq 0 ]; then
    log "  ✅ PASS"
else
    log "  ❌ FAIL ($FAILFAST_VIOLATIONS install.sh без fail-fast)"
    VIOLATIONS=$((VIOLATIONS + FAILFAST_VIOLATIONS))
fi
log ""

# === Detector 7: prompts + python + shell coverage (R6.1* regression — мой smoke test пропустил) ===
log "[7/11] prompts_python_shell_coverage — нет hardcoded DS-strategy в prompts/.py/.sh..."
COVERAGE_VIOLATIONS=0
# Python scripts: должны читать GOVERNANCE_REPO из env, не хардкодить
while IFS= read -r py; do
    [ -f "$py" ] || continue
    # Антипаттерн: Path с literal "DS-strategy" без чтения env
    if grep -qE '"DS-strategy"|/DS-strategy[/"]' "$py" 2>/dev/null; then
        # Допустимо если читает GOVERNANCE_REPO из env (значит fallback default)
        if ! grep -qE 'IWE_GOVERNANCE_REPO|GOVERNANCE_REPO' "$py" 2>/dev/null; then
            log "  ⚠ $py: hardcoded DS-strategy без чтения GOVERNANCE_REPO env"
            COVERAGE_VIOLATIONS=$((COVERAGE_VIOLATIONS + 1))
        fi
    fi
done < <(find roles -name '*.py' -type f 2>/dev/null)

# Shell scripts (12 мая, WP-291 follow-up): дополнение к Python-проверке.
# Bug 1 (b24639f) — в dt-collect.sh:238 был hardcode /DS-strategy/ который detector
# не ловил, потому что .sh файлы не сканировались. SESSION_LOG="$WORKSPACE/DS-strategy/..."
# игнорировал параметризованный $GOVERNANCE_DIR на line 34.
#
# Scope: roles/ + scripts/. Whitelist parameter-expansion fallback и комментарии.
while IFS= read -r sh; do
    [ -f "$sh" ] || continue
    # Antipattern: `/DS-strategy/` или `"DS-strategy"` literal без use $GOVERNANCE_DIR
    if grep -qE '"DS-strategy"|/DS-strategy[/"]' "$sh" 2>/dev/null; then
        # Допустимо если читает GOVERNANCE_REPO из env (значит fallback default — паттерн Python detector выше)
        if grep -qE 'IWE_GOVERNANCE_REPO|GOVERNANCE_REPO' "$sh" 2>/dev/null; then
            continue
        fi
        # Фильтр fallback `${VAR:-...DS-strategy...}` (`:-` должен быть внутри parameter-expansion с DS-strategy)
        # и комментариев (строка вида `path:NN:   # ...`).
        HITS=$(grep -nE '"DS-strategy"|/DS-strategy[/"]' "$sh" 2>/dev/null \
            | grep -vE '\$\{[^}]*:-[^}]*DS-strategy|^[^:]+:[[:space:]]*#' || true)
        if [ -n "$HITS" ]; then
            log "  ⚠ $sh: hardcoded DS-strategy без \$GOVERNANCE_DIR / GOVERNANCE_REPO env:"
            echo "$HITS" | while IFS= read -r line; do log "      $line"; done
            COVERAGE_VIOLATIONS=$((COVERAGE_VIOLATIONS + 1))
        fi
    fi
done < <(find roles scripts -name '*.sh' -type f 2>/dev/null)

# Prompts: не должны иметь bare DS-strategy/, должны использовать {{GOVERNANCE_REPO}}
while IFS= read -r prompt; do
    [ -f "$prompt" ] || continue
    # Hits: bare 'DS-strategy/' или ' DS-strategy ' или '`DS-strategy`' или '`DS-strategy/'
    # WP-279 fix: расширен паттерн — ранее пропускал `DS-strategy/path` (backtick+slash).
    # 0.29.19 DRY fix: regex source — setup/detector-regex.sh ($DETECTOR_07_REGEX).
    if grep -qE "$DETECTOR_07_REGEX" "$prompt" 2>/dev/null; then
        # Game допустима если параллельно есть {{GOVERNANCE_REPO}} (миграционная стадия)
        log "  ⚠ $prompt: bare DS-strategy без {{GOVERNANCE_REPO}}"
        COVERAGE_VIOLATIONS=$((COVERAGE_VIOLATIONS + 1))
    fi
done < <(find roles -name 'prompts' -type d 2>/dev/null | xargs -I{} find {} -name '*.md' -type f 2>/dev/null)

if [ "$COVERAGE_VIOLATIONS" -eq 0 ]; then
    log "  ✅ PASS"
else
    log "  ❌ FAIL ($COVERAGE_VIOLATIONS prompts/.py/.sh с hardcoded DS-strategy)"
    VIOLATIONS=$((VIOLATIONS + COVERAGE_VIOLATIONS))
fi
log ""

# === Detector 8: bare {{...}} в sed-выражениях substituted-runners (R6.1**, 0.29.6) ===
log "[8/11] sed_placeholder_escape — substituted runners НЕ имеют bare {{X}} в sed (build-runtime подменит)..."
SED_VIOLATIONS=0
# Парсим overlay-реестр: substituted-файлы из реестра проверяем на bare {{X}} в sed-выражениях.
# Антипаттерн (R6.1**): sed -e "s|{{X}}|val|" в substituted runner'е → build-runtime подменит {{X}} → sed broken.
# Правильно: использовать escape (через bash переменные _o='{''{', _c='}''}', либо вынести в helper).
while IFS= read -r path; do
    [ -f "$path" ] || continue
    case "$path" in *.sh)
        # Ищем sed -e "s|{{X}}|...|" — это bare placeholder в substituted-файле = регрессия R6.1**.
        if grep -qE 'sed.*-e.*"s\|\{\{[A-Z_]+\}\}\|' "$path" 2>/dev/null; then
            log "  ⚠ $path: bare {{X}} в sed-выражении (R6.1** antipattern, build-runtime подменит литерал)"
            SED_VIOLATIONS=$((SED_VIOLATIONS + 1))
        fi
        ;;
    esac
done < <(awk '/^substituted:/,/^[a-z_]+:/' .claude/runtime-overlay.yaml 2>/dev/null | grep -oE '^\s+- .*' | sed 's/^[[:space:]]*-[[:space:]]*//' | sed 's/[[:space:]]*#.*//')

if [ "$SED_VIOLATIONS" -eq 0 ]; then
    log "  ✅ PASS"
else
    log "  ❌ FAIL ($SED_VIOLATIONS substituted runners с bare {{X}} sed)"
    VIOLATIONS=$((VIOLATIONS + SED_VIOLATIONS))
fi
log ""

# === Detector 9: manifest version matches CHANGELOG ===
log "[9/11] manifest_version — update-manifest.json version == CHANGELOG.md version..."
if [ -f update-manifest.json ] && [ -f CHANGELOG.md ] && command -v python3 >/dev/null 2>&1; then
    MANIFEST_VERSION=$(python3 -c "import json; print(json.load(open('update-manifest.json')).get('version',''))" 2>/dev/null || echo "")
    CHANGELOG_VERSION=$(grep -m1 -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' CHANGELOG.md | sed 's/^## \[//;s/\]$//' 2>/dev/null || echo "")
    if [ -z "$MANIFEST_VERSION" ] || [ -z "$CHANGELOG_VERSION" ]; then
        log "  ⊘ SKIP (не удалось прочитать версии)"
    elif [ "$MANIFEST_VERSION" = "$CHANGELOG_VERSION" ]; then
        log "  ✅ PASS (v$MANIFEST_VERSION)"
    else
        log "  ❌ FAIL: manifest=$MANIFEST_VERSION, CHANGELOG=$CHANGELOG_VERSION — запусти generate-manifest.sh"
        VIOLATIONS=$((VIOLATIONS + 1))
    fi
else
    log "  ⊘ SKIP (нет update-manifest.json, CHANGELOG.md или python3)"
fi
log ""

# === Detector 10: deprecated_files ↔ runner usage cross-check ===
# Корень бага (22 мая, Евгений): update-manifest.json пометил 4 промпта deprecated
# с reason «migrated to run_skill», но strategist.sh по-прежнему вызывал run_claude
# для этих же промптов. update.sh удалил бы файлы → runner упал бы с «Command file
# not found». CI не ловил: smoke-test проверял runner только с несуществующим
# сценарием, не с реальными.
log "[10/11] deprecated_runner_usage — deprecated_files не содержат промптов, которые runner ещё вызывает..."
DEPRECATED_RUNNER_VIOLATIONS=0
RUNNER="roles/strategist/scripts/strategist.sh"
if [ -f update-manifest.json ] && [ -f "$RUNNER" ] && command -v python3 >/dev/null 2>&1; then
    # Извлекаем пути deprecated strategist prompts из манифеста
    DEPRECATED_PROMPTS=$(python3 -c "
import json, sys
try:
    m = json.load(open('update-manifest.json'))
    paths = [e['path'] for e in m.get('deprecated_files', []) if '/strategist/prompts/' in e.get('path', '')]
    print('\n'.join(paths))
except Exception:
    pass
" 2>/dev/null)
    # Сравниваем с командами run_claude в runner'е
    if [ -n "$DEPRECATED_PROMPTS" ]; then
        while IFS= read -r cmd; do
            [ -z "$cmd" ] && continue
            prompt_path="roles/strategist/prompts/${cmd}.md"
            if echo "$DEPRECATED_PROMPTS" | grep -qF "$prompt_path"; then
                log "  ❌ CONFLICT: $prompt_path помечен deprecated, но runner вызывает run_claude \"$cmd\""
                DEPRECATED_RUNNER_VIOLATIONS=$((DEPRECATED_RUNNER_VIOLATIONS + 1))
            fi
        done < <(grep -oE 'run_claude\s+"[^"]+"' "$RUNNER" 2>/dev/null | grep -oE '"[^"]+"' | tr -d '"' | sort -u)
    fi
    if [ "$DEPRECATED_RUNNER_VIOLATIONS" -eq 0 ]; then
        log "  ✅ PASS"
    else
        log "  ❌ FAIL ($DEPRECATED_RUNNER_VIOLATIONS промптов deprecated, но runner их вызывает — update.sh удалит файлы, runner упадёт)"
        VIOLATIONS=$((VIOLATIONS + DEPRECATED_RUNNER_VIOLATIONS))
    fi
else
    log "  ⊘ SKIP (нет update-manifest.json, $RUNNER или python3)"
fi
log ""

# === Detector 11: prompt bash-script cross-references ===
# Checks that scripts referenced as `bash "…/scripts/<name>.sh"` in role prompts
# exist inside FMT/scripts/. Missing scripts = runtime failure for users on fresh install.
log "[11/11] prompt_script_refs — bash-вызовы scripts/*.sh в промптах существуют в FMT/scripts/..."
PROMPT_SCRIPT_VIOLATIONS=0
if command -v grep >/dev/null 2>&1; then
    while IFS= read -r script_name; do
        [ -z "$script_name" ] && continue
        if [ ! -f "scripts/$script_name" ]; then
            log "  ⚠ WARN: roles/.../prompts/*.md ссылается на scripts/$script_name — файл отсутствует в FMT/scripts/"
            PROMPT_SCRIPT_VIOLATIONS=$((PROMPT_SCRIPT_VIOLATIONS + 1))
        fi
    done < <(
        grep -rh 'bash[[:space:]]\+.*scripts/[^[:space:]"'\'']*\.sh' roles/*/prompts/*.md 2>/dev/null \
            | grep -oE 'scripts/[^[:space:]/]+\.sh' \
            | sed 's|scripts/||' \
            | sort -u
    )
    if [ "$PROMPT_SCRIPT_VIOLATIONS" -eq 0 ]; then
        log "  ✅ PASS"
    else
        log "  ❌ FAIL ($PROMPT_SCRIPT_VIOLATIONS script(s) referenced in prompts but absent from FMT/scripts/ — add via script-promote.sh or use if-exists guard)"
        VIOLATIONS=$((VIOLATIONS + PROMPT_SCRIPT_VIOLATIONS))
    fi
else
    log "  ⊘ SKIP (grep недоступен)"
fi
log ""

# === Verdict ===
log "=================================================="
if [ "$VIOLATIONS" -eq 0 ]; then
    log "  ✅ Integration contracts: PASS"
    log "=================================================="
    exit 0
else
    log "  ❌ Integration contracts: $VIOLATIONS violations"
    log "=================================================="
    exit "$VIOLATIONS"
fi
