#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329  # globals/functions are evaluated from update.sh.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

extract_function() {
    awk -v signature="$1() {" '
      $0 == signature { capture=1 }
      capture { print }
      capture && /^}/ { exit }
    ' "$ROOT/update.sh"
}
eval "$(
    extract_function github_api_get
    extract_function resolve_delivery_ref
)"
declare -F github_api_get >/dev/null
declare -F resolve_delivery_ref >/dev/null

REPO='example/fixture'
BRANCH='main'
API_BASE="https://api.github.com/repos/$REPO"
CURL_BASE_OPTS=''
_CURL_SSL_OPT=''
GITHUB_API_AUTH_FAILURE=90
GITHUB_API_INVALID_TOKEN=91
GITHUB_API_UNSAFE_CURL_OPTIONS=92
EXIT_NETWORK=2
PY_BIN=python3
UPDATE_CHANNEL=main
GH_TOKEN=delivery_ref_fixture_token
GITHUB_TOKEN=''
export GH_TOKEN GITHUB_TOKEN
py_available() { command -v "$PY_BIN" >/dev/null 2>&1; }

curl() {
    printf '%s\n' '{"sha":"0123456789abcdef0123456789abcdef01234567"}'
}

run_contract() {
    RAW_BASE="https://raw.githubusercontent.com/$REPO/$BRANCH"
    resolve_delivery_ref > "$TMP/pinned.out"
    OUT=$(<"$TMP/pinned.out")
    if [ "$RAW_BASE" != "https://raw.githubusercontent.com/$REPO/0123456789abcdef0123456789abcdef01234567" ]; then
        echo 'delivery ref did not pin raw downloads to the resolved commit' >&2
        exit 1
    fi
    if ! grep -Fq 'Снимок поставки: 0123456789ab' <(printf '%s' "$OUT"); then
        echo 'delivery ref did not report the pinned snapshot' >&2
        exit 1
    fi

    curl() {
        printf '%s\n' '{"sha":"not-a-commit"}'
    }

    RAW_BASE="https://raw.githubusercontent.com/$REPO/$BRANCH"
    resolve_delivery_ref > "$TMP/fallback.out"
    OUT=$(<"$TMP/fallback.out")
    if [ "$RAW_BASE" != "https://raw.githubusercontent.com/$REPO/$BRANCH" ]; then
        echo 'delivery ref changed the base after an invalid API response' >&2
        exit 1
    fi
    if ! grep -Fq 'используется подвижная ветка' <(printf '%s' "$OUT"); then
        echo 'delivery ref hid the fallback to the moving branch' >&2
        exit 1
    fi

    curl() {
        return 22
    }
    RAW_BASE="https://raw.githubusercontent.com/$REPO/$BRANCH"
    set +e
    ( resolve_delivery_ref > "$TMP/error.out" 2> "$TMP/error.err" )
    ERROR_RC=$?
    set -e
    if [ "$ERROR_RC" -ne "$EXIT_NETWORK" ]; then
        echo "authenticated transport error returned $ERROR_RC, expected $EXIT_NETWORK" >&2
        exit 1
    fi

    echo 'PASS: update pins manifest and files to one delivery commit'
}

EXPECTED='PASS: update pins manifest and files to one delivery commit'
set +e
(
    set -euo pipefail
    run_contract
) > "$TMP/contract.out" 2> "$TMP/contract.err"
CONTRACT_RC=$?
set -e
if [ "$CONTRACT_RC" -ne 0 ]; then
    cat "$TMP/contract.err" >&2
    echo "delivery-ref contract failed with status $CONTRACT_RC" >&2
    exit 1
fi
if [ -s "$TMP/contract.err" ]; then
    cat "$TMP/contract.err" >&2
    echo 'delivery-ref contract emitted unexpected stderr' >&2
    exit 1
fi
ACTUAL=$(<"$TMP/contract.out")
if [ "$ACTUAL" != "$EXPECTED" ]; then
    echo "delivery-ref contract stdout mismatch: $ACTUAL" >&2
    exit 1
fi
printf '%s\n' "$ACTUAL"
