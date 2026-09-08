#!/usr/bin/env bash
# Regression coverage for issue #720: the template shipped two homes for
# decisions (decisions/decision-log-YYYY-MM.md and seed Strategy.md §
# "Ключевые решения") with a rule only for the journal — no cross-link, no
# indication which one is source-of-truth. Separately, the Decision Capture
# nudge in protocol-work.md referenced cognitive_budget.daily_decision_points,
# a key that never existed anywhere in the shipped config, so the nudge could
# never fire.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)

fail=0
pass() { echo "  ✅ PASS: $*"; }
fail_test() { echo "  ❌ FAIL: $*" >&2; fail=1; }

STRATEGY_SEED="$ROOT/seed/strategy/docs/Strategy.md"
if grep -q 'SoT: decisions/decision-log-YYYY-MM.md' "$STRATEGY_SEED" 2>/dev/null; then
    pass "seed Strategy.md 'Ключевые решения' points to the decision-log journal as SoT"
else
    fail_test "seed Strategy.md is missing the SoT cross-link to decisions/decision-log-YYYY-MM.md"
fi

CONFIG="$ROOT/memory/day-rhythm-config.yaml"
if grep -q 'daily_decision_points' "$CONFIG" 2>/dev/null; then
    pass "day-rhythm-config.yaml defines daily_decision_points (nudge threshold in protocol-work.md § 2a can resolve)"
else
    fail_test "day-rhythm-config.yaml is missing daily_decision_points — the Decision Capture nudge cannot resolve its threshold"
fi

if [ "$fail" -eq 0 ]; then
    echo "✅ test_issue_720_decision_log_sot: all checks passed"
fi
exit "$fail"
