#!/usr/bin/env bash
# routing: utility  deterministic=true
# see DP.SC.159, DP.ROLE.059
# style-promote.sh — promotion of file-style snapshot into platform template IWE
#
# Flow: personal folder/.claude/styles/<file>.md → substitutions → FMT/.claude/styles/<file>.md
#
# Usage:
#   bash style-promote.sh <path-to-file-style> [--dry-run]
#
# Style files: markdown with YAML frontmatter, content after the second ---.
# Difference from hook-promote: no chmod +x; smoke — validation frontmatter + non-empty content.

set -uo pipefail

SRC="${1:-}"
dry_run=false
[[ "${2:-}" == "--dry-run" ]] && dry_run=true

if [[ -z "$SRC" || ! -f "$SRC" ]]; then
    echo "Usage: $0 <path-to-file-style> [--dry-run]" >&2
    exit 1
fi

IWE="${IWE_WORKSPACE:-$HOME/IWE}"
FMT_DIR="${IWE_TEMPLATE:-$IWE/IWE}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fname=$(basename "$SRC")
DEST="$FMT_DIR/.claude/styles/$fname"

echo "🔄 Promoting style file: $fname"
echo "   From: $SRC"
echo "   To:   $DEST"
echo ""

# Personal path substitutions → template variables
GOV_REPO_AUTHOR="${IWE_GOVERNANCE_REPO:-DS-strategy}"
GOV_REPO_TMPL="DS-strategy"

result=$(sed \
    -e "s|$HOME/IWE|\${IWE:-\$HOME/IWE}|g" \
    -e "s|$HOME|\$HOME|g" \
    -e "s|$GOV_REPO_AUTHOR|\${IWE_GOVERNANCE_REPO:-$GOV_REPO_TMPL}|g" \
    "$SRC")

if $dry_run; then
    echo "--- dry-run: result after substitutions ---"
    printf '%s\n' "$result"
    echo "--- end ---"
    exit 0
fi

# Smoke-style file validation:
# 1. There must be at least 2 lines with "---" (frontmatter)
# 2. Content after frontmatter is not empty (>100 characters)
frontmatter_count=$(printf '%s\n' "$result" | grep -c "^---$" || true)
content_after=$(printf '%s\n' "$result" | awk '/^---$/{n++; if(n==2){found=1; next}} found' 2>/dev/null)
content_len=${#content_after}

if [[ "$frontmatter_count" -lt 2 ]]; then
    echo "❌ Smoke-check: YAML frontmatter not found YAML frontmatter (at least 2 lines ---)" >&2
    exit 1
fi

if [[ "$content_len" -lt 100 ]]; then
    echo "❌ Smoke-check: content after frontmatter too small ($content_len characters < 100)" >&2
    exit 1
fi
echo "   smoke-check: OK (frontmatter: ${frontmatter_count}×---, content: ${content_len} characters)"

# Create directory if it does not exist
mkdir -p "$FMT_DIR/.claude/styles"

# Write file
printf '%s\n' "$result" > "$DEST"

echo "✅ Promoted: FMT/.claude/styles/$fname"

# Writing to promotion-status.yaml via shared library
COMMON="$SCRIPT_DIR/promote-common.sh"
if [[ -f "$COMMON" ]]; then
    # shellcheck source=promote-common.sh
    source "$COMMON"
    source_sha=$(cd "$(dirname "$SRC")" && git rev-parse --short HEAD 2>/dev/null || echo "")
    record_promotion ".claude/styles/$fname" "style" "$source_sha" "" "true"
fi

echo ""
echo "Next step:"
echo "  cd $FMT_DIR && git add .claude/styles/$fname promotion-status.yaml && git commit -m 'feat(styles): promote $fname to platform'"
