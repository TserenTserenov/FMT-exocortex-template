#!/usr/bin/env bash
# WP-529 Ф4, scenario 2 ("неверная метка"): a file whose downloaded bytes
# don't match the manifest's declared sha256 must never be classified as a
# normal fetch — the Phase A worker must mark it hash-mismatch, and that
# status must never collapse into "fetched"/"cache-hit" downstream.
#
# Extracts the real worker body out of update.sh's heredoc (WP-546 Ф2) via
# the shared extraction lib — not a hand-retyped copy, so this test breaks
# automatically if the real worker's hash-check logic is edited without
# updating the test (same rationale as
# test_update_fetch_missing_status_failclosed.sh and T10 in
# setup/test-update-edge-cases.sh).
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
UPDATE_SH="$ROOT/update.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP" 2>/dev/null; [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null' EXIT

# shellcheck source=lib/extract-update-fetch-worker.sh
. "$ROOT/scripts/tests/lib/extract-update-fetch-worker.sh"
WORKER="$TMP/fetch-worker.sh"
extract_update_fetch_worker "$UPDATE_SH" > "$WORKER"
[ -s "$WORKER" ] || {
    echo "FAIL: worker extraction is empty — markers no longer match update.sh"
    exit 1
}

# A tiny local fixture server stands in for RAW_BASE — no dependency on a
# live remote, deterministic content.
FIXTURE_DIR="$TMP/fixture"
mkdir -p "$FIXTURE_DIR"
echo "real upstream content" > "$FIXTURE_DIR/tampered.txt"

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
( cd "$FIXTURE_DIR" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 ) &
SERVER_PID=$!
for _ in $(seq 1 30); do
    curl -sf "http://127.0.0.1:$PORT/tampered.txt" >/dev/null 2>&1 && break
    sleep 0.1
done

mkdir -p "$TMP/files" "$TMP/status" "$TMP/local"
export RAW_BASE="http://127.0.0.1:$PORT"
export CURL_BASE_OPTS="--max-time 5"
export _CURL_SSL_OPT=""
export SCRIPT_DIR="$TMP/local"
export IWE_UPDATE_FILES_DIR="$TMP/files"
export IWE_UPDATE_STATUS_DIR="$TMP/status"

# expected_hash deliberately wrong — this is the injected "неверная метка":
# the manifest declares a hash that does not match what's actually served.
WRONG_HASH="0000000000000000000000000000000000000000000000000000000000000"
bash "$WORKER" "tampered.txt|$WRONG_HASH"

kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null || true; SERVER_PID=""

STATUS_FILE="$TMP/status/tampered.txt.status"
[ -f "$STATUS_FILE" ] || {
    echo "FAIL: no status file written for the mismatched file"
    exit 1
}
FETCH_STATUS=$(cut -f1 "$STATUS_FILE")
[ "$FETCH_STATUS" = "hash-mismatch" ] || {
    echo "FAIL: expected status=hash-mismatch, got '$FETCH_STATUS' (would classify as a normal file)"
    exit 1
}
[ ! -f "$TMP/files/tampered.txt" ] || {
    echo "FAIL: mismatched content was left in staging — a later classification pass could still pick it up"
    exit 1
}

echo "PASS: a sha256 mismatch is marked hash-mismatch and the tainted content is not staged"
