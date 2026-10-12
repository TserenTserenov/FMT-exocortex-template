#!/usr/bin/env bash
# issue #1213: when day-rhythm-config.yaml can't be read (missing file, no
# python3), the strategy_day guard used to fall back to a hardcoded "monday"
# default regardless of the config's real content -- a config outage on an
# actual Monday silently blocked DayPlan generation (exit 2) with no visible
# cause. The guard must now skip (not guess) when the config is unreadable.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCAFFOLD="$ROOT/scripts/day-open-scaffold.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/iwe-day-open-1213.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail=0
pass() { echo "  ✅ PASS: $*"; }
fail_test() { echo "  ❌ FAIL: $*" >&2; fail=1; }

WORKSPACE="$TEST_ROOT/workspace"
mkdir -p "$WORKSPACE/memory" "$WORKSPACE/DS-strategy/current"
MONDAY="2026-10-12"

# No day-rhythm-config.yaml at all -> YAML_PARSE_OK=false -> guard must not
# fire just because today happens to be a real Monday.
out=$(IWE_WORKSPACE="$WORKSPACE" bash "$SCAFFOLD" "$MONDAY" 2>"$TEST_ROOT/stderr.log")
rc=$?
if [ "$rc" != 2 ]; then
  pass "missing config on a real Monday: exit $rc (not the false-positive 2)"
else
  fail_test "missing config on a real Monday still exits 2"
fi
grep -q "strategy_day не проверен" "$TEST_ROOT/stderr.log" \
  && pass "warns about the unverified strategy_day guard" \
  || fail_test "no warning emitted for the unreadable config (stderr: $(cat "$TEST_ROOT/stderr.log"))"
[ -n "$out" ] && pass "DayPlan body still produced despite the unreadable config" \
  || fail_test "no output at all for the missing-config Monday run"

# A readable config that explicitly sets strategy_day: monday must still guard.
cat > "$WORKSPACE/memory/day-rhythm-config.yaml" <<'YAML'
day_open:
  strategy_day: monday
YAML
if command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" >/dev/null 2>&1; then
  IWE_WORKSPACE="$WORKSPACE" bash "$SCAFFOLD" "$MONDAY" >/dev/null 2>"$TEST_ROOT/stderr2.log"
  rc=$?
  [ "$rc" = 2 ] && pass "readable config with strategy_day: monday still guards a real Monday" \
    || fail_test "readable config no longer guards strategy_day (exit $rc)"
else
  echo "  (skipped: python3+PyYAML unavailable, cannot exercise the readable-config branch)"
fi

exit "$fail"
