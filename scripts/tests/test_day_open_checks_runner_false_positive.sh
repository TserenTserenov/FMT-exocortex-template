#!/usr/bin/env bash
set -euo pipefail

# issue #466: day-open-checks-runner.sh reported "all checks passed" without
# ever executing a check block, in two independent ways:
#   1. When extensions/day-open.checks.md was missing, awk's stdout was
#      empty, the `while read -d ''` loop body never ran, and the error
#      counter stayed at 0 — indistinguishable from "every check passed".
#   2. The check-file path was hardcoded to a single filename, so a file
#      following the documented multi-file convention (e.g.
#      day-open.checks.moi.md, same pattern load-extensions.sh supports)
#      was invisible to the runner and produced the same false "all checks
#      passed".

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/extensions" "$TMP/DS-strategy/current"
echo "test dayplan" > "$TMP/DS-strategy/current/DayPlan 2026-08-18.md"

run_runner() {
  IWE_ROOT="$TMP" IWE_GOVERNANCE_REPO="DS-strategy" \
    bash "$ROOT/scripts/day-open-checks-runner.sh" 2>&1
}

# --- Case 1: no checks file at all — must fail, not silently pass ---
OUT=$(run_runner) && STATUS=0 || STATUS=$?
if [ "$STATUS" -eq 0 ]; then
  echo "FAIL (expected, unpatched): runner reported success with no checks file present"
  echo "$OUT"
  exit 1
fi
if ! echo "$OUT" | grep -q "nothing to check"; then
  echo "FAIL: expected a 'nothing to check' diagnostic, got:"
  echo "$OUT"
  exit 1
fi

# --- Case 2: split-file convention (day-open.checks.moi.md) must be found and run ---
cat > "$TMP/extensions/day-open.checks.moi.md" <<'EOF'
# split checks file

```bash
echo "split file check ran"
true
```
EOF

OUT=$(run_runner) && STATUS=0 || STATUS=$?
if [ "$STATUS" -ne 0 ]; then
  echo "FAIL (expected, unpatched): split-file day-open.checks.moi.md was not picked up"
  echo "$OUT"
  exit 1
fi
if ! echo "$OUT" | grep -q "split file check ran"; then
  echo "FAIL: split-file check block did not execute"
  echo "$OUT"
  exit 1
fi
if ! echo "$OUT" | grep -q "all 1 check(s) passed"; then
  echo "FAIL: expected exactly 1 check to have run, got:"
  echo "$OUT"
  exit 1
fi

# --- Case 3: a genuinely failing check block must still be caught ---
cat > "$TMP/extensions/day-open.checks.moi.md" <<'EOF'
# split checks file, failing block

```bash
echo "this check fails"
false
```
EOF

OUT=$(run_runner) && STATUS=0 || STATUS=$?
if [ "$STATUS" -eq 0 ]; then
  echo "FAIL: a failing check block was not detected as a failure"
  echo "$OUT"
  exit 1
fi
if ! echo "$OUT" | grep -q "1/1 block(s) failed"; then
  echo "FAIL: expected a 1/1 failure count, got:"
  echo "$OUT"
  exit 1
fi

echo "PASS: day-open-checks-runner.sh fails honestly on missing checks, picks up split-file convention, and still catches real failures"
