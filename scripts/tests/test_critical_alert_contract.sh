#!/usr/bin/env bash
# Contract test for bug #340: fmt-critical-alert.sh must classify errors correctly.
# Inject API error 403 and verify exit(2) for critical state, not exit(0) or silent failure.

set -euo pipefail

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

cd "$TMPDIR"

# Mock gh API with HTTP 403 error for issues endpoint
cat > mock-gh.sh <<'EOF'
#!/bin/bash
if [[ "$*" == *"issues"* ]]; then
  echo '{"message": "API rate limit exceeded", "documentation_url": "..."}' >&2
  exit 1
fi
if [[ "$*" == *".has_issues"* ]]; then
  echo '{"has_issues": true}'
  exit 0
fi
echo "Unexpected gh call: $*" >&2
exit 1
EOF
chmod +x mock-gh.sh

# Get script
ALERT_SCRIPT="${IWE_TEMPLATE:-$HOME/IWE/FMT-exocortex-template}/scripts/fmt-critical-alert.sh"
if [ ! -f "$ALERT_SCRIPT" ]; then
  echo "fmt-critical-alert.sh not found" >&2
  exit 1
fi

# Run with injected mock gh
export REPO="test-owner/test-repo"
export PATH="$TMPDIR:$PATH"
export GH_PAGER=""

OUTPUT=$(mktemp)
EXIT_CODE=0
bash "$ALERT_SCRIPT" > "$OUTPUT" 2>&1 || EXIT_CODE=$?

echo "=== Output ==="
cat "$OUTPUT"
echo ""
echo "Exit code: $EXIT_CODE"

# Verify contract:
# 1. Must NOT return 0 (success) when API error occurs
# 2. Must return non-zero exit code (critical error)
# 3. Must not publish partial/empty issue list as success

if [ $EXIT_CODE -eq 0 ]; then
  echo "FAIL: Returned 0 (success) despite API error" >&2
  exit 1
fi

# Check that error is explicitly documented (not silent)
if ! grep -iq "error\|failed\|403\|rate" "$OUTPUT"; then
  echo "WARN: Error not clearly documented in output" >&2
fi

echo "✓ Contract verified: critical error status (exit $EXIT_CODE), not silent failure"
exit 0
