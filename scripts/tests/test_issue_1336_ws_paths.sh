#!/usr/bin/env bash
# Regression for issue #1336: memory-exocortex-sync.sh and
# restore-from-exocortex.sh computed WORKSPACE_DIR as "${WORKSPACE_DIR:-$HOME/IWE}"
# and never read IWE_WORKSPACE, so on an install with a non-standard workspace
# (IWE_WORKSPACE in .iwe-paths) the mirror/restore silently went to the wrong
# path. Both scripts must resolve workspace by the conveyor canon
# (memory/dry-run-contract.md): env WORKSPACE_DIR > .iwe-paths > $HOME/IWE.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/.claude/hooks/memory-exocortex-sync.sh"
RESTORE="$ROOT/scripts/restore-from-exocortex.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/iwe-issue-1336-ws-paths.XXXXXX")"

FAIL=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
pass() { echo "  ✅ PASS: $*"; }

cleanup() {
    local rc=$?
    rm -rf -- "$TEST_ROOT"
    exit "$rc"
}
trap cleanup EXIT INT TERM

# --- fixture: a "non-standard" workspace known ONLY through $HOME/.iwe-paths ---
FAKE_HOME="$TEST_ROOT/home"
REAL_WS="$TEST_ROOT/workspace"
ENV_WS="$TEST_ROOT/env-workspace"   # decoy for the env-precedence check
mkdir -p "$FAKE_HOME" "$REAL_WS/memory" "$REAL_WS/GOVREPO" "$ENV_WS/GOVREPO" "$TEST_ROOT/cwd"

cat > "$FAKE_HOME/.iwe-paths" <<EOF
export IWE_WORKSPACE="$REAL_WS"
export GOVERNANCE_REPO="GOVREPO"
EOF

echo "hello-1336" > "$REAL_WS/memory/test-note.md"

# Hook env: no WORKSPACE_DIR, no IWE_WORKSPACE, no GOVERNANCE_REPO — the only
# source of truth is $HOME/.iwe-paths. Freeze disabled (empty override, same
# as test_issue_1279 T3) so the mirror itself is allowed.
run_hook() {
    printf '%s' "$1" | \
        env -u WORKSPACE_DIR -u IWE_WORKSPACE -u GOVERNANCE_REPO -u IWE_GOVERNANCE_REPO \
            HOME="$FAKE_HOME" \
            IWE_FROZEN_CANONICAL_PATH= \
            IWE_MEMORY_SRC="$REAL_WS/memory" \
            bash "$HOOK"
}

WRITE_EVENT=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$REAL_WS/memory/test-note.md")
MIRRORED="$REAL_WS/GOVREPO/exocortex/test-note.md"
WRONG_MIRROR="$FAKE_HOME/IWE/GOVREPO/exocortex/test-note.md"

# --- T1: hook resolves workspace from .iwe-paths and mirrors there ---
OUT=$(cd "$TEST_ROOT/cwd" && run_hook "$WRITE_EVENT" 2>&1)
RC=$?
if [ "$RC" -eq 0 ] && [ -f "$MIRRORED" ] && [ "$(cat "$MIRRORED")" = "hello-1336" ] && [ ! -e "$WRONG_MIRROR" ]; then
    pass "T1: hook mirrors into .iwe-paths workspace, not into \$HOME/IWE"
else
    fail "T1: expected mirror at .iwe-paths workspace, got rc=$RC mirrored=$([ -f "$MIRRORED" ] && echo yes || echo no) wrong=$([ -e "$WRONG_MIRROR" ] && echo yes || echo no) out=[$OUT]"
fi

# --- T2: explicit WORKSPACE_DIR env still wins over .iwe-paths ---
echo "env-wins" > "$REAL_WS/memory/env-note.md"
ENV_EVENT=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$REAL_WS/memory/env-note.md")
OUT=$(cd "$TEST_ROOT/cwd" && printf '%s' "$ENV_EVENT" | \
    env -u IWE_WORKSPACE -u GOVERNANCE_REPO -u IWE_GOVERNANCE_REPO \
        HOME="$FAKE_HOME" \
        WORKSPACE_DIR="$ENV_WS" \
        IWE_FROZEN_CANONICAL_PATH= \
        IWE_MEMORY_SRC="$REAL_WS/memory" \
        bash "$HOOK" 2>&1)
RC=$?
if [ "$RC" -eq 0 ] && [ -f "$ENV_WS/GOVREPO/exocortex/env-note.md" ] && [ ! -e "$REAL_WS/GOVREPO/exocortex/env-note.md" ]; then
    pass "T2: env WORKSPACE_DIR overrides .iwe-paths"
else
    fail "T2: expected env override to win, got rc=$RC env-mirror=$([ -f "$ENV_WS/GOVREPO/exocortex/env-note.md" ] && echo yes || echo no) file-mirror=$([ -e "$REAL_WS/GOVREPO/exocortex/env-note.md" ] && echo yes || echo no) out=[$OUT]"
fi

# --- T3: restore resolves workspace from .iwe-paths (no env at all) ---
RESTORE_CASE="$TEST_ROOT/restore-case"
RESTORE_WS="$RESTORE_CASE/ws"
mkdir -p "$RESTORE_WS/GOVREPO/exocortex" "$RESTORE_CASE/home"
echo "restored-1336" > "$RESTORE_WS/GOVREREPO_UNUSED" 2>/dev/null || true
rm -f "$RESTORE_WS/GOVREREPO_UNUSED"
echo "restored-1336" > "$RESTORE_WS/GOVREPO/exocortex/restored-note.md"
cat > "$RESTORE_CASE/home/.iwe-paths" <<EOF
export IWE_WORKSPACE="$RESTORE_WS"
export GOVERNANCE_REPO="GOVREPO"
EOF

OUT=$(cd "$TEST_ROOT/cwd" && \
    env -u WORKSPACE_DIR -u IWE_WORKSPACE -u IWE_ROOT -u GOVERNANCE_REPO -u IWE_GOVERNANCE_REPO -u IWE_MEMORY_SRC \
        HOME="$RESTORE_CASE/home" \
        bash "$RESTORE" "$RESTORE_WS/GOVREPO" --force 2>&1)
RC=$?
RESTORED="$RESTORE_WS/memory/restored-note.md"
WRONG_RESTORED="$RESTORE_CASE/home/IWE/memory/restored-note.md"
if [ "$RC" -eq 0 ] && [ -f "$RESTORED" ] && [ "$(cat "$RESTORED")" = "restored-1336" ] && [ ! -e "$WRONG_RESTORED" ]; then
    pass "T3: restore resolves workspace from .iwe-paths, memory lands in the real workspace"
else
    fail "T3: expected restore into .iwe-paths workspace, got rc=$RC restored=$([ -f "$RESTORED" ] && echo yes || echo no) wrong=$([ -e "$WRONG_RESTORED" ] && echo yes || echo no) out=[$OUT]"
fi

if [ "$FAIL" -eq 0 ]; then
    echo "test_issue_1336_ws_paths: ALL PASS"
    exit 0
else
    echo "test_issue_1336_ws_paths: $FAIL FAILURE(S)"
    exit 1
fi
