#!/bin/bash
# Validate Template — проверка целостности FMT-exocortex-template
#
# Режимы (--mode=...):
#   pristine  (default) — все 7 проверок. Для CI, author template-sync, fresh clone до setup.sh.
#   installed           — пропускает чеки 2/3/4, которые легитимно нарушаются после setup.sh
#                         (/Users/ подставлен, /opt/homebrew в CLAUDE_PATH, MEMORY заполняется работой).
#                         Используется setup.sh --validate как делегат структурных чеков.
#
# 7 проверок:
# 1. Нет автор-специфичного контента                              [pristine + installed]
# 2. Нет захардкоженных путей /Users/                             [pristine only]
# 3. Нет захардкоженных путей /opt/homebrew                       [pristine only]
# 4. MEMORY.md — скелет (мало строк в РП-таблице)                 [pristine only]
# 5. Обязательные файлы существуют                                [pristine + installed]
# 6. Нет хардкод-путей к FMT/scripts|roles в протоколах (WP-219)  [pristine + installed]
# 7. settings.json hooks ↔ .claude/hooks/ cross-ref (issue #13)   [pristine + installed]

set -euo pipefail

# Parse args: --mode=pristine|installed (default pristine) + позиционный TEMPLATE_DIR
MODE="pristine"
TEMPLATE_DIR=""
for arg in "$@"; do
    case "$arg" in
        --mode=pristine|--mode=installed) MODE="${arg#--mode=}" ;;
        --mode=*)
            echo "ERROR: unknown mode '${arg#--mode=}'. Use --mode=pristine or --mode=installed." >&2
            exit 2
            ;;
        --help|-h)
            echo "Usage: validate-template.sh [--mode=pristine|installed] [TEMPLATE_DIR]"
            echo "  Default mode: pristine (CI, author sync, fresh clone)"
            echo "  Use --mode=installed for post-setup checks (skips placeholder-substitution-related rules)."
            exit 0
            ;;
        *) [ -z "$TEMPLATE_DIR" ] && TEMPLATE_DIR="$arg" ;;
    esac
done
TEMPLATE_DIR="${TEMPLATE_DIR:-$HOME/IWE/FMT-exocortex-template}"
FAIL=0

# Guard: post-setup state + default pristine mode → подсказать installed-режим и выйти.
# Детектор стабильный: {{HOME_DIR}} в pristine FMT/CLAUDE.md гарантирован (используется в §4 Memory + §9 Авторское).
if [ "$MODE" = "pristine" ] \
   && [ -f "$TEMPLATE_DIR/CLAUDE.md" ] \
   && ! grep -q '{{HOME_DIR}}' "$TEMPLATE_DIR/CLAUDE.md" 2>/dev/null; then
    echo "ВНИМАНИЕ: FMT обработан setup.sh (плейсхолдер {{HOME_DIR}} в CLAUDE.md уже подставлен)."
    echo ""
    echo "Pristine-режим (default) применим к:"
    echo "  • CI (.github/workflows/validate-template.yml)"
    echo "  • Author template-sync (перед commit FMT)"
    echo "  • Свежий clone ДО запуска setup.sh"
    echo ""
    echo "Для проверки установленного workspace используйте один из:"
    echo "  bash setup.sh --validate                              # env + структурные чеки (делегат)"
    echo "  bash setup/validate-template.sh --mode=installed      # явно installed (4 универсальных чека)"
    echo "  /audit-installation                                   # полный аудит (Claude Code skill)"
    exit 0
fi

echo "=== Validating: $TEMPLATE_DIR (mode=$MODE) ==="

# Утилита: подсчёт совпадений grep (безопасно с pipefail)
grep_count() {
    local pattern="$1"
    shift
    grep -rn "$pattern" "$@" 2>/dev/null | wc -l | tr -d ' ' || true
}

# 1. Нет автор-специфичного контента
echo -n "[1/5] Author-specific content... "
CHECK1_FAIL=0

