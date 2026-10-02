#!/usr/bin/env bash
# Regression coverage for issue #913: generate-skills-catalog.sh's
# build_invoked_by() ran `find "$PROTOCOLS_DIR" -name "protocol-*.md"` without
# a trailing slash. On a stock install `memory/` is a symlink to auto-memory
# (a junction on Windows), and `find` does not descend into a symlinked start
# point without a trailing slash -- 0 protocols found instead of 5, silently
# dropping every skill's "used in protocol" catalog entry.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
SCRIPT="$ROOT/scripts/generate-skills-catalog.sh"

fail=0
pass() { echo "  ✅ PASS: $*"; }
fail_test() { echo "  ❌ FAIL: $*" >&2; fail=1; }

# Source line must find files through a symlinked start point.
if grep -qE 'find "\$PROTOCOLS_DIR/"' "$SCRIPT"; then
    pass "PROTOCOLS_DIR lookup uses a trailing slash (descends into a symlink)"
else
    fail_test "PROTOCOLS_DIR lookup is missing the trailing slash fix"
fi

# Live behavioral proof, independent of the source text above: build a real
# symlinked directory and confirm plain `find DIR` misses it while `find DIR/`
# does not -- the same distinction the fix relies on.
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT
mkdir -p "$TMPDIR_TEST/real-memory"
: > "$TMPDIR_TEST/real-memory/protocol-open.md"
ln -s "$TMPDIR_TEST/real-memory" "$TMPDIR_TEST/memory"

without_slash=$(find "$TMPDIR_TEST/memory" -name "protocol-*.md" 2>/dev/null | wc -l | tr -d ' ')
with_slash=$(find "$TMPDIR_TEST/memory/" -name "protocol-*.md" 2>/dev/null | wc -l | tr -d ' ')

if [ "$without_slash" -eq 0 ] && [ "$with_slash" -eq 1 ]; then
    pass "live symlink probe reproduces the bug (0 without slash) and confirms the fix (1 with slash)"
else
    fail_test "live symlink probe did not reproduce the expected without=0/with=1 split (got without=$without_slash with=$with_slash)"
fi

if [ "$fail" -eq 0 ]; then
    echo "✅ test_issue_913_skills_catalog_symlink: all checks passed"
fi
exit "$fail"
