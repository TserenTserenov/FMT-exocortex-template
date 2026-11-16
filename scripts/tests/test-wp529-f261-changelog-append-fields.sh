#!/usr/bin/env bash
# test_changelog_append_keeps_handoff_fields.sh — WP-529 Ф261, finding 4 of the 10.11 pipeline
# review: changelog-append.sh rebuilt the whole [Unreleased] section from commit subjects and
# erased entries written by hand together with their handoff fields. A section that carries
# the fields must stay byte for byte as it was; a section without them is still rebuilt.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
SCRIPT="$ROOT/scripts/changelog-append.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; fail=1; }

make_repo() {
    local repo="$1" changelog="$2"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.email test@example.invalid
    git -C "$repo" config user.name test
    printf '%b' "$changelog" > "$repo/CHANGELOG.md"
    git -C "$repo" add CHANGELOG.md
    git -C "$repo" commit -qm 'init'
    git -C "$repo" commit -q --allow-empty -m 'fix: something'
}

HEADER='# Changelog\n\n'
OLD='## [0.1.0] - 2026-01-01\n\n### Added\n\n- first\n'

echo "1. [Unreleased] with handoff fields is left untouched"
R1="$TMP/with-fields"
make_repo "$R1" "${HEADER}## [Unreleased]\n\n### Changed\n\n- [behavior] hand-written entry\n  - Цель: 77 · Результат: служебное — проверка\n  - Как проверить: bash x\n  - Как откатить: git revert\n\n${OLD}"
cp "$R1/CHANGELOG.md" "$TMP/before.md"
msg=$(IWE_TEMPLATE="$R1" bash "$SCRIPT" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && pass "exit 0, promote scripts keep going" || fail "expected exit 0, got $rc"
cmp -s "$TMP/before.md" "$R1/CHANGELOG.md" && pass "CHANGELOG.md is byte for byte the same" \
    || fail "CHANGELOG.md changed: the hand-written entry would be lost"
printf '%s' "$msg" | grep -q "полями передачи" && pass "the refusal is named in the output" \
    || fail "no explanation printed: $msg"

echo "2. [Unreleased] without the fields is still rebuilt from commits"
R2="$TMP/no-fields"
make_repo "$R2" "${HEADER}## [Unreleased]\n\n### Changed\n\n- stale line\n\n${OLD}"
IWE_TEMPLATE="$R2" bash "$SCRIPT" >/dev/null 2>&1
grep -q "something" "$R2/CHANGELOG.md" && pass "new block carries the commit subject" \
    || fail "commit subject missing from the rebuilt block"
grep -q "stale line" "$R2/CHANGELOG.md" && fail "stale line survived the rebuild" || pass "old block was replaced"

echo "3. dry-run on a section with the fields prints no block"
out=$(IWE_TEMPLATE="$R1" bash "$SCRIPT" --dry-run 2>&1)
printf '%s' "$out" | grep -q -- "--- dry-run" && fail "dry-run printed a replacement block" \
    || pass "dry-run reports the refusal instead of a replacement"

[ "$fail" -eq 0 ] && echo "PASS" || { echo "FAILED"; exit 1; }
