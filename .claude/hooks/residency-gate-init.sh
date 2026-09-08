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
# exists (issue #323).
RESIDENCY_GATE_PY="${CLAUDE_ROOT:-.}/.claude/skills/residency-gate/residency-gate.py"
PROJECT_ROOT="${CLAUDE_ROOT:-.}"
RUNNER="$PROJECT_ROOT/.claude/lib/residency-gate-run.sh"

if [ ! -r "$RUNNER" ]; then
  echo "[ResidencyGate:dependency_error] Shared runner is missing: $RUNNER" >&2
  return 1
fi

# shellcheck source=/dev/null
source "$RUNNER"
residency_gate_run "$PROJECT_ROOT" "$RESIDENCY_GATE_PY" \
  check-activation "$FUNCTION_ID" "$MANIFEST_FILE"

DETAIL=$(residency_gate_human_detail)
case "$RESIDENCY_GATE_OUTCOME" in
  allowed)
    return 0
    ;;
  policy_denied)
    echo "[ResidencyGate:policy_denied] Function '$FUNCTION_ID' blocked at activation time" >&2
    echo "[ResidencyGate] Blocking reasons: $DETAIL" >&2
    ;;
  manifest_invalid)
    echo "[ResidencyGate:manifest_invalid] Invalid data-needs declaration for '$FUNCTION_ID': $DETAIL" >&2
    ;;
  dependency_error)
    echo "[ResidencyGate:dependency_error] PyYAML-capable Python is unavailable: $DETAIL" >&2
    ;;
  *)
    echo "[ResidencyGate:runtime_error] Consent could not be checked safely for '$FUNCTION_ID': $DETAIL" >&2
    ;;
esac
return 1
