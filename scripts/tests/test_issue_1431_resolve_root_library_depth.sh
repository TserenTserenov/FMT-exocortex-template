#!/usr/bin/env bash
# test_issue_1431_resolve_root_library_depth.sh — issue #1431.
#
# iwe_resolve_root() derives the workspace root from where lib/common.sh is
# installed. Three levels up is right for the template and governance copies;
# for the workspace copy <root>/scripts/lib it is the root's parent, which may
# carry its own .iwe-runtime and .exocortex.env. Each case below builds a
# disposable layout, calls the resolver with no root variables, and checks the
# exact stdout and exit code. route-task.sh cases cover the explicit-IWE_DIR
# check and the --help header from the same issue.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
LIB="$ROOT/scripts/lib/common.sh"
ROUTER="$ROOT/scripts/route-task.sh"

FAIL=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL=$((FAIL+1)); }
pass() { echo "  ✅ PASS: $*"; }
TEST_ROOT=$(mktemp -d)
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
# Invoked indirectly by the trap below.
# shellcheck disable=SC2329
cleanup() { local rc=$?; rm -rf "$TEST_ROOT"; exit "$rc"; }
trap cleanup EXIT INT TERM

# install_lib DIR — copy the library under test into DIR.
install_lib() { mkdir -p "$1" && cp "$LIB" "$1/common.sh"; }

# resolve LIBRARY [EXPLICIT] — run the resolver with no root variables at all.
# The inner script expands its own positional parameters: single quotes intended.
# shellcheck disable=SC2016
resolve() {
    env -i HOME="$TEST_ROOT/home" PATH="$PATH" /bin/bash -c \
        'source "$1"; iwe_resolve_root "${2:-}"' _ "$1" "${2:-}" 2>/dev/null
}

# expect NAME LIBRARY EXPECTED_STDOUT EXPECTED_RC [EXPLICIT]
expect() {
    local name="$1" library="$2" want="$3" want_rc="$4" got rc
    got=$(resolve "$library" "${5:-}")
    rc=$?
    if [ "$got" = "$want" ] && [ "$rc" -eq "$want_rc" ]; then
        pass "$name"
    else
        fail "$name: expected '$want' rc=$want_rc, got '$got' rc=$rc"
    fi
}

DECOY="$TEST_ROOT/decoy-workspace"
mkdir -p "$DECOY" "$TEST_ROOT/home"

echo "=== 1. template copy <root>/FMT-exocortex-template/scripts/lib ==="
# The template checkout's own .exocortex.env must not override the root.
R1="$TEST_ROOT/t1/IWE"
install_lib "$R1/FMT-exocortex-template/scripts/lib"
printf 'WORKSPACE_DIR=%s\n' "$DECOY" > "$R1/FMT-exocortex-template/.exocortex.env"
expect "template copy resolves to the workspace root" \
    "$R1/FMT-exocortex-template/scripts/lib/common.sh" "$R1" 0

echo "=== 2. governance copy <root>/<governance>/scripts/lib (#427/#455) ==="
R2="$TEST_ROOT/t2/IWE"
install_lib "$R2/DS-strategy/scripts/lib"
mkdir -p "$R2/FMT-exocortex-template"
expect "governance copy resolves to the workspace root" \
    "$R2/DS-strategy/scripts/lib/common.sh" "$R2" 0

echo "=== 3. workspace copy <root>/scripts/lib, decoy markers in the parent ==="
# Before the fix the parent won: its .iwe-runtime passed the marker check and
# its .exocortex.env pointed elsewhere.
R3="$TEST_ROOT/t3/home/IWE"
install_lib "$R3/scripts/lib"
mkdir -p "$R3/FMT-exocortex-template" "$TEST_ROOT/t3/home/.iwe-runtime"
printf 'WORKSPACE_DIR=%s\n' "$DECOY" > "$TEST_ROOT/t3/home/.exocortex.env"
expect "workspace copy resolves to itself, not its parent" \
    "$R3/scripts/lib/common.sh" "$R3" 0

echo "=== 4. symlinked library, layout of test-route-task.sh T18 ==="
# The layout is defined by where the link sits, not by its target.
R4="$TEST_ROOT/t4/IWE"
mkdir -p "$R4/FMT-exocortex-template/scripts/lib"
ln -s "$LIB" "$R4/FMT-exocortex-template/scripts/lib/common.sh"
expect "symlinked template copy resolves to the link's workspace" \
    "$R4/FMT-exocortex-template/scripts/lib/common.sh" "$R4" 0

echo "=== 5. three-level candidate keeps reading .exocortex.env ==="
R5="$TEST_ROOT/t5/IWE"
install_lib "$R5/DS-strategy/scripts/lib"
printf 'WORKSPACE_DIR=%s\n' "$DECOY" > "$R5/.exocortex.env"
expect "configured WORKSPACE_DIR still wins without markers" \
    "$R5/DS-strategy/scripts/lib/common.sh" "$DECOY" 0

echo "=== 6. no markers and no configuration ==="
R6="$TEST_ROOT/t6/IWE"
install_lib "$R6/DS-strategy/scripts/lib"
expect "unresolvable layout fails with empty stdout" \
    "$R6/DS-strategy/scripts/lib/common.sh" "" 1

echo "=== 7. precedence ==="
expect "explicit argument wins over the library location" \
    "$R3/scripts/lib/common.sh" "$DECOY" 0 "$DECOY"
# shellcheck disable=SC2016
got=$(env -i HOME="$TEST_ROOT/home" PATH="$PATH" IWE_WORKSPACE="$DECOY" /bin/bash -c \
    'source "$1"; iwe_resolve_root' _ "$R3/scripts/lib/common.sh")
if [ "$got" = "$DECOY" ]; then
    pass "IWE_WORKSPACE wins over the library location"
else
    fail "IWE_WORKSPACE: expected '$DECOY', got '$got'"
fi

echo "=== 8. route-task.sh: explicit IWE_DIR and --help ==="
out=$(IWE_DIR="$TEST_ROOT/does-not-exist" bash "$ROUTER" --list 2>&1)
rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "workspace root is not a directory"; then
    pass "missing IWE_DIR fails before the catalog lookup"
else
    fail "missing IWE_DIR: rc=$rc, output: $out"
fi
help=$(IWE_DIR="$R3" bash "$ROUTER" --help 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$help" | grep -q "^Usage:" \
        && ! printf '%s' "$help" | grep -qE "shellcheck|issue #1094"; then
    pass "--help prints the header only"
else
    fail "--help: rc=$rc, output: $help"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "OK: issue #1431 regression passed"
    exit 0
fi
echo "FAILED: $FAIL case(s)"
exit 1
