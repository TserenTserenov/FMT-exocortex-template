#!/bin/bash
# test-delivery-route-label.sh — WP-529 Ф2 acceptance test for
# scripts/check-delivery-route-label.sh: a change to a manually-curated
# delivery category must fail without a matching Delivery-Route trailer, and
# pass once the correct one is present. Runs the REAL check script against a
# throwaway git fixture — not a reimplementation of its logic.
#
# Usage: bash setup/test-delivery-route-label.sh

set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SELF_DIR")"
CHECK_SCRIPT_REAL="$REPO_ROOT/scripts/check-delivery-route-label.sh"
TEST_ROOT="${DELIVERY_ROUTE_TEST_WORKSPACE:-/tmp/iwe-delivery-route-test-$$}"

FAIL_COUNT=0
PASS_COUNT=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "  ✅ PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }

cleanup() { local rc=$?; [ "${KEEP:-0}" = "1" ] || rm -rf "$TEST_ROOT"; exit "$rc"; }
trap cleanup EXIT INT TERM

mkdir -p "$TEST_ROOT"
FIXTURE="$TEST_ROOT/repo"
mkdir -p "$FIXTURE/scripts" "$FIXTURE/docs"

# Minimal but structurally faithful fixture: check-delivery-route-label.sh's
# dump_arrays() extracts the literal block between "^SKIP_PATTERNS=(" and the
# next "^}" — this fixture keeps that exact shape (a curated array + a
# trailing function close), same as the real generate-manifest.sh, without
# needing the rest of the real generator (CHANGELOG.md lookup, git ls-files).
cat > "$FIXTURE/generate-manifest.sh" <<'EOF'
#!/bin/bash
SKIP_PATTERNS=(
    ".git/"
)
EXCLUDED_EXACT=(
    "promotion-status.yaml"
)
is_explicit_include() {
    return 1
}
EOF

cat > "$FIXTURE/docs/critical-files-map.yaml" <<'EOF'
version: 1
categories:
  - id: dev-only-excluded
    derived_from_block: EXCLUDED_EXACT
    owner: test
    proof_of_delivery: none
EOF

cat > "$FIXTURE/update-manifest.json" <<'EOF'
{"schema_version": 2, "version": "0.0.0-test", "files": []}
EOF

cp "$CHECK_SCRIPT_REAL" "$FIXTURE/scripts/check-delivery-route-label.sh"
chmod +x "$FIXTURE/scripts/check-delivery-route-label.sh"

# check-delivery-route-label.sh resolves scripts/lib/find-python3.sh relative
# to its own BASH_SOURCE location — since the line above copies it into the
# fixture, the resolver must live at the same relative path here too.
mkdir -p "$FIXTURE/scripts/lib"
cp "$REPO_ROOT/scripts/lib/find-python3.sh" "$FIXTURE/scripts/lib/find-python3.sh"

git -C "$FIXTURE" init -q
git -C "$FIXTURE" config user.email t@t
git -C "$FIXTURE" config user.name t
git -C "$FIXTURE" add -A
git -C "$FIXTURE" commit -q -m init
BASE_SHA=$(git -C "$FIXTURE" rev-parse HEAD)

run_check() {
    (cd "$FIXTURE" && bash scripts/check-delivery-route-label.sh "$BASE_SHA")
}

echo "--- Scenario A: no curated change → no label required ---"
OUT_A=$(run_check 2>&1); RC_A=$?
if [ "$RC_A" -eq 0 ] && echo "$OUT_A" | grep -q "метка не нужна"; then
    pass "A: unchanged tree passes without requiring a label"
else
    fail "A: expected exit 0 with 'метка не нужна', got exit $RC_A: $OUT_A"
fi

echo "--- Scenario B: curated array changed, no Delivery-Route trailer ---"
sed -i.bak 's/"promotion-status.yaml"/"promotion-status.yaml"\n    "new-dev-file.py"/' "$FIXTURE/generate-manifest.sh"
rm -f "$FIXTURE/generate-manifest.sh.bak"
git -C "$FIXTURE" add generate-manifest.sh
git -C "$FIXTURE" commit -q -m "add new-dev-file.py to excluded scripts"
OUT_B=$(run_check 2>&1); RC_B=$?
if [ "$RC_B" -eq 1 ] && echo "$OUT_B" | grep -q "dev-only-excluded.*отсутствует"; then
    pass "B: missing Delivery-Route trailer is a deterministic, named failure"
else
    fail "B: expected exit 1 naming dev-only-excluded, got exit $RC_B: $OUT_B"
fi

echo "--- Scenario C: same change, wrong Delivery-Route label ---"
git -C "$FIXTURE" commit -q --amend -m "$(printf 'add new-dev-file.py to excluded scripts\n\nDelivery-Route: user-space-excluded\n')"
OUT_C=$(run_check 2>&1); RC_C=$?
if [ "$RC_C" -eq 1 ] && echo "$OUT_C" | grep -q "dev-only-excluded.*отсутствует"; then
    pass "C: a wrong (but present) label still fails deterministically, naming the real category"
else
    fail "C: expected exit 1 naming dev-only-excluded despite a present-but-wrong trailer, got exit $RC_C: $OUT_C"
fi

echo "--- Scenario D: same change, correct Delivery-Route label ---"
git -C "$FIXTURE" commit -q --amend -m "$(printf 'add new-dev-file.py to excluded scripts\n\nDelivery-Route: dev-only-excluded\n')"
OUT_D=$(run_check 2>&1); RC_D=$?
if [ "$RC_D" -eq 0 ] && echo "$OUT_D" | grep -q "все затронутые категории задекларированы верно"; then
    pass "D: the correct label makes the same change pass deterministically"
else
    fail "D: expected exit 0, got exit $RC_D: $OUT_D"
fi

echo ""
echo "============================================"
echo "  Results: $PASS_COUNT PASS, $FAIL_COUNT FAIL"
echo "============================================"
[ "$FAIL_COUNT" -eq 0 ]
