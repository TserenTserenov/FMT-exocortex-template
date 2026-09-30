#!/bin/bash
# strategy-session-isolated-copy-smoke.sh -- text regression guard (WP-530 F72 wave 4).
# The skill used to write docs/Strategy.md, Dissatisfactions.md, WeekPlan, Backlog
# through the canonical governance path while the canon is frozen. It must resolve the
# working copy first ($GOV_WT) and build every write path from it.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="${STRATEGY_SKILL_UNDER_TEST:-$SCRIPT_DIR/../../.claude/skills/strategy-session/SKILL.md}"
[ -f "$SKILL" ] || { echo "FAIL: $SKILL not found"; exit 1; }
FAILURES=0
check() { if [ "$2" = ok ]; then echo "PASS: $1"; else echo "FAIL: $1"; FAILURES=$((FAILURES+1)); fi; }

# 1. no canonical literal followed by a written subpath
if grep -nE '\{\{WORKSPACE_DIR\}\}/\{\{GOVERNANCE_REPO\}\}/(docs|current|inbox|Lifework|archive)' "$SKILL" >/dev/null; then
  check "no canonical literal in write/read paths" bad
else check "no canonical literal in write/read paths" ok; fi
# 2. resolver or git-root resolution present
grep -q 'resolve_active_worktree' "$SKILL" && grep -q 'GOV_WT=' "$SKILL" \
  && check "resolver call defines GOV_WT" ok || check "resolver call defines GOV_WT" bad
# 3. isolation + publish instructions
grep -q 'session-guard.sh open --isolate' "$SKILL" && check "isolation command present" ok || check "isolation command present" bad
grep -q 'ds-publish.sh' "$SKILL" && check "ds-publish present" ok || check "ds-publish present" bad
# 4. write targets use $GOV_WT
for t in docs/Strategy.md docs/Dissatisfactions.md 'current/WeekPlan W{N}.md' docs/Backlog.md; do
  grep -qF "\$GOV_WT/$t" "$SKILL" && check "GOV_WT path: $t" ok || check "GOV_WT path: $t" bad
done
[ "$FAILURES" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$FAILURES FAILED"; exit 1; }
