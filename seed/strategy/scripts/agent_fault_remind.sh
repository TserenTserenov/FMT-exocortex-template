#!/usr/bin/env bash
# Legacy positional protocol delegated to the Python compatibility shim.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="$(command -v python3 || true)"
if [[ -z "$PYTHON_BIN" ]]; then
    echo "ERROR: python3 is required for agent-fault" >&2
    exit 2
fi
if [[ "${1:-}" == "--stats" ]]; then
    exec "$PYTHON_BIN" "$SCRIPT_DIR/agent_fault_remind.py" "$@"
fi
PROTOCOL="${1:-work}"
[[ $# -eq 0 ]] || shift
exec "$PYTHON_BIN" "$SCRIPT_DIR/agent_fault_remind.py" \
    --protocol "$PROTOCOL" "$@"
