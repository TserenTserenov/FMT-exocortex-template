#!/usr/bin/env bash
set -euo pipefail

# issue #466: an absent checks file or an ignored split file must not produce
# a false "all checks passed". WP-529 F11 adds the template's universal checks
# first, then any user split files, so a fresh install always runs real checks.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/extensions" "$TMP/DS-strategy/current"
cat > "$TMP/DS-strategy/current/DayPlan 2026-08-18.md" <<'EOF'
# DayPlan 2026-08-18

## Требует внимания

- Нет срочных сигналов.

EOF

run_runner() {
  IWE_ROOT="$TMP" IWE_TEMPLATE="$ROOT" IWE_GOVERNANCE_REPO="DS-strategy" \
    bash "$ROOT/scripts/day-open-checks-runner.sh" 2>&1
}

# --- Case 1: no user checks file — the template baseline still runs ---
OUT=$(run_runner) && STATUS=0 || STATUS=$?
if [ "$STATUS" -ne 0 ] || ! echo "$OUT" | grep -q "all 3 check(s) passed"; then
  echo "FAIL: template checks did not run without a user file"
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
if ! echo "$OUT" | grep -q "all 4 check(s) passed"; then
  echo "FAIL: expected three template checks and one user check, got:"
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
if ! echo "$OUT" | grep -q "1/4 block(s) failed"; then
  echo "FAIL: expected one failed user check among four blocks, got:"
  echo "$OUT"
  exit 1
fi

echo "PASS: day-open-checks-runner.sh runs template and user checks together and catches real failures"
