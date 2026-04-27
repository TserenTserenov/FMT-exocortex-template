#!/bin/bash
# integration-contract-validator.sh — детектор Spec↔State drift.
#
# WP-273 R4.8 (proposal Евгения, Round 4 red-team). Закрывает 4-й системный корень:
# докуменация говорит А, код делает Б — нужен автоматический детектор расхождений
# до релиза.
#
# 4 детектора:
#   1. manifest_paths    — пути из update-manifest.json существуют в дереве
#   2. seed_references   — protocol-*.md ссылки на seed/ существуют в seed/
#   3. extension_table   — extensions/README.md table ↔ реальное placement EXTENSION POINT в protocol-*/SKILL.md
#   4. hook_artifact     — .claude/hooks/*.sh не грепают TOOL_INPUT (антипаттерн R4.5)
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
verbose() { $VERBOSE && echo "  $@" || true; }

log "=== Integration Contract Validator (WP-273 R4.8) ==="
log ""

# === Detector 1: manifest paths existence ===
log "[1/4] manifest_paths — пути из update-manifest.json в дереве..."
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
log "[2/4] seed_references — protocol-*.md ссылки на seed/ существуют..."
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
log "[3/4] extension_table — extensions/README.md table ↔ EXTENSION POINT в protocol-*.md/SKILL.md..."
EXT_VIOLATIONS=0
if [ -f extensions/README.md ]; then
    # Parse extension table from README.md: lines like "| protocol-close | checks | ..."
    declare_table=$(grep -E '^\|\s*`?[a-z][a-z-]*`?\s*\|\s*`?[a-z]+`?\s*\|' extensions/README.md 2>/dev/null | head -20 || true)

    # Find actual EXTENSION POINT references in protocols/skills
    real_eps=$(grep -hroE 'EXTENSION POINT[^`]*`extensions/[a-z-]+\.[a-z]+\.md`' memory/protocol-*.md .claude/skills/*/SKILL.md 2>/dev/null | grep -oE 'extensions/[a-z-]+\.[a-z]+\.md' | sort -u || true)

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
log "[4/4] hook_artifact — hooks не грепают TOOL_INPUT (R4.5 антипаттерн)..."
HOOK_VIOLATIONS=0
if [ -d .claude/hooks ]; then
    while IFS= read -r f; do
        # Pattern: TOOL_INPUT непосредственно через grep
        if grep -qE 'TOOL_INPUT.*\|.*grep' "$f" 2>/dev/null; then
            log "  ⚠ $f: grep TOOL_INPUT (нарушает hooks-design.md)"
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
