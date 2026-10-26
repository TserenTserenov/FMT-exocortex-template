#!/usr/bin/env bash
# Regression for issue #1279: memory-exocortex-sync.sh had no freeze
# awareness and mirrored straight into the canonical governance checkout
# even while session-guard.sh refuses every other direct write to it.
# Under freeze the hook now hands the change to scripts/exocortex-publish.sh in
# the background (isolated worktree + ds-publish.sh, covered end to end by
# test_issue_1279_exo_publish.sh); here the canon is not a git repo, so that
# publish must record a failure and still never create exocortex/ in it.
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
    local tool_input="$1" frozen_override="${2-unset}" canonical_owner="${3:-}"
    local freeze_env=(env -u IWE_FROZEN_CANONICAL_PATH)
    [ "$frozen_override" = "unset" ] || freeze_env=(env "IWE_FROZEN_CANONICAL_PATH=$frozen_override")
    printf '%s' "$tool_input" | \
        "${freeze_env[@]}" WORKSPACE_DIR="$TEST_ROOT/workspace" GOVERNANCE_REPO=GOVREPO \
        IWE_MEMORY_SRC="$TEST_ROOT/workspace/memory" \
        IWE_CANONICAL_OWNER="$canonical_owner" \
        IWE_EXOCORTEX_TRIGGER_MIN_INTERVAL="${IWE_EXOCORTEX_TRIGGER_MIN_INTERVAL:-0}" \
        bash "$HOOK"
}

WRITE_EVENT=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$TEST_ROOT/workspace/memory/test-file.md")
BASH_EVENT='{"tool_name":"Bash","tool_input":{"command":"echo touch"}}'

STATUS="$TEST_ROOT/workspace/.iwe-runtime/state/exocortex-publish.status"
wait_status() {  # waits for the background publisher to record an attempt
    local i=0
    while [ "$i" -lt 60 ]; do
        [ -f "$STATUS" ] && { sleep 1; return 0; }
        sleep 0.5; i=$((i + 1))
    done
    return 1
}

# --- T1: frozen by default (no override) — direct-file-path branch hands off, never writes the canon ---
OUT=$(run_hook "$WRITE_EVENT" unset 2>&1)
RC=$?
wait_status
if [ "$RC" -eq 0 ] && [ ! -e "$TEST_ROOT/workspace/GOVREPO/exocortex" ] && echo "$OUT" | grep -q "freeze" \
   && echo "$OUT" | grep -q "в фоне" && grep -q '^result=fail' "$STATUS" 2>/dev/null; then
    pass "T1: frozen by default — no write into the canon, publish handed to exocortex-publish.sh (non-git canon → status=fail recorded), hook exits 0"
else
    fail "T1: expected hand-off (exit 0, no exocortex/, 'в фоне', status=fail), got rc=$RC out=[$OUT] status=[$(cat "$STATUS" 2>/dev/null)] exocortex-exists=$([ -e "$TEST_ROOT/workspace/GOVREPO/exocortex" ] && echo yes || echo no)"
fi

# --- T2: frozen by default — Bash-reconcile branch hands a changed memory off too ---
rm -f "$STATUS"
touch "$TEST_ROOT/workspace/memory/test-file.md"
OUT=$(IWE_EXOCORTEX_PUBLISH_MIN_INTERVAL=0 run_hook "$BASH_EVENT" unset 2>&1)
RC=$?
wait_status
if [ "$RC" -eq 0 ] && [ ! -e "$TEST_ROOT/workspace/GOVREPO/exocortex" ] && echo "$OUT" | grep -q "в фоне"; then
    pass "T2: frozen by default, Bash-reconcile path — no canon write, change handed to the publisher"
else
    fail "T2: expected hand-off on Bash-reconcile branch too, got rc=$RC out=[$OUT]"
fi

# --- T2b: Bash event with nothing changed since the snapshot — no background run at all ---
OUT=$(run_hook "$BASH_EVENT" unset 2>&1)
RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ ! -e "$TEST_ROOT/workspace/GOVREPO/exocortex" ]; then
    pass "T2b: unchanged memory under freeze — hook stays silent, nothing started"
else
    fail "T2b: expected silence for an unchanged tree, got rc=$RC out=[$OUT]"
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

# --- T5: default freeze, but the run holds --canonical-owner (strategist.sh passes it) — mirror must work ---
rm -rf "$TEST_ROOT/workspace/GOVREPO/exocortex"
OUT=$(run_hook "$WRITE_EVENT" unset "week-review-2026-10-23-123" 2>&1)
RC=$?
if [ "$RC" -eq 0 ] && [ -f "$MIRRORED" ] && [ "$(cat "$MIRRORED")" = "hello" ] && ! echo "$OUT" | grep -q "freeze"; then
    pass "T5: canonical-owner run under default freeze — mirror written, no skip warning"
else
    fail "T5: expected mirror under IWE_CANONICAL_OWNER, got rc=$RC mirrored-exists=$([ -f "$MIRRORED" ] && echo yes || echo no) out=[$OUT]"
fi

# --- T6: default freeze, no owner (e.g. an interactive --isolate session) — mirror into the canon skipped ---
rm -rf "$TEST_ROOT/workspace/GOVREPO/exocortex"
rm -f "$STATUS"
# No --if-due throttling here, so the background run ends with a status line
# and the sandbox is not removed under its feet.
OUT=$(IWE_EXOCORTEX_PUBLISH_MIN_INTERVAL=0 run_hook "$WRITE_EVENT" unset "" 2>&1)
RC=$?
wait_status
if [ "$RC" -eq 0 ] && [ ! -e "$TEST_ROOT/workspace/GOVREPO/exocortex" ] && echo "$OUT" | grep -q "в фоне"; then
    pass "T6: default freeze without owner — canon not written, handed to the publisher (empty IWE_CANONICAL_OWNER grants nothing)"
else
    fail "T6: expected skip with empty IWE_CANONICAL_OWNER, got rc=$RC out=[$OUT]"
fi

if [ "$FAIL" -eq 0 ]; then
    echo "test_issue_1279_exocortex_freeze: ALL PASS"
    exit 0
else
    echo "test_issue_1279_exocortex_freeze: $FAIL FAILURE(S)"
    exit 1
fi
