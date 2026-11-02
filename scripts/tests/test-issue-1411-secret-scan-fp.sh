#!/usr/bin/env bash
# issue #1411 (item 2): the pre-commit secret scan blocked the commit of a
# template update on its own file names. The yookassa rule matched long
# lowercase snake_case test identifiers (a JSON path to a four-segment test
# script, a `name()` call, an escaped `\.sh` in a regex), and the
# generic-token-assignment rule matched a 40+ char marker in a pytest
# fixture. Feeds the real scanner through a staged diff in a throwaway repo:
# word identifiers must pass, a base64url-shaped key must still block.
# Probe strings are assembled at runtime so this file never holds a literal
# the scanner would flag on itself.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

REPO="$TMP/repo"
mkdir -p "$REPO/.claude/hooks" "$REPO/scripts"
cp "$ROOT/.claude/hooks/secret-bypass-lib.sh" "$ROOT/.claude/hooks/secret-bypass-analyzer.py" "$REPO/.claude/hooks/"
cp "$ROOT/scripts/pre-commit-secret-scan.sh" "$REPO/scripts/"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@test
git -C "$REPO" config user.name test
git -C "$REPO" add .claude scripts
git -C "$REPO" commit -q -m base

# Runs the scanner on a single staged probe file; returns its exit code.
scan_probe() {
    printf '%s\n' "$1" > "$REPO/probe.txt"
    git -C "$REPO" add probe.txt
    ( cd "$REPO" && bash scripts/pre-commit-secret-scan.sh ) >"$TMP/scan.out" 2>&1
    local rc=$?
    git -C "$REPO" rm -q --cached probe.txt
    rm -f "$REPO/probe.txt"
    return "$rc"
}

expect_clean() {
    if scan_probe "$2"; then
        ok "$1"
    else
        sed 's/^/    /' "$TMP/scan.out"
        bad "$1"
    fi
}

expect_blocked() {
    scan_probe "$2"
    local rc=$?
    if [ "$rc" -eq 1 ] && grep -q -- "- $3:" "$TMP/scan.out"; then
        ok "$1"
    else
        sed 's/^/    /' "$TMP/scan.out"
        bad "$1 (rc=$rc)"
    fi
}

T="test""_"
L="live""_"

# Lines shaped exactly like the ones reported in the issue.
expect_clean "manifest JSON path to a four-segment test script" \
    "      \"path\": \"scripts/tests/${T}critical_alert_disabled_tracker.sh\","
expect_clean "generate-manifest.sh list entry" \
    "    \"scripts/tests/${T}update_deprecated_mirror_guard.sh\""
expect_clean "shell assignment of a test basename" \
    "SELF_TEST_BASENAME=\"${T}issue_python_resolver_contract.sh\""
expect_clean "escaped extension inside a regex" \
    "grep -Ev '^scripts/tests/${T}issue_463_setup_reuses_resolved_python3\\.sh\$'"
expect_clean "pytest helper call without a def" \
    "    ${T}yaml_need_without_schema_version_raises()"
expect_clean "long precompact checkpoint identifier, bare" \
    "${T}issue_1183_precompact_checkpoint_survives_restart"
expect_clean "identifier wrapped across comment lines (trailing underscore)" \
    "# see ${T}update_download_batch_network_failure_"
expect_clean "fixture marker shortened below the generic-token floor" \
    "    secret = \"outside-dir-secret-must-not-leak-533\""

# Base64url-shaped keys (random mixed case, built at runtime) still block.
rand_tail() {
    python3 -c 'import secrets,string;a=string.ascii_letters+string.digits;print("".join(secrets.choice(a) for _ in range(32)))'
}
TAIL=$(rand_tail)
case "$TAIL" in *[A-Z]*) ;; *) TAIL="Q${TAIL#?}" ;; esac
expect_blocked "random mixed-case test-prefixed key" "YOOKASSA_SECRET=${T}${TAIL}" yookassa
expect_blocked "random mixed-case live-prefixed key" "shop: ${L}${TAIL}" yookassa
expect_blocked "dense digit test-prefixed key" "${T}$(printf '9%.0s' $(seq 32))" yookassa
expect_blocked "word prefix with a random mixed-case tail" "${T}issue_1411_ab_${TAIL}" yookassa

echo "Итого: пройдено $pass, упало $fail"
[ "$fail" -eq 0 ] || exit 1
