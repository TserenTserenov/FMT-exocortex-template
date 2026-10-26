#!/usr/bin/env bash
# test_issue_1266_open_log.sh — open-sessions.log is an append-only history
# (session-guard only appends; audit/dt-collect count history). Day Close must
# not tell the agent to delete lines, and day-close-prepare.sh must show the
# openings of today, not the oldest lines of the file (issue #1266).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

FAIL=0
pass() { echo "  ✅ PASS: $*"; }
fail() { echo "  ❌ FAIL: $*"; FAIL=$((FAIL + 1)); }

if grep -q 'удалить строки закрытых' "$ROOT/.claude/skills/day-close/SKILL.md"; then
    fail "day-close SKILL.md still tells to delete lines from open-sessions.log"
else
    pass "day-close SKILL.md does not ask to delete open-sessions.log lines"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
GOV="$TMP/ws/DS-strategy"
mkdir -p "$GOV/inbox" "$TMP/home"
TODAY=$(date +%Y-%m-%d)
for i in $(seq 1 40); do
    printf '2026-01-%02d 09:00 | WP-%d | claude-code | old session %d\n' $(( (i % 28) + 1 )) "$i" "$i"
done > "$GOV/inbox/open-sessions.log"
printf '%s 10:15 | WP-77 | claude-code | todays session\n' "$TODAY" >> "$GOV/inbox/open-sessions.log"

HOME="$TMP/home" IWE_WORKSPACE="$TMP/ws" WORKSPACE_DIR="$TMP/ws" IWE_ROOT="$TMP/ws" \
    IWE_DS_MY_STRATEGY="$GOV" IWE_GOVERNANCE_REPO=DS-strategy \
    bash "$ROOT/scripts/day-close-prepare.sh" > "$TMP/out" 2>&1
SECTION=$(sed -n '/^--- 3\. OPEN SESSIONS LOG ---/,/^--- 4\./p' "$TMP/out")
if printf '%s\n' "$SECTION" | grep -q 'todays session' && \
   ! printf '%s\n' "$SECTION" | grep -q 'old session'; then
    pass "prepare shows today's openings, not the oldest lines"
else
    fail "section 3 does not show today's openings only: $(printf '%s\n' "$SECTION" | head -4 | tr '\n' ' ')"
fi

[ "$FAIL" -eq 0 ] && echo "PASS: issue #1266 open-sessions log" || { echo "FAIL: issue #1266 has $FAIL violation(s)"; exit 1; }
