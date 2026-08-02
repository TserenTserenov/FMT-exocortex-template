#!/usr/bin/env bash
# Contract test for bug #339: capture-bus.sh must handle detector crash without blocking.
# Inject crash mid-loop and verify continued execution and degraded (non-zero) status.

set -euo pipefail

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

cd "$TMPDIR"

# Prepare config with 3 detectors: 1 succeeds, 2 crashes mid-loop
cat > capture-config.yaml <<'EOF'
detectors:
  - name: detector-1-ok
    path: ./detector-1.sh
    event_type: capture
    cost_class: free
    enabled: true
  - name: detector-2-crash
    path: ./detector-2.sh
    event_type: capture
    cost_class: free
    enabled: true
  - name: detector-3-ok
    path: ./detector-3.sh
    event_type: capture
    cost_class: free
    enabled: true
EOF

# Detector 1: success
cat > detector-1.sh <<'EOF'
#!/bin/bash
echo "detector-1: OK"
EOF
chmod +x detector-1.sh

# Detector 2: crash after brief delay (simulate mid-loop failure)
cat > detector-2.sh <<'EOF'
#!/bin/bash
sleep 1
echo "detector-2: crashing" >&2
exit 1
EOF
chmod +x detector-2.sh

# Detector 3: success
cat > detector-3.sh <<'EOF'
#!/bin/bash
echo "detector-3: OK"
EOF
chmod +x detector-3.sh

# Get capture-bus.sh hook
CAPTURE_BUS="${IWE_TEMPLATE:-$HOME/IWE/FMT-exocortex-template}/.claude/hooks/capture-bus.sh"
if [ ! -f "$CAPTURE_BUS" ]; then
  echo "capture-bus.sh not found" >&2
  exit 1
fi

# Run hook with short timeout to force detector 2 crash
export CAPTURE_DETECTOR_TIMEOUT_SECONDS=10
export CAPTURE_CONFIG_FILE="./capture-config.yaml"
export IWE_SCRIPTS="${IWE_SCRIPTS:-$HOME/IWE/scripts}"

START=$(date +%s)
EXIT_CODE=0
bash "$CAPTURE_BUS" 2>&1 | tee capture-output.txt > /dev/null || EXIT_CODE=$?
END=$(date +%s)
ELAPSED=$((END - START))

echo "Elapsed: ${ELAPSED}s"
echo "Exit code: $EXIT_CODE"

# Verify contract:
# 1. Hook should NOT return success (0) when detector crashes
# 2. Execution should continue past detector 2 (detector 3 should run)
# 3. Hook should complete within timeout window (not block)

if [ $EXIT_CODE -eq 0 ]; then
  echo "FAIL: Hook returned 0 (success) despite detector crash" >&2
  exit 1
fi

if ! grep -q "detector-3" capture-output.txt; then
  echo "FAIL: Hook did not continue past crashed detector" >&2
  exit 1
fi

if [ $ELAPSED -gt 30 ]; then
  echo "FAIL: Hook blocked too long (${ELAPSED}s)" >&2
  exit 1
fi

echo "✓ Contract verified: non-zero status, continued execution, no blocking"
exit 0
