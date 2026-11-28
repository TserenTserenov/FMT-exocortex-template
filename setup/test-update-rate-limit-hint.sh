#!/usr/bin/env bash
# update.sh: when the anonymous GitHub API limit is used up, the failure message names the reason
# and the way out (finding of the rc.3 attack on 0.42.2). Real resolve_delivery_ref() and
# github_rate_limit_hint() extracted from update.sh, curl and gh stubbed, no network.
# Bash 3.2 compatible.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SELF_DIR")"
UPDATE_SH="$REPO_ROOT/update.sh"

FAIL_COUNT=0
PASS_COUNT=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "  ✅ PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/iwe-rate-limit-hint.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
FUNCS="$WORK/funcs.sh"
extract_function() {
    awk -v signature="$1() {" '
        $0 == signature { found=1 }
        found { print }
        found && /^}$/ { exit }
    ' "$UPDATE_SH"
}
{
    extract_function github_api_get
    extract_function github_rate_limit_hint
    extract_function resolve_delivery_ref
} > "$FUNCS"
for fn in github_api_get github_rate_limit_hint resolve_delivery_ref; do
    grep -q "^$fn() {" "$FUNCS" || { echo "FATAL: $fn extraction is empty" >&2; exit 2; }
done

RESET_EPOCH=1900000000

# rate_limit_body <remaining> <style: pretty|compact>: what GitHub returns for /rate_limit
rate_limit_body() {
    if [ "$2" = "compact" ]; then
        printf '{"resources":{"core":{"limit":60,"remaining":%s,"reset":%s,"used":60}},"rate":{"limit":60,"remaining":%s,"reset":%s,"used":60}}' \
            "$1" "$RESET_EPOCH" "$1" "$RESET_EPOCH"
    else
        printf '{\n  "resources": {\n    "core": {\n      "limit": 60,\n      "remaining": %s,\n      "reset": %s,\n      "used": 60\n    }\n  },\n  "rate": {\n    "limit": 60,\n    "remaining": %s,\n    "reset": %s,\n    "used": 60\n  }\n}\n' \
            "$1" "$RESET_EPOCH" "$1" "$RESET_EPOCH"
    fi
}

# run_case <name> <channel> <probe: limit0|limit0-compact|left5|offline> <gh_token> <gh_authenticated: yes|no>
# Sets CASE_RC, CASE_ERR (stderr of resolve_delivery_ref) and CASE_PROBES (how often /rate_limit was asked).
run_case() {
    local name="$1" channel="$2" probe="$3" gh_token="$4" gh_auth="$5"
    local err="$WORK/$name.err" calls="$WORK/$name.calls"
    : > "$calls"
    (
        set -uo pipefail
        REPO="owner/tmpl"
        BRANCH="main"
        API_BASE="https://api.github.com/repos/$REPO"
        RAW_BASE="https://raw.githubusercontent.com/$REPO/$BRANCH"
        CURL_BASE_OPTS=""
        _CURL_SSL_OPT=""
        EXIT_NETWORK=2
        GITHUB_API_AUTH_FAILURE=90
        GITHUB_API_INVALID_TOKEN=91
        GITHUB_API_UNSAFE_CURL_OPTIONS=92
        UPDATE_CHANNEL="$channel"
        PY_BIN=python3
        GH_TOKEN="$gh_token"
        GITHUB_TOKEN=""
        export GH_TOKEN GITHUB_TOKEN
        py_available() { return 0; }
        command() {
            if [ "${1:-}" = "-v" ] && [ "${2:-}" = "gh" ]; then
                [ "$gh_auth" = "yes" ]
                return
            fi
            builtin command "$@"
        }
        gh() { return 1; }   # only reached when gh_auth=yes: `gh auth status` succeeds below
        if [ "$gh_auth" = "yes" ]; then gh() { return 0; }; fi
        curl() {
            local url="" argument
            for argument in "$@"; do
                case "$argument" in http*) url="$argument" ;; esac
            done
            echo "$url" >> "$calls"
            case "$url" in
                https://api.github.com/rate_limit)
                    case "$probe" in
                        limit0) rate_limit_body 0 pretty ;;
                        limit0-compact) rate_limit_body 0 compact ;;
                        left5) rate_limit_body 5 pretty ;;
                        *) return 7 ;;
                    esac
                    ;;
                *) return 22 ;;   # curl -f on HTTP 403: every other API call fails
            esac
        }
        # shellcheck disable=SC1090
        . "$FUNCS"
        resolve_delivery_ref
    ) > /dev/null 2> "$err"
    CASE_RC=$?
    CASE_ERR=$(cat "$err")
    CASE_PROBES=$(grep -c '/rate_limit$' "$calls" || true)
}

expect_contains() { # <case> <needle>
    case "$CASE_ERR" in *"$2"*) pass "$1: stderr has «$2»" ;; *) fail "$1: stderr lacks «$2»; got: $CASE_ERR" ;; esac
}
expect_lacks() { # <case> <needle>
    case "$CASE_ERR" in *"$2"*) fail "$1: stderr must not have «$2»; got: $CASE_ERR" ;; *) pass "$1: no «$2»" ;; esac
}
expect_rc() { # <case> <rc>
    if [ "$CASE_RC" -eq "$2" ]; then pass "$1: exit status $2"; else fail "$1: exit status $CASE_RC, expected $2"; fi
}

echo "== release channel, anonymous, limit used up"
run_case release_limit release limit0 "" no
expect_rc release_limit 2
expect_contains release_limit "не удалось определить последний релиз"
expect_contains release_limit "исчерпан лимит анонимных запросов к GitHub"
expect_contains release_limit "GH_TOKEN=<токен> bash update.sh"
expect_contains release_limit "подождать и повторить"
case "$CASE_ERR" in
    *"сбросится около "[0-9][0-9]":"[0-9][0-9]" по времени этого компьютера"*) pass "release_limit: reset time shown" ;;
    *) fail "release_limit: no reset time in: $CASE_ERR" ;;
esac

echo "== compact JSON answer of /rate_limit"
run_case release_compact release limit0-compact "" no
expect_contains release_compact "исчерпан лимит анонимных запросов к GitHub"

echo "== limit not used up: the plain failure message only"
run_case release_left release left5 "" no
expect_rc release_left 2
expect_contains release_left "не удалось определить последний релиз"
expect_lacks release_left "исчерпан лимит"

echo "== probe itself fails (offline): the plain failure message only"
run_case release_offline release offline "" no
expect_contains release_offline "не удалось определить последний релиз"
expect_lacks release_offline "исчерпан лимит"

echo "== a token is set: no hint, and /rate_limit is not even asked"
run_case release_token release limit0 "ghp_testtoken123" no
expect_lacks release_token "исчерпан лимит"
if [ "$CASE_PROBES" -eq 0 ]; then pass "release_token: /rate_limit not asked"; else fail "release_token: /rate_limit asked $CASE_PROBES time(s)"; fi

echo "== authenticated gh: no hint"
run_case release_gh release limit0 "" yes
expect_lacks release_gh "исчерпан лимит"

echo "== rc channel: the tag list fails on the limit"
run_case rc_limit rc limit0 "" no
expect_contains rc_limit "не удалось получить список rc-тегов"
expect_contains rc_limit "исчерпан лимит анонимных запросов к GitHub"

echo
echo "Итог: $PASS_COUNT PASS, $FAIL_COUNT FAIL"
[ "$FAIL_COUNT" -eq 0 ]
