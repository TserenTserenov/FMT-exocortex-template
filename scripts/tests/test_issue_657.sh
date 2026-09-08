#!/usr/bin/env bash
# test_issue_657.sh — regression for the composing EXIT-trap in
# strategist.sh (issue #657): a second `trap ... EXIT` used to silently
# replace the first — the inhibitor-kill cleanup never ran once
# acquire_lock() registered its own trap, on every ordinary run, not only
# on kill -9/orphaning.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
SCRIPT="$ROOT/roles/strategist/scripts/strategist.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0

# --- 1. Both markers must survive to script exit, in registration order,
# not just the last one registered (the exact bug: a lone `trap X EXIT`
# followed by `trap Y EXIT` only ever runs Y).
cat > "$TMP/run1.sh" <<EOF
#!/bin/bash
set -e
$(sed -n '/^_EXIT_CLEANUPS=()/,/^trap run_exit_cleanups EXIT$/p' "$SCRIPT")
MARKER="$TMP/markers1.txt"
add_exit_cleanup "echo first >> '\$MARKER'"
add_exit_cleanup "echo second >> '\$MARKER'"
EOF
bash "$TMP/run1.sh"
if [ ! -f "$TMP/markers1.txt" ]; then
    echo "❌ no cleanups ran at all"
    fail=1
elif [ "$(cat "$TMP/markers1.txt")" != $'first\nsecond' ]; then
    echo "❌ expected both cleanups to run in order, got:"
    cat "$TMP/markers1.txt"
    fail=1
fi

# --- 2. acquire_lock()'s own trap registration (extracted verbatim from the
# real function) must coexist with an inhibitor-style cleanup registered
# before it — this is the literal collision from the issue: inhibit trap
# registered first, acquire_lock() trap registered second.
cat > "$TMP/run2.sh" <<EOF
#!/bin/bash
set -e
$(sed -n '/^_EXIT_CLEANUPS=()/,/^trap run_exit_cleanups EXIT$/p' "$SCRIPT")
log() { :; }
LOCK_DIR="$TMP/locks"
DATE="20260904"
mkdir -p "\$LOCK_DIR"
$(awk '/^acquire_lock\(\)/{c=1} c{print} c&&/^}/{exit}' "$SCRIPT")

INHIBIT_MARKER="$TMP/inhibit-killed.txt"
add_exit_cleanup "echo killed >> '\$INHIBIT_MARKER'"
acquire_lock "test-scenario"
EOF
bash "$TMP/run2.sh"
if [ ! -f "$TMP/inhibit-killed.txt" ]; then
    echo "❌ inhibitor-kill cleanup did not run — acquire_lock()'s trap clobbered it (issue #657)"
    fail=1
fi
if [ ! -d "$TMP/locks" ] || find "$TMP/locks" -mindepth 1 -maxdepth 1 -type d | grep -q .; then
    echo "❌ lock directory was not cleaned up by acquire_lock()'s registered cleanup"
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "✅ test_issue_657: OK"
fi
exit "$fail"
