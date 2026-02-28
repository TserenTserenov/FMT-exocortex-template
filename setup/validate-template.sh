#!/bin/bash
# Validate Template — проверка целостности FMT-exocortex-template
#
# 5 проверок:
# 1. Нет автор-специфичного контента
# 2. Нет захардкоженных путей /Users/
# 3. Нет захардкоженных путей /opt/homebrew
# 4. MEMORY.md — скелет (мало строк в РП-таблице)
# 5. Обязательные файлы существуют

set -euo pipefail

TEMPLATE_DIR="${1:-$HOME/Github/FMT-exocortex-template}"
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
for pattern in "tserentserenov" "PACK-MIM" "aist_bot_newarchitecture" "DS-Knowledge-Index-Tseren"; do
    # Исключаем github.com URLs — это ссылки на публичные reference implementations
    count=$(grep -rn "$pattern" "$TEMPLATE_DIR" --include="*.md" --include="*.sh" \
            --include="*.json" --include="*.plist" --include="*.yaml" 2>/dev/null \
            | grep -v 'github.com/' | wc -l | tr -d ' ' || true)
    if [ "$count" -gt 0 ]; then
        [ "$CHECK1_FAIL" -eq 0 ] && echo "FAIL"
        echo "  Found '$pattern' in $count non-URL locations:"
        grep -rn "$pattern" "$TEMPLATE_DIR" --include="*.md" --include="*.sh" \
            --include="*.json" --include="*.plist" 2>/dev/null | grep -v 'github.com/' | head -3 || true
        CHECK1_FAIL=1
        FAIL=1
    fi
done
[ "$CHECK1_FAIL" -eq 0 ] && echo "PASS"

# 2. Нет захардкоженных /Users/ путей (исключаем шаблонные примеры вида /Users/.../)
echo -n "[2/5] Hardcoded /Users/ paths... "
count=$(grep -rn '/Users/' "$TEMPLATE_DIR" --include="*.md" --include="*.sh" \
        --include="*.json" --include="*.plist" 2>/dev/null \
        | grep -v '/Users/\.\.\./' | wc -l | tr -d ' ' || true)
if [ "$count" -gt 0 ]; then
    echo "FAIL ($count hits)"
    grep -rn '/Users/' "$TEMPLATE_DIR" --include="*.md" --include="*.sh" 2>/dev/null \
        | grep -v '/Users/\.\.\./' | head -3 || true
    FAIL=1
else
    echo "PASS"
fi

# 3. Нет захардкоженных /opt/homebrew путей (кроме README примеров, CI и PATH в plist)
echo -n "[3/5] Hardcoded /opt/homebrew paths... "
count=$(grep -rn '/opt/homebrew' "$TEMPLATE_DIR" --include="*.md" --include="*.sh" \
        --include="*.json" --include="*.plist" 2>/dev/null \
        | grep -v 'README.md' \
        | grep -v 'validate-template.yml' \
        | grep -v '/usr/local/bin.*:/opt/homebrew' \
        | wc -l | tr -d ' ' || true)
if [ "$count" -gt 0 ]; then
    echo "FAIL ($count hits)"
    grep -rn '/opt/homebrew' "$TEMPLATE_DIR" --include="*.md" --include="*.sh" 2>/dev/null \
        | grep -v 'README.md' | grep -v 'validate-template.yml' | head -3 || true
    FAIL=1
else
    echo "PASS"
fi

# 4. MEMORY.md — скелет (≤15 строк в таблице)
echo -n "[4/5] MEMORY.md is skeleton... "
MEMORY_FILE="$TEMPLATE_DIR/memory/MEMORY.md"
if [ -f "$MEMORY_FILE" ]; then
    rp_rows=$(grep -c '^|' "$MEMORY_FILE" 2>/dev/null || echo 0)
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
         strategist-agent/scripts/strategist.sh; do
    if [ ! -f "$TEMPLATE_DIR/$f" ]; then
        echo ""
        echo "  MISSING: $f"
        MISSING=1
        FAIL=1
    fi
done
[ "$MISSING" -eq 0 ] && echo "PASS"

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "=== ALL CHECKS PASSED ==="
    exit 0
else
    echo "=== VALIDATION FAILED ==="
    exit 1
fi
