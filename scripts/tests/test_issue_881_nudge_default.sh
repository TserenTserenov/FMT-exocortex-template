#!/usr/bin/env bash
# Regression coverage for issue #881: new keys added to the shipped
# memory/day-rhythm-config.yaml never reach an existing install (update.sh
# leaves the user-owned file alone on purpose), so the Decision Capture nudge
# in protocol-work.md had no threshold there and never fired. The reader now
# states the default itself; this test pins that default to the shipped one so
# the two cannot drift apart.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)

fail=0
pass() { echo "  ✅ PASS: $*"; }
fail_test() { echo "  ❌ FAIL: $*" >&2; fail=1; }

PROTOCOL="$ROOT/memory/protocol-work.md"
CONFIG="$ROOT/memory/day-rhythm-config.yaml"

nudge_line=$(grep -m1 '^\*\*Nudge:\*\*' "$PROTOCOL" 2>/dev/null || true)
if [ -z "$nudge_line" ]; then
    fail_test "protocol-work.md has no '**Nudge:**' paragraph to carry the default"
fi

doc_default=$(printf '%s\n' "$nudge_line" | sed -n 's/.*значение по умолчанию \*\*\([0-9][0-9]*\)\*\*.*/\1/p')
if [ -n "$doc_default" ]; then
    pass "nudge paragraph names its own default for a missing key: $doc_default"
else
    fail_test "nudge paragraph does not state a default for a missing cognitive_budget.daily_decision_points (existing installs have no such key)"
fi

config_default=$(sed -n 's/^  daily_decision_points: *\([0-9][0-9]*\).*/\1/p' "$CONFIG" | head -1)
if [ -z "$config_default" ]; then
    fail_test "day-rhythm-config.yaml has no numeric cognitive_budget.daily_decision_points"
elif [ "$doc_default" = "$config_default" ]; then
    pass "reader default ($doc_default) equals the shipped config value ($config_default)"
else
    fail_test "reader default '$doc_default' differs from shipped config value '$config_default' — the two must move together"
fi

if [ "$fail" -eq 0 ]; then
    echo "✅ test_issue_881_nudge_default: all checks passed"
fi
exit "$fail"
