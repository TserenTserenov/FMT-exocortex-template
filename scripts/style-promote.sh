#!/usr/bin/env bash
# routing: utility  deterministic=true
# see DP.SC.159, DP.ROLE.059
# style-promote.sh — promote a style snapshot file to the IWE platform template
#
# Flow: personal folder/.claude/styles/<file>.md → substitutions → FMT/.claude/styles/<file>.md
#
# Usage:
#   bash style-promote.sh <path-to-style-file> [--dry-run]
#
# Style files: markdown with YAML frontmatter, content after the second ---.
# Difference from hook-promote: no chmod +x; smoke test — frontmatter check + non-empty content.

set -uo pipefail

SRC="${1:-}"
dry_run=false
[[ "${2:-}" == "--dry-run" ]] && dry_run=true

if [[ -z "$SRC" || ! -f "$SRC" ]]; then
    echo "Использование: $0 <путь-к-файлу-стиля> [--dry-run]" >&2
    exit 1
fi

IWE="${IWE_WORKSPACE:-$HOME/IWE}"
FMT_DIR="${IWE_TEMPLATE:-$IWE/FMT-exocortex-template}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fname=$(basename "$SRC")
DEST="$FMT_DIR/.claude/styles/$fname"

echo "🔄 Промоция файла стиля: $fname"
echo "   Откуда: $SRC"
echo "   Куда:   $DEST"
echo ""

# Substitutions of personal paths → template variables
GOV_REPO_AUTHOR="${IWE_GOVERNANCE_REPO:-DS-strategy}"
GOV_REPO_TMPL="DS-strategy"

result=$(sed \
    -e "s|$HOME/IWE|\${IWE:-\$HOME/IWE}|g" \
    -e "s|$HOME|\$HOME|g" \
    -e "s|$GOV_REPO_AUTHOR|\${IWE_GOVERNANCE_REPO:-$GOV_REPO_TMPL}|g" \
    "$SRC")

if $dry_run; then
    echo "--- dry-run: результат после подстановок ---"
    printf '%s\n' "$result"
    echo "--- конец ---"
    exit 0
fi

# Style file smoke check:
# 1. There must be at least 2 lines with "---" (frontmatter)
# 2. Content after the frontmatter is not empty (>100 characters)
frontmatter_count=$(printf '%s\n' "$result" | grep -c "^---$" || true)
content_after=$(printf '%s\n' "$result" | awk '/^---$/{n++; if(n==2){found=1; next}} found' 2>/dev/null)
content_len=${#content_after}

if [[ "$frontmatter_count" -lt 2 ]]; then
    echo "❌ Smoke-проверка: не найден YAML frontmatter (нужно минимум 2 строки ---)" >&2
    exit 1
fi

if [[ "$content_len" -lt 100 ]]; then
    echo "❌ Smoke-проверка: контент после frontmatter слишком мал ($content_len символов < 100)" >&2
    exit 1
fi
echo "   smoke-check: OK (frontmatter: ${frontmatter_count}×---, контент: ${content_len} символов)"

# Create the directory if missing
mkdir -p "$FMT_DIR/.claude/styles"

# Write the file
printf '%s\n' "$result" > "$DEST"

echo "✅ Промотирован: FMT/.claude/styles/$fname"

# Write to promotion-status.yaml via the shared library
COMMON="$SCRIPT_DIR/promote-common.sh"
if [[ -f "$COMMON" ]]; then
    # shellcheck source=promote-common.sh
    source "$COMMON"
    source_sha=$(cd "$(dirname "$SRC")" && git rev-parse --short HEAD 2>/dev/null || echo "")
    record_promotion ".claude/styles/$fname" "style" "$source_sha" "" "true"
fi

echo ""
echo "Следующий шаг:"
echo "  cd $FMT_DIR && git add .claude/styles/$fname promotion-status.yaml && git commit -m 'feat(styles): promote $fname to platform'"
