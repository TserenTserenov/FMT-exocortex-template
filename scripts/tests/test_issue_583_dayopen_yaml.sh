#!/usr/bin/env bash
# Regression coverage for issue #583: extensions/day-open.checks.md blocked
# every DayPlan generated with a YAML frontmatter, because both default
# blocks read the physical first line ("head -1") instead of the first
# '# '-heading, and the date-match block died silently under `set -e` when
# the header search came up empty (no message, just "N/3 failed").
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TMP_ROOT"' EXIT

pass_count=0
pass() { echo "  ✅ PASS: $*"; pass_count=$((pass_count + 1)); }
fail() { echo "  ❌ FAIL: $*" >&2; exit 1; }

# Shell out to the real entrypoint (day-open-checks-runner.sh), not a
# sourced lib call: that script deliberately runs under `set -uo pipefail`
# WITHOUT `-e` (day-open-hooks.sh's per-block `( set -e; eval "$block" )`
# isolation relies on the caller not already having errexit on) — sourcing
# the lib into this test's own `set -e` shell breaks that isolation and
# aborts the whole run the instant a block is meant to fail.
CHECKS_RUNNER_OUT=""
CHECKS_RUNNER_RC=0
run_checks() {
  local dayplan="$1"
  if CHECKS_RUNNER_OUT=$(IWE_ROOT="$ROOT" bash "$ROOT/scripts/day-open-checks-runner.sh" "$dayplan" 2>&1); then
    CHECKS_RUNNER_RC=0
  else
    CHECKS_RUNNER_RC=$?
  fi
}

echo "--- YAML-frontmatter DayPlan, date matches filename (real scaffold shape) ---"
plan="$TMP_ROOT/DayPlan 2026-08-30.md"
cat > "$plan" <<'EOF'
---
type: daily-plan
date: 2026-08-30
---

# Day Plan: 30 августа 2026 (Воскресенье)

## Требует внимания

- нет
EOF
run_checks "$plan"
if [ "$CHECKS_RUNNER_RC" -eq 0 ]; then
  pass "YAML-frontmatter DayPlan with matching date passes all default checks"
else
  echo "$CHECKS_RUNNER_OUT" >&2
  fail "YAML-frontmatter DayPlan still blocked — issue #583 not fixed"
fi

echo "--- YAML-frontmatter DayPlan, H1 date mismatched (negative control) ---"
# Real scaffold output writes the H1 in human Russian ("30 августа 2026"),
# which never contains an ISO date, so this block's comparison is normally
# a no-op (documented as "if the date is even there"). Use an explicit ISO
# date in H1 to actually exercise the comparison logic itself.
mismatch="$TMP_ROOT/DayPlan 2026-08-30.md"
cat > "$mismatch" <<'EOF'
---
type: daily-plan
date: 2026-08-29
---

# Day Plan: 2026-08-29 (Суббота)
EOF
run_checks "$mismatch"
if [ "$CHECKS_RUNNER_RC" -ne 0 ] && printf '%s' "$CHECKS_RUNNER_OUT" | grep -q "не совпадает с именем файла"; then
  pass "date mismatch between filename and H1 is still caught (fix did not remove the real check)"
else
  echo "$CHECKS_RUNNER_OUT" >&2
  fail "date-mismatch negative control passed — the fix silently disabled the check, not just the false positive"
fi

echo "--- YAML-frontmatter DayPlan with no '# '-heading anywhere (must fail loudly, not silently) ---"
noheading="$TMP_ROOT/DayPlan 2026-08-28.md"
cat > "$noheading" <<'EOF'
---
type: daily-plan
date: 2026-08-28
---

Просто текст без заголовка первого уровня.
EOF
run_checks "$noheading"
if [ "$CHECKS_RUNNER_RC" -ne 0 ] && printf '%s' "$CHECKS_RUNNER_OUT" | grep -q "нет ни одного"; then
  pass "DayPlan without any H1 heading is blocked with a visible failure, not a silent set -e death"
else
  echo "$CHECKS_RUNNER_OUT" >&2
  fail "DayPlan without H1 either passed, or failed silently — checks are not fail-closed with a message"
fi

echo "issue-583 day-open.checks.md YAML fix: $pass_count checks passed"