# Глобальные (запрет везде, кроме CHANGELOG и GitHub URLs)
for pattern in "tserentserenov" "PACK-MIM" "aist_bot_newarchitecture" \
               "DS-Knowledge-Index-Tseren" "DS-IT-systems" "DS-ai-systems" \
               "DS-my-strategy" "engines/tailor"; do
    count=$(grep -rn "$pattern" "$TEMPLATE_DIR" --include="*.md" --include="*.sh" \
            --include="*.py" --include="*.json" --include="*.plist" --include="*.yaml" \
            --exclude='validate-template.sh' --exclude='LEARNING-PATH.md' \
            --exclude='CHANGELOG.md' 2>/dev/null \
            | grep -v 'github.com/' | grep -v 'docs/adr/' | wc -l | tr -d ' ' || true)
    if [ "$count" -gt 0 ]; then
        [ "$CHECK1_FAIL" -eq 0 ] && echo "FAIL"
        echo "  Found '$pattern' (global) in $count locations:"
        grep -rn "$pattern" "$TEMPLATE_DIR" --include="*.md" --include="*.sh" \
            --include="*.py" --include="*.json" --include="*.plist" \
            --exclude='validate-template.sh' --exclude='LEARNING-PATH.md' \
            --exclude='CHANGELOG.md' 2>/dev/null \
            | grep -v 'github.com/' | grep -v 'docs/adr/' | head -3 || true
        CHECK1_FAIL=1
        FAIL=1
    fi
done

# Protocol-only — запрет в протоколах/скиллах/хуках/CLAUDE.md (разрешено в README/docs/onboarding как упоминание продукта)
for pattern in "@aist_me_bot" "digital-twin" "content-pipeline" \
               "knowledge-mcp" "gateway-mcp" "DS-agent-workspace/scheduler"; do
    count=$(cd "$TEMPLATE_DIR" && grep -rn "$pattern" \
            .claude/skills .claude/hooks .claude/rules memory CLAUDE.md 2>/dev/null \
            | grep -v 'CHANGELOG.md' | wc -l | tr -d ' ' || true)
    if [ "$count" -gt 0 ]; then
        [ "$CHECK1_FAIL" -eq 0 ] && echo "FAIL"
        echo "  Found '$pattern' (protocol-only) in $count locations:"
        (cd "$TEMPLATE_DIR" && grep -rn "$pattern" \
            .claude/skills .claude/hooks .claude/rules memory CLAUDE.md 2>/dev/null | head -3) || true
        CHECK1_FAIL=1
        FAIL=1
    fi
done
[ "$CHECK1_FAIL" -eq 0 ] && echo "PASS"

# 2. Нет захардкоженных /Users/ путей [pristine only]
# В installed-режиме setup.sh легитимно подставил $WORKSPACE_DIR → /Users/<user>/...
echo -n "[2/5] Hardcoded /Users/ paths... "
if [ "$MODE" = "installed" ]; then
    echo "SKIP (installed mode — /Users/ подставлен setup'ом)"
else
    count=$(grep -rn '/Users/' "$TEMPLATE_DIR" --include="*.md" --include="*.sh" \
            --include="*.json" --include="*.plist" \
            --exclude='validate-template.sh' --exclude='setup.sh' \
            --exclude='CHANGELOG.md' 2>/dev/null \
            | grep -v '/Users/\.\.\./' \
            | grep -v '# .*\(/Users/\|e\.g\.\)' \
            | wc -l | tr -d ' ' || true)
    if [ "$count" -gt 0 ]; then
        echo "FAIL ($count hits)"
        grep -rn '/Users/' "$TEMPLATE_DIR" --include="*.md" --include="*.sh" \
            --exclude='validate-template.sh' --exclude='setup.sh' \
            --exclude='CHANGELOG.md' 2>/dev/null \
            | grep -v '/Users/\.\.\./' \
            | grep -v '# .*\(/Users/\|e\.g\.\)' | head -3 || true
        FAIL=1
    else
        echo "PASS"
    fi
fi

