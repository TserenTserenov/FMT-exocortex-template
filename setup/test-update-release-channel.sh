#!/bin/bash
# test-update-release-channel.sh — WP-529 F7 follow-up (pilot decision
# 2026-08-21): update.sh delivers the LAST PUBLISHED RELEASE by default, not
# the moving main — an external user proved the old contract shipped red,
# unreleased main while still reporting the last release's version number.
#
# Extracts resolve_delivery_ref() out of the real update.sh (same technique as
# scripts/tests/lib/extract-update-download-batch.sh) and drives it with a
# stubbed curl: no network, each case asserts what RAW_BASE gets pinned to.
#
# Bash 3.2 compatible. Usage: bash setup/test-update-release-channel.sh

set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SELF_DIR")"
UPDATE_SH="$REPO_ROOT/update.sh"

FAIL_COUNT=0
PASS_COUNT=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "  ✅ PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }

FUNCS=$(mktemp)
trap 'rm -f "$FUNCS"' EXIT
awk '
    /^resolve_delivery_ref\(\) \{$/ { found=1 }
    found { print }
    found && /^\}$/ { exit }
' "$UPDATE_SH" > "$FUNCS"
[ -s "$FUNCS" ] || { echo "FATAL: resolve_delivery_ref extraction is empty — marker no longer matches update.sh" >&2; exit 2; }

TAG_SHA="1111111111111111111111111111111111111111"
MAIN_SHA="2222222222222222222222222222222222222222"

# run_case CHANNEL HAS_RELEASES HAS_PY -> prints resulting RAW_BASE + output
run_case() {
    local channel="$1" has_releases="$2" has_py="$3"
    (
        set -uo pipefail
        REPO="owner/tmpl"
        BRANCH="main"
        API_BASE="https://api.github.com/repos/$REPO"
        RAW_BASE="https://raw.githubusercontent.com/$REPO/$BRANCH"
        CURL_BASE_OPTS="--max-time 2"
        _CURL_SSL_OPT=""
        EXIT_NETWORK=2
        UPDATE_CHANNEL="$channel"
        PY_BIN="$(command -v python3 || echo python3)"
        HAS_RELEASES="$has_releases"
        HAS_PY="$has_py"
        py_available() { [ "$HAS_PY" = "yes" ]; }
        curl() {
            local url=""
            for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
            case "$url" in
                */releases/latest)
                    [ "$HAS_RELEASES" = "yes" ] || return 22
                    printf '{"tag_name": "v9.9.9", "name": "v9.9.9"}\n' ;;
                */commits/v9.9.9) printf '{"sha": "%s"}\n' "$TAG_SHA" ;;
                */commits/main)   printf '{"sha": "%s"}\n' "$MAIN_SHA" ;;
                *) return 22 ;;
            esac
        }
        # shellcheck disable=SC1090
        . "$FUNCS"
        resolve_delivery_ref
        echo "RAW_BASE=$RAW_BASE"
    )
}

echo "=== 1. release channel (default): pinned to the release tag's SHA ==="
OUT=$(run_case release yes yes)
echo "$OUT" | grep -q "RAW_BASE=.*/$TAG_SHA$" && pass "RAW_BASE pinned to release SHA" || fail "expected release SHA pin, got: $OUT"
echo "$OUT" | grep -q "релиз v9.9.9" && pass "announces the release tag" || fail "no release announcement: $OUT"

echo "=== 2. release channel, no releases published: FAIL-CLOSED abort (#501) ==="
# no errexit here: the harness runs under `set -uo pipefail` WITHOUT -e —
# enabling it after this case would abort cases 3-4 on any non-zero and
# swallow the final Result line (cold review, Medium 4)
OUT=$(run_case release no yes 2>&1)
RC2=$?
[ "$RC2" -ne 0 ] && pass "resolver aborts non-zero instead of falling back (#501)" || fail "expected non-zero abort, got rc=0: $OUT"
echo "$OUT" | grep -q "IWE_UPDATE_CHANNEL=main" && pass "abort message carries the explicit main-channel hint" || fail "no actionable hint in abort: $OUT"
echo "$OUT" | grep -q "RAW_BASE=" && fail "fallback still resolved a RAW_BASE: $OUT" || pass "no delivery base resolved on failed release lookup"

echo "=== 3. IWE_UPDATE_CHANNEL=main: the old moving-branch contract, pinned ==="
OUT=$(run_case main yes yes)
echo "$OUT" | grep -q "RAW_BASE=.*/$MAIN_SHA$" && pass "main channel pins main SHA" || fail "expected main pin, got: $OUT"
echo "$OUT" | grep -q "релиз" && fail "main channel must not consult releases: $OUT" || pass "releases API not consulted on main channel"

echo "=== 4. release channel without python3: pinned to the tag itself ==="
OUT=$(run_case release yes no)
echo "$OUT" | grep -q "RAW_BASE=.*/v9.9.9$" && pass "RAW_BASE pinned to tag without python" || fail "expected tag pin, got: $OUT"

echo
echo "Result: $PASS_COUNT PASS, $FAIL_COUNT FAIL"
[ "$FAIL_COUNT" -eq 0 ] && exit 0 || exit 1
