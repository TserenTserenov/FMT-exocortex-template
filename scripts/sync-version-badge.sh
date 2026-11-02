#!/usr/bin/env bash
# routing: utility  deterministic=true
# see VR.SC.006 (release-verification-protocol)
#
# sync-version-badge.sh — sync of the version badge in README.md with CHANGELOG.md
#
# Usage:
#   bash sync-version-badge.sh --check    # drift check (CI gate)
#   bash sync-version-badge.sh --fix      # drift fix (locally / pre-commit)
#   bash sync-version-badge.sh            # --fix by default

set -uo pipefail

MODE="${1:---fix}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CHANGELOG="$REPO_ROOT/CHANGELOG.md"
README="$REPO_ROOT/README.md"

if [[ ! -f "$CHANGELOG" ]]; then
    echo "FAIL: CHANGELOG.md не найден ($CHANGELOG)" >&2
    exit 1
fi

if [[ ! -f "$README" ]]; then
    echo "FAIL: README.md не найден ($README)" >&2
    exit 1
fi

# Extract the latest version from CHANGELOG (first line ## [X.Y.Z])
CHANGELOG_VERSION=$(grep -m1 -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' "$CHANGELOG" \
    | sed 's/^## \[//;s/\]$//' || true)

if [[ -z "$CHANGELOG_VERSION" ]]; then
    echo "FAIL: не удалось извлечь версию из CHANGELOG.md" >&2
    exit 1
fi

# Extract the version from the README badge
README_VERSION=$(grep -oE 'version-[0-9]+\.[0-9]+\.[0-9]+' "$README" \
    | sed 's/version-//' | head -n1 || true)

if [[ -z "$README_VERSION" ]]; then
    echo "WARN: version badge не найден в README.md" >&2
    # If there is no badge — not an error in check mode, but not a PASS either
    exit 0
fi

if [[ "$CHANGELOG_VERSION" == "$README_VERSION" ]]; then
    echo "PASS: version badge sync ($CHANGELOG_VERSION)"
    exit 0
fi

echo "FAIL: рассинхрон версий!"
echo "  CHANGELOG.md top: $CHANGELOG_VERSION"
echo "  README.md badge:  $README_VERSION"

if [[ "$MODE" == "--check" ]]; then
    echo "  Fix: запусти bash scripts/sync-version-badge.sh --fix"
    exit 1
fi

if [[ "$MODE" == "--fix" ]]; then
    # Update the badge in README
    # -E (not BRE \+): BSD sed on macOS does not support \+ — silently does not match, 0 replacements without an error.
    sed -E -i.bak \
        -e "s/version-[0-9]+\.[0-9]+\.[0-9]+/version-$CHANGELOG_VERSION/g" \
        "$README"
    rm -f "$README.bak"
    echo "  FIX: README.md обновлен до $CHANGELOG_VERSION"
    echo "  Следующий шаг: git add README.md && git commit --amend / отдельный коммит"
    exit 0
fi

echo "Использование: $0 [--check | --fix]" >&2
exit 1
