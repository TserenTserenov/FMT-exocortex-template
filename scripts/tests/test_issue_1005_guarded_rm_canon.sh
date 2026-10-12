#!/usr/bin/env bash
# Regression coverage for the macOS half of issue #1005: guarded-rm's canonical
# path resolution must accept a target whose last TWO OR MORE levels do not
# exist (as `realpath -m` does on Linux), and must keep resolving symlinks and
# ".." the way the filesystem does.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
SCRIPT="$ROOT/.claude/bin/guarded-rm"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
BASE=$(cd "$TMP" && pwd -P)

fail=0
pass() { echo "  ✅ PASS: $*"; }
fail_test() { echo "  ❌ FAIL: $*" >&2; fail=1; }

canon_of() {
    bash -c '
        WINDOWS=0
        '"$(sed -n '/^canon() {/,/^}/p' "$SCRIPT")"'
        canon "$1"
    ' _ "$1"
}

mkdir -p "$BASE/real/sub"
ln -s "$BASE/real/sub" "$BASE/link"

got=$(canon_of "$BASE/absent-a/b/c")
[ "$got" = "$BASE/absent-a/b/c" ] && pass "three missing levels resolve literally" || fail_test "missing levels: '$got'"

got=$(canon_of "$BASE/link/new/deeper")
[ "$got" = "$BASE/real/sub/new/deeper" ] && pass "symlink in the existing prefix is expanded" || fail_test "symlink prefix: '$got'"

got=$(canon_of "$BASE/link/../x/y")
[ "$got" = "$BASE/real/x/y" ] && pass "'..' after a symlink means the parent of its target" || fail_test "dotdot after link: '$got'"

got=$(canon_of "$BASE/absent/../real/sub")
[ "$got" = "$BASE/real/sub" ] && pass "'..' folds a missing segment" || fail_test "dotdot over missing: '$got'"

got=$(canon_of "$BASE/absent/../link/new")
[ "$got" = "$BASE/real/sub/new" ] && pass "a symlink after a folded missing segment is still expanded" || fail_test "link after missing: '$got'"

ln -s "$BASE/nowhere/target" "$BASE/dangling"
got=$(canon_of "$BASE/dangling/x")
[ "$got" = "$BASE/nowhere/target/x" ] && pass "dangling symlink is replaced by its target" || fail_test "dangling link: '$got'"

ln -s "rel-target" "$BASE/rel-dangling"
got=$(canon_of "$BASE/rel-dangling/x")
[ "$got" = "$BASE/rel-target/x" ] && pass "relative dangling symlink resolves next to the link" || fail_test "relative dangling link: '$got'"

ln -s "$BASE/loop-b" "$BASE/loop-a"
ln -s "$BASE/loop-a" "$BASE/loop-b"
# Only the perl fallback walks the links itself; where `realpath -m` exists
# (Linux) the platform tool answers and its loop behaviour is not ours to pin.
if realpath -m -- / >/dev/null 2>&1; then
    pass "symlink loop: realpath -m platform, perl fallback not in use (skipped)"
elif canon_of "$BASE/loop-a/x" >/dev/null 2>&1; then
    fail_test "symlink loop must fail closed"
else
    pass "symlink loop fails closed"
fi

exit $fail
