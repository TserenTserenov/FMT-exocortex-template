#!/usr/bin/env bash
# Validator: ensure all test files are listed in update-manifest.json
# This prevents silent omission of tests from template delivery.

set -euo pipefail

MANIFEST="${IWE_TEMPLATE:-$HOME/IWE/FMT-exocortex-template}/update-manifest.json"
TEST_DIR="${IWE_TEMPLATE:-$HOME/IWE/FMT-exocortex-template}/scripts/tests"

if [ ! -f "$MANIFEST" ]; then
  echo "ERROR: update-manifest.json not found" >&2
  exit 1
fi

MISSING=0

# Check test files (regression + contract + validator)
for test_file in "$TEST_DIR"/test_*.sh; do
  [ -f "$test_file" ] || continue
  basename=$(basename "$test_file")

  if ! grep -q "\"$basename\"" "$MANIFEST"; then
    echo "ERROR: $basename not in update-manifest.json" >&2
    MISSING=$((MISSING + 1))
  fi
done

# Check runner
if ! grep -q "run-regression-tests.sh" "$MANIFEST"; then
  echo "ERROR: run-regression-tests.sh not in update-manifest.json" >&2
  MISSING=$((MISSING + 1))
fi

if [ $MISSING -gt 0 ]; then
  echo "FAIL: $MISSING file(s) missing from manifest" >&2
  exit 1
fi

echo "✓ All test files covered in update-manifest.json"
exit 0
