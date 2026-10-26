#!/usr/bin/env bash
# WP-529 Ф239: IWE_UPDATE_CHANNEL=rc resolves the newest vX.Y.Z-rc.N tag via
# the git refs API (tags are not GitHub Releases, so /releases never lists
# them), picks the max by the numeric tuple (X,Y,Z,N) — not string order —
# pins the candidate commit SHA before Step 0, refuses closed when no
# candidate exists, and warns when the candidate is older than the published
# release.
#
# No network: a curl stub serves the API fixtures and fails everything else.
# Bash 3.2 compatible.
#
# Usage: bash setup/test-update-rc-channel.sh

set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
UPDATE_SH="$(dirname "$SELF_DIR")/update.sh"

FAIL_COUNT=0
PASS_COUNT=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "  ✅ PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/iwe-rc-channel-XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

STUB_DIR="$TEST_ROOT/stub"
mkdir -p "$STUB_DIR"

REFS_FIXTURE='[
  {"ref":"refs/tags/v0.41.9","object":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}},
  {"ref":"refs/tags/v0.42.0-rc.2","object":{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}},
  {"ref":"refs/tags/v0.42.0-rc.10","object":{"sha":"cccccccccccccccccccccccccccccccccccccccc"}},
  {"ref":"refs/tags/v0.43.0-rc.1","object":{"sha":"dddddddddddddddddddddddddddddddddddddddd"}},
  {"ref":"refs/tags/v0.43.0-rc","object":{"sha":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}}
]'
COMMIT_FIXTURE='{"sha":"f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9"}'

# $1 = path to the releases/latest fixture file (empty = API error there)
write_stub() {
    cat > "$STUB_DIR/curl" <<STUB
#!/bin/bash
for last; do :; done
case "\$last" in
    *api.github.com*matching-refs*) printf '%s' '$REFS_FIXTURE' ;;
    *api.github.com*commits/v0.43.0-rc.1) printf '%s' '$COMMIT_FIXTURE' ;;
    *api.github.com*releases/latest)
        if [ -n "$1" ]; then cat "$1"; else exit 22; fi ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "$STUB_DIR/curl"
}

run_rc() {  # prints output, returns update.sh's code
    PATH="$STUB_DIR:$PATH" HOME="$TEST_ROOT" GH_TOKEN= GITHUB_TOKEN= \
        IWE_UPDATE_CHANNEL=rc bash "$UPDATE_SH" --check 2>&1
}

echo "--- Fresh candidate: max tuple wins (v0.43.0-rc.1 over v0.42.0-rc.10), SHA pinned ---"
printf '{"tag_name":"v0.42.0"}' > "$TEST_ROOT/latest-fresh.json"
write_stub "$TEST_ROOT/latest-fresh.json"
OUT=$(run_rc)
if echo "$OUT" | grep -q "Канал поставки: кандидат v0.43.0-rc.1 (снимок f9f9f9f9f9f9)"; then
    pass "newest rc tag resolved and pinned to commit SHA"
else
    fail "rc resolution wrong: $OUT"
fi
if echo "$OUT" | grep -q "устарел"; then
    fail "fresh candidate wrongly reported as stale: $OUT"
else
    pass "fresh candidate produces no stale warning"
fi

echo "--- Stale candidate: release v0.43.0 already published ---"
printf '{"tag_name":"v0.43.0"}' > "$TEST_ROOT/latest-stale.json"
write_stub "$TEST_ROOT/latest-stale.json"
OUT=$(run_rc)
if echo "$OUT" | grep -q "кандидат v0.43.0-rc.1 устарел"; then
    pass "stale candidate warns and points at the release channel"
else
    fail "stale candidate not flagged: $OUT"
fi

echo "--- No candidates: fail-closed, no fallback ---"
write_stub ""
cat > "$STUB_DIR/curl" <<'STUB'
#!/bin/bash
for last; do :; done
case "$last" in
    *api.github.com*matching-refs*) printf '[]' ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$STUB_DIR/curl"
OUT=$(run_rc)
RC=$?
if [ "$RC" -eq 2 ]; then
    pass "empty candidate list exits 2 (network/fail-closed)"
else
    fail "empty candidate list exited $RC, expected 2: $OUT"
fi
if echo "$OUT" | grep -q "кандидатов в выпуск"; then
    pass "empty candidate list names the problem"
else
    fail "empty candidate list has no diagnostic: $OUT"
fi
if echo "$OUT" | grep -q "Канал поставки"; then
    fail "empty candidate list still picked a delivery channel: $OUT"
else
    pass "empty candidate list delivers nothing"
fi

echo "--- Malformed refs JSON: fail-closed ---"
cat > "$STUB_DIR/curl" <<'STUB'
#!/bin/bash
for last; do :; done
case "$last" in
    *api.github.com*matching-refs*) printf 'not json' ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$STUB_DIR/curl"
OUT=$(run_rc)
RC=$?
if [ "$RC" -eq 2 ] && echo "$OUT" | grep -q "кандидатов в выпуск"; then
    pass "malformed refs JSON fails closed"
else
    fail "malformed refs JSON: rc=$RC out=$OUT"
fi

echo "--- Commit lookup fails: fail-closed, no tag-name fallback ---"
write_stub ""
cat > "$STUB_DIR/curl" <<STUB
#!/bin/bash
for last; do :; done
case "\$last" in
    *api.github.com*matching-refs*) printf '%s' '$REFS_FIXTURE' ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$STUB_DIR/curl"
OUT=$(run_rc)
RC=$?
if [ "$RC" -eq 2 ] && echo "$OUT" | grep -q "не удалось закрепить кандидат"; then
    pass "failed commit lookup refuses the update"
else
    fail "failed commit lookup: rc=$RC out=$OUT"
fi
if echo "$OUT" | grep -q "Канал поставки"; then
    fail "failed commit lookup still picked a delivery channel: $OUT"
else
    pass "failed commit lookup delivers nothing"
fi

echo
echo "Result: $PASS_COUNT PASS, $FAIL_COUNT FAIL"
[ "$FAIL_COUNT" -eq 0 ] && exit 0 || exit 1
