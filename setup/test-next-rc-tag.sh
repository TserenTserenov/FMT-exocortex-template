#!/usr/bin/env bash
# WP-529 Ф239: next-rc-tag.sh picks max(N)+1 from REMOTE rc tags.
#
# Regression anchors (cold review of the first draft):
# - annotated tags make `git ls-remote --tags` print two lines per tag (tag
#   and peeled ^{}) — a line count would double-increment;
# - gaps from deleted tags — count+1 would collide with an existing tag;
# - a failing ls-remote must abort, not print rc.1.
#
# Runs against a real local bare repo (file:// remote), no network.
# Usage: bash setup/test-next-rc-tag.sh

set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$(dirname "$SELF_DIR")/scripts/next-rc-tag.sh"

FAIL_COUNT=0
PASS_COUNT=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "  ✅ PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/iwe-next-rc-tag-XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

REMOTE="$TEST_ROOT/remote.git"
git init -q --bare -b main "$REMOTE"
WORK="$TEST_ROOT/work"
git clone -q "$REMOTE" "$WORK"
git -C "$WORK" config user.name t
git -C "$WORK" config user.email t@example.invalid
git -C "$WORK" commit -q --allow-empty -m init
git -C "$WORK" push -q origin main

echo "--- No rc tags yet: rc.1 ---"
OUT=$(bash "$SCRIPT" 0.42.0 "$REMOTE")
[ "$OUT" = "v0.42.0-rc.1" ] && pass "empty tag space -> rc.1" || fail "got $OUT"

echo "--- Lightweight rc.1 + rc.2: rc.3 ---"
git -C "$WORK" tag v0.42.0-rc.1
git -C "$WORK" tag v0.42.0-rc.2
git -C "$WORK" push -q origin --tags
OUT=$(bash "$SCRIPT" 0.42.0 "$REMOTE")
[ "$OUT" = "v0.42.0-rc.3" ] && pass "lightweight rc.1,rc.2 -> rc.3" || fail "got $OUT"

echo "--- Annotated rc.3 (two ls-remote lines): rc.4, not rc.5/7 ---"
git -C "$WORK" tag -a v0.42.0-rc.3 -m rc3
git -C "$WORK" push -q origin v0.42.0-rc.3
OUT=$(bash "$SCRIPT" 0.42.0 "$REMOTE")
[ "$OUT" = "v0.42.0-rc.4" ] && pass "annotated rc.3 -> rc.4 (peeled lines ignored)" || fail "got $OUT"

echo "--- Gap at rc.3 (never existed): max+1 = rc.5, count+1 would collide with rc.4 ---"
git -C "$WORK" tag v0.42.0-rc.4
git -C "$WORK" push -q origin v0.42.0-rc.4
OUT=$(bash "$SCRIPT" 0.42.0 "$REMOTE")
[ "$OUT" = "v0.42.0-rc.5" ] && pass "rc.1,rc.2,rc.4 -> rc.5 (max+1, not count+1=4 collision)" || fail "got $OUT"

echo "--- Other versions do not leak in ---"
git -C "$WORK" tag v0.43.0-rc.7
git -C "$WORK" push -q origin v0.43.0-rc.7
OUT=$(bash "$SCRIPT" 0.42.0 "$REMOTE")
[ "$OUT" = "v0.42.0-rc.5" ] && pass "v0.43.0-rc.7 does not bump v0.42.0" || fail "got $OUT"
OUT=$(bash "$SCRIPT" 0.43.0 "$REMOTE")
[ "$OUT" = "v0.43.0-rc.8" ] && pass "v0.43.0-rc.7 -> rc.8" || fail "got $OUT"

echo "--- Malformed tag names are ignored ---"
git -C "$WORK" tag "v0.42.0-rc" || true
git -C "$WORK" tag "v0.42.0-rc.x" || true
git -C "$WORK" push -q origin --tags
OUT=$(bash "$SCRIPT" 0.42.0 "$REMOTE")
[ "$OUT" = "v0.42.0-rc.5" ] && pass "rc / rc.x ignored" || fail "got $OUT"

echo "--- Remote failure: exit 1, no guessed tag ---"
OUT=$(bash "$SCRIPT" 0.42.0 "$TEST_ROOT/absent.git" 2>/dev/null)
RC=$?
if [ "$RC" -ne 0 ] && [ -z "$OUT" ]; then
    pass "unreachable remote fails without printing a tag"
else
    fail "unreachable remote: rc=$RC out=$OUT"
fi

echo
echo "Result: $PASS_COUNT PASS, $FAIL_COUNT FAIL"
[ "$FAIL_COUNT" -eq 0 ] && exit 0 || exit 1
