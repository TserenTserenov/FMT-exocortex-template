#!/usr/bin/env bash
# Validator: ensure all test files are listed in update-manifest.json
# This prevents silent omission of tests from template delivery.
#
# Earlier version grepped for a quoted exact basename ("test_foo.sh") — every
# manifest entry stores the FULL relative path ("scripts/tests/test_foo.sh"),
# so the character before the basename is "/", never '"'. The grep could never
# match, so this validator failed on every single test file unconditionally
# (found 03.08, running it for real: 6/6 false "not in manifest" errors on
# files that were plainly present). Now parses the manifest as JSON and checks
# the actual files[].path contract instead of grepping for a substring.

set -euo pipefail

MANIFEST="${IWE_TEMPLATE:-$HOME/IWE/FMT-exocortex-template}/update-manifest.json"
TEST_DIR="${IWE_TEMPLATE:-$HOME/IWE/FMT-exocortex-template}/scripts/tests"

if [ ! -f "$MANIFEST" ]; then
  echo "ERROR: update-manifest.json not found" >&2
  exit 1
fi

manifest_has_path() {
  python3 - "$MANIFEST" "$1" <<'PY'
import json
import sys

manifest_path, wanted = sys.argv[1:3]
with open(manifest_path, encoding="utf-8") as fh:
    data = json.load(fh)

paths = {
    item["path"]
    for item in data.get("files", [])
    if isinstance(item, dict) and isinstance(item.get("path"), str)
}
raise SystemExit(0 if wanted in paths else 1)
PY
}

MISSING=0

# find, not a `test_*.sh` glob: the glob only matched the top level of
# scripts/tests/ and silently skipped scripts/tests/lib/ — exactly the "test
# quietly falls out of template delivery" failure mode this validator exists
# to catch (found in review 03.08, when scripts/tests/lib/capture_fixture.sh
# was added and this validator had no way to notice a missing entry for it).
while IFS= read -r test_file; do
  relative="scripts/tests/${test_file#"$TEST_DIR"/}"
  if ! manifest_has_path "$relative"; then
    echo "ERROR: $relative not in update-manifest.json" >&2
    MISSING=$((MISSING + 1))
  fi
done < <(find "$TEST_DIR" -name '*.sh' -type f)

if ! manifest_has_path "scripts/run-regression-tests.sh"; then
  echo "ERROR: scripts/run-regression-tests.sh not in update-manifest.json" >&2
  MISSING=$((MISSING + 1))
fi

if [ $MISSING -gt 0 ]; then
  echo "FAIL: $MISSING file(s) missing from manifest" >&2
  exit 1
fi

echo "✓ All test files covered in update-manifest.json"
