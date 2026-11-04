#!/usr/bin/env bash
# test_session_guard_open_log_path.sh — `session-guard.sh open-log-path` prints
# the session-open log this guard writes, without side effects on that log, and
# rejects arguments. dt-collect.sh reads the path from here (WP-529 F248).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="$ROOT/scripts/session-guard.sh"

FAIL=0
pass() { echo "  ✅ PASS: $*"; }
fail() { echo "  ❌ FAIL: $*"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

OUT=$(IWE_ROOT="$TMP" IWE_GOVERNANCE_REPO=DS-test bash "$GUARD" open-log-path 2>&1)
RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = "$TMP/DS-test/inbox/open-sessions.log" ] \
    && pass "prints the governance open log: $OUT" || fail "rc=$RC output '$OUT'"
[ ! -e "$TMP/DS-test/inbox/open-sessions.log" ] \
    && pass "the log itself is not created" || fail "open-log-path created the log"

OUT=$(IWE_ROOT="$TMP" IWE_GOVERNANCE_REPO=DS-test bash "$GUARD" open-log-path extra 2>&1)
RC=$?
[ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'no arguments accepted' \
    && pass "extra argument rejected, rc $RC" || fail "extra argument: rc=$RC output '$OUT'"

[ "$FAIL" -eq 0 ] && echo "PASS: session-guard open-log-path" || { echo "FAIL: $FAIL"; exit 1; }
