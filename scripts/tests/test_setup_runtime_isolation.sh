#!/bin/bash
# test_setup_runtime_isolation.sh — v0.38.7 matrix finding 6 (external user,
# reproduced with a negative control): setting up workspace B with a foreign
# exported IWE_RUNTIME (from workspace A) wrote hot-files.list into A's
# runtime. setup.sh step 4f passes IWE_ROOT but did not pin IWE_RUNTIME, and
# generate-hot-files-list.sh prefers the inherited env value.
#
# Invariant under test: with the FIXED call shape (explicit IWE_RUNTIME, the
# policy comment at step 4f), a poisoned environment cannot redirect the
# write. The discriminating control shows the OLD call shape still leaks —
# so this test fails against the pre-fix behaviour, not vacuously.
#
# Bash 3.2 compatible. Usage: bash scripts/tests/test_setup_runtime_isolation.sh

set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
GEN="$REPO_ROOT/scripts/generate-hot-files-list.sh"

FAIL_COUNT=0
PASS_COUNT=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "  ✅ PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }
TEST_ROOT="/tmp/iwe-runtime-isolation-test-$$"
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

WS_A="$TEST_ROOT/workspace-A"; WS_B="$TEST_ROOT/workspace-B"
mkdir -p "$WS_A/.iwe-runtime" "$WS_B"
mkdir -p "$WS_B/DS-strategy"  # generator's governance-repo probe target

echo "=== 1. Fixed call shape: poisoned env must NOT redirect the write ==="
OUT=$(IWE_RUNTIME="$WS_A/.iwe-runtime" \
      env IWE_RUNTIME="$WS_A/.iwe-runtime" IWE_ROOT="$WS_B" IWE_GOVERNANCE_REPO="DS-strategy" \
      bash -c 'IWE_ROOT="$IWE_ROOT" IWE_RUNTIME="$IWE_ROOT/.iwe-runtime" IWE_GOVERNANCE_REPO="$IWE_GOVERNANCE_REPO" bash "'"$GEN"'"' 2>&1) || true
if [ -f "$WS_B/.iwe-runtime/hot-files.list" ]; then
  pass "hot-files.list written into the TARGET workspace B"
else
  fail "target workspace B got nothing; output: $OUT"
fi
if [ -f "$WS_A/.iwe-runtime/hot-files.list" ]; then
  fail "poisoned workspace A received the write — isolation broken"
else
  pass "poisoned workspace A untouched"
fi

echo "=== 2. Discriminating control: the OLD call shape (no explicit IWE_RUNTIME) leaks ==="
rm -rf "$WS_A/.iwe-runtime" "$WS_B/.iwe-runtime"; mkdir -p "$WS_A/.iwe-runtime"
OUT=$(env IWE_RUNTIME="$WS_A/.iwe-runtime" bash -c 'IWE_ROOT="'"$WS_B"'" IWE_GOVERNANCE_REPO="DS-strategy" bash "'"$GEN"'"' 2>&1) || true
if [ -f "$WS_A/.iwe-runtime/hot-files.list" ] && [ ! -f "$WS_B/.iwe-runtime/hot-files.list" ]; then
  pass "control: inherited IWE_RUNTIME redirects the old shape (test can tell the difference)"
else
  fail "control did not leak — either the generator changed contract or the test is blind; output: $OUT"
fi

echo "=== 3. setup.sh call sites carry the explicit pin (policy is wired, not just documented) ==="
if grep -q 'IWE_ROOT="\$WORKSPACE_DIR" IWE_RUNTIME="\$IWE_RUNTIME_PATH"' "$REPO_ROOT/setup.sh"; then
  pass "step 4f passes IWE_RUNTIME explicitly"
else
  fail "step 4f call no longer pins IWE_RUNTIME"
fi
if grep -q 'export IWE_RUNTIME="\$IWE_RUNTIME_PATH"' "$REPO_ROOT/setup.sh"; then
  pass "role-install loop pins IWE_RUNTIME explicitly"
else
  fail "role-install loop no longer pins IWE_RUNTIME"
fi

echo
echo "Result: $PASS_COUNT PASS, $FAIL_COUNT FAIL"
[ "$FAIL_COUNT" -eq 0 ] && exit 0 || exit 1
