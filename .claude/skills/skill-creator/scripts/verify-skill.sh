#!/usr/bin/env bash
# Verify the skill with the shared Python/PyYAML dependency resolver.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVER="$SCRIPT_DIR/../../../../scripts/lib/find-python3.sh"
if [ ! -f "$RESOLVER" ]; then
    echo "FAIL: Python resolver missing: $RESOLVER" >&2
    exit 1
fi
if ! PYTHON=$(bash "$RESOLVER"); then
    echo "FAIL: skill verification requires Python 3.10+ and PyYAML" >&2
    exit 1
fi
exec "$PYTHON" "$SCRIPT_DIR/verify-skill.py" "$@"