# 3. Нет захардкоженных /opt/homebrew путей [pristine only]
# В installed-режиме CLAUDE_PATH=/opt/homebrew/bin/claude — легитимная подстановка.
echo -n "[3/5] Hardcoded /opt/homebrew paths... "
if [ "$MODE" = "installed" ]; then
    echo "SKIP (installed mode — CLAUDE_PATH может быть /opt/homebrew/...)"
else
    count=$(grep -rn '/opt/homebrew' "$TEMPLATE_DIR" --include="*.md" --include="*.sh" \
            --include="*.json" --include="*.plist" \
            --exclude='validate-template.sh' --exclude='setup.sh' \
            --exclude='CHANGELOG.md' 2>/dev/null \
            | grep -v 'README.md' \
            | grep -v 'PLATFORM-COMPAT.md' \
            | grep -v 'validate-template.yml' \
            | grep -v '/usr/local/bin.*:/opt/homebrew' \
            | wc -l | tr -d ' ' || true)
    if [ "$count" -gt 0 ]; then
        echo "FAIL ($count hits)"
        grep -rn '/opt/homebrew' "$TEMPLATE_DIR" --include="*.md" --include="*.sh" \
            --exclude='validate-template.sh' --exclude='setup.sh' \
            --exclude='CHANGELOG.md' 2>/dev/null \
            | grep -v 'README.md' | grep -v 'PLATFORM-COMPAT.md' \
            | grep -v 'validate-template.yml' \
            | grep -v '/usr/local/bin.*:/opt/homebrew' | head -3 || true
        FAIL=1
    else
        echo "PASS"
    fi
fi

# 4. MEMORY.md — скелет (≤15 строк в таблице) [pristine only]
# В installed-режиме MEMORY заполняется работой пользователя (РП, заметки).
echo -n "[4/5] MEMORY.md is skeleton... "
if [ "$MODE" = "installed" ]; then
    echo "SKIP (installed mode — MEMORY заполняется работой)"
else
    MEMORY_FILE="$TEMPLATE_DIR/memory/MEMORY.md"
    if [ -f "$MEMORY_FILE" ]; then
        rp_rows=$(grep -c '^|' "$MEMORY_FILE" 2>/dev/null || true); rp_rows=${rp_rows:-0}
        if [ "$rp_rows" -gt 15 ]; then
            echo "FAIL ($rp_rows table rows, expected ≤15)"
            FAIL=1
        else
            echo "PASS ($rp_rows rows)"
        fi
    else
        echo "WARN (file missing)"
    fi
fi

# 5. Обязательные файлы
echo -n "[5/5] Required files... "
MISSING=0
for f in CLAUDE.md ONTOLOGY.md README.md \
         memory/MEMORY.md memory/hard-distinctions.md \
         memory/protocol-open.md memory/protocol-close.md \
         memory/navigation.md \
         roles/strategist/scripts/strategist.sh; do
    if [ ! -f "$TEMPLATE_DIR/$f" ]; then
        echo ""
        echo "  MISSING: $f"
        MISSING=1
        FAIL=1
    fi
done
[ "$MISSING" -eq 0 ] && echo "PASS"

