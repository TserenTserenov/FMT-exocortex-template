#!/usr/bin/env bash
# routing: utility  deterministic=true
# see DP.SC.159, DP.ROLE.059
# Installs the CI guard (ID collision detector) into all Pack repos in ~/IWE/
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
  echo "ERROR: шаблон CI guard не найден: $SRC"
  exit 1
fi

INSTALLED=0
SKIPPED=0
FAILED=0

for pack_dir in "$IWE_DIR"/PACK-*/; do
  [ -d "$pack_dir" ] || continue
  pack_name=$(basename "$pack_dir")

  # Check — is it a git repo?
  if ! git -C "$pack_dir" rev-parse --git-dir &>/dev/null; then
    echo "  ⚠️  $pack_name — не git-репо, пропускаю"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Is there already a guard?
  if [ -f "$pack_dir/.github/workflows/pack-lint.yml" ]; then
    echo "  ✅ $pack_name — страж уже установлен"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  echo "  📦 $pack_name — устанавливаю страж..."

  if $DRY_RUN; then
    echo "     [DRY RUN] cp -r $SRC $pack_dir/"
    INSTALLED=$((INSTALLED + 1))
    continue
  fi

  if cp -r "$SRC" "$pack_dir/" && \
     git -C "$pack_dir" add .github/ && \
     git -C "$pack_dir" commit -m "feat(ci): pack-lint R4 — ID collision detector" && \
     git -C "$pack_dir" push; then
    echo "     ✅ установлен и запушен"
    INSTALLED=$((INSTALLED + 1))
  else
    echo "     ❌ ошибка при установке"
    FAILED=$((FAILED + 1))
  fi
done

echo ""
echo "Итог: установлено=$INSTALLED, пропущено=$SKIPPED, ошибок=$FAILED"
[ "$FAILED" -eq 0 ] && exit 0 || exit 1
