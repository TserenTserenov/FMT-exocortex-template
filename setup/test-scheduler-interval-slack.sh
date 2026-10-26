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

# issue #1348: a failed inbox-check must still stamp its interval. Every run is a full
# AI pass, so the old "retry next dispatch" re-ran it every 10 min with no limit. The block
# is cut out of dispatch() and run with stubs; extractor exit code is the only variable.
BLOCK="$(mktemp)"
trap 'rm -f "$SNIPPET" "$BLOCK"' EXIT
{
    echo 'run_inbox_block() {'
    sed -n '/# --- Экстрактор: inbox-check/,/^    if \[ "\$ran" -eq 0 \]; then/p' "$SCHEDULER" | sed '$d'
    echo '}'
} > "$BLOCK"
if ! grep -q 'EXTRACTOR_SH" inbox-check' "$BLOCK"; then
    fail "inbox-check block is missing from $SCHEDULER"
else
    # expect_inbox EXTRACTOR_RC STAMPED(yes|no) NAME
    expect_inbox() {
        local stamped=no
        (
            # shellcheck disable=SC2034  # read by the sourced dispatch block
            HOUR=10 TASK_TIMEOUT_LONG=5 EXTRACTOR_SH="/bin/sh -c 'exit $1'" ran=0 LOG_FILE=/dev/null
            STAMPS="$(mktemp)"
            last_run_seconds_ago() { echo 999999; }
            mark_interval() { echo "$1" >> "$STAMPS"; }
            log() { :; }
            timeout() { shift; eval "$*"; }
            # shellcheck source=/dev/null
            . "$BLOCK"
            run_inbox_block
            grep -qx 'extractor-inbox-check' "$STAMPS"; rc=$?
            rm -f "$STAMPS"
            exit "$rc"
        ) && stamped=yes
        if [ "$stamped" = "$2" ]; then pass "$3"; else fail "$3 — extractor rc=$1 want stamped=$2 got=$stamped"; fi
    }
    expect_inbox 0 yes "a successful inbox-check stamps its interval"
    expect_inbox 1 yes "a failed inbox-check stamps its interval too (no 10-min retry loop, #1348)"
fi

echo ""
echo "PASS=$PASS_COUNT FAIL=$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
