#!/usr/bin/env bash
# routing: helper  skill=week-close  called-by=haiku
# see DP.SC.159, DP.ROLE.059
# changelog-flush.sh — переименовывает [Unreleased] → конкретную версию в CHANGELOG.md
#
# Использование:
#   bash changelog-flush.sh --version 0.31.0 [--dry-run]
#
# Если [Unreleased] нет — сначала вызвать changelog-append.sh.

set -uo pipefail

FMT_DIR="${IWE_TEMPLATE:-${IWE_WORKSPACE:-$HOME/IWE}/FMT-exocortex-template}"
CHANGELOG="$FMT_DIR/CHANGELOG.md"
dry_run=false
version=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) dry_run=true ;;
        --version) version="${2:-}"; shift ;;
    esac
    shift
done

if [[ -z "$version" ]]; then
    echo "Использование: $0 --version X.Y.Z [--dry-run]" >&2
    exit 1
fi

if ! grep -q '## \[Unreleased\]' "$CHANGELOG" 2>/dev/null; then
    echo "⚠️  Блок [Unreleased] не найден. Сначала запусти: bash changelog-append.sh" >&2
    exit 1
fi

today=$(date +%Y-%m-%d)
new_header="## [$version] — $today"

if $dry_run; then
    echo "dry-run: заменить '## [Unreleased] — ...' → '$new_header'"
    grep '## \[Unreleased\]' "$CHANGELOG"
    exit 0
fi

# Кросс-платформенный wrapper (docs/PLATFORM-COMPAT.md)
# macOS BSD sed: exit 0 но без "GNU" в выводе
if sed --version 2>&1 | grep -q GNU; then
    sed_inplace() { sed -i "$@"; }
else
    sed_inplace() { sed -i '' "$@"; }
fi
sed_inplace "s|## \[Unreleased\].*|$new_header|" "$CHANGELOG"

echo "✅ [Unreleased] → [$version] ($today)"
echo "Следующий шаг:"
echo "  cd $FMT_DIR && git add CHANGELOG.md && git commit -m 'chore: release v$version'"
