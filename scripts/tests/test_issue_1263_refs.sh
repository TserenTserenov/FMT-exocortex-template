#!/usr/bin/env bash
# test_issue_1263_refs.sh — after #1334 the template ships no /connect-guide,
# /lesson or /lesson-close; shipped texts must not send the user there, and
# personal-guide-start must not copy skills into the personal repo (issue #1263).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

FAIL=0
pass() { echo "  ✅ PASS: $*"; }
fail() { echo "  ❌ FAIL: $*"; FAIL=$((FAIL + 1)); }

[ ! -d "$ROOT/.claude/skills/connect-guide" ] || fail "connect-guide is shipped again — update this test"
HITS=$(grep -n '/connect-guide' "$ROOT/scripts/day-open-scaffold.sh" \
    "$ROOT/seed/strategy/scripts/day-open-scaffold.sh" "$ROOT/memory/roles.md" 2>/dev/null || true)
if [ -z "$HITS" ]; then
    pass "Day Open scaffold and roles catalogue do not point to the absent /connect-guide"
else
    fail "stale /connect-guide reference: $HITS"
fi
SKILL="$ROOT/.claude/skills/personal-guide-start/SKILL.md"
if grep -q 'SKILLS_TO_DISTRIBUTE' "$SKILL" || grep -qE 'personal_write\([^)]*\.claude/' "$SKILL"; then
    fail "personal-guide-start copies skills into the personal repo again"
else
    pass "personal-guide-start does not copy skills via personal_write"
fi

[ "$FAIL" -eq 0 ] && echo "PASS: issue #1263 skill references" || { echo "FAIL: issue #1263 has $FAIL violation(s)"; exit 1; }
