#!/usr/bin/env bash
# routing: utility  deterministic=true
# see DP.SC.159, DP.ROLE.059
# hook-promote.sh — promotion of a personal hook into a platform template IWE
#
# Flow: personal folder/<hook>.sh → substitutions → FMT/.claude/hooks/<hook>.sh
#
# Usage:
#   bash hook-promote.sh <path-to-hook> [--dry-run]

set -uo pipefail

SRC="${1:-}"
dry_run=false
[[ "${2:-}" == "--dry-run" ]] && dry_run=true

if [[ -z "$SRC" || ! -f "$SRC" ]]; then
    echo "Usage: $0 <path-to-hook> [--dry-run]" >&2
    exit 1
fi

IWE="${IWE_WORKSPACE:-$HOME/IWE}"
FMT_DIR="${IWE_TEMPLATE:-$IWE/IWE}"
GOV_REPO_AUTHOR="${IWE_GOVERNANCE_REPO:-DS-strategy}"
GOV_REPO_TMPL="DS-strategy"

fname=$(basename "$SRC")
DEST="$FMT_DIR/.claude/hooks/$fname"

echo "🔄 Promoting hook: $fname"
echo "   From: $SRC"
echo "   To:   $DEST"
echo ""

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

# Validation via temporary file
tmp_dir=$(mktemp -d)
tmp_file="$tmp_dir/$fname"
printf '%s\n' "$result" > "$tmp_file"
chmod +x "$tmp_file"

VALIDATOR="$FMT_DIR/scripts/validate-fmt-scripts.sh"
if [[ -f "$VALIDATOR" ]]; then
    if ! bash "$VALIDATOR" "$tmp_dir" 2>&1; then
        rm -rf "$tmp_dir"
        echo "❌ Personal hardcoded values remain after substitutions. Use --dry-run." >&2
        exit 1
    fi
fi

# Smoke-test in isolated env with template variables
echo "   smoke-test smoke-test with template environment..."
smoke_result=0
env -i \
    HOME="/tmp/iwe-smoke-user" \
    IWE="/tmp/iwe-smoke-user/IWE" \
    IWE_GOVERNANCE_REPO="DS-strategy" \
    PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" \
    bash "$tmp_file" --help > /dev/null 2>&1 || smoke_result=$?

if [[ $smoke_result -eq 127 ]]; then
    rm -rf "$tmp_dir"
    echo "❌ Smoke-test: exit 127 — hook does not start in a foreign environment." >&2
    exit 1
fi
echo "   smoke-test: OK (exit $smoke_result)"

cp "$tmp_file" "$DEST"
chmod +x "$DEST"
rm -rf "$tmp_dir"

echo "✅ Promoted: FMT/.claude/hooks/$fname"

CHANGELOG_SCRIPT="$FMT_DIR/scripts/changelog-append.sh"
if [[ -f "$CHANGELOG_SCRIPT" ]]; then IWE_TEMPLATE="$FMT_DIR" bash "$CHANGELOG_SCRIPT"; fi

MANIFEST_SCRIPT="$FMT_DIR/generate-manifest.sh"
if [[ -f "$MANIFEST_SCRIPT" ]]; then
    echo "🔄 Rebuilding update-manifest.json..."
    bash "$MANIFEST_SCRIPT" 2>&1
else
    echo "⚠️  generate-manifest.sh not found — update update-manifest.json manually"
fi

echo "Next step:"
echo "  cd $FMT_DIR && git add .claude/hooks/$fname CHANGELOG.md update-manifest.json && git commit -m 'feat: promote $fname to platform'"
