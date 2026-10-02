#!/usr/bin/env bash
# Regression coverage for the memory/-symlink half of issue #912.
#
# On a stock install `memory/` is a symlink to the agent's auto-memory store
# outside the workspace. extensions-gate.sh resolved the symlink (needed to
# catch a skill-folder symlink escape) but then compared the resolved path
# only against the workspace root -- a file reached through memory/ resolves
# outside that root, so the gate treated protocol-*.md files reached through
# the link as "external" and allowed any edit, unprotected. This is a live
# gap independent of the Windows path-form half of #912 (which needs a real
# Windows host to verify and is not covered here): reproducible on this
# machine with a plain symlink.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
HOOK_SRC="$ROOT/.claude/hooks/extensions-gate.sh"

PYTHON=$(command -v python3 || true)
if [ -z "$PYTHON" ] || ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: python3 and jq are required by the hook under test"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
WS="$TMP/ws"
MEMORY_TARGET="$TMP/real-memory-outside-workspace"

mkdir -p "$WS/.claude/hooks" "$MEMORY_TARGET"
cp "$HOOK_SRC" "$WS/.claude/hooks/extensions-gate.sh"
chmod +x "$WS/.claude/hooks/extensions-gate.sh"
printf 'placeholder\n' > "$MEMORY_TARGET/protocol-open.md"
ln -s "$MEMORY_TARGET" "$WS/memory"

fail=0
pass() { echo "  ✅ PASS: $*"; }
fail_test() { echo "  ❌ FAIL: $*" >&2; fail=1; }

FILE_PATH="$WS/memory/protocol-open.md"
PAYLOAD=$("$PYTHON" -c '
import json, sys
print(json.dumps({"session_id": "t", "hook_event_name": "PreToolUse", "tool_name": "Edit",
                  "tool_input": {"file_path": sys.argv[1], "old_string": "placeholder", "new_string": "changed"}}))
' "$FILE_PATH")

OUT=$(printf '%s' "$PAYLOAD" | env -u IWE_TEMPLATE -u IWE_SCRIPTS "$WS/.claude/hooks/extensions-gate.sh" 2>&1)
RC=$?

if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qF '"decision": "block"'; then
    pass "editing memory/protocol-open.md through the symlink is denied (was: silently allowed as 'external')"
else
    fail_test "expected a block decision, got rc=$RC: $OUT"
fi

# Sanity: a file genuinely outside the workspace (not through memory/) must
# still be treated as external and left alone -- the fix must not turn the
# gate into "protect everything reachable from anywhere".
OUTSIDE="$TMP/outside/notes.md"
mkdir -p "$TMP/outside"
printf 'placeholder\n' > "$OUTSIDE"
PAYLOAD2=$("$PYTHON" -c '
import json, sys
print(json.dumps({"session_id": "t", "hook_event_name": "PreToolUse", "tool_name": "Edit",
                  "tool_input": {"file_path": sys.argv[1], "old_string": "placeholder", "new_string": "changed"}}))
' "$OUTSIDE")
OUT2=$(printf '%s' "$PAYLOAD2" | env -u IWE_TEMPLATE -u IWE_SCRIPTS "$WS/.claude/hooks/extensions-gate.sh" 2>&1)
RC2=$?
if [ "$RC2" -eq 0 ] && ! printf '%s' "$OUT2" | grep -qF '"decision": "block"'; then
    pass "a genuinely external file (unrelated to memory/) stays editable"
else
    fail_test "expected ALLOW for an unrelated external file, got rc=$RC2: $OUT2"
fi

if [ "$fail" -eq 0 ]; then
    echo "✅ test_issue_912_extensions_gate_memory_symlink: all checks passed (Windows path-form half of #912 needs a real Windows host, not covered here)"
fi
exit "$fail"
