#!/usr/bin/env bash
# test_issue_966_sessions_root.sh -- regression for issue #966.
#
# setup/install-iwe-paths.sh wrote `export IWE_SESSIONS_ROOT="$IWE_WORKSPACE/MC-sessions"`
# unconditionally, but MC-sessions is created "on demand", not by setup.sh (pilot
# decision 18.08, ADR-004). resolve_orz_sessions_dir (scripts/session-guard.sh)
# reads an explicitly set IWE_SESSIONS_ROOT as a deliberate choice and refuses
# without a legacy fallback, so on every installation that never adopted
# MC-sessions `session-guard.sh open` failed (no semaphore, `close` then says
# "семафор не найден").
#
# The fix lives in the generator only: the line carries the path while the
# directory exists, and an EMPTY value otherwise (the resolver's condition is
# `[ -n "${IWE_SESSIONS_ROOT:-}" ]`, so empty equals unset, and the file keeps
# exactly eight `export IWE_` lines -- asserted by T25 in
# setup/test-update-edge-cases.sh). The resolver stays strict (ADR-004): an
# existing MC-sessions that is not a git repository is still refused loudly --
# a broken migration must not be hidden by the empty value.
#
# The resolver is lifted out of session-guard.sh with awk and run in isolation
# (the whole script is never started against a real environment).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf -- "$TMP"' EXIT
# Neither the installer nor git may read or write the real HOME; git must not
# discover a repository above the fixtures (a TMPDIR inside a work tree).
export HOME="$TMP/home" TMPDIR="$TMP/tmp" GIT_CEILING_DIRECTORIES="$TMP"
mkdir -p "$HOME" "$TMPDIR"

# Same contract as the helper in session-guard.sh; the resolver calls it on refusal.
fail() { echo "session-guard: $1" >&2; exit "${2:-1}"; }
eval "$(awk '
  /^resolve_orz_sessions_dir\(\)/ { capture=1 }
  capture { print }
  capture && /^}/ { exit }
' "$ROOT/scripts/session-guard.sh")"
declare -F resolve_orz_sessions_dir >/dev/null || { echo "FAIL: resolve_orz_sessions_dir not found in session-guard.sh"; exit 1; }

# The generator's two possible lines; $IWE_WORKSPACE stays unexpanded in the file.
# shellcheck disable=SC2016 # the literal dollar sign is the point
PATH_LINE='export IWE_SESSIONS_ROOT="$IWE_WORKSPACE/MC-sessions"'
EMPTY_LINE='export IWE_SESSIONS_ROOT=""'

failures=0
check() { # <desc> <expected> <actual>
    if [ "$2" = "$3" ]; then
        echo "PASS: $1"
    else
        echo "FAIL: $1 -- ожидалось [$2], получено [$3]"
        failures=$((failures + 1))
    fi
}
check_contains() { # <desc> <haystack> <needle>
    case "$2" in
        *"$3"*) echo "PASS: $1" ;;
        *) echo "FAIL: $1 -- нет строки [$3] в [$2]"; failures=$((failures + 1)) ;;
    esac
}

generate() { # <ws> -- (re)generate .iwe-paths the way update.sh does
    mkdir -p "$1"
    "$BASH" "$ROOT/setup/install-iwe-paths.sh" --workspace "$1" --governance DS-strategy \
        --skip-zshenv --quiet >/dev/null 2>&1
}
sessions_root_line() { # <ws> -> the IWE_SESSIONS_ROOT line of the generated file
    grep '^export IWE_SESSIONS_ROOT=' "$1/.iwe-paths"
}
export_line_count() { # <ws>
    grep -c '^export IWE_' "$1/.iwe-paths"
}
# Run the resolver as a session-guard subcommand would: environment from the
# generated file only. Sets R_OUT (stdout), R_ERR (stderr), R_RC.
resolve() { # <ws>
    # shellcheck source=/dev/null
    # shellcheck disable=SC2034 # GOV_REPO is read by the resolver lifted above
    R_OUT=$( ( . "$1/.iwe-paths"; GOV_REPO="$IWE_GOVERNANCE_REPO"; resolve_orz_sessions_dir ) 2>"$TMP/resolver.err" )
    R_RC=$?
    R_ERR=$(cat "$TMP/resolver.err")
}

