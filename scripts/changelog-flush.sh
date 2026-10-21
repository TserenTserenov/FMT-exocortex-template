#!/usr/bin/env bash
# routing: helper  skill=week-close  called-by=haiku
# see DP.SC.159, DP.ROLE.059
# changelog-flush.sh — renames [Unreleased] → to a specific version in CHANGELOG.md
#
# Usage:
#   bash changelog-flush.sh --version 0.31.0 [--dry-run]
#
# If [Unreleased] is absent — first run changelog-append.sh.

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
    echo "Usage: $0 --version X.Y.Z [--dry-run]" >&2
    exit 1
fi

# #9 High-2 (review Phase14): after the first flush empty heading [Unreleased]
# remains forever — the check «heading exists» would become dead code and
# would allow stamping out empty releases. The guard requires NON-EMPTY content
# between [Unreleased] and the next versioned heading.
UNRELEASED_CONTENT=$(awk '
    /^## \[Unreleased\]/ { in_u=1; next }
    in_u && /^## \[/ { exit }
    in_u && NF { print }
' "$CHANGELOG" 2>/dev/null)
if [ -z "$UNRELEASED_CONTENT" ]; then
    echo "⚠️  Section [Unreleased] is empty or missing. First run: IWE_TEMPLATE=\"$FMT_DIR\" bash \"$FMT_DIR/scripts/changelog-append.sh\"" >&2
    exit 1
fi

today=$(date +%Y-%m-%d)
new_header="## [$version] — $today"

if $dry_run; then
    echo "dry-run: replace '## [Unreleased] — ...' → '$new_header'"
    grep '## \[Unreleased\]' "$CHANGELOG"
    exit 0
fi

# 2026-08-23 (live failure before v0.38.8): flush RENAMED the heading
# [Unreleased] to the version — the section disappeared, changelog-append wrote into a void,
# the next bump saw nothing to release. awk instead of sed: the heading remains «nothing to release». awk instead of sed: header remains
# in place with an empty section, the version is inserted as a new section below it
# (newlines in replacement are not portable between GNU and BSD sed).
_flush_tmp="$CHANGELOG.flush.$$"
awk -v hdr="$new_header" '
    !done && /^## \[Unreleased\]/ { print "## [Unreleased]"; print ""; print hdr; done=1; next }
    { print }
' "$CHANGELOG" > "$_flush_tmp" && mv "$_flush_tmp" "$CHANGELOG" || {
    echo "❌ flush not applied (failure awk/mv)" >&2
    rm -f "$_flush_tmp"
    exit 1
}

echo "✅ [Unreleased] → [$version] ($today), empty header [Unreleased] preserved"
echo "Next step:"
echo "  cd $FMT_DIR && git add CHANGELOG.md && git commit -m 'chore: release v$version'"
