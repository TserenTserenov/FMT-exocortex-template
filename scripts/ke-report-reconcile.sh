#!/bin/bash
# WP-170/WP-569: Explicit scoped writer; no implicit whole-queue mutation.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KE_PYTHON=$(bash "$SCRIPT_DIR/lib/find-python3.sh") || exit 1
exec "$KE_PYTHON" "$SCRIPT_DIR/ke-report-state.py" reconcile "$@"
