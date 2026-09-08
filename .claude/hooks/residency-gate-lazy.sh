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
# exists (issue #323).
RESIDENCY_GATE_PY="${CLAUDE_ROOT:-.}/.claude/skills/residency-gate/residency-gate.py"
PROJECT_ROOT="${CLAUDE_ROOT:-.}"
RUNNER="$PROJECT_ROOT/.claude/lib/residency-gate-run.sh"

if [ ! -r "$RUNNER" ]; then
  echo "[ResidencyGate:dependency_error] Shared runner is missing: $RUNNER" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$RUNNER"
residency_gate_run "$PROJECT_ROOT" "$RESIDENCY_GATE_PY" \
  check-lazy "$FUNCTION_ID" "$DATA_TYPE" "$FLOW_DIRECTION" "$NEED_NAME"

DETAIL=$(residency_gate_human_detail)
case "$RESIDENCY_GATE_OUTCOME" in
  allowed)
    echo "[ResidencyGate:allowed] Access allowed: $DETAIL" >&2
    exit 0
    ;;
  policy_denied)
    echo "[ResidencyGate:policy_denied] Access denied for $FUNCTION_ID/$NEED_NAME: $DETAIL" >&2
    ;;
  manifest_invalid)
    echo "[ResidencyGate:manifest_invalid] Invalid data-needs declaration for $FUNCTION_ID/$NEED_NAME: $DETAIL" >&2
    ;;
  dependency_error)
    echo "[ResidencyGate:dependency_error] PyYAML-capable Python is unavailable: $DETAIL" >&2
    ;;
  *)
    echo "[ResidencyGate:runtime_error] Consent could not be checked safely for $FUNCTION_ID/$NEED_NAME: $DETAIL" >&2
    ;;
esac
exit 1
