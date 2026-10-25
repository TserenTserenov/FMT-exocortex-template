#!/usr/bin/env bash
# Regression for issue #1280: the update.sh delivery hint must point to the
# template's own session-guard.sh (guaranteed to exist right after the update)
# and use the actual session agent -- not a governance-repo copy update.sh
# never delivers, and not the literal "--agent manual" that the open-gate
# harness can never match (WP-561 Ф46 live-check finding A2).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
UPDATE_SH="$ROOT/update.sh"

FAIL=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
pass() { echo "  ✅ PASS: $*"; }

if [ ! -f "$UPDATE_SH" ]; then
    fail "update.sh not found at $UPDATE_SH"
    echo "test_issue_1280_delivery_hint: $FAIL FAILURE(S)"
    exit 1
fi

# --- T1: hint opens the semaphore via the template's session-guard.sh ---
if grep -qF 'bash \"$SCRIPT_DIR/scripts/session-guard.sh\" open --housekeeping update-delivery' "$UPDATE_SH"; then
    pass "T1: hint opens via \$SCRIPT_DIR/scripts/session-guard.sh (template copy)"
else
    fail "T1: hint no longer opens via the template's session-guard.sh"
fi

# --- T2: hint never points into the governance repo for session-guard.sh ---
if ! grep -qF '"$GOVERNANCE_DIR_FOR_DELIVERY_HINT/scripts/session-guard.sh"' "$UPDATE_SH"; then
    pass "T2: no governance-repo session-guard.sh path in the hint (file is never delivered there)"
else
    fail "T2: hint still references governance-repo session-guard.sh that does not exist on community installs"
fi

# --- T3: --agent follows the actual runtime, no literal "manual" ---
if ! grep -qF -- '--agent manual' "$UPDATE_SH" \
   && grep -qF -- '--agent \"\${IWE_AGENT:-claude-code}\"' "$UPDATE_SH"; then
    pass "T3: --agent follows \${IWE_AGENT:-claude-code} (expanded at operator session), literal 'manual' gone"
else
    fail "T3: hint must use --agent \"\${IWE_AGENT:-claude-code}\" and contain no '--agent manual'"
fi

# --- T5: the hinted template path is a real file in the repo (peer round 2, Grok) ---
if [ -f "$ROOT/scripts/session-guard.sh" ]; then
    pass "T5: scripts/session-guard.sh exists next to update.sh (hinted path is real)"
else
    fail "T5: scripts/session-guard.sh missing from template root — hinted path would fail"
fi

# --- T4: same-session harness note is printed (harness_session_id binding) ---
if grep -qF "harness_session_id" "$UPDATE_SH" && grep -qF "ОДНОЙ сессии агента" "$UPDATE_SH"; then
    pass "T4: hint warns that open/commit/close must stay inside one agent session"
else
    fail "T4: hint lost the harness_session_id same-session warning"
fi

if [ "$FAIL" -eq 0 ]; then
    echo "test_issue_1280_delivery_hint: ALL PASS"
    exit 0
else
    echo "test_issue_1280_delivery_hint: $FAIL FAILURE(S)"
    exit 1
fi
