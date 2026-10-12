#!/usr/bin/env bash
# Regression coverage for the rsync half of issue #1099 (day-close.sh on Git
# Bash for Windows): the rules mirror must work when rsync is absent, copy
# dotfiles, drop files removed at the source, and never leave the mirror empty
# when the copy fails.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
SCRIPT="$ROOT/scripts/day-close.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
pass() { echo "  ✅ PASS: $*"; }
fail_test() { echo "  ❌ FAIL: $*" >&2; fail=1; }

# The real block, lifted verbatim from day-close.sh, wrapped in a function.
BLOCK=$(awk '/^    if command -v rsync >\/dev\/null 2>&1; then$/{f=1} f{print} f&&/^    fi$/{exit}' "$SCRIPT")
if [ -z "$BLOCK" ]; then
    fail_test "rsync fallback block not found in day-close.sh"
    exit 1
fi

# PATH without rsync: a directory that links only the tools the block needs.
mkdir -p "$TMP/bin"
for tool in bash rm mkdir cp mv printf; do
    p=$(command -v "$tool") && ln -sf "$p" "$TMP/bin/$tool"
done

run_mirror() {
    PATH="$TMP/bin" WORKSPACE_DIR="$TMP/ws" EXOCORTEX_DST="$TMP/dst" "$TMP/bin/bash" -c '
        mirror() {
'"$BLOCK"'
        }
        mirror
    '
}

mkdir -p "$TMP/ws/.claude/rules" "$TMP/dst/rules"
echo "keep" > "$TMP/ws/.claude/rules/a.md"
echo "dot"  > "$TMP/ws/.claude/rules/.hidden.md"
echo "stale" > "$TMP/dst/rules/removed.md"

if run_mirror 2>"$TMP/err"; then pass "mirror succeeds without rsync"; else fail_test "mirror failed: $(cat "$TMP/err")"; fi
[ "$(cat "$TMP/dst/rules/a.md" 2>/dev/null)" = "keep" ] && pass "regular file copied" || fail_test "a.md missing"
[ "$(cat "$TMP/dst/rules/.hidden.md" 2>/dev/null)" = "dot" ] && pass "dotfile copied" || fail_test ".hidden.md missing"
[ ! -e "$TMP/dst/rules/removed.md" ] && pass "file removed at the source is dropped" || fail_test "stale file survived"
ls "$TMP/dst" | grep -q 'rules.new' && fail_test "temporary directory left behind" || pass "no temporary directory left"

# Failed copy keeps the previous mirror intact.
rm -rf "$TMP/ws/.claude/rules"
if run_mirror 2>/dev/null; then fail_test "missing source must fail"; else pass "missing source fails"; fi
[ "$(cat "$TMP/dst/rules/a.md" 2>/dev/null)" = "keep" ] && pass "previous mirror kept after failed copy" || fail_test "mirror emptied by failed copy"

exit $fail
