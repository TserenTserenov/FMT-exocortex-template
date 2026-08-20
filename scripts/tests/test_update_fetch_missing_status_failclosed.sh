#!/usr/bin/env bash
# WP-529 Ф4, scenario 1 ("пропуск файла"): a Phase A worker that never wrote
# its status file (killed by signal/OOM/xargs timeout) must not let that
# manifest entry pass silently — update.sh's preflight (Step 2, right after
# the `xargs -P 8` dispatch) must synthesize a fail-closed fetch-failed
# status for it, not leave it unclassified.
#
# Extracts the real preflight block from update.sh via unique line-content
# markers (same technique setup/test-update-edge-cases.sh T10 uses) — a
# hand-retyped copy would silently diverge from the real code.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
UPDATE_SH="$ROOT/update.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

extract_preflight_block() {
    awk '
        /^    MISSING_STATUS_COUNT=0$/ { found=1 }
        found { print }
        found && /^    fi$/ { exit }
    ' "$UPDATE_SH"
}

PREFLIGHT_BLOCK="$TMP/preflight.sh"
extract_preflight_block > "$PREFLIGHT_BLOCK"
[ -s "$PREFLIGHT_BLOCK" ] || {
    echo "FAIL: preflight block extraction is empty — markers no longer match update.sh"
    exit 1
}

IWE_UPDATE_STATUS_DIR="$TMP/status"
mkdir -p "$IWE_UPDATE_STATUS_DIR"

# One manifest entry ("present.txt") got a real status from Phase A; the
# other ("vanished.txt") is the injected negative scenario — its worker
# never ran to completion, so no status file exists for it.
printf 'fetched\tpresent.txt\tdownload_success\t\n' > "$IWE_UPDATE_STATUS_DIR/present.txt.status"

UPDATE_FETCH_ENTRIES="$TMP/entries.txt"
printf 'present.txt|\nvanished.txt|\n' > "$UPDATE_FETCH_ENTRIES"

# The extracted block reads $IWE_UPDATE_STATUS_DIR / $UPDATE_FETCH_ENTRIES
# and sets $MISSING_STATUS_COUNT / $MISSING_STATUS_SAMPLE — sourced (not a
# subshell) so we can assert on those variables afterward, in the current
# shell, exactly once: the block itself writes the synthesized status file
# to disk as a side effect, so a second sourcing would find it already
# present and no longer "missing" — sourcing must happen only once per fixture.
STDERR_OUT="$TMP/stderr.txt"
# shellcheck disable=SC1090
. "$PREFLIGHT_BLOCK" 2>"$STDERR_OUT"

[ "$MISSING_STATUS_COUNT" -eq 1 ] || {
    echo "FAIL: expected MISSING_STATUS_COUNT=1, got $MISSING_STATUS_COUNT"
    exit 1
}
[ -f "$IWE_UPDATE_STATUS_DIR/vanished.txt.status" ] || {
    echo "FAIL: no synthesized status file was written for the missing entry"
    exit 1
}
SYNTHESIZED=$(cat "$IWE_UPDATE_STATUS_DIR/vanished.txt.status")
case "$SYNTHESIZED" in
    fetch-failed*missing-status-synthesized*) ;;
    *)
        echo "FAIL: synthesized status is not fetch-closed: $SYNTHESIZED"
        exit 1
        ;;
esac
grep -q '⚠' "$STDERR_OUT" || {
    echo "FAIL: no warning printed to stderr for the missing status file"
    exit 1
}
# The entry that DID get a real status must be untouched by the preflight.
UNTOUCHED=$(cat "$IWE_UPDATE_STATUS_DIR/present.txt.status")
[ "$UNTOUCHED" = "$(printf 'fetched\tpresent.txt\tdownload_success\t')" ] || {
    echo "FAIL: preflight modified an entry that already had a real status"
    exit 1
}

echo "PASS: a missing Phase A status is synthesized fail-closed (fetch-failed), not silently skipped"
