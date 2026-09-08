#!/usr/bin/env bash
# WP-529 Ф4, scenario "пропуск файла" — rewritten against the actual merged
# WP-546 Ф2 implementation (see test_update_download_batch_network_failure_
# failclosed.sh header for why this Ф4 test family was rewritten).
#
# The two previous tests prove download_batch() and verify_batch_integrity()
# are individually fail-closed. This one proves the GLUE between them and
# classification — the retry-queue build + final per-file loop (update.sh
# Step 2, "if [ ${#DOWNLOAD_QUEUE[@]} -gt 0 ]; then ... done") — actually
# routes a file that never becomes deliverable into SKIPPED_DOWNLOAD, not
# NEW_FILES/UPDATED_FILES/UNCHANGED, and that a retry is genuinely attempted
# (not skipped by a wrong queue-building condition) without ever aborting
# under set -e.
#
# Extracted from the real update.sh, not hand-copied — see
# scripts/tests/lib/extract-update-download-batch.sh.
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

GLUE=$(mktemp)
CLEANUP_DIRS+=("$GLUE")
extract_update_retry_and_classify "$UPDATE_SH" > "$GLUE"
[ -s "$GLUE" ] || {
    echo "FAIL: retry+classify block extraction is empty — markers no longer match update.sh"
    exit 1
}

TMPDIR_UPDATE=$(mktemp -d)
CLEANUP_DIRS+=("$TMPDIR_UPDATE")
SCRIPT_DIR="$TMPDIR_UPDATE/local"
mkdir -p "$SCRIPT_DIR"

FIXTURE_DIR="$TMPDIR_UPDATE/fixture"
mkdir -p "$FIXTURE_DIR"
printf 'a real deliverable file\n' > "$FIXTURE_DIR/deliverable.txt"

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
SERVER_LOG="$TMPDIR_UPDATE/server.log"
# stderr, not /dev/null: http.server logs one line per request there by
# default — used below to prove the retry actually re-requested gone.txt,
# not just that it ended up unreachable by whatever route.
( cd "$FIXTURE_DIR" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>"$SERVER_LOG" ) &
SERVER_PID=$!
for _ in $(seq 1 30); do
    curl -sf "http://127.0.0.1:$PORT/deliverable.txt" >/dev/null 2>&1 && break
    sleep 0.1
done

# RAW_BASE points at the real fixture server, so "deliverable.txt" succeeds
# and "gone.txt" (not served — genuinely 404, not a network-down scenario)
# never becomes deliverable through either the first attempt or the retry.
RAW_BASE="http://127.0.0.1:$PORT"
CURL_BASE_OPTS="--max-time 5"
_CURL_SSL_OPT=""

DOWNLOAD_QUEUE=("deliverable.txt" "gone.txt")
DOWNLOAD_DESCS=("a real file" "never exists")
DOWNLOAD_HASHES=("" "")   # empty: no sha256 declared for either in this fixture
NEW_FILES=(); NEW_DESCS=(); UPDATED_FILES=(); UPDATED_LINES=(); UNCHANGED=0; SKIPPED_DOWNLOAD=()

# Serializes one array as a `NAME=(...)` line the parent can source back.
# `printf '%q '` on a zero-element array still runs its format string once,
# producing `NAME=('')` — a false one-element array, not a false empty one —
# so length is checked first and an empty array is written out literally.
serialize_array() {
    local name="$1"; shift
    if [ "$#" -eq 0 ]; then
        printf '%s=()\n' "$name"
    else
        printf '%s=(%s)\n' "$name" "$(printf '%q ' "$@")"
    fi
}

