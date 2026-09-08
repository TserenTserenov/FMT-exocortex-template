#!/usr/bin/env bash
# #529/#538: release pinning plus authenticated GitHub API precedence.
# Temp-only, no network. Bash 3.2 compatible.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SELF_DIR")"
UPDATE_SH="$REPO_ROOT/update.sh"

FAIL_COUNT=0
PASS_COUNT=0
CASE_COUNT=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "  ✅ PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }

FUNCS=$(mktemp)
TRACE_DIR=$(mktemp -d)
trap 'rm -f "$FUNCS"; rm -rf "$TRACE_DIR"' EXIT
extract_function() {
    awk -v signature="$1() {" '
        $0 == signature { found=1 }
        found { print }
        found && /^}$/ { exit }
    ' "$UPDATE_SH"
}
extract_function github_api_get > "$FUNCS"
extract_function resolve_delivery_ref >> "$FUNCS"
grep -q '^github_api_get() {' "$FUNCS" || {
    echo "FATAL: github_api_get extraction is empty" >&2
    exit 2
}
grep -q '^resolve_delivery_ref() {' "$FUNCS" || {
    echo "FATAL: resolve_delivery_ref extraction is empty" >&2
    exit 2
}

TAG_SHA="1111111111111111111111111111111111111111"
MAIN_SHA="2222222222222222222222222222222222222222"

# run_case CHANNEL HAS_PY GH_PRESENT GH_AUTH FAIL_MODE GH_TOKEN GITHUB_TOKEN [HOSTILE_DEBUG]
run_case() {
    local channel="$1" has_py="$2" gh_present="$3" gh_auth="$4"
    local fail_mode="$5" gh_token="$6" github_token="$7"
    local hostile_debug="${8:-}"
    (
        set -uo pipefail
        REPO="owner/tmpl"
        BRANCH="main"
        API_BASE="https://api.github.com/repos/$REPO"
        RAW_BASE="https://raw.githubusercontent.com/$REPO/$BRANCH"
        CURL_BASE_OPTS="--insecure --max-time 2"
        _CURL_SSL_OPT=""
        EXIT_NETWORK=2
        GITHUB_API_AUTH_FAILURE=90
        GITHUB_API_INVALID_TOKEN=91
        GITHUB_API_UNSAFE_CURL_OPTIONS=92
        UPDATE_CHANNEL="$channel"
        PY_BIN=python3
        HAS_PY="$has_py"
        GH_PRESENT="$gh_present"
        GH_AUTH="$gh_auth"
        FAIL_MODE="$fail_mode"
        GH_TOKEN="$gh_token"
        GITHUB_TOKEN="$github_token"
        GH_DEBUG="$hostile_debug"
        DEBUG="$hostile_debug"
        export GH_TOKEN GITHUB_TOKEN GH_DEBUG DEBUG
        py_available() { [ "$HAS_PY" = "yes" ]; }
        command() {
            if [ "${1:-}" = "-v" ] && [ "${2:-}" = "gh" ]; then
                [ "$GH_PRESENT" = "yes" ]
                return
            fi
            builtin command "$@"
        }
        curl() {
            local api_url="" argument has_config=false config="" source="anonymous"
            local saw_insecure=false saw_max_time=false config_disabled=false
            [ "${1:-}" = "-q" ] && config_disabled=true
            for argument in "$@"; do
                if { [ -n "$GH_TOKEN" ] && [[ "$argument" == *"$GH_TOKEN"* ]]; } || \
                   { [ -n "$GITHUB_TOKEN" ] && [[ "$argument" == *"$GITHUB_TOKEN"* ]]; }; then
                    echo "CALL curl:secret-in-argv" >&2
                    return 98
                fi
                case "$argument" in
                    http*) api_url="$argument" ;;
                    -K) has_config=true ;;
                    --insecure) saw_insecure=true ;;
                    --max-time) saw_max_time=true ;;
                esac
            done
            if $has_config; then
                config=$(cat)
                if [ -n "$GH_TOKEN" ] && [[ "$config" == *"Bearer $GH_TOKEN"* ]]; then
                    source="GH_TOKEN"
                elif [ -n "$GITHUB_TOKEN" ] && [[ "$config" == *"Bearer $GITHUB_TOKEN"* ]]; then
                    source="GITHUB_TOKEN"
                else
                    echo "CALL curl:invalid-config:$api_url" >&2
                    return 97
                fi
            fi
            echo "CALL curl:$source:$api_url:safe=$saw_insecure,$saw_max_time:q=$config_disabled" >&2
            if [ "$FAIL_MODE" = "curl-auth" ] && [ "$source" != "anonymous" ]; then
                return 22
            fi
            case "$api_url" in
                */releases/latest) printf '{"tag_name":"v9.9.9"}\n' ;;
                */commits/v9.9.9) printf '{"sha":"%s"}\n' "$TAG_SHA" ;;
                */commits/main) printf '{"sha":"%s"}\n' "$MAIN_SHA" ;;
                *) return 22 ;;
            esac
        }
        gh() {
            if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ]; then
                [ -z "${GH_DEBUG:-}" ] || return 78
                [ -z "${DEBUG:-}" ] || return 79
                [ "${GH_PROMPT_DISABLED:-}" = "1" ] || return 80
                [ "$GH_AUTH" = "yes" ]
                return
            fi
            if [ "${1:-}" = "api" ]; then
                local endpoint="" argument
                for argument in "$@"; do
                    case "$argument" in /repos/*) endpoint="$argument" ;; esac
                done
                echo "CALL gh:$endpoint:GH_DEBUG=${GH_DEBUG:-}:DEBUG=${DEBUG:-}:PROMPT=${GH_PROMPT_DISABLED:-}" >&2
                [ "$FAIL_MODE" = "gh-api" ] && return 1
                case "$endpoint" in
                    */releases/latest) printf '{"tag_name":"v9.9.9"}\n' ;;
                    */commits/v9.9.9) printf '{"sha":"%s"}\n' "$TAG_SHA" ;;
                    */commits/main) printf '{"sha":"%s"}\n' "$MAIN_SHA" ;;
                    *) return 1 ;;
                esac
                return
            fi
            return 1
        }
        # shellcheck disable=SC1090
        . "$FUNCS"
        resolve_delivery_ref
        echo "RAW_BASE=$RAW_BASE"
    )
}

