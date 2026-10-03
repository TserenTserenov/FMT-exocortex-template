#!/usr/bin/env bash
# issue #1038: Python's explicit empty-value fallback is a safe governance default.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VALIDATOR="$ROOT/scripts/validate-fmt-scripts.sh"
FIXTURE_DIR=$(mktemp -d)
trap 'rm -rf "$FIXTURE_DIR"' EXIT

cat > "$FIXTURE_DIR/safe.py" <<'EOF'
import os
governance = os.environ.get("IWE_GOVERNANCE_REPO") or "DS-strategy"
EOF

if ! env -u IWE_GOVERNANCE_REPO bash "$VALIDATOR" --scripts --files "$FIXTURE_DIR/safe.py" >/dev/null 2>&1; then
    echo "FAIL: explicit Python env fallback was rejected" >&2
    exit 1
fi

cat > "$FIXTURE_DIR/unsafe.py" <<'EOF'
import os
governance = "DS-strategy"; fallback = os.environ.get("IWE_GOVERNANCE_REPO") or "DS-strategy"
EOF

if env -u IWE_GOVERNANCE_REPO bash "$VALIDATOR" --scripts --files "$FIXTURE_DIR/unsafe.py" >/dev/null 2>&1; then
    echo "FAIL: hardcode before a safe fallback was accepted" >&2
    exit 1
fi

echo "PASS: issue #1038 validator distinguishes fallback from hardcode"