set +e
# set +u inside the subshell: the extracted glue is update.sh code, and
# update.sh runs WITHOUT -u by contract — on Bash 3.2 (macOS /bin/bash) an
# empty-array expansion like "${UPDATED_FILES[@]}" is an unbound-variable
# error under -u (fixed in 4.4+), so keeping the harness's -u inside the
# glue tests an environment the real code never runs in.
( set -e; set +u
  # shellcheck disable=SC1090
  . "$GLUE"
  # Re-export the arrays a subshell can't hand back to the parent — write
  # them to a file the parent reads after the subshell exits, since a
  # subshell's variable changes never propagate out.
  {
    serialize_array NEW_FILES "${NEW_FILES[@]}"
    serialize_array UPDATED_FILES "${UPDATED_FILES[@]}"
    printf 'UNCHANGED=%q\n' "$UNCHANGED"
    serialize_array SKIPPED_DOWNLOAD "${SKIPPED_DOWNLOAD[@]}"
  } > "$TMPDIR_UPDATE/result-vars.sh"
)
GLUE_EXIT=$?
set -e

kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

# Cold-context review point: the block's own docstring claims a retry is
# "genuinely attempted, not skipped by a wrong queue-building condition" —
# but the final classification alone (gone.txt ends up in SKIPPED_DOWNLOAD)
# can't tell "retried and still failed" from "never queued for retry at
# all", since a permanently-404 fixture produces the same end state either
# way. The access log can: two GET requests for gone.txt is direct evidence
# the retry queue actually re-submitted it.
GONE_REQUESTS=$(grep -c 'GET /gone.txt' "$SERVER_LOG" 2>/dev/null || true)
GONE_REQUESTS=${GONE_REQUESTS:-0}
[ "$GONE_REQUESTS" -ge 2 ] || {
    echo "FAIL: gone.txt was requested $GONE_REQUESTS time(s), expected >=2 (initial attempt + retry) — the retry queue may not actually be re-submitting failed files"
    exit 1
}

[ "$GLUE_EXIT" -eq 0 ] || {
    echo "FAIL: the retry+classify block exited $GLUE_EXIT under set -e — an undeliverable file must not abort the update"
    exit 1
}
[ -f "$TMPDIR_UPDATE/result-vars.sh" ] || {
    echo "FAIL: retry+classify block did not run to completion (no result captured)"
    exit 1
}
# shellcheck disable=SC1091
. "$TMPDIR_UPDATE/result-vars.sh"

# The undeliverable file: never in NEW_FILES/UPDATED_FILES, must be in
# SKIPPED_DOWNLOAD — this is the actual WP-529 Ф4 fail-closed criterion.
FOUND_IN_SKIPPED=false
for f in "${SKIPPED_DOWNLOAD[@]}"; do
    [ "$f" = "gone.txt" ] && FOUND_IN_SKIPPED=true
done
$FOUND_IN_SKIPPED || {
    echo "FAIL: gone.txt (never deliverable) is not in SKIPPED_DOWNLOAD — got SKIPPED_DOWNLOAD=(${SKIPPED_DOWNLOAD[*]:-})"
    exit 1
}
for f in "${NEW_FILES[@]}"; do
    [ "$f" = "gone.txt" ] && { echo "FAIL: gone.txt was classified as NEW_FILES despite never being deliverable"; exit 1; }
done

# The deliverable file: proves the block can tell the two apart (Codex
# review point 5's positive-control principle, applied to this glue layer
# too) — it must land in NEW_FILES (SCRIPT_DIR is empty, so any delivered
# file is "new"), not SKIPPED_DOWNLOAD.
FOUND_AS_NEW=false
for f in "${NEW_FILES[@]}"; do
    [ "$f" = "deliverable.txt" ] && FOUND_AS_NEW=true
done
$FOUND_AS_NEW || {
    echo "FAIL: deliverable.txt (genuinely fetched) is not in NEW_FILES — got NEW_FILES=(${NEW_FILES[*]:-})"
    exit 1
}

echo "PASS: an undeliverable file lands in SKIPPED_DOWNLOAD (not NEW/UPDATED/UNCHANGED), a deliverable one lands in NEW_FILES, no set -e abort"
