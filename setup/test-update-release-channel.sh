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

# Explicit templates: a bare `mktemp` on macOS ignores $TMPDIR, and this test must stay inside it.
FUNCS=$(mktemp "${TMPDIR:-/tmp}/iwe-release-channel-funcs.XXXXXX")
TRACE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/iwe-release-channel.XXXXXX")
trap 'rm -f "$FUNCS"; rm -rf "$TRACE_DIR"' EXIT
extract_function() {
    awk -v signature="$1() {" '
        $0 == signature { found=1 }
        found { print }
        found && /^}$/ { exit }
    ' "$UPDATE_SH"
}
{
    extract_function github_api_get
    extract_function resolve_delivery_ref
    extract_function detect_release_rollback
    # #963: the helpers detect_release_rollback() calls for histories with no common ancestor
    extract_function manifest_version
    extract_function version_compare
    extract_function rollback_by_version
} > "$FUNCS"
grep -q '^github_api_get() {' "$FUNCS" || {
    echo "FATAL: github_api_get extraction is empty" >&2
    exit 2
}
grep -q '^resolve_delivery_ref() {' "$FUNCS" || {
    echo "FATAL: resolve_delivery_ref extraction is empty" >&2
    exit 2
}
grep -q '^detect_release_rollback() {' "$FUNCS" || {
    echo "FATAL: detect_release_rollback extraction is empty" >&2
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
                    case "$argument" in
                        # Git Bash (MSYS) rewrites an argument that starts with "/" into a
                        # Windows path ("C:/Program Files/Git/repos/..."), and gh then
                        # rejects the endpoint (issue #980): fail like it does.
                        /*)
                            echo "CALL gh:invalid API endpoint, leading slash: $argument" >&2
                            return 1
                            ;;
                        repos/*) endpoint="$argument" ;;
                    esac
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
# #980: the endpoint reaches gh as "repos/..." (no leading slash), so Git Bash has nothing to rewrite.
if grep -q -- "CALL gh:repos/owner/tmpl/releases/latest:" <<<"$OUT"; then
    pass "3 gh endpoint has no leading slash"
else
    fail "3 gh endpoint is not a bare repos/... path: $OUT"
fi
if grep -q -- "RAW_BASE=.*/$TAG_SHA$" <<<"$OUT"; then
    pass "3 gh route pins the release commit"
else
    fail "3 gh route did not pin the release: $OUT"
fi
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

# --- issue #980: no other `gh api` call may pass an endpoint with a leading slash ---
# Git Bash (MSYS) rewrites such an argument into a Windows path before gh sees it.
# The matrix above only exercises github_api_get(); this static scan covers every
# `gh api` call site in update.sh, and its detector is checked on samples first so
# that a scan that finds nothing cannot pass by being blind.
gh_api_leading_slash_hits() {
    grep -nE 'gh api[^#]*[[:space:]]"?/[A-Za-z]|^[[:space:]]*endpoint="/' "$1" || true
}
CASE_COUNT=$((CASE_COUNT + 1))
SLASH_SAMPLE="$TRACE_DIR/gh-api-sample.txt"
# shellcheck disable=SC2016  # the samples are literal source text, not expansions
printf '%s\n' 'endpoint="/${api_url#https://api.github.com/}"' > "$SLASH_SAMPLE"
if [ -n "$(gh_api_leading_slash_hits "$SLASH_SAMPLE")" ]; then
    pass "9b detector flags the old endpoint assignment"
else
    fail "9b detector missed the old endpoint assignment"
fi
printf '%s\n' 'gh api --method GET "/repos/owner/repo/releases/latest"' > "$SLASH_SAMPLE"
if [ -n "$(gh_api_leading_slash_hits "$SLASH_SAMPLE")" ]; then
    pass "9b detector flags a literal /repos argument"
else
    fail "9b detector missed a literal /repos argument"
fi
# shellcheck disable=SC2016
printf '%s\n' 'endpoint="${api_url#https://api.github.com/}"' 'gh api --method GET "$endpoint"' 'gh api user' > "$SLASH_SAMPLE"
if [ -z "$(gh_api_leading_slash_hits "$SLASH_SAMPLE")" ]; then
    pass "9b detector accepts bare endpoints"
else
    fail "9b detector rejected bare endpoints"
fi
if grep -q 'gh api' "$UPDATE_SH"; then
    pass "9b update.sh still calls gh api (scan is not vacuous)"
else
    fail "9b update.sh has no gh api call: the scan checks nothing"
fi
SLASH_HITS=$(gh_api_leading_slash_hits "$UPDATE_SH")
if [ -z "$SLASH_HITS" ]; then
    pass "9b no gh api call in update.sh passes a leading-slash endpoint"
else
    fail "9b leading-slash gh api endpoint in update.sh: $SLASH_HITS"
fi

# --- issue #863: detect_release_rollback ---
CASE_COUNT=$((CASE_COUNT + 1))
ROLLBACK_REPO=$(mktemp -d "${TMPDIR:-/tmp}/iwe-rollback-repo.XXXXXX")
(
    set -euo pipefail
    git -C "$ROLLBACK_REPO" init -q
    git -C "$ROLLBACK_REPO" config user.email "test@example.com"
    git -C "$ROLLBACK_REPO" config user.name "test"
    echo one > "$ROLLBACK_REPO/f"
    git -C "$ROLLBACK_REPO" add f
    git -C "$ROLLBACK_REPO" commit -qm "release"
    RELEASE_COMMIT=$(git -C "$ROLLBACK_REPO" rev-parse HEAD)
    echo two >> "$ROLLBACK_REPO/f"
    git -C "$ROLLBACK_REPO" commit -qam "local ahead"
    LOCAL_HEAD=$(git -C "$ROLLBACK_REPO" rev-parse HEAD)

    # shellcheck disable=SC1090
    . "$FUNCS"
    UPDATE_CHANNEL=release
    RELEASE_SHA="$RELEASE_COMMIT"
    SCRIPT_DIR="$ROLLBACK_REPO"
    PY_BIN=""
    py_available() { return 1; }
    github_api_get() { return 1; }

    rc=0
    detect_release_rollback || rc=$?
    echo "ROLLBACK_RC=$rc"
    echo "RELEASE_COMMIT=$RELEASE_COMMIT"
    echo "LOCAL_HEAD=$LOCAL_HEAD"
) >"$TRACE_DIR/rollback-out.txt" 2>"$TRACE_DIR/rollback-err.txt" || true
ROLLBACK_OUT=$(cat "$TRACE_DIR/rollback-out.txt")
echo "$ROLLBACK_OUT" | grep -q "ROLLBACK_RC=0" && pass "10 rollback detected when local ahead of release" \
    || fail "10 expected rollback rc=0: out=$ROLLBACK_OUT err=$(cat "$TRACE_DIR/rollback-err.txt")"

CASE_COUNT=$((CASE_COUNT + 1))
(
    set -euo pipefail
    # Same repo: release SHA equals HEAD → no rollback.
    # shellcheck disable=SC1090
    . "$FUNCS"
    UPDATE_CHANNEL=release
    RELEASE_SHA=$(git -C "$ROLLBACK_REPO" rev-parse HEAD)
    SCRIPT_DIR="$ROLLBACK_REPO"
    PY_BIN=""
    py_available() { return 1; }
    github_api_get() { return 1; }
    rc=0
    detect_release_rollback || rc=$?
    echo "EQUAL_RC=$rc"
) >"$TRACE_DIR/equal-out.txt" 2>"$TRACE_DIR/equal-err.txt" || true
EQUAL_OUT=$(cat "$TRACE_DIR/equal-out.txt")
echo "$EQUAL_OUT" | grep -q "EQUAL_RC=1" && pass "11 equal HEAD is not a rollback" \
    || fail "11 expected equal rc=1: out=$EQUAL_OUT err=$(cat "$TRACE_DIR/equal-err.txt")"

CASE_COUNT=$((CASE_COUNT + 1))
(
    set -euo pipefail
    # shellcheck disable=SC1090
    . "$FUNCS"
    UPDATE_CHANNEL=main
    RELEASE_SHA=$(git -C "$ROLLBACK_REPO" rev-parse HEAD~1)
    SCRIPT_DIR="$ROLLBACK_REPO"
    rc=0
    detect_release_rollback || rc=$?
    echo "MAIN_RC=$rc"
) >"$TRACE_DIR/main-out.txt" 2>"$TRACE_DIR/main-err.txt" || true
MAIN_OUT=$(cat "$TRACE_DIR/main-out.txt")
echo "$MAIN_OUT" | grep -q "MAIN_RC=1" && pass "12 main channel skips rollback detection" \
    || fail "12 expected main rc=1: out=$MAIN_OUT err=$(cat "$TRACE_DIR/main-err.txt")"

CASE_COUNT=$((CASE_COUNT + 1))
(
    set -euo pipefail
    # Tag-like RELEASE_SHA + bad JSON → uncertain (rc=2), must not abort under set -e.
    # shellcheck disable=SC1090
    . "$FUNCS"
    UPDATE_CHANNEL=release
    RELEASE_SHA="v9.9.9"
    SCRIPT_DIR="$ROLLBACK_REPO"
    PY_BIN=python3
    py_available() { return 0; }
    github_api_get() { printf '%s\n' '{"not":"a commit"}'; return 0; }
    rc=0
    detect_release_rollback || rc=$?
    echo "UNCERTAIN_RC=$rc"
) >"$TRACE_DIR/uncertain-out.txt" 2>"$TRACE_DIR/uncertain-err.txt" || true
UNCERTAIN_OUT=$(cat "$TRACE_DIR/uncertain-out.txt")
echo "$UNCERTAIN_OUT" | grep -q "UNCERTAIN_RC=2" && pass "13 unresolved tag returns uncertain (2) without abort" \
    || fail "13 expected uncertain rc=2: out=$UNCERTAIN_OUT err=$(cat "$TRACE_DIR/uncertain-err.txt")"

rm -rf "$ROLLBACK_REPO"

# --- issue #963: version_compare() orders plain X.Y.Z versions numerically ---
# "0.9.0" < "0.10.0": a string comparison gets this wrong, and so would sort -V on
# some platforms.  Anything that is not digits-only X.Y.Z must be refused (rc 2, no
# output), because the caller turns that into "cannot determine", never into "no rollback".
CASE_COUNT=$((CASE_COUNT + 1))
check_version_compare() {
    local a="$1" b="$2" expect="$3" out rc=0
    # shellcheck disable=SC1090
    out=$( . "$FUNCS"; version_compare "$a" "$b" ) || rc=$?
    if [ "$expect" = "invalid" ]; then
        if [ "$rc" -eq 2 ] && [ -z "$out" ]; then
            pass "20 version_compare '$a' '$b' is refused"
        else
            fail "20 version_compare '$a' '$b' expected refusal (rc 2, no output), got rc=$rc out='$out'"
        fi
    elif [ "$rc" -eq 0 ] && [ "$out" = "$expect" ]; then
        pass "20 version_compare '$a' '$b' = $expect"
    else
        fail "20 version_compare '$a' '$b' expected $expect, got rc=$rc out='$out'"
    fi
}
if grep -q '^version_compare() {' "$FUNCS"; then
    check_version_compare 0.9.0 0.10.0 -1
    check_version_compare 0.10.0 0.9.0 1
    check_version_compare 1.2.3 1.2.3 0
    check_version_compare 1.2.9 1.3.0 -1
    check_version_compare 2.0.0 1.99.99 1
    check_version_compare 1.10.0 1.9.9 1
    check_version_compare 01.02.03 1.2.3 0
    check_version_compare 08.0.0 7.0.0 1
    check_version_compare "" 1.2.3 invalid
    check_version_compare 1.2.3 "" invalid
    check_version_compare 1.2 1.2.3 invalid
    check_version_compare 1.2.3.4 1.2.3 invalid
    check_version_compare 1.2.x 1.2.3 invalid
    check_version_compare v1.2.3 1.2.3 invalid
    check_version_compare 1.2.3-rc1 1.2.3 invalid
    check_version_compare dev 1.2.3 invalid
    check_version_compare 1234567890.0.0 1.0.0 invalid
else
    fail "20 version_compare() is missing from update.sh"
fi
if grep -q '^manifest_version() {' "$FUNCS"; then
    printf '{\n  "schema_version": 2,\n  "version": "0.40.2",\n  "files": []\n}\n' > "$TRACE_DIR/manifest-sample.json"
    # shellcheck disable=SC1090
    MANIFEST_VERSION_SAMPLE=$( . "$FUNCS"; manifest_version "$TRACE_DIR/manifest-sample.json" )
    if [ "$MANIFEST_VERSION_SAMPLE" = "0.40.2" ]; then
        pass "20 manifest_version reads the top-level version, not schema_version"
    else
        fail "20 manifest_version returned '$MANIFEST_VERSION_SAMPLE', expected 0.40.2"
    fi
else
    fail "20 manifest_version() is missing from update.sh"
fi

# --- issue #963: histories with no common ancestor (a fork whose root commit differs) ---
# detect_release_rollback() turned "git merge-base" exit 1 (no common ancestor) into
# "cannot determine" (2), so every such fork was blocked under --yes although nothing
# was rolled back. The cases below run the WHOLE update.sh --yes against a sandboxed
# install and a stubbed GitHub (curl/gh/git shims, no network): what matters is whether
# the files were replaced, and why a run stopped - not the return code of one function.
RUN_ROOT="$TRACE_DIR/release-runs"
mkdir -p "$RUN_ROOT"
REAL_GIT=$(command -v git)

# write_release_shims DIR - curl/gh/git stand-ins for a whole update.sh run.
#   curl: GitHub API answers and raw file bodies come from $UPSTREAM_FIXTURE
#   gh:   never authenticated, so update.sh takes its anonymous curl path
#   git:  the real git, except that "merge-base" exits with $FAKE_MERGE_BASE_RC when it is set
write_release_shims() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/curl" <<'SHIM'
#!/bin/bash
if [ "${1:-}" = "--help" ]; then
    printf -- '  --parallel \n  --parallel-max <num>\n  --remove-on-error \n'
    exit 0
fi
url="" out="" cfg=""
while [ $# -gt 0 ]; do
    case "$1" in
        http*) url="$1" ;;
        -o) out="$2"; shift ;;
        -K) cfg="$2"; shift ;;
    esac
    shift
