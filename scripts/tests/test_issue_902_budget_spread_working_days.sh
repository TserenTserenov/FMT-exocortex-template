#!/usr/bin/env bash
# Regression coverage for issue #902 (minimal fix): Budget Spread's days_left
# calculation was hardcoded to a mon-fri week in day-open-details.md's prose
# (this step is executed by an LLM agent reading the skill file, not by a
# script -- the "code" here is the instruction text itself). A user whose
# working week runs further had their daily budget overstated. This checks
# the wiring is present and internally consistent: the new config key exists
# with the old mon-fri default (no behavior change for users who don't set
# it), and the instruction text actually reads it instead of a hardcoded
# "пн-пт". non_working_calendars integration is explicitly out of scope for
# this fix (deferred to RP-561 per the peer-session decision) and is not
# asserted here.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
CONFIG="$ROOT/memory/day-rhythm-config.yaml"
DETAILS="$ROOT/.claude/skills/day-open/day-open-details.md"

fail=0
pass() { echo "  ✅ PASS: $*"; }
fail_test() { echo "  ❌ FAIL: $*" >&2; fail=1; }

if grep -qE '^\s*working_days:\s*\[mon,\s*tue,\s*wed,\s*thu,\s*fri\]' "$CONFIG"; then
    pass "working_days key exists in day-rhythm-config.yaml with the mon-fri default"
else
    fail_test "working_days key missing or default changed from mon-fri in $CONFIG"
fi

if grep -qF 'budget_spread.working_days' "$DETAILS"; then
    pass "day-open-details.md's days_left rule reads budget_spread.working_days"
else
    fail_test "day-open-details.md still hardcodes the mon-fri week shape"
fi

if grep -qF 'ключа нет → как раньше, пн–пт' "$DETAILS"; then
    pass "instruction text preserves the old mon-fri behavior when the key is absent (no silent change for existing users)"
else
    fail_test "instruction text does not document a safe default for configs without working_days"
fi

if [ "$fail" -eq 0 ]; then
    echo "✅ test_issue_902_budget_spread_working_days: all checks passed"
fi
exit "$fail"
