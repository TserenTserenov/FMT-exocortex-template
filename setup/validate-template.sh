#!/bin/bash
# Validate Template — проверка целостности FMT-exocortex-template
#
# 7 проверок:
# 1. Нет автор-специфичного контента
# 2. Нет захардкоженных путей /Users/
# 3. Нет захардкоженных путей /opt/homebrew
# 4. MEMORY.md — скелет (мало строк в РП-таблице)
# 5. Обязательные файлы существуют
# 6. Нет хардкод-путей к FMT-exocortex-template/scripts|roles в протоколах/скиллах (WP-219, DP.FM.009)
# 7. settings.json hooks ↔ .claude/hooks/ cross-ref (issue #13)

set -euo pipefail

TEMPLATE_DIR="${1:-$HOME/IWE/FMT-exocortex-template}"
FAIL=0

echo "=== Validating: $TEMPLATE_DIR ==="

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

# 2. Нет захардкоженных /Users/ путей (исключаем: шаблонные /Users/.../,
#    validate-template.sh (мета-проверки), setup.sh (примеры вида /Users/alice/))
echo -n "[2/5] Hardcoded /Users/ paths... "
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

# 3. Нет захардкоженных /opt/homebrew путей (кроме README, CI, PATH в plist,
#    validate-template.sh (мета-проверки), setup.sh (fallback default),
#    PLATFORM-COMPAT.md (документация о совместимости))
echo -n "[3/5] Hardcoded /opt/homebrew paths... "
count=$(grep -rn '/opt/homebrew' "$TEMPLATE_DIR" --include="*.md" --include="*.sh" \
        --include="*.json" --include="*.plist" \
        --exclude='validate-template.sh' --exclude='setup.sh' 2>/dev/null \
        | grep -v 'README.md' \
        | grep -v 'PLATFORM-COMPAT.md' \
        | grep -v 'validate-template.yml' \
        | grep -v '/usr/local/bin.*:/opt/homebrew' \
        | wc -l | tr -d ' ' || true)
if [ "$count" -gt 0 ]; then
    echo "FAIL ($count hits)"
    grep -rn '/opt/homebrew' "$TEMPLATE_DIR" --include="*.md" --include="*.sh" \
        --exclude='validate-template.sh' --exclude='setup.sh' 2>/dev/null \
        | grep -v 'README.md' | grep -v 'PLATFORM-COMPAT.md' \
        | grep -v 'validate-template.yml' | head -3 || true
    FAIL=1
else
    echo "PASS"
fi

# 4. MEMORY.md — скелет (≤15 строк в таблице)
echo -n "[4/5] MEMORY.md is skeleton... "
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
# вместо абсолютных путей к FMT-exocortex-template/scripts|roles.
echo -n "[6/6] Hardcoded script paths in protocols/skills... "
CHECK6_FAIL=0
CHECK6_FILES=""
for pattern in 'FMT-exocortex-template/scripts' 'FMT-exocortex-template/roles/[a-z]*/scripts'; do
    hits=$(grep -rnE "$pattern" \
            "$TEMPLATE_DIR/memory" \
            "$TEMPLATE_DIR/.claude/skills" \
            --include="*.md" 2>/dev/null \
            | grep -v '\$IWE_' || true)
    if [ -n "$hits" ]; then
        [ "$CHECK6_FAIL" -eq 0 ] && echo "FAIL"
        echo "  Pattern '$pattern' found (должен быть \$IWE_SCRIPTS / \$IWE_ROLES):"
        echo "$hits" | head -3
        CHECK6_FAIL=1
        FAIL=1
    fi
done
[ "$CHECK6_FAIL" -eq 0 ] && echo "PASS"

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
