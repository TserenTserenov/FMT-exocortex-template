#!/usr/bin/env bash
# test_role_runner_update_marker_guard.sh — WP-529 F6 (Evgenii post-update
# defect #1, 18.08): update.sh reinstalls auto-roles while .update-incomplete
# is still present (the transaction closes at the very end), and RunAtLoad in
# the strategist plists fires the agent right at launchctl load — a mutating
# run started mid-update at 22:38. The runner must skip cleanly while the
# marker exists, and must NOT short-circuit when it does not.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/template" "$TMP/ws" "$TMP/home"
touch "$TMP/template/.update-incomplete"

echo "--- with marker: runner must skip before any mutation ---"
set +e
OUT=$(HOME="$TMP/home" IWE_TEMPLATE="$TMP/template" IWE_WORKSPACE="$TMP/ws" \
      bash "$ROOT/roles/strategist/scripts/strategist.sh" morning 2>&1)
RC=$?
set -e

if [ "$RC" -ne 0 ]; then
    echo "❌ FAIL: expected clean skip (exit 0), got $RC"
    echo "$OUT"
    exit 1
fi
if ! echo "$OUT" | grep -q "update in progress"; then
    echo "❌ FAIL: skip message about update in progress not printed"
    echo "$OUT"
    exit 1
fi
if [ -d "$TMP/home/logs/strategist" ]; then
    echo "❌ FAIL: log/lock dirs created — runner went past the guard"
    exit 1
fi
echo "✅ PASS: strategist.sh skips cleanly while .update-incomplete is present"

echo "--- without marker: guard must NOT short-circuit the runner ---"
rm "$TMP/template/.update-incomplete"
set +e
OUT2=$(HOME="$TMP/home" IWE_TEMPLATE="$TMP/template" IWE_WORKSPACE="$TMP/ws" \
       PATH="/usr/bin:/bin" bash "$ROOT/roles/strategist/scripts/strategist.sh" morning 2>&1)
RC2=$?
set -e

# Without claude CLI in PATH the runner proceeds past the guard and fails
# later (exit 127 at the CLAUDE_PATH check, or otherwise non-zero). A clean
# exit 0 with the update-skip message would mean the guard fires spuriously.
if [ "$RC2" -eq 0 ] && echo "$OUT2" | grep -q "update in progress"; then
    echo "❌ FAIL: guard fired without a marker"
    echo "$OUT2"
    exit 1
fi
echo "✅ PASS: without the marker the guard does not short-circuit (rc=$RC2)"
