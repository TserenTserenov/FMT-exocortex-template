#!/usr/bin/env bash
# Regression coverage for issue #888: the #361 fix to the Pull-on-Touch rule
# only reached CLAUDE.md's short form (SoT for the hot core). The expanded
# form in .claude/rules-lazy/blocking-rules-full.md, which the core itself
# sends agents to for the full wording, stayed on the pre-#361 text: manual
# `git pull --rebase` with no mention of the PreToolUse hook or the ban on a
# manual `cd && git pull`. This only catches drift on the ONE rule #888
# reported -- a general sync mechanism between the two files is a separate,
# larger piece of work the peer session deliberately left to the pilot.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
CORE="$ROOT/CLAUDE.md"
FULL="$ROOT/.claude/rules-lazy/blocking-rules-full.md"

fail=0
pass() { echo "  ✅ PASS: $*"; }
fail_test() { echo "  ❌ FAIL: $*" >&2; fail=1; }

core_line=$(grep -m1 '\*\*Pull-on-Touch:\*\*' "$CORE")
full_line=$(grep -m1 '\*\*Pull-on-Touch:\*\*' "$FULL")

if [ -z "$core_line" ] || [ -z "$full_line" ]; then
    fail_test "Pull-on-Touch line not found in one of the two files (CORE='${core_line:-<none>}' FULL='${full_line:-<none>}')"
elif [ "$core_line" = "$full_line" ]; then
    pass "CLAUDE.md and blocking-rules-full.md carry the identical Pull-on-Touch wording"
else
    fail_test "Pull-on-Touch wording has drifted again:
CLAUDE.md:                 $core_line
blocking-rules-full.md:    $full_line"
fi

if printf '%s' "$full_line" | grep -q 'PreToolUse-хук'; then
    pass "expanded rule names the PreToolUse hook (not manual git pull)"
else
    fail_test "expanded rule still describes a manual git pull, not the hook (#361/#888 regression)"
fi

if [ "$fail" -eq 0 ]; then
    echo "✅ test_issue_888_pull_on_touch_sync: all checks passed"
fi
exit "$fail"
