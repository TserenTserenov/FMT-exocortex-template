#!/usr/bin/env bash
# routing: helper  skill=week-close  called-by=haiku
# see DP.SC.159, DP.ROLE.059
# changelog-flush.sh — renames [Unreleased] → a concrete version in CHANGELOG.md
#
# Usage:
#   bash changelog-flush.sh --version 0.31.0 [--dry-run]
#
# If there is no [Unreleased] — call changelog-append.sh first.

set -uo pipefail

FMT_DIR="${IWE_TEMPLATE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
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

# #9 High-2 (review Phase 14): after the first flush an empty [Unreleased] header
# stays forever — the "header exists" check would become dead and
# allow minting empty releases. The guard requires NON-EMPTY content
# between [Unreleased] and the next version header.
UNRELEASED_CONTENT=$(awk '
    /^## \[Unreleased\]/ { in_u=1; next }
    in_u && /^## \[/ { exit }
    in_u && NF { print }
' "$CHANGELOG" 2>/dev/null)
if [ -z "$UNRELEASED_CONTENT" ]; then
    echo "⚠️  Секция [Unreleased] пуста или отсутствует. Сначала запусти: IWE_TEMPLATE=\"$FMT_DIR\" bash \"$FMT_DIR/scripts/changelog-append.sh\"" >&2
    exit 1
fi

today=$(date +%Y-%m-%d)
new_header="## [$version] — $today"

if $dry_run; then
    echo "dry-run: заменить '## [Unreleased] — ...' → '$new_header'"
    grep '## \[Unreleased\]' "$CHANGELOG"
    exit 0
fi

# 2026-08-23 (live failure before v0.38.8): flush RENAMED the [Unreleased]
# header to a version — the section vanished, changelog-append wrote into the void,
# the next bump saw "nothing to release". awk instead of sed: the header stays
# in place as an empty section, the version is inserted as a new section under it
# (line breaks in a replacement are not portable between GNU and BSD sed).
_flush_tmp="$CHANGELOG.flush.$$"
awk -v hdr="$new_header" '
    !done && /^## \[Unreleased\]/ { print "## [Unreleased]"; print ""; print hdr; done=1; next }
    { print }
' "$CHANGELOG" > "$_flush_tmp" && mv "$_flush_tmp" "$CHANGELOG" || {
    echo "❌ flush не применён (сбой awk/mv)" >&2
    rm -f "$_flush_tmp"
    exit 1
}

echo "✅ [Unreleased] → [$version] ($today), пустой заголовок [Unreleased] сохранён"
echo "Следующий шаг:"
echo "  cd $FMT_DIR && git add CHANGELOG.md && git commit -m 'chore: release v$version'"
