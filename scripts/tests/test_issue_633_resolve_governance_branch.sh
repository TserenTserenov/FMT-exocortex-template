#!/bin/bash
# Regression test for issue #633: extractor.sh hardcoded 'main' as the
# governance repo's default branch in eight places, so inbox-check silently
# never ran on a repo whose real default branch was e.g. 'master'.
#
# Extracts resolve_governance_branch() straight out of the real extractor.sh
# (instead of sourcing the whole file) because that file guards against
# direct execution from the raw FMT checkout and requires a built runtime
# with an authenticated claude CLI -- neither of which this test needs.
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/roles/extractor/scripts/extractor.sh"
FUNC_SRC=$(awk '/^resolve_governance_branch\(\) \{/,/^}/' "$SCRIPT")
if [ -z "$FUNC_SRC" ]; then
    echo "FAIL: resolve_governance_branch() not found in $SCRIPT"
    exit 1
fi
eval "$FUNC_SRC"

FAIL=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

git init -q -b master "$TMP/bare-src"
git -C "$TMP/bare-src" config user.email "test@example.invalid"
git -C "$TMP/bare-src" config user.name "Issue 633 regression"
git -C "$TMP/bare-src" commit -q --allow-empty -m init
git clone -q "$TMP/bare-src" "$TMP/clone"
resolved=$(unset IWE_GOVERNANCE_BRANCH; resolve_governance_branch "$TMP/clone")
if [ "$resolved" = "master" ]; then
    echo "PASS: resolves 'master' from origin/HEAD when no override is set"
else
    echo "FAIL: expected 'master', got '$resolved'"
    FAIL=1
fi

git init -q -b main "$TMP/main-repo"
resolved=$(IWE_GOVERNANCE_BRANCH=custom resolve_governance_branch "$TMP/main-repo")
if [ "$resolved" = "custom" ]; then
    echo "PASS: IWE_GOVERNANCE_BRANCH override takes precedence"
else
    echo "FAIL: expected 'custom', got '$resolved'"
    FAIL=1
fi

git init -q -b feature-x "$TMP/no-remote"
resolved=$(unset IWE_GOVERNANCE_BRANCH; resolve_governance_branch "$TMP/no-remote")
if [ "$resolved" = "feature-x" ]; then
    echo "PASS: falls back to the checked-out branch when there is no origin/HEAD"
else
    echo "FAIL: expected 'feature-x', got '$resolved'"
    FAIL=1
fi

exit $FAIL
