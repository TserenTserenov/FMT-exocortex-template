#!/usr/bin/env bash
# issue #1261: build_message("note-review") must return its static text even
# when no DayPlan file exists for today — find_strategy_file() maps
# "note-review" to the same DayPlan path as "day-plan", so the generic
# file-not-found early return swallowed the message before this fix.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEMPLATE="$ROOT/roles/synchronizer/scripts/templates/strategist.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

# No current/DayPlan <date>.md anywhere under this workspace.
mkdir -p "$SANDBOX/DS-strategy/current"
export IWE_WORKSPACE="$SANDBOX"
export IWE_GOVERNANCE_REPO="DS-strategy"

# shellcheck source=/dev/null
source "$TEMPLATE"

OUTPUT=$(build_message "note-review")

[ -n "$OUTPUT" ] || fail "note-review message is empty with no DayPlan present"
case "$OUTPUT" in
    *"Note-Review завершён"*) ;;
    *) fail "note-review message does not contain the expected static text: $OUTPUT" ;;
esac

pass "note-review message is non-empty and static even without a DayPlan file"
