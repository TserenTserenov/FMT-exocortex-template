#!/usr/bin/env bash
# Regression coverage for issue #886: the first Day Close of a week creates the
# paired `WeekReport W{N} YYYY-MM-DD.md` skeleton, so day summaries land in the
# WeekReport from day one instead of falling back into the WeekPlan.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
SCRIPT="$ROOT/scripts/week-report-ensure.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
pass() { echo "  ✅ PASS: $*"; }
fail_test() { echo "  ❌ FAIL: $*" >&2; fail=1; }

GOV="$TMP/gov"
mkdir -p "$GOV/current"

# --- no WeekPlan: nothing to pair with, never blocks.
out=$(bash "$SCRIPT" --governance-dir "$GOV"); rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q '^WEEKREPORT: skipped'; then
    pass "no WeekPlan: skipped, exit 0"
else
    fail_test "no WeekPlan: rc=$rc out='$out'"
fi

# --- two WeekPlans: the newest one (numeric order, W9 < W10) names the week.
: > "$GOV/current/WeekPlan W9 2026-09-07.md"
: > "$GOV/current/WeekPlan W10 2026-10-12.md"
out=$(bash "$SCRIPT" --governance-dir "$GOV")
TARGET="$GOV/current/WeekReport W10 2026-10-12.md"
if [ -f "$TARGET" ] && printf '%s' "$out" | grep -q '^WEEKREPORT: created'; then
    pass "skeleton created next to the newest WeekPlan (paired name)"
else
    fail_test "skeleton not created: out='$out' files=$(ls "$GOV/current")"
fi

# --- content: frontmatter, week id, and the word the artifact validator needs.
if grep -q '^type: week-report$' "$TARGET" && grep -q '^week: W10$' "$TARGET" \
   && grep -q '^## Итоги W10$' "$TARGET"; then
    pass "frontmatter and «Итоги» section present"
else
    fail_test "skeleton content wrong: $(cat "$TARGET")"
fi

# --- idempotent: a second run leaves the file untouched.
echo "накопленная сводка дня" >> "$TARGET"
before=$(cat "$TARGET")
out=$(bash "$SCRIPT" --governance-dir "$GOV")
after=$(cat "$TARGET")
if [ "$before" = "$after" ] && printf '%s' "$out" | grep -q '^WEEKREPORT: exists'; then
    pass "existing WeekReport is not touched"
else
    fail_test "second run changed the file or reported wrongly: '$out'"
fi

# --- an existing report of the same week under another date keeps the week unique.
rm "$TARGET"
: > "$GOV/current/WeekReport W10 2026-10-13.md"
out=$(bash "$SCRIPT" --governance-dir "$GOV")
if printf '%s' "$out" | grep -q '^WEEKREPORT: exists' && [ ! -f "$TARGET" ]; then
    pass "a report of the same week (other date) is reused, no duplicate"
else
    fail_test "duplicate created or wrong state: '$out'"
fi

# --- the day-close skill sends the agent through the script first.
if grep -q 'week-report-ensure.sh' "$ROOT/.claude/skills/day-close/SKILL.md"; then
    pass "day-close skill calls week-report-ensure.sh"
else
    fail_test "day-close skill does not mention week-report-ensure.sh"
fi

exit $fail
