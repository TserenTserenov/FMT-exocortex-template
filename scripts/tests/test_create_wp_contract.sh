#!/usr/bin/env bash
# Contract test for bug #338: create-wp.sh must guarantee atomic registry coherence.
# Inject fault (make WeekPlan readonly) and verify rollback or full success, not partial.

set -euo pipefail

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

cd "$TMPDIR"
cp -r "${IWE_TEMPLATE:-$HOME/IWE/FMT-exocortex-template}/seed/strategy" .
cd strategy

export IWE_GOVERNANCE_REPO="."
export IWE_TEMPLATE="${IWE_TEMPLATE:-$HOME/IWE/FMT-exocortex-template}"

# Capture initial state
INITIAL_REGISTRY_COUNT=$(grep -c "^| WP-" docs/WP-REGISTRY.md 2>/dev/null || echo 0)
INITIAL_INBOX_COUNT=$(find inbox -type d -name "WP-*" 2>/dev/null | wc -l)

# Inject fault: make WeekPlan readonly to force mid-stream failure
WEEKPLAN=$(find current -maxdepth 1 -name "WeekPlan*.md" | head -1)
chmod 444 "$WEEKPLAN"

# Attempt create-wp
EXIT_CODE=0
bash "$IWE_TEMPLATE/scripts/create-wp.sh" \
  --title "Contract Test WP" \
  --budget "1h" \
  --priority "P4" \
  --no-consent-check \
  2>&1 | head -20 || EXIT_CODE=$?

chmod 644 "$WEEKPLAN"

echo "Exit code: $EXIT_CODE"

# Verify atomicity
FINAL_REGISTRY_COUNT=$(grep -c "^| WP-" docs/WP-REGISTRY.md 2>/dev/null || echo 0)
FINAL_INBOX_COUNT=$(find inbox -type d -name "WP-*" 2>/dev/null | wc -l)

if [ "$EXIT_CODE" -ne 0 ]; then
  # Failure path: state should be rolled back
  if [ "$FINAL_REGISTRY_COUNT" -ne "$INITIAL_REGISTRY_COUNT" ] || [ "$FINAL_INBOX_COUNT" -ne "$INITIAL_INBOX_COUNT" ]; then
    echo "FAIL: Partial state after failure (atomicity violated)" >&2
    exit 1
  fi
  echo "✓ Correctly rolled back after fault injection"
  exit 0
else
  # Success path: all locations should be consistent
  if [ "$FINAL_REGISTRY_COUNT" -gt "$INITIAL_REGISTRY_COUNT" ] && [ "$FINAL_INBOX_COUNT" -gt "$INITIAL_INBOX_COUNT" ]; then
    echo "✓ Atomic success: all locations updated consistently"
    exit 0
  else
    echo "FAIL: Partial success (not atomic)" >&2
    exit 1
  fi
fi
