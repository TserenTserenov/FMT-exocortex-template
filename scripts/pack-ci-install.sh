#!/usr/bin/env bash
# routing: utility  deterministic=true
# see DP.SC.159, DP.ROLE.059
# Installs CI guard (ID collision detector) into all Pack-repos in ~/IWE/
# Usage: bash pack-ci-install.sh [--dry-run]
# Source: WP-5 F-pack-ci-auto-setup (18 May 2026)

set -euo pipefail

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

IWE_DIR="${IWE_DIR:-$HOME/IWE}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$TEMPLATE_DIR/pack-templates/.github"

if [ ! -d "$SRC" ]; then
  echo "ERROR: CI guard template CI guard not found: $SRC"
  exit 1
fi

INSTALLED=0
SKIPPED=0
FAILED=0

for pack_dir in "$IWE_DIR"/PACK-*/; do
  [ -d "$pack_dir" ] || continue
  pack_name=$(basename "$pack_dir")

  # Check whether — this is a git git-repo?
  if ! git -C "$pack_dir" rev-parse --git-dir &>/dev/null; then
    echo "  ⚠️  $pack_name — not a git git-repo, skipping"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Guard already present?
  if [ -f "$pack_dir/.github/workflows/pack-lint.yml" ]; then
    echo "  ✅ $pack_name — guard already installed"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  echo "  📦 $pack_name — installing guard..."

  if $DRY_RUN; then
    echo "     [DRY RUN] cp -r $SRC $pack_dir/"
    INSTALLED=$((INSTALLED + 1))
    continue
  fi

  if cp -r "$SRC" "$pack_dir/" && \
     git -C "$pack_dir" add .github/ && \
     git -C "$pack_dir" commit -m "feat(ci): pack-lint R4 — ID collision detector" && \
     git -C "$pack_dir" push; then
    echo "     ✅ installed and pushed"
    INSTALLED=$((INSTALLED + 1))
  else
    echo "     ❌ error during installation"
    FAILED=$((FAILED + 1))
  fi
done

echo ""
echo "Summary: installed=$INSTALLED, skipped=$SKIPPED, errors=$FAILED"
[ "$FAILED" -eq 0 ] && exit 0 || exit 1
