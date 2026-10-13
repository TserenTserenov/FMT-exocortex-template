#!/usr/bin/env bash
# issue #884: a user extension cancelling a skill's behavior (e.g.
# week-close.before.no-weekly-post) used to keep firing on the autonomous
# scheduler path, because the night-cycle prompt (roles/strategist/prompts/
# *.md) never called load-extensions.sh at all -- only the interactive skill
# did. week-review.md's step 5b (already fixed, #1195) is the reference
# pattern: this test extends the same check to the two prompts confirmed
# reachable without it (day-plan.md manually via `strategist.sh day-plan`,
# month-close.md's inline fallback when the skill delegation target is
# missing). session-prep.md and the strategy-session* dispatcher are not
# covered here: session-prep has no existing extension-point convention to
# wire into (would be new scope, not a gap in an existing one), and
# strategy-session* is reached only through .claude/skills/strategy-session/
# SKILL.md, which already reads strategy-session before/after itself.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

fail=0
pass() { echo "  ✅ PASS: $*"; }
fail_test() { echo "  ❌ FAIL: $*" >&2; fail=1; }

check_calls() {  # <file> <extension-namespace>
    local file="$1" ns="$2"
    grep -q "load-extensions.sh $ns before" "$file" \
        && pass "$file calls load-extensions.sh $ns before" \
        || fail_test "$file does not call load-extensions.sh $ns before"
    grep -q "load-extensions.sh $ns after" "$file" \
        && pass "$file calls load-extensions.sh $ns after" \
        || fail_test "$file does not call load-extensions.sh $ns after"
}

check_calls "$ROOT/roles/strategist/prompts/day-plan.md" "day-open"
check_calls "$ROOT/roles/strategist/prompts/month-close.md" "month-close"

# Reference: week-review.md's own fix (#1195) must still be present (no regression).
grep -q "load-extensions.sh week-close before" "$ROOT/roles/strategist/prompts/week-review.md" \
    && pass "week-review.md still calls load-extensions.sh week-close before (#1195, no regression)" \
    || fail_test "week-review.md lost its #1195 extension read"

exit "$fail"
