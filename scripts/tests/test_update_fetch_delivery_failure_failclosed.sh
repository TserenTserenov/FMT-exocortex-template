#!/usr/bin/env bash
# WP-529 Ф4, scenario 3 ("сбой доставки"): a file that fails to download
# (connection refused, both attempts) must be marked fetch-failed — never
# silently treated as unchanged or dropped without a trace.
#
# Extracts the real worker body out of update.sh's heredoc (WP-546 Ф2) via
# the shared extraction lib — see test_update_fetch_hash_mismatch_failclosed.sh
# for why extraction, not a hand-retyped copy.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
UPDATE_SH="$ROOT/update.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=lib/extract-update-fetch-worker.sh
. "$ROOT/scripts/tests/lib/extract-update-fetch-worker.sh"
WORKER="$TMP/fetch-worker.sh"
extract_update_fetch_worker "$UPDATE_SH" > "$WORKER"
[ -s "$WORKER" ] || {
    echo "FAIL: worker extraction is empty — markers no longer match update.sh"
    exit 1
}

mkdir -p "$TMP/files" "$TMP/status" "$TMP/local"
# Port 1 is a reserved, always-refused port on any real host — a fast,
# deterministic "delivery is down" without a live-network dependency.
export RAW_BASE="http://127.0.0.1:1"
export CURL_BASE_OPTS="--max-time 2"
export _CURL_SSL_OPT=""
export SCRIPT_DIR="$TMP/local"
export IWE_UPDATE_FILES_DIR="$TMP/files"
export IWE_UPDATE_STATUS_DIR="$TMP/status"

START=$(date +%s)
bash "$WORKER" "broken-delivery.txt|"
ELAPSED=$(( $(date +%s) - START ))

STATUS_FILE="$TMP/status/broken-delivery.txt.status"
[ -f "$STATUS_FILE" ] || {
    echo "FAIL: no status file written for the undeliverable file"
    exit 1
}
FETCH_STATUS=$(cut -f1 "$STATUS_FILE")
[ "$FETCH_STATUS" = "fetch-failed" ] || {
    echo "FAIL: expected status=fetch-failed, got '$FETCH_STATUS'"
    exit 1
}
DETAIL=$(cut -f3 "$STATUS_FILE")
[ "$DETAIL" = "fetch_failed_after_retry" ] || {
    echo "FAIL: expected detail_code=fetch_failed_after_retry (proves the retry ran), got '$DETAIL'"
    exit 1
}
[ ! -e "$TMP/files/broken-delivery.txt" ] || {
    echo "FAIL: staging has a file for a delivery that never succeeded"
    exit 1
}
# A connection-refused failure is instant — this only guards against a
# regression that turns the retry into a blocking network timeout (curl
# --max-time 2 x2 attempts would be >=4s, not the sub-second we expect here).
[ "$ELAPSED" -lt 10 ] || {
    echo "FAIL: worker took ${ELAPSED}s for two connection-refused attempts — retry may be blocking on a timeout instead"
    exit 1
}

echo "PASS: an undeliverable file is marked fetch-failed after one retry, nothing staged"