echo "=== #538 nine-case authenticated GitHub API matrix ==="

CASE_COUNT=$((CASE_COUNT + 1))
OUT=$(run_case release yes yes yes none gh_primary github_secondary 2>&1)
echo "$OUT" | grep -q "CALL curl:GH_TOKEN:.*/releases/latest" && pass "1 GH_TOKEN has first precedence" || fail "1 wrong GH_TOKEN route: $OUT"
echo "$OUT" | grep -q "GITHUB_TOKEN\|CALL gh:" && fail "1 lower-priority auth was used: $OUT" || pass "1 no lower-priority fallback"
echo "$OUT" | grep -q "secret-in-argv" && fail "1 token appeared in curl argv: $OUT" || pass "1 token stays out of curl argv"
echo "$OUT" | grep -q "safe=true,true" && pass "1 safe curl transport options survive" || fail "1 safe curl options missing: $OUT"
echo "$OUT" | grep -q "q=true" && pass "1 authenticated curl disables curlrc first" || fail "1 curlrc was not disabled: $OUT"
grep -Fq 'curl -q "${authenticated_curl_options[@]}"' "$FUNCS" && pass "1 curl -q is statically first" || fail "1 authenticated curl does not place -q first"
echo "$OUT" | grep -q "RAW_BASE=.*/$TAG_SHA$" && pass "1 release pinned to tag commit" || fail "1 release not pinned: $OUT"

