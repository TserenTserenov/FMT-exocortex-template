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

# Structural check, not just substring presence: a naive text-splice fix can
# land daily_decision_points at the top level while silently reparenting an
# unrelated pre-existing sibling key (e.g. pomodoro.session_alert_minutes)
# under cognitive_budget by mistake — grep alone can't tell YAML nesting
# apart from plain text adjacency. find-python3.sh's contract guarantees
# PyYAML on CI (validate-template.yml); skip quietly where it's missing
# (local dev without the dependency installed).
if python3 -c "import yaml" 2>/dev/null; then
    if python3 -c "
import sys, yaml
with open('$CONFIG') as f:
    data = yaml.safe_load(f) or {}
cognitive_budget = data.get('cognitive_budget') or {}
sys.exit(0 if 'daily_decision_points' in cognitive_budget else 1)
"; then
        pass "daily_decision_points parses under cognitive_budget: (not merely present as text)"
    else
        fail_test "daily_decision_points exists in the file but does not parse under the cognitive_budget: mapping"
    fi

    # Regression for the exact bug this check exists to catch: a naive
    # text-splice landed cognitive_budget: right before pomodoro's
    # pre-existing session_alert_minutes line without adjusting its indent,
    # silently reparenting it under cognitive_budget instead of pomodoro.
    if python3 -c "
import sys, yaml
with open('$CONFIG') as f:
    data = yaml.safe_load(f) or {}
pomodoro = data.get('pomodoro') or {}
cognitive_budget = data.get('cognitive_budget') or {}
sys.exit(0 if ('session_alert_minutes' in pomodoro and 'session_alert_minutes' not in cognitive_budget) else 1)
"; then
        pass "pomodoro.session_alert_minutes stayed under pomodoro: (not reparented under cognitive_budget)"
    else
        fail_test "pomodoro.session_alert_minutes is missing from pomodoro: or leaked into cognitive_budget: — a text-splice edit likely misnested it"
    fi
else
    echo "  ℹ SKIP: PyYAML not available locally — structural nesting check runs on CI only"
fi

if [ "$fail" -eq 0 ]; then
    echo "✅ test_issue_720_decision_log_sot: all checks passed"
fi
exit "$fail"
