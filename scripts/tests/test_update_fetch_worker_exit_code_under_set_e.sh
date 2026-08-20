#!/usr/bin/env bash
# WP-546 Ф2 (cold-context review, peer-session
# 2026-08-20-06-wp546-wp529-update-parallel): update.sh runs under `set -e`
# from its first line. The Phase A worker's success branch (a clean fetch,
# the MOST common outcome) used to fall off the end of the heredoc without
# an explicit `exit 0` — its exit status was whatever the last `mv` inside
# write_status() happened to return. Under `set -e`, a single worker
# returning non-zero for any transient reason aborts the entire xargs
# dispatch and the whole script, bypassing the fail-closed preflight this
# Step exists to run — the opposite of "one bad file doesn't sink the other
# 631" (issue #350's principle). Caught by cold-context review, not by the
# other three fail-closed tests (they exercise the negative branches, which
# already had `exit 0`; the success branch was the one missing it).
#
# Two checks: (1) the worker's success path genuinely exits 0 when run
# under `set -e`, on the real extracted code — not a hand-copied claim.
# (2) a static tripwire on the dispatch line itself (defense in depth, WP-546
# Ф2 turn-review): if `|| true` after `xargs -P 8 ...` is ever removed, this
# fails loudly instead of silently reintroducing the abort-on-one-failure bug.
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

FIXTURE_DIR="$TMP/fixture"
mkdir -p "$FIXTURE_DIR" "$TMP/files" "$TMP/status" "$TMP/local"
echo "clean content" > "$FIXTURE_DIR/clean.txt"

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
( cd "$FIXTURE_DIR" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 ) &
SERVER_PID=$!
for _ in $(seq 1 30); do
    curl -sf "http://127.0.0.1:$PORT/clean.txt" >/dev/null 2>&1 && break
    sleep 0.1
done

export RAW_BASE="http://127.0.0.1:$PORT"
export CURL_BASE_OPTS="--max-time 5"
export _CURL_SSL_OPT=""
export SCRIPT_DIR="$TMP/local"
export IWE_UPDATE_FILES_DIR="$TMP/files"
export IWE_UPDATE_STATUS_DIR="$TMP/status"

# Check 1: run the worker's success path under `set -e`, in a subshell so a
# non-zero exit doesn't kill this test script itself — capture the real
# exit code instead.
set +e
( set -e; bash "$WORKER" "clean.txt|" )
WORKER_EXIT=$?
set -e

kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null || true; SERVER_PID=""

[ "$WORKER_EXIT" -eq 0 ] || {
    echo "FAIL: worker's success (fetched) branch exited $WORKER_EXIT under set -e, expected 0"
    exit 1
}
FETCH_STATUS=$(cut -f1 "$TMP/status/clean.txt.status")
[ "$FETCH_STATUS" = "fetched" ] || {
    echo "FAIL: expected status=fetched, got '$FETCH_STATUS'"
    exit 1
}

# Check 2: static tripwire on the dispatch line in update.sh itself.
grep -q 'xargs -P 8 -I{} bash "\$IWE_UPDATE_WORKER" {} < "\$UPDATE_FETCH_ENTRIES" || true' "$UPDATE_SH" || {
    echo "FAIL: the xargs dispatch in update.sh no longer has '|| true' — a single worker's"
    echo "      non-zero exit will now abort the whole update under set -e (see comment above)."
    exit 1
}

echo "PASS: worker success path exits 0 under set -e, and the dispatch line's || true guard is intact"
