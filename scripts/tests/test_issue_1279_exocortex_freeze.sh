#!/usr/bin/env bash
# Regression for issue #1279: memory-exocortex-sync.sh had no freeze
# awareness and mirrored straight into the canonical governance checkout
# even while session-guard.sh refuses every other direct write to it.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/.claude/hooks/memory-exocortex-sync.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/iwe-issue-1279-freeze.XXXXXX")"

FAIL=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
pass() { echo "  ✅ PASS: $*"; }

cleanup() {
    local rc=$?
    rm -rf -- "$TEST_ROOT"
    exit "$rc"
}
trap cleanup EXIT INT TERM

mkdir -p "$TEST_ROOT/workspace/memory" "$TEST_ROOT/workspace/GOVREPO"
echo "hello" > "$TEST_ROOT/workspace/memory/test-file.md"

run_hook() {
    local tool_input="$1" frozen_override="${2-unset}"
    if [ "$frozen_override" = "unset" ]; then
        printf '%s' "$tool_input" | \
            WORKSPACE_DIR="$TEST_ROOT/workspace" GOVERNANCE_REPO=GOVREPO \
            IWE_MEMORY_SRC="$TEST_ROOT/workspace/memory" \
            bash "$HOOK"
    else
        printf '%s' "$tool_input" | \
            WORKSPACE_DIR="$TEST_ROOT/workspace" GOVERNANCE_REPO=GOVREPO \
            IWE_MEMORY_SRC="$TEST_ROOT/workspace/memory" \
            IWE_FROZEN_CANONICAL_PATH="$frozen_override" \
            bash "$HOOK"
    fi
}

WRITE_EVENT=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$TEST_ROOT/workspace/memory/test-file.md")
BASH_EVENT='{"tool_name":"Bash","tool_input":{"command":"echo touch"}}'

# --- T1: frozen by default (no override) — direct-file-path branch must skip, not write ---
OUT=$(run_hook "$WRITE_EVENT" unset 2>&1)
RC=$?
if [ "$RC" -eq 0 ] && [ ! -e "$TEST_ROOT/workspace/GOVREPO/exocortex" ] && echo "$OUT" | grep -q "freeze"; then
    pass "T1: frozen by default — mirror skipped, exocortex/ never created, hook still exits 0"
else
    fail "T1: expected skip (exit 0, no exocortex/, 'freeze' in stderr), got rc=$RC out=[$OUT] exocortex-exists=$([ -e "$TEST_ROOT/workspace/GOVREPO/exocortex" ] && echo yes || echo no)"
fi

# --- T2: frozen by default — Bash-reconcile branch must also skip ---
OUT=$(run_hook "$BASH_EVENT" unset 2>&1)
RC=$?
if [ "$RC" -eq 0 ] && [ ! -e "$TEST_ROOT/workspace/GOVREPO/exocortex" ] && echo "$OUT" | grep -q "freeze"; then
    pass "T2: frozen by default, Bash-reconcile path — mirror skipped"
else
    fail "T2: expected skip on Bash-reconcile branch too, got rc=$RC out=[$OUT]"
fi

# --- T3: explicit empty override disables freeze — mirror must still work (no regression) ---
OUT=$(run_hook "$WRITE_EVENT" "" 2>&1)
RC=$?
MIRRORED="$TEST_ROOT/workspace/GOVREPO/exocortex/test-file.md"
if [ "$RC" -eq 0 ] && [ -f "$MIRRORED" ] && [ "$(cat "$MIRRORED")" = "hello" ]; then
    pass "T3: freeze disabled via empty override — mirror still works as before"
else
    fail "T3: expected mirrored file with original content, got rc=$RC mirrored-exists=$([ -f "$MIRRORED" ] && echo yes || echo no) out=[$OUT]"
fi

# --- T4: a frozen path that does NOT match GOVERNANCE_REPO must not block this repo's mirror ---
rm -rf "$TEST_ROOT/workspace/GOVREPO/exocortex"
OTHER_FROZEN_DIR="$TEST_ROOT/unrelated-frozen-repo"
mkdir -p "$OTHER_FROZEN_DIR"
OUT=$(run_hook "$WRITE_EVENT" "$OTHER_FROZEN_DIR" 2>&1)
RC=$?
if [ "$RC" -eq 0 ] && [ -f "$MIRRORED" ] && [ "$(cat "$MIRRORED")" = "hello" ]; then
    pass "T4: freeze override points elsewhere — this repo's mirror is unaffected"
else
    fail "T4: expected mirror unaffected by an unrelated frozen path, got rc=$RC mirrored-exists=$([ -f "$MIRRORED" ] && echo yes || echo no) out=[$OUT]"
fi

if [ "$FAIL" -eq 0 ]; then
    echo "test_issue_1279_exocortex_freeze: ALL PASS"
    exit 0
else
    echo "test_issue_1279_exocortex_freeze: $FAIL FAILURE(S)"
    exit 1
fi
