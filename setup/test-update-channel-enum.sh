#!/usr/bin/env bash
# WP-529 F26: IWE_UPDATE_CHANNEL accepts only "release" and "main".
#
# Before this guard an unknown value (a typo like "realese", or a channel name
# invented by a user reading old docs) fell through to the main branch without
# a word: someone who explicitly asked for the pinned release got unreleased
# main instead. The run must fail closed and name the accepted values.
#
# No network: the guard fires before any transport, so --check never gets far
# enough to need one. Bash 3.2 compatible.
#
# Usage: bash setup/test-update-channel-enum.sh

set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
UPDATE_SH="$(dirname "$SELF_DIR")/update.sh"

FAIL_COUNT=0
PASS_COUNT=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "  ✅ PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/iwe-channel-enum-XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

# A curl stub makes the "valid channel" cases fail on transport instead of
# reaching the network: we assert only that the enum guard let them through,
# never that the update itself succeeds.
STUB_DIR="$TEST_ROOT/stub"
mkdir -p "$STUB_DIR"
printf '#!/bin/bash\nexit 7\n' > "$STUB_DIR/curl"
chmod +x "$STUB_DIR/curl"

run_channel() {  # $1 = channel value; prints output, returns update.sh's code
    PATH="$STUB_DIR:$PATH" HOME="$TEST_ROOT" \
        IWE_UPDATE_CHANNEL="$1" bash "$UPDATE_SH" --check 2>&1
}

# An EMPTY value is deliberately absent from this list: IWE_UPDATE_CHANNEL=""
# means "not set" to the `${VAR:-release}` expansion, and falling back to the
# safest channel is the right answer there. A single space is a different
# case — that is a real value, and a wrong one.
echo "--- Rejected: unknown channel values ---"
for bad in realese RELEASE dev " " main-branch; do
    OUT=$(run_channel "$bad")
    RC=$?
    label=${bad:-<пусто>}
    if [ "$RC" -eq 1 ]; then
        pass "channel '$label' rejected with exit 1"
    else
        fail "channel '$label' exited $RC, expected 1: $OUT"
    fi
    if echo "$OUT" | grep -q "Неизвестный канал обновления"; then
        pass "channel '$label' names the problem"
    else
        fail "channel '$label' has no diagnostic: $OUT"
    fi
    if echo "$OUT" | grep -q "release" && echo "$OUT" | grep -q "main"; then
        pass "channel '$label' lists both accepted values"
    else
        fail "channel '$label' does not list accepted values: $OUT"
    fi
done

echo "--- Accepted: the two real channels pass the guard ---"
for good in release main; do
    OUT=$(run_channel "$good")
    if echo "$OUT" | grep -q "Неизвестный канал обновления"; then
        fail "channel '$good' was rejected by the enum guard: $OUT"
    else
        pass "channel '$good' passes the enum guard"
    fi
done

echo "--- Default: unset and empty both fall back to the safe channel ---"
OUT=$(PATH="$STUB_DIR:$PATH" HOME="$TEST_ROOT" bash "$UPDATE_SH" --check 2>&1)
if echo "$OUT" | grep -q "Неизвестный канал обновления"; then
    fail "unset IWE_UPDATE_CHANNEL was rejected: $OUT"
else
    pass "unset IWE_UPDATE_CHANNEL passes the enum guard"
fi

OUT=$(run_channel "")
if echo "$OUT" | grep -q "Неизвестный канал обновления"; then
    fail "empty IWE_UPDATE_CHANNEL was rejected instead of defaulting: $OUT"
else
    pass "empty IWE_UPDATE_CHANNEL defaults like unset, not rejected"
fi

echo
echo "Result: $PASS_COUNT PASS, $FAIL_COUNT FAIL"
[ "$FAIL_COUNT" -eq 0 ] && exit 0 || exit 1
