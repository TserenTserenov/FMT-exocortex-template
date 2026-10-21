#!/usr/bin/env bash
# routing: utility  deterministic=true
# see VR.SC.006 (release-verification-protocol)
#
# sync-version-badge.sh — synchronization version badge in README.md with CHANGELOG.md
#
# Usage:
#   bash sync-version-badge.sh --check    # check drift (CI gate)
#   bash sync-version-badge.sh --fix      # fix drift (locally / pre-commit)
#   bash sync-version-badge.sh            # --fix default

set -uo pipefail

MODE="${1:---fix}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CHANGELOG="$REPO_ROOT/CHANGELOG.md"
README="$REPO_ROOT/README.md"

if [[ ! -f "$CHANGELOG" ]]; then
    echo "FAIL: CHANGELOG.md not found ($CHANGELOG)" >&2
    exit 1
fi

if [[ ! -f "$README" ]]; then
    echo "FAIL: README.md not found ($README)" >&2
    exit 1
fi

# Extracting the latest version from CHANGELOG (first line ## [X.Y.Z])
CHANGELOG_VERSION=$(grep -m1 -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' "$CHANGELOG" \
    | sed 's/^## \[//;s/\]$//' || true)

if [[ -z "$CHANGELOG_VERSION" ]]; then
    echo "FAIL: failed to extract version from CHANGELOG.md" >&2
    exit 1
fi

# Extracting version from README badge
README_VERSION=$(grep -oE 'version-[0-9]+\.[0-9]+\.[0-9]+' "$README" \
    | sed 's/version-//' | head -n1 || true)

if [[ -z "$README_VERSION" ]]; then
    echo "WARN: version badge not found in README.md" >&2
    # If the badge is absent — this is not an error in check, but also not PASS
    exit 0
fi

if [[ "$CHANGELOG_VERSION" == "$README_VERSION" ]]; then
    echo "PASS: version badge sync ($CHANGELOG_VERSION)"
    exit 0
fi

echo "FAIL: version mismatch!"
echo "  CHANGELOG.md top: $CHANGELOG_VERSION"
echo "  README.md badge:  $README_VERSION"

if [[ "$MODE" == "--check" ]]; then
    echo "  Fix: run bash scripts/sync-version-badge.sh --fix"
    exit 1
fi

if [[ "$MODE" == "--fix" ]]; then
    # Updating badge in README
    # -E (not BRE \+): BSD sed on macOS does not support \+ — silently does not match, 0 replacements without error.
    sed -E -i.bak \
        -e "s/version-[0-9]+\.[0-9]+\.[0-9]+/version-$CHANGELOG_VERSION/g" \
        "$README"
    rm -f "$README.bak"
    echo "  FIX: README.md updated to $CHANGELOG_VERSION"
    echo "  Next step: git add README.md && git commit --amend / separate commit"
    exit 0
fi

echo "Usage: $0 [--check | --fix]" >&2
exit 1
