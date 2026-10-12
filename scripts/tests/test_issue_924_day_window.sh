#!/usr/bin/env bash
# Regression coverage for the remaining half of issue #924: the commits of
# "yesterday" are collected over the half-open window
# [YDAY <day_boundary>, DATE <day_boundary>), not over the calendar day.
#   - a commit exactly at the boundary opens the new day (counted once);
#   - without a boundary (or 00:00) the calendar day is kept;
#   - day-open-scaffold.sh and day-open-pipeline.sh carry the same function.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
SCAFFOLD="$ROOT/scripts/day-open-scaffold.sh"
PIPELINE="$ROOT/scripts/day-open-pipeline.sh"

fail=0
pass() { echo "  ✅ PASS: $*"; }
fail_test() { echo "  ❌ FAIL: $*" >&2; fail=1; }

extract() { sed -n '/^iwe_day_window() {/,/^}/p' "$1"; }

if [ -n "$(extract "$SCAFFOLD")" ] && [ "$(extract "$SCAFFOLD")" = "$(extract "$PIPELINE")" ]; then
    pass "both scripts carry an identical iwe_day_window"
else
    fail_test "iwe_day_window is missing or differs between scaffold and pipeline"
fi

window() {
    bash -c "$(extract "$SCAFFOLD")"'
        iwe_day_window "$1" "$2" "$3"' _ "$1" "$2" "$3"
}

got=$(window 2026-10-11 2026-10-12 "04:30")
[ "$got" = "2026-10-11 04:30:00|2026-10-12 04:29:59" ] \
    && pass "boundary 04:30 -> [04:30:00, next day 04:29:59]" || fail_test "04:30: '$got'"

got=$(window 2026-10-11 2026-10-12 "")
[ "$got" = "2026-10-11 00:00:00|2026-10-11 23:59:59" ] \
    && pass "no boundary keeps the calendar day" || fail_test "empty: '$got'"

got=$(window 2026-10-11 2026-10-12 "00:00")
[ "$got" = "2026-10-11 00:00:00|2026-10-11 23:59:59" ] \
    && pass "boundary 00:00 keeps the calendar day" || fail_test "00:00: '$got'"

got=$(window 2026-10-11 2026-10-12 "9:05")
[ "$got" = "2026-10-11 09:05:00|2026-10-12 09:04:59" ] \
    && pass "single-digit hour is parsed" || fail_test "9:05: '$got'"

got=$(window 2026-10-11 2026-10-12 "garbage")
[ "$got" = "2026-10-11 00:00:00|2026-10-11 23:59:59" ] \
    && pass "invalid boundary falls back to the calendar day" || fail_test "garbage: '$got'"

# Real git: a commit at 04:30:00 sharp belongs to the new day only.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" init -q
commit_at() {
    GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$1" git -C "$TMP" \
        -c user.email=t@t -c user.name=t commit -q --allow-empty -m "$2"
}
commit_at "2026-10-11T02:00:00" "night-before-boundary"      # belongs to 10-10
commit_at "2026-10-11T04:30:00" "exactly-at-boundary"        # belongs to 10-11
commit_at "2026-10-11T23:00:00" "evening"                    # belongs to 10-11
commit_at "2026-10-12T04:29:59" "last-second"                # belongs to 10-11
commit_at "2026-10-12T04:30:00" "new-day"                    # belongs to 10-12

w=$(window 2026-10-11 2026-10-12 "04:30")
n=$(git -C "$TMP" log --since="${w%%|*}" --until="${w##*|}" --format=%s | sort | tr '\n' ' ')
[ "$n" = "evening exactly-at-boundary last-second " ] \
    && pass "window selects exactly the commits of the business day" || fail_test "selected: '$n'"

exit $fail