CASE_COUNT=$((CASE_COUNT + 1))
OUT=$(run_case release yes yes yes none "" github_primary 2>&1)
echo "$OUT" | grep -q "CALL curl:GITHUB_TOKEN:.*/releases/latest" && pass "2 empty GH_TOKEN yields to GITHUB_TOKEN" || fail "2 wrong GITHUB_TOKEN route: $OUT"
echo "$OUT" | grep -q "CALL gh:" && fail "2 gh bypassed explicit token: $OUT" || pass "2 explicit token beats gh"
echo "$OUT" | grep -q "secret-in-argv" && fail "2 token appeared in curl argv: $OUT" || pass "2 token stays out of curl argv"

CASE_COUNT=$((CASE_COUNT + 1))
DEBUG_SECRET="hostile_debug_secret_538"
OUT=$(run_case release yes yes yes none "" "" "$DEBUG_SECRET" 2>&1)
echo "$OUT" | grep -q "CALL gh:.*/releases/latest" && pass "3 authenticated gh is third" || fail "3 gh route missing: $OUT"
echo "$OUT" | grep -q "CALL curl:" && fail "3 curl used despite authenticated gh: $OUT" || pass "3 no curl fallback"
echo "$OUT" | grep -q "GH_DEBUG=:DEBUG=:PROMPT=1" && pass "3 gh debug and prompts are neutralized" || fail "3 unsafe gh environment: $OUT"
echo "$OUT" | grep -Fq "$DEBUG_SECRET" && fail "3 hostile gh debug value leaked: $OUT" || pass "3 hostile gh debug value absent"

CASE_COUNT=$((CASE_COUNT + 1))
OUT=$(run_case release yes no no none "" "" 2>&1)
echo "$OUT" | grep -q "CALL curl:anonymous:.*/releases/latest" && pass "4 anonymous curl is final fallback" || fail "4 anonymous route missing: $OUT"
echo "$OUT" | grep -q "RAW_BASE=.*/$TAG_SHA$" && pass "4 anonymous release still pins SHA" || fail "4 anonymous pin failed: $OUT"

CASE_COUNT=$((CASE_COUNT + 1))
OUT=$(run_case release yes yes yes curl-auth gh_fail github_unused 2>&1)
RC=$?
[ "$RC" -ne 0 ] && pass "5 GH_TOKEN request failure is fail-closed" || fail "5 GH_TOKEN failure returned zero: $OUT"
echo "$OUT" | grep -q "CALL gh:\|curl:anonymous" && fail "5 explicit-token failure fell back: $OUT" || pass "5 no fallback after GH_TOKEN failure"

CASE_COUNT=$((CASE_COUNT + 1))
OUT=$(run_case main yes yes yes curl-auth "" github_fail 2>&1)
RC=$?
[ "$RC" -ne 0 ] && pass "6 GITHUB_TOKEN branch failure is fail-closed" || fail "6 GITHUB_TOKEN failure returned zero: $OUT"
echo "$OUT" | grep -q "CALL gh:\|curl:anonymous\|RAW_BASE=" && fail "6 explicit-token failure fell back: $OUT" || pass "6 no moving/anonymous fallback"

CASE_COUNT=$((CASE_COUNT + 1))
OUT=$(run_case release yes yes yes gh-api "" "" 2>&1)
RC=$?
[ "$RC" -ne 0 ] && pass "7 authenticated gh failure is fail-closed" || fail "7 gh failure returned zero: $OUT"
echo "$OUT" | grep -q "CALL curl:" && fail "7 gh failure fell back to curl: $OUT" || pass "7 no curl fallback after gh failure"