done
serve() {
    local u="$1" o="$2" rel
    case "$u" in
        https://api.github.com/*/releases/latest) printf '{"tag_name":"v9.9.9"}\n'; return 0 ;;
        https://api.github.com/*/commits/*) printf '{"sha":"%s"}\n' "$FIXTURE_RELEASE_SHA"; return 0 ;;
    esac
    rel="${u#https://raw.githubusercontent.com/}"; rel="${rel#*/}"; rel="${rel#*/}"; rel="${rel#*/}"
    if [ ! -f "$UPSTREAM_FIXTURE/$rel" ]; then
        echo "curl: (22) The requested URL returned error: 404" >&2
        return 22
    fi
    if [ -n "$o" ]; then cp "$UPSTREAM_FIXTURE/$rel" "$o"; else cat "$UPSTREAM_FIXTURE/$rel"; fi
}
if [ -n "$cfg" ]; then
    rc=0; pending=""
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            'url = '*) pending=$(printf '%s' "$line" | sed -e 's/^url = "//' -e 's/"$//') ;;
            'output = '*) target=$(printf '%s' "$line" | sed -e 's/^output = "//' -e 's/"$//'); serve "$pending" "$target" || rc=1 ;;
        esac
    done < "$cfg"
    exit "$rc"
fi
serve "$url" "$out"
SHIM
    printf '#!/bin/bash\nexit 1\n' > "$dir/gh"
    cat > "$dir/git" <<'SHIM'
