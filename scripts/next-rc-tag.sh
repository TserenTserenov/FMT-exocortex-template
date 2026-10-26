#!/usr/bin/env bash
# WP-529 Ф239: print the next release-candidate tag name for a version.
#
# Numbering is computed from REMOTE tags (a parallel workflow run is invisible
# to a local `git tag -l`), taking the maximum existing N — not the count:
# annotated tags make `git ls-remote --tags` print two lines per tag (the tag
# and its peeled ^{}), and deleted tags leave gaps, so count+1 would both
# double-increment and collide.
#
# Usage: next-rc-tag.sh <version> [remote]   # remote defaults to origin
# Output on stdout: vX.Y.Z-rc.N (next free N). Exit 1 on any lookup failure —
# the caller must not fall back to guessing a number.

set -euo pipefail

VERSION="${1:-}"
REMOTE="${2:-origin}"

case "$VERSION" in
    *[!0-9.]*|"") echo "usage: next-rc-tag.sh <numeric version> [remote]" >&2; exit 1 ;;
esac

REFS=$(git ls-remote --tags "$REMOTE" "v${VERSION}-rc.*") || {
    echo "next-rc-tag: git ls-remote $REMOTE failed" >&2
    exit 1
}

# grep exits 1 when nothing matches (no rc tags yet — the common first-run
# case); that empty result is valid input, not a failure, so do not let it
# trip `set -e`/`pipefail`.
MAX_N=$(printf '%s\n' "$REFS" \
    | { grep -o "refs/tags/v${VERSION}-rc\.[0-9]*$" || true; } \
    | sed 's/.*-rc\.//' \
    | sort -n \
    | tail -1)

# 10#$MAX_N: a tag numbered with a leading zero (rc.08) is octal to Bash
# arithmetic — force base 10 (cold review, iteration 2).
echo "v${VERSION}-rc.$(( 10#${MAX_N:-0} + 1 ))"
