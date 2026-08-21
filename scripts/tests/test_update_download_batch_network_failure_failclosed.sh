#!/usr/bin/env bash
# WP-529 Ф4, scenario "сбой доставки" — rewritten against the actual merged
# WP-546 Ф2 implementation (main commit 8112b1a: curl --parallel batch fetch,
# not the xargs/heredoc-worker draft this Ф4 test family was first written
# against in a since-abandoned parallel session, see
# sessions/2026-08/20/2026-08-20-06-wp546-wp529-update-parallel/ turn 7).
#
# A file whose batch download never succeeds must never be silently treated
# as delivered — it must end up in SKIPPED_DOWNLOAD, and download_batch's
# `|| true` must not let curl's failure abort the calling script under
# `set -e` (that exact bug — curl unguarded under set -e — was independently
# found and fixed in both this session's abandoned draft and the version
# that actually landed).
#
# Extracts download_batch()/hash_file() out of the real update.sh via unique
# line-content markers — a hand-retyped copy would silently diverge from the
# real code (same rationale as T10 in setup/test-update-edge-cases.sh).
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
UPDATE_SH="$ROOT/update.sh"
CLEANUP_DIRS=()
SERVER_PID=""
# ${arr[@]+...} idiom: a bare "${CLEANUP_DIRS[@]}" on an EMPTY array is an
# unbound-variable error under set -u on Bash 3.2 (fixed in 4.4+) — the trap
# then dies mid-cleanup and masks the test's real failure (WP-529 F9 class).
trap '[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; for d in ${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}; do rm -rf "$d" 2>/dev/null; done' EXIT

# shellcheck source=lib/extract-update-download-batch.sh
. "$ROOT/scripts/tests/lib/extract-update-download-batch.sh"

FUNCS=$(mktemp)
CLEANUP_DIRS+=("$FUNCS")
{
    extract_update_hash_file "$UPDATE_SH"
    extract_update_download_batch "$UPDATE_SH"
} > "$FUNCS"
[ -s "$FUNCS" ] || {
    echo "FAIL: function extraction is empty — markers no longer match update.sh"
    exit 1
}
# shellcheck disable=SC1090
. "$FUNCS"

# download_batch's serial/parallel switch lives in update.sh's MAIN BODY
# (WP-546 parallelization), not inside the extracted function — without it the
# first `if $USE_PARALLEL_DOWNLOAD` dies as unbound under set -u (live red CI
# on main, run 32470798303). Pin the serial path: these cases assert the
# fail-closed download contract, which must hold identically in both modes.
USE_PARALLEL_DOWNLOAD=false

# --- Case 1: network failure — RAW_BASE is unreachable ---
# Fresh TMPDIR_UPDATE per case (Codex review point 3: no state leaking
# between cases).
TMPDIR_UPDATE=$(mktemp -d)
CLEANUP_DIRS+=("$TMPDIR_UPDATE")
RAW_BASE="http://127.0.0.1:1"   # port 1: always connection-refused
CURL_BASE_OPTS="--max-time 2"
_CURL_SSL_OPT=""

set +e
( set -e; download_batch "broken/one.txt" "broken/two.txt" )
BATCH_EXIT=$?
set -e

# Codex review point 4: assert the return code explicitly — this is the
# whole point of download_batch's `|| true`, not just an assumption.
[ "$BATCH_EXIT" -eq 0 ] || {
    echo "FAIL: download_batch exited $BATCH_EXIT under set -e (an unreachable RAW_BASE must not abort the caller)"
    exit 1
}
[ ! -s "$TMPDIR_UPDATE/files/broken/one.txt" ] || {
    echo "FAIL: broken/one.txt has staged content despite an unreachable RAW_BASE"
    exit 1
}
[ ! -s "$TMPDIR_UPDATE/files/broken/two.txt" ] || {
    echo "FAIL: broken/two.txt has staged content despite an unreachable RAW_BASE"
    exit 1
}
echo "PASS: network failure — download_batch returns 0 under set -e and stages nothing"

# --- Case 2: positive control — a real, reachable file must NOT land in the
# same "nothing staged" outcome as case 1 (Codex review point 5: prove the
# test can tell success and failure apart, not just always agree). ---
TMPDIR_UPDATE=$(mktemp -d)
CLEANUP_DIRS+=("$TMPDIR_UPDATE")
FIXTURE_DIR="$TMPDIR_UPDATE/fixture"
mkdir -p "$FIXTURE_DIR"
# Codex review point 6: non-empty payload — a 0-byte fixture would make
# `[ -s ... ]` misreport success as failure regardless of this test.
printf 'real content, not empty\n' > "$FIXTURE_DIR/present.txt"

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
( cd "$FIXTURE_DIR" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 ) &
SERVER_PID=$!
for _ in $(seq 1 30); do
    curl -sf "http://127.0.0.1:$PORT/present.txt" >/dev/null 2>&1 && break
    sleep 0.1
done

RAW_BASE="http://127.0.0.1:$PORT"
CURL_BASE_OPTS="--max-time 5"
_CURL_SSL_OPT=""

download_batch "present.txt"
kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

[ -s "$TMPDIR_UPDATE/files/present.txt" ] || {
    echo "FAIL: a reachable file was not staged — positive control failed, the test can't distinguish success from failure"
    exit 1
}
[ "$(cat "$TMPDIR_UPDATE/files/present.txt")" = "real content, not empty" ] || {
    echo "FAIL: staged content does not match the fixture"
    exit 1
}
echo "PASS: positive control — a reachable file is staged with its real content"
