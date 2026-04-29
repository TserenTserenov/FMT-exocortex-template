#!/bin/bash
# test-detectors.sh — regression test для detector regex'ов в integration-contract-validator.sh
#
# # see VR.SC.006 (release-verification-protocol), VR.M.006 (5-layer verification, слой 4)
# # see AR.203 (release verification trigger)
#
# Назначение: ловить regex-gap регрессии (как 0.29.14 backtick+slash).
# Каждый detector тестируется на исторических positive/negative samples в
# setup/detector-fixtures/.
#
# Усложнение: detector'ы скопированы как inline grep-паттерны в validator.
# Поэтому test runner запускает РЕАЛЬНЫЕ regex-паттерны через тот же grep,
# а не вызывает validator целиком (избегает false-positive из manifest и пр.).
#
# Usage:
#   bash setup/test-detectors.sh [--verbose]
#
# Exit:
#   0 — все fixtures прошли (positive caught, negative not caught)
#   N — N fixtures failed

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="$(dirname "$SCRIPT_DIR")"
FIXTURES_DIR="$SCRIPT_DIR/detector-fixtures"
VERBOSE=false

[ "${1:-}" = "--verbose" ] && VERBOSE=true

cd "$TEMPLATE_DIR"

FAIL=0
PASS=0

# Detector regex'ы — shared source (0.29.19 DRY fix).
# При добавлении detector_08+ — пополнять detector-regex.sh.
# shellcheck source=detector-regex.sh
. "$SCRIPT_DIR/detector-regex.sh"

run_test() {
    local detector_id="$1"
    local fixture="$2"
    local expect="$3"  # "positive" (должен поймать) | "negative" (не должен)
    local regex="$4"

    local matched=0
    if grep -qE "$regex" "$fixture" 2>/dev/null; then
        matched=1
    fi

    if [ "$expect" = "positive" ] && [ "$matched" -eq 1 ]; then
        $VERBOSE && echo "  ✅ PASS: detector #$detector_id caught $(basename "$fixture")"
        PASS=$((PASS + 1))
    elif [ "$expect" = "negative" ] && [ "$matched" -eq 0 ]; then
        $VERBOSE && echo "  ✅ PASS: detector #$detector_id correctly ignored $(basename "$fixture")"
        PASS=$((PASS + 1))
    elif [ "$expect" = "positive" ] && [ "$matched" -eq 0 ]; then
        echo "  ❌ FAIL: detector #$detector_id MISSED positive sample: $fixture"
        echo "     Regex regressed — паттерн больше не ловится. См. CHANGELOG за detector $detector_id fix."
        FAIL=$((FAIL + 1))
    else
        echo "  ❌ FAIL: detector #$detector_id false-positive on negative sample: $fixture"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Detector regex regression tests ==="
echo ""

# Detector #7 fixtures
for f in "$FIXTURES_DIR"/detector_07/positive_*.md; do
    [ -f "$f" ] || continue
    run_test "07" "$f" "positive" "$DETECTOR_07_REGEX"
done
for f in "$FIXTURES_DIR"/detector_07/negative_*.md; do
    [ -f "$f" ] || continue
    run_test "07" "$f" "negative" "$DETECTOR_07_REGEX"
done

# (Дополнительные detector fixtures добавляются по мере появления regex-регрессий)

echo ""
echo "=================================================="
if [ "$FAIL" -eq 0 ]; then
    echo "  ✅ Detector regex tests: PASS ($PASS fixtures)"
    exit 0
else
    echo "  ❌ Detector regex tests: $FAIL failed of $((FAIL + PASS))"
    exit "$FAIL"
fi