#!/bin/bash
if [ -n "${FAKE_MERGE_BASE_RC:-}" ]; then
    is_merge_base=false
    for arg in "$@"; do
        [ "$arg" = "--is-ancestor" ] && exec "$REAL_GIT" "$@"
        [ "$arg" = "merge-base" ] && is_merge_base=true
    done
    if $is_merge_base; then
        echo "fatal: simulated repository failure" >&2
        exit "$FAKE_MERGE_BASE_RC"
    fi
fi
exec "$REAL_GIT" "$@"
SHIM
    chmod +x "$dir/curl" "$dir/gh" "$dir/git"
}

# build_release_run NAME LOCAL_VERSION RELEASE_VERSION HISTORY
#   LOCAL_VERSION: a version for the installed update-manifest.json, or MISSING for no manifest
#   HISTORY:       unrelated = the release commit has its own root (no common ancestor)
#                  shallow   = the same, but the install is a --depth 1 clone
# Sets RUN_DIR, UP_DIR (what the release delivers), SD_DIR (the install), FIXTURE_SHA (the release commit).
# The release changes docs/note.md, so there is a change to apply and the rollback check is reached.
build_release_run() {
    local name="$1" local_version="$2" release_version="$3" history="$4"
    local src rel
    RUN_DIR="$RUN_ROOT/$name"
    UP_DIR="$RUN_DIR/upstream"
    SD_DIR="$RUN_DIR/ws/FMT-exocortex-template"
    src="$RUN_DIR/src"
    rel="$RUN_DIR/release-repo"
    mkdir -p "$UP_DIR/docs" "$RUN_DIR/ws" "$RUN_DIR/home" "$RUN_DIR/tmp" "$rel" \
        "$src/.claude/lib" "$src/scripts/lib" "$src/docs"
    write_release_shims "$RUN_DIR/shim"

    cp "$UPDATE_SH" "$UP_DIR/update.sh"
    printf '# Template CLAUDE.md\n\nSame content both sides.\n' > "$UP_DIR/CLAUDE.md"
    printf 'release content\n' > "$UP_DIR/docs/note.md"
    python3 - "$UP_DIR" "$release_version" <<'PY'
import hashlib
import json
import pathlib
import sys

root, version = pathlib.Path(sys.argv[1]), sys.argv[2]
files = [
    {"path": path, "sha256": hashlib.sha256((root / path).read_bytes()).hexdigest()}
    for path in ("CLAUDE.md", "docs/note.md", "update.sh")
]
manifest = {"schema_version": 2, "version": version, "files": files, "deprecated_files": []}
(root / "update-manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
PY

    # The install: update.sh, its two sourced libraries, CLAUDE.md, the old docs/note.md.
    cp "$UPDATE_SH" "$src/update.sh"
    chmod +x "$src/update.sh"
    cp "$REPO_ROOT/.claude/lib/frontmatter.sh" "$src/.claude/lib/frontmatter.sh"
    cp "$REPO_ROOT/scripts/lib/common.sh" "$src/scripts/lib/common.sh"
    cp "$UP_DIR/CLAUDE.md" "$src/CLAUDE.md"
    cp "$UP_DIR/CLAUDE.md" "$src/.claude.md.base"
    printf 'old content\n' > "$src/docs/note.md"
    if [ "$local_version" != "MISSING" ]; then
        printf '{"schema_version": 2, "version": "%s", "files": []}\n' "$local_version" > "$src/update-manifest.json"
    fi
    git -C "$src" init -q
    git -C "$src" config user.email "test@example.com"
    git -C "$src" config user.name "test"
    git -C "$src" add -A
    git -C "$src" commit -q -m "install, first commit"
    printf 'second\n' > "$src/second.txt"
    git -C "$src" add second.txt
    git -C "$src" commit -q -m "install, second commit"
    if [ "$history" = "shallow" ]; then
        git clone -q --depth 1 "file://$src" "$SD_DIR"
    else
        git clone -q "file://$src" "$SD_DIR"
    fi

    # The release: a commit with its own root, whose object is already in the install.
    git -C "$rel" init -q
    git -C "$rel" config user.email "test@example.com"
    git -C "$rel" config user.name "test"
    printf 'release root\n' > "$rel/root.txt"
    git -C "$rel" add root.txt
    git -C "$rel" commit -q -m "release root"
    FIXTURE_SHA=$(git -C "$rel" rev-parse HEAD)
    git -C "$SD_DIR" fetch -q "$rel" "HEAD:refs/test/release"

    # The workspace around the install (as setup.sh leaves it).
    cp "$UP_DIR/CLAUDE.md" "$RUN_DIR/ws/CLAUDE.md"
    cp "$UP_DIR/CLAUDE.md" "$RUN_DIR/ws/.claude.md.base"
    printf 'GOVERNANCE_REPO="pilot-governance"\n' > "$RUN_DIR/ws/.exocortex.env"

    # A fixture that is not what the case needs would make every assertion below meaningless.
    local want_shallow=false
    [ "$history" = "shallow" ] && want_shallow=true
    if ! git -C "$SD_DIR" cat-file -e "$FIXTURE_SHA" 2>/dev/null \
        || git -C "$SD_DIR" merge-base HEAD "$FIXTURE_SHA" >/dev/null 2>&1 \
        || [ "$(git -C "$SD_DIR" rev-parse --is-shallow-repository)" != "$want_shallow" ]; then
        fail "$name: broken fixture (release object missing, histories related, or wrong shallow state)"
    fi
}

# run_release_update [MERGE_BASE_RC] - the real update.sh --yes on the release channel.
# Sets RUN_RC; the combined output is $RUN_DIR/out.log.
run_release_update() {
    env -u GH_TOKEN -u GITHUB_TOKEN \
        PATH="$RUN_DIR/shim:$PATH" HOME="$RUN_DIR/home" TMPDIR="$RUN_DIR/tmp" \
        UPSTREAM_FIXTURE="$UP_DIR" FIXTURE_RELEASE_SHA="$FIXTURE_SHA" REAL_GIT="$REAL_GIT" \
        FAKE_MERGE_BASE_RC="${1:-}" \
        bash "$SD_DIR/update.sh" --yes > "$RUN_DIR/out.log" 2>&1
    RUN_RC=$?
}

# assert_applied CASE - rc 0, the release content landed, no "cannot check history" stop
assert_applied() {
    local label="$1" note
    note=$(cat "$SD_DIR/docs/note.md")
    if [ "$RUN_RC" -eq 0 ] && [ "$note" = "release content" ]; then
        pass "$label --yes applies the release"
    else
        fail "$label expected the release applied (rc 0), got rc=$RUN_RC, docs/note.md='$note', tail: $(tail -4 "$RUN_DIR/out.log" | tr '\n' ' ')"
    fi
    if grep -q "Остановлено" "$RUN_DIR/out.log"; then
        fail "$label the run printed a stop message although the release was applied"
    else
        pass "$label no stop message"
    fi
}

# assert_stopped CASE REASON_PATTERN - rc 1 (EXIT_USAGE), the files untouched, the reason printed
assert_stopped() {
    local label="$1" reason="$2" note
    note=$(cat "$SD_DIR/docs/note.md")
    if [ "$RUN_RC" -eq 1 ]; then
        pass "$label --yes stops with exit 1"
    else
        fail "$label expected exit 1, got $RUN_RC, tail: $(tail -4 "$RUN_DIR/out.log" | tr '\n' ' ')"
    fi
    if [ "$note" = "old content" ]; then
        pass "$label the target file is untouched"
    else
        fail "$label the target file changed to '$note' although the run stopped"
    fi
    if grep -q "Остановлено: $reason" "$RUN_DIR/out.log"; then
        pass "$label the stop names its reason ($reason)"
    else
        fail "$label expected the stop reason '$reason', tail: $(tail -4 "$RUN_DIR/out.log" | tr '\n' ' ')"
    fi
}

CASE_COUNT=$((CASE_COUNT + 1))
build_release_run unrelated-newer 0.40.1 0.40.2 unrelated
run_release_update
assert_applied "14 unrelated histories, release newer:"

CASE_COUNT=$((CASE_COUNT + 1))
build_release_run unrelated-older 0.41.0 0.40.2 unrelated
run_release_update
assert_stopped "15 unrelated histories, release older:" "обнаружен откат"

CASE_COUNT=$((CASE_COUNT + 1))
build_release_run unrelated-equal 0.40.2 0.40.2 unrelated
run_release_update
assert_applied "16 unrelated histories, equal versions (not proof of a rollback):"

CASE_COUNT=$((CASE_COUNT + 1))
build_release_run no-manifest MISSING 0.40.2 unrelated
run_release_update
assert_stopped "17a unrelated histories, no local manifest:" "не удалось проверить историю релиза"
build_release_run bad-local-version dev 0.40.2 unrelated
run_release_update
assert_stopped "17b unrelated histories, unreadable local version:" "не удалось проверить историю релиза"
build_release_run bad-release-version 0.40.1 weird unrelated
run_release_update
assert_stopped "17c unrelated histories, unreadable release version:" "не удалось проверить историю релиза"

CASE_COUNT=$((CASE_COUNT + 1))
build_release_run shallow-install 0.40.1 0.40.2 shallow
run_release_update
assert_stopped "18 shallow clone, release object present:" "не удалось проверить историю релиза"

CASE_COUNT=$((CASE_COUNT + 1))
build_release_run merge-base-error 0.40.1 0.40.2 unrelated
run_release_update 128
assert_stopped "19 git merge-base fails with 128:" "не удалось проверить историю релиза"

[ "$CASE_COUNT" -eq 21 ] || fail "matrix executed $CASE_COUNT cases, expected 21"
echo
echo "Result: $PASS_COUNT PASS, $FAIL_COUNT FAIL ($CASE_COUNT cases)"
[ "$FAIL_COUNT" -eq 0 ] && exit 0 || exit 1
