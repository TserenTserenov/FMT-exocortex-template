#!/usr/bin/env bash
# Run regression tests for bug fixes (#338, #339, #340).
# Used in CI and pre-commit validation.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/tests" && pwd)"
FAILED=0

echo "Running regression tests..."
echo ""

for test_script in "$TEST_DIR"/test_*.sh; do
  # Include regression tests + contract tests; skip validator (runs separately)
  test_base=$(basename "$test_script" .sh)
  [[ "$test_base" == "validate_manifest_coverage" ]] && continue

  test_name=$test_base
  echo "Running: $test_name"

  if bash "$test_script"; then
    echo "✓ $test_name PASSED"
  else
    echo "✗ $test_name FAILED"
    FAILED=$((FAILED + 1))
  fi
  echo ""
done

# Run validator separately (ensures manifest completeness)
echo "Running: validate_manifest_coverage"
if bash "$TEST_DIR/validate_manifest_coverage.sh"; then
  echo "✓ validate_manifest_coverage PASSED"
else
  echo "✗ validate_manifest_coverage FAILED"
  FAILED=$((FAILED + 1))
fi
echo ""

if [ $FAILED -eq 0 ]; then
  echo "✓ All regression tests passed"
  exit 0
else
  echo "✗ $FAILED test(s) failed"
  exit 1
fi