# 6. Нет хардкод-путей к скриптам в протоколах/скиллах (WP-219, DP.FM.009)
# Протоколы и скиллы должны использовать $IWE_SCRIPTS / $IWE_ROLES / $IWE_TEMPLATE / $IWE_WORKSPACE
# вместо абсолютных путей к FMT-exocortex-template/scripts|roles или bare ~/IWE/scripts.
# Enumerate-all: собираем ВСЕ нарушения по всем паттернам, выводим списком, потом fail (предотвращает iterative fix-retry).
echo -n "[6/6] Hardcoded script paths in protocols/skills... "
CHECK6_FAIL=0
CHECK6_HITS=""
# Паттерн 1-2: ссылки на FMT-template путь (legacy DP.FM.009)
# Паттерн 3: bare `bash ~/IWE/scripts/X.sh` или `bash $HOME/IWE/scripts/X.sh` без fallback на $IWE_SCRIPTS
#   (исключает корректные `bash ${IWE_SCRIPTS:-$HOME/IWE/scripts}/X.sh`, т.к. после `bash ` идёт `${`, не `~` и не `$HOME`)
for pattern in 'FMT-exocortex-template/scripts' \
               'FMT-exocortex-template/roles/[a-z]*/scripts' \
               'bash (~|\$HOME)/IWE/scripts/'; do
    hits=$(grep -rnE "$pattern" \
            "$TEMPLATE_DIR/memory" \
            "$TEMPLATE_DIR/.claude/skills" \
            --include="*.md" 2>/dev/null \
            | grep -v '\$IWE_' || true)
    if [ -n "$hits" ]; then
        CHECK6_HITS="${CHECK6_HITS}${CHECK6_HITS:+$'\n'}--- Pattern: $pattern ---"$'\n'"$hits"
        CHECK6_FAIL=1
        FAIL=1
    fi
done
if [ "$CHECK6_FAIL" -eq 1 ]; then
    echo "FAIL"
    echo "  Должен быть \$IWE_SCRIPTS / \$IWE_ROLES (или \${IWE_SCRIPTS:-\$HOME/IWE/scripts} для inline-команд):"
    echo "$CHECK6_HITS"
else
    echo "PASS"
fi

# 7. settings.json hooks ↔ .claude/hooks/ cross-ref (issue #13)
# Проверка в обе стороны:
#   (a) FAIL: hook упомянут в settings.json, но файла нет в .claude/hooks/
#   (b) WARN: hook есть в .claude/hooks/, но не упомянут ни в одном settings.json
#       (может быть вызываем напрямую, например wakatime-heartbeat.sh)
echo -n "[7/7] Hooks cross-ref (settings.json ↔ .claude/hooks/)... "
CHECK7_FAIL=0
HOOKS_DIR="$TEMPLATE_DIR/.claude/hooks"
SETTINGS_FILES=()
[ -f "$TEMPLATE_DIR/.claude/settings.json" ] && SETTINGS_FILES+=("$TEMPLATE_DIR/.claude/settings.json")
[ -f "$TEMPLATE_DIR/.claude/settings.local.json" ] && SETTINGS_FILES+=("$TEMPLATE_DIR/.claude/settings.local.json")

if [ ${#SETTINGS_FILES[@]} -eq 0 ] || [ ! -d "$HOOKS_DIR" ]; then
    echo "SKIP (no settings.json or hooks/ dir)"
else
    REFERENCED=$(grep -hoE '\.claude/hooks/[a-zA-Z0-9_-]+\.sh' "${SETTINGS_FILES[@]}" 2>/dev/null | sort -u || true)
    for ref in $REFERENCED; do
        if [ ! -f "$TEMPLATE_DIR/$ref" ]; then
            [ "$CHECK7_FAIL" -eq 0 ] && echo "FAIL"
            echo "  Missing hook: $ref (referenced in settings.json but file not found)"
            CHECK7_FAIL=1
            FAIL=1
        fi
    done

    ORPHAN_WARN=0
    for hook in "$HOOKS_DIR"/*.sh; do
        [ -f "$hook" ] || continue
        name=$(basename "$hook")
        if ! grep -q "\.claude/hooks/$name" "${SETTINGS_FILES[@]}" 2>/dev/null; then
            if [ "$ORPHAN_WARN" -eq 0 ]; then
                [ "$CHECK7_FAIL" -eq 0 ] && echo "PASS (with warnings)"
                ORPHAN_WARN=1
            fi
            echo "  WARN: hook $name не упомянут в settings.json (может быть dead code или прямой вызов)"
        fi
    done
    [ "$CHECK7_FAIL" -eq 0 ] && [ "$ORPHAN_WARN" -eq 0 ] && echo "PASS"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "=== ALL CHECKS PASSED ==="
    exit 0
else
    echo "=== VALIDATION FAILED ==="
    exit 1
fi