CASE_COUNT=$((CASE_COUNT + 1))
INVALID_SECRET='invalid-token-secret'
OUT=$(
  {
    set -uo pipefail
    CURL_BASE_OPTS=""
    _CURL_SSL_OPT=""
    GITHUB_API_AUTH_FAILURE=90
    GITHUB_API_INVALID_TOKEN=91
    GITHUB_API_UNSAFE_CURL_OPTIONS=92
    GH_TOKEN="$INVALID_SECRET"
    GITHUB_TOKEN="unused_secondary"
    export GH_TOKEN GITHUB_TOKEN
    curl() { echo "CALL curl" >&2; return 0; }
    command() { builtin command "$@"; }
    # shellcheck disable=SC1090
    . "$FUNCS"
    set -x
    github_api_get "https://api.github.com/repos/owner/tmpl/releases/latest" >/dev/null
    INVALID_RC=$?
    if [[ "$-" == *x* ]]; then
        echo "TRACE_RESTORED=yes"
    else
        echo "TRACE_RESTORED=no"
    fi
    set +x
    echo "INVALID_RC=$INVALID_RC"
  } 2>&1
)
echo "$OUT" | grep -q "INVALID_RC=91" && pass "8 unsafe token is rejected" || fail "8 unsafe token status wrong: $OUT"
echo "$OUT" | grep -q "TRACE_RESTORED=yes" && pass "8 xtrace state restored" || fail "8 xtrace not restored: $OUT"
echo "$OUT" | grep -Fq "$INVALID_SECRET" && fail "8 token leaked under xtrace: $OUT" || pass "8 token absent from output"
echo "$OUT" | grep -q "CALL curl" && fail "8 invalid token reached transport: $OUT" || pass "8 invalid token stopped before transport"

DANGEROUS_SECRET="dangerous_primary_538"
TRACE_SENTINEL="$TRACE_DIR/auth-trace.txt"
OUT=$(
  {
    set -uo pipefail
    CURL_BASE_OPTS="--trace-ascii $TRACE_SENTINEL"
    _CURL_SSL_OPT=""
    GITHUB_API_AUTH_FAILURE=90
    GITHUB_API_INVALID_TOKEN=91
    GITHUB_API_UNSAFE_CURL_OPTIONS=92
    GH_TOKEN="$DANGEROUS_SECRET"
    GITHUB_TOKEN=""
    export GH_TOKEN GITHUB_TOKEN
    curl() { echo "CALL curl" >&2; return 0; }
    gh() { echo "CALL gh" >&2; return 0; }
    command() { builtin command "$@"; }
    # shellcheck disable=SC1090
    . "$FUNCS"
    github_api_get "https://api.github.com/repos/owner/tmpl/releases/latest" >/dev/null
    echo "DANGEROUS_RC=$?"
  } 2>&1
)
echo "$OUT" | grep -q "DANGEROUS_RC=92" && pass "8 unsafe authenticated curl options are rejected" || fail "8 unsafe curl status wrong: $OUT"
echo "$OUT" | grep -q "CALL curl\|CALL gh" && fail "8 unsafe curl options reached a transport: $OUT" || pass "8 unsafe curl options have no fallback"
[ ! -e "$TRACE_SENTINEL" ] && pass "8 unsafe trace target was not created" || fail "8 unsafe trace target was created"
echo "$OUT" | grep -Fq "$DANGEROUS_SECRET" && fail "8 token leaked while rejecting curl options: $OUT" || pass "8 rejected curl options leak no token"

CASE_COUNT=$((CASE_COUNT + 1))
OUT=$(run_case release no no no none "" "" 2>&1)
echo "$OUT" | grep -q "RAW_BASE=.*/v9.9.9$" && pass "9 no-python release pins immutable tag" || fail "9 no-python tag pin failed: $OUT"
echo "$OUT" | grep -q "/commits/v9.9.9" && fail "9 no-python path made unnecessary commit GET: $OUT" || pass "9 only latest-release GET used"

[ "$CASE_COUNT" -eq 9 ] || fail "matrix executed $CASE_COUNT cases, expected 9"
echo
echo "Result: $PASS_COUNT PASS, $FAIL_COUNT FAIL ($CASE_COUNT cases)"
[ "$FAIL_COUNT" -eq 0 ] && exit 0 || exit 1
