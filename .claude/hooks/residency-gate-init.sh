#!/bin/bash
# claude-hook: false — sourced consent library с обязательными аргументами
# ResidencyGate Point A: Activation-time consent check
# Runs when a function starts (launchd trigger, day-open, etc.)
# Usage: source residency-gate-init.sh <function_id> <manifest_file>

set -e

if [ $# -lt 2 ]; then
  echo "Usage: source residency-gate-init.sh <function_id> <manifest_file>" >&2
  return 1
fi

FUNCTION_ID="$1"
MANIFEST_FILE="$2"
# CLAUDE_ROOT = project root that CONTAINS .claude/ (default: cwd). The old
# default ".claude" produced ".claude/.claude/skills/..." — a path that never
# exists (issue #323). Kept as one self-contained assignment: T15
# (setup/test-update-edge-cases.sh) greps this exact line in isolation and
# evaluates it standalone — a second variable it doesn't grep would resolve
# empty there even though this script itself works fine end-to-end.
RESIDENCY_GATE_PY="${CLAUDE_ROOT:-.}/.claude/skills/residency-gate/residency-gate.py"

# Resolved once, before residency-gate.py runs at all (issue #521A): a
# missing PyYAML then reads as a dependency error here, not the generic
# "blocked at activation time" this hook used to fabricate for any crash.
PY3=$("${CLAUDE_ROOT:-.}/scripts/lib/find-python3.sh" 2>&1) || {
  echo "[ResidencyGate] Dependency error for '$FUNCTION_ID': $PY3" >&2
  return 1
}

# `&& RC=0 || RC=$?` survives `set -e` (this file is sourced — an unguarded
# failure here would abort the CALLER's shell, not just this script). A
# fallback embedded via `cmd || echo fallback` INSIDE the same command
# substitution does not replace a failed command's stdout — it appends to
# it, so a normal denial (residency-gate.py already printed valid JSON, then
# exited 1) produced two concatenated JSON blobs, and every code path below
# matched the hand-written fallback instead of the real one (found in cold
# review). The empty-result fallback only fires when there is truly nothing
# to parse.
RESULT=$("$PY3" "$RESIDENCY_GATE_PY" check-activation "$FUNCTION_ID" "$MANIFEST_FILE" 2>/dev/null) && RC=0 || RC=$?
[ -n "$RESULT" ] || RESULT='{"allowed":false,"error_class":"runtime_error","error":"residency-gate.py produced no output"}'

if [ "$RC" -eq 0 ]; then
  return 0
fi

# error_class distinguishes a genuine policy denial from residency-gate.py
# itself breaking (issue #521A contract: 2 invalid_manifest, 3 dependency_error,
# 4 runtime_error — absent means a normal policy_denial). jq, not grep/sed: a
# hand-rolled regex over `json.dumps` output breaks on the space it always
# inserts after `:` and truncates on any escaped quote inside the message —
# both found live in cold review, jq parses either correctly.
ERROR_CLASS=$(jq -r '.error_class // empty' <<<"$RESULT" 2>/dev/null || echo "")
DETAIL=$(jq -r '.error // (.blocking // [] | join("; ")) // empty' <<<"$RESULT" 2>/dev/null || echo "")
[ -n "$DETAIL" ] || DETAIL="$RESULT"
case "$ERROR_CLASS" in
  dependency_error) echo "[ResidencyGate] Dependency error for '$FUNCTION_ID': $DETAIL" >&2 ;;
  invalid_manifest) echo "[ResidencyGate] Invalid declaration for '$FUNCTION_ID': $DETAIL" >&2 ;;
  runtime_error) echo "[ResidencyGate] Runtime error for '$FUNCTION_ID': $DETAIL" >&2 ;;
  *)
    echo "[ResidencyGate] Function '$FUNCTION_ID' blocked at activation time" >&2
    echo "[ResidencyGate] Blocking reasons: $DETAIL" >&2
    ;;
esac
return 1
