#!/usr/bin/env bash
# test-scheduler-interval-slack.sh — regression for a scheduler tick lost by one second
# (tsekh-1, 21.09.2026): "every 3h" tasks are gated on the time since the previous dispatch
# start, and 15:00:52 -> 18:00:51 is 10799 s, one short of 10800, so the extractor inbox-check
# waited another full interval. interval_reached forgives timer jitter (INTERVAL_SLACK_SECONDS)
# but still holds off a dispatch started by hand shortly before the timer tick.
#
# scheduler.sh runs its dispatch at top level, so the constant and the function are cut out of
# it textually and sourced alone.
#
# Usage: bash setup/test-scheduler-interval-slack.sh

set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SCHEDULER="$(dirname "$SELF_DIR")/roles/synchronizer/scripts/scheduler.sh"

FAIL_COUNT=0
PASS_COUNT=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "  ✅ PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }

SNIPPET="$(mktemp)"
trap 'rm -f "$SNIPPET"' EXIT
# constant, comments and the function: up to the first closing brace at column 0
sed -n '/^INTERVAL_SLACK_SECONDS=/,/^}/p' "$SCHEDULER" > "$SNIPPET"
if ! grep -q '^interval_reached() {' "$SNIPPET"; then
    fail "interval_reached is missing from $SCHEDULER"
    exit 1
fi
# shellcheck source=/dev/null
. "$SNIPPET"

# expect ELAPSED INTERVAL yes|no NAME
expect() {
    local got=no
    if interval_reached "$1" "$2"; then got=yes; fi
    if [ "$got" = "$3" ]; then pass "$4"; else fail "$4 — elapsed=$1 interval=$2 want=$3 got=$got"; fi
}

expect 10799  10800 yes "the incident: 10799 s of 10800 is due"
expect 10800  10800 yes "exactly one interval is due"
expect 21600  10800 yes "two intervals are due"
expect 999999 10800 yes "no marker yet is due"
expect 10500  10800 yes "lower edge of the slack is due"
expect 10499  10800 no  "one second below the slack is not due"
expect 2340   10800 no  "a manual dispatch 39 min before the tick holds it off"

if grep -q 'interval_reached "\$elapsed" 10800' "$SCHEDULER"; then
    pass "the extractor gate uses interval_reached"
else
    fail "the extractor gate no longer uses interval_reached (raw comparison creeps back)"
fi

echo ""
echo "PASS=$PASS_COUNT FAIL=$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