echo "--- (1) no MC-sessions: empty value, resolver falls back to legacy with a WARN ---"
WS1="$TMP/ws-unmigrated"
generate "$WS1"
check "генератор: IWE_SESSIONS_ROOT пуст, пока MC-sessions нет" "$EMPTY_LINE" "$(sessions_root_line "$WS1")"
check "генератор: ровно восемь строк export IWE_ (контракт T25)" "8" "$(export_line_count "$WS1")"
resolve "$WS1"
check "резолвер: код возврата 0 (не отказ)" "0" "$R_RC"
check "резолвер: legacy-путь \$GOV_REPO/sessions" "$WS1/DS-strategy/sessions" "$R_OUT"
check_contains "резолвер: видимый WARN про отсутствие MC-sessions" "$R_ERR" "WARN: MC-sessions не найден"

echo "--- the pre-fix file on the same installation heals on regeneration ---"
# What 0.40.1+ generated: the same file with the unconditional path line.
sed "s|^export IWE_SESSIONS_ROOT=.*|$PATH_LINE|" \
    "$WS1/.iwe-paths" > "$TMP/prefix.iwe-paths" && mv "$TMP/prefix.iwe-paths" "$WS1/.iwe-paths"
resolve "$WS1"
check_contains "до пересоздания (файл 0.40.1+): отказ по явному корню" "$R_ERR" "задан явно, но недоступен"
generate "$WS1"
resolve "$WS1"
check "после пересоздания: резолвер снова идёт в legacy" "$WS1/DS-strategy/sessions" "$R_OUT"

echo "--- (2) MC-sessions is a git repository: the path is used ---"
WS2="$TMP/ws-migrated"
mkdir -p "$WS2"
git init -q "$WS2/MC-sessions" 2>/dev/null
generate "$WS2"
check "генератор: путь к MC-sessions, когда каталог есть" \
    "$PATH_LINE" "$(sessions_root_line "$WS2")"
check "генератор: ровно восемь строк export IWE_ (контракт T25)" "8" "$(export_line_count "$WS2")"
resolve "$WS2"
check "резолвер: код возврата 0" "0" "$R_RC"
check "резолвер: корень сессий — MC-sessions" "$WS2/MC-sessions" "$R_OUT"
check "резолвер: без WARN" "" "$R_ERR"

echo "--- regeneration follows the directory: empty value turns into the path ---"
git init -q "$WS1/MC-sessions" 2>/dev/null
generate "$WS1"
check "после появления MC-sessions генератор пишет путь" \
    "$PATH_LINE" "$(sessions_root_line "$WS1")"

echo "--- (3) MC-sessions exists but is not a git repository: refusal stays loud (ADR-004) ---"
WS3="$TMP/ws-broken"
mkdir -p "$WS3/MC-sessions"
generate "$WS3"
check "генератор: каталог есть — пишет путь, не маскирует пустым значением" \
    "$PATH_LINE" "$(sessions_root_line "$WS3")"
resolve "$WS3"
check "резолвер: отказ (код возврата 1)" "1" "$R_RC"
check "резолвер: на stdout ничего" "" "$R_OUT"
check_contains "резолвер: громкая причина про не-git каталог" "$R_ERR" "недоступен или не git-репозиторий"

if [ "$failures" -gt 0 ]; then
    echo "FAIL: $failures проверок упало"
    exit 1
fi
echo "PASS: IWE_SESSIONS_ROOT is set only while MC-sessions exists; the resolver stays strict (issue #966)"
