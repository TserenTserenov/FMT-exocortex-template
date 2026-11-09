#!/usr/bin/env bash
# Regression coverage for issue #1231: artifactor.py's keyword path required
# PACK-digital-platform (an author-only Pack never shipped with the template)
# and died with CONFIG_ERROR/exit 3 on every ordinary install. The Pack
# missing entirely must now degrade to result_kind_resolution=unresolved; a
# Pack that IS installed but whose registry file is itself missing/corrupt
# must still be CONFIG_ERROR/exit 3 -- that part never changed.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
SCRIPT="$ROOT/scripts/artifactor.py"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
pass() { echo "  ✅ PASS: $*"; }
fail_test() { echo "  ❌ FAIL: $*" >&2; fail=1; }

PROMPT="открывай день и собери план на сегодня"

# --- 1. Pack directory absent entirely: degrade, exit 0, unresolved.
out=$(env IWE_ROOT="$TMP/no-pack-here" python3 -I "$SCRIPT" "$PROMPT" 2>/dev/null)
rc=$?
if [ "$rc" -eq 0 ]; then pass "Pack absent: exit 0 (no CONFIG_ERROR)"; else fail_test "Pack absent: expected exit 0, got $rc"; fi
if printf '%s' "$out" | grep -q '"result_kind_resolution": "unresolved"'; then
    pass "Pack absent: result_kind_resolution=unresolved"
else
    fail_test "Pack absent: expected unresolved in output: $out"
fi
if printf '%s' "$out" | grep -q '"expected_result_kind": null'; then
    pass "Pack absent: expected_result_kind=null"
else
    fail_test "Pack absent: expected null expected_result_kind: $out"
fi

# --- 2. Pack directory present but the registry file itself is missing:
# this is corruption, not a template-install fact -- must stay CONFIG_ERROR.
mkdir -p "$TMP/pack-no-registry/PACK-digital-platform/pack/digital-platform"
err=$(env IWE_ROOT="$TMP/pack-no-registry" python3 -I "$SCRIPT" "$PROMPT" 2>&1 >/dev/null)
rc=$?
if [ "$rc" -eq 3 ]; then pass "Pack present, registry missing: exit 3 (CONFIG_ERROR)"; else fail_test "Pack present, registry missing: expected exit 3, got $rc"; fi
if printf '%s' "$err" | grep -q 'CONFIG_ERROR'; then
    pass "Pack present, registry missing: CONFIG_ERROR message on stderr"
else
    fail_test "Pack present, registry missing: no CONFIG_ERROR message: $err"
fi

# --- 3. --check-registry (name check against the concept-kinds registry, WP-575):
# the registry lives in the same author-only Pack, so the same split applies.
RESULT="$TMP/result.json"
printf '%s\n' '{"artifact": "Платформа обучения", "result_type": "system"}' > "$RESULT"
out=$(env -u CONCEPT_KINDS_REGISTRY IWE_ROOT="$TMP/no-pack-here" python3 -I "$SCRIPT" --check-registry "$RESULT" 2>/dev/null)
rc=$?
if [ "$rc" -eq 0 ]; then pass "check-registry, Pack absent: exit 0"; else fail_test "check-registry, Pack absent: expected exit 0, got $rc ($out)"; fi
case "$out" in
    "REGISTRY_OK no-pack "*) pass "check-registry, Pack absent: REGISTRY_OK no-pack" ;;
    *) fail_test "check-registry, Pack absent: expected 'REGISTRY_OK no-pack', got: $out" ;;
esac
out=$(env -u CONCEPT_KINDS_REGISTRY IWE_ROOT="$TMP/pack-no-registry" python3 -I "$SCRIPT" --check-registry "$RESULT" 2>/dev/null)
rc=$?
if [ "$rc" -eq 4 ]; then pass "check-registry, Pack present without registry: exit 4"; else fail_test "check-registry, Pack present without registry: expected exit 4, got $rc ($out)"; fi
case "$out" in
    REGISTRY_BLOCK*) pass "check-registry, Pack present without registry: REGISTRY_BLOCK" ;;
    *) fail_test "check-registry, Pack present without registry: expected REGISTRY_BLOCK, got: $out" ;;
esac

[ "$fail" -eq 0 ] && echo "test_1231_artifactor: ALL PASS" || echo "test_1231_artifactor: FAILURES ABOVE"
exit "$fail"
