#!/usr/bin/env bash
# WP-529 Ф4, scenario "неверная метка" — rewritten against the actual merged
# WP-546 Ф2 implementation (see test_update_download_batch_network_failure_
# failclosed.sh header for why this Ф4 test family was rewritten).
#
# A file whose downloaded bytes don't match the manifest's declared sha256
# must have its staged copy removed by verify_batch_integrity() — proven
# here as a state CHANGE between download_batch() and verify_batch_integrity()
# (Codex review point 1: file present after download, absent after verify —
# not just "absent at the end", which could also mean the download itself
# silently failed and this test would pass for the wrong reason).
#
# verify_batch_integrity() reads the global parallel arrays DOWNLOAD_QUEUE/
# DOWNLOAD_HASHES by index — this test builds them explicitly and asserts
# they stay aligned (Codex review point 2), since a silent index mismatch
# would make the function check the wrong hash against the wrong file.
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
    extract_update_verify_batch_integrity "$UPDATE_SH"
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

TMPDIR_UPDATE=$(mktemp -d)
CLEANUP_DIRS+=("$TMPDIR_UPDATE")
FIXTURE_DIR="$TMPDIR_UPDATE/fixture"
mkdir -p "$FIXTURE_DIR"
printf 'real content, not empty\n' > "$FIXTURE_DIR/tampered.txt"
printf 'a second real file, also not empty\n' > "$FIXTURE_DIR/clean.txt"

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
( cd "$FIXTURE_DIR" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 ) &
SERVER_PID=$!
for _ in $(seq 1 30); do
    curl -sf "http://127.0.0.1:$PORT/clean.txt" >/dev/null 2>&1 && break
    sleep 0.1
done

RAW_BASE="http://127.0.0.1:$PORT"
CURL_BASE_OPTS="--max-time 5"
_CURL_SSL_OPT=""

# DOWNLOAD_QUEUE/DOWNLOAD_HASHES built explicitly, matched by index — same
# contract download_batch's caller in update.sh Step 2 relies on.
WRONG_HASH="0000000000000000000000000000000000000000000000000000000000000"
RIGHT_HASH=$(printf 'a second real file, also not empty\n' | sha256sum | cut -d' ' -f1)
DOWNLOAD_QUEUE=("tampered.txt" "clean.txt")
DOWNLOAD_HASHES=("$WRONG_HASH" "$RIGHT_HASH")
[ "${#DOWNLOAD_QUEUE[@]}" -eq "${#DOWNLOAD_HASHES[@]}" ] || {
    echo "FAIL: DOWNLOAD_QUEUE/DOWNLOAD_HASHES fixture itself is misaligned before the function even runs"
    exit 1
}

download_batch "${DOWNLOAD_QUEUE[@]}"
kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

# State BEFORE verify_batch_integrity: both files genuinely downloaded —
# proves the removal below is verify_batch_integrity's doing, not a
# download failure masquerading as an integrity failure.
[ -s "$TMPDIR_UPDATE/files/tampered.txt" ] || {
    echo "FAIL: tampered.txt was not staged by download_batch — can't test integrity removal on a file that was never there"
    exit 1
}
[ -s "$TMPDIR_UPDATE/files/clean.txt" ] || {
    echo "FAIL: clean.txt was not staged by download_batch"
    exit 1
}

verify_batch_integrity

# State AFTER: the mismatched file is gone, the correctly-hashed one is not
# touched — proves the function checks the right hash against the right
# file (not swapped indices).
[ ! -e "$TMPDIR_UPDATE/files/tampered.txt" ] || {
    echo "FAIL: tampered.txt (wrong hash) still present after verify_batch_integrity — a hash mismatch was not caught"
    exit 1
}
[ -s "$TMPDIR_UPDATE/files/clean.txt" ] || {
    echo "FAIL: clean.txt (correct hash) was removed — verify_batch_integrity mismatched indices between DOWNLOAD_QUEUE and DOWNLOAD_HASHES"
    exit 1
}

echo "PASS: verify_batch_integrity removes only the file whose sha256 does not match its own manifest hash"
