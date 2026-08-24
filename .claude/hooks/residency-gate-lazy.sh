#!/bin/bash
# claude-hook: false — consent CLI с четырьмя аргументами, не событие Claude
# ResidencyGate Point B: Lazy consent check at data access time
# Runs when a function tries to access specific data
# Usage: residency-gate-lazy.sh <function_id> <data_type> <flow_direction> <need_name>

set -e

if [ $# -lt 4 ]; then
  echo "Usage: residency-gate-lazy.sh <function_id> <type> <flow> <name>" >&2
  exit 1
fi

FUNCTION_ID="$1"
DATA_TYPE="$2"
FLOW_DIRECTION="$3"
NEED_NAME="$4"
# CLAUDE_ROOT = project root that CONTAINS .claude/ (default: cwd). The old
# default ".claude" produced ".claude/.claude/skills/..." — a path that never
# exists (issue #323). Kept as one self-contained assignment: T15
# (setup/test-update-edge-cases.sh) greps this exact line in isolation and
# evaluates it standalone — a second variable it doesn't grep would resolve
# empty there even though this script itself works fine end-to-end.
RESIDENCY_GATE_PY="${CLAUDE_ROOT:-.}/.claude/skills/residency-gate/residency-gate.py"

# Resolved once, before residency-gate.py runs at all (issue #521A): a
# missing PyYAML then reads as a dependency error here, not a fabricated
# "consent denied" from a crash three layers down.
PY3=$("${CLAUDE_ROOT:-.}/scripts/lib/find-python3.sh" 2>&1) || {
  echo "[ResidencyGate] Dependency error for $FUNCTION_ID/$NEED_NAME: $PY3" >&2
  exit 1
}

# `&& RC=0 || RC=$?` deliberately survives `set -e`: a bare `RESULT=$(cmd)`
# aborts the script the instant residency-gate.py exits non-zero — a genuine
# policy denial (the common case) never even reached the message below
# (found alongside #521A while fixing the same class of bug). The empty-
# result fallback guards the case residency-gate.py exits without printing
# anything at all (e.g. $RESIDENCY_GATE_PY missing) — otherwise the `jq`
# calls below see an empty string and the case statement falls through with
# nothing to show (found in cold review).
RESULT=$("$PY3" "$RESIDENCY_GATE_PY" check-lazy "$FUNCTION_ID" "$DATA_TYPE" "$FLOW_DIRECTION" "$NEED_NAME" 2>/dev/null) && RC=0 || RC=$?
[ -n "$RESULT" ] || RESULT='{"allowed":false,"error_class":"runtime_error","error":"residency-gate.py produced no output"}'

if [ "$RC" -eq 0 ]; then
  REASON=$(jq -r '.reason // empty' <<<"$RESULT" 2>/dev/null || echo "")
  echo "[ResidencyGate] Access allowed: $REASON" >&2
  exit 0
fi

# error_class distinguishes a genuine policy denial from residency-gate.py
# itself breaking (issue #521A contract: 2 invalid_manifest, 3 dependency_error,
# 4 runtime_error — absent means a normal policy_denial). jq, not grep/sed: a
# hand-rolled regex over `json.dumps` output breaks on the space it always
# inserts after `:` and truncates on any escaped quote inside the message —
# both found live in cold review, jq parses either correctly.
ERROR_CLASS=$(jq -r '.error_class // empty' <<<"$RESULT" 2>/dev/null || echo "")
DETAIL=$(jq -r '.error // .reason // empty' <<<"$RESULT" 2>/dev/null || echo "")
[ -n "$DETAIL" ] || DETAIL="$RESULT"
case "$ERROR_CLASS" in
  dependency_error) echo "[ResidencyGate] Dependency error for $FUNCTION_ID/$NEED_NAME: $DETAIL" >&2 ;;
  invalid_manifest) echo "[ResidencyGate] Invalid declaration for $FUNCTION_ID/$NEED_NAME: $DETAIL" >&2 ;;
  runtime_error) echo "[ResidencyGate] Runtime error for $FUNCTION_ID/$NEED_NAME: $DETAIL" >&2 ;;
  *) echo "[ResidencyGate] Access denied for $FUNCTION_ID/$NEED_NAME: $DETAIL" >&2 ;;
esac
exit 1
