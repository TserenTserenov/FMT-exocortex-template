#!/usr/bin/env bash
# Regression coverage for the residuals of #1099, #1010 (F8) and #1006 (WP-7 Ф224):
#   1. pre-commit-secret-scan.sh finds its pattern library in the directory above
#      the repo, with neither IWE_ROOT exported nor the workspace at $HOME/IWE;
#   2. update.sh compares memory paths without case on Windows (drive letter),
#      exactly elsewhere;
#   3. memory backups: runs older than the keep window go, the newest three stay,
#      foreign names are never touched;
#   4. the urgent security notification carries the push's commit count, not "1".
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
pass() { echo "  ✅ PASS: $*"; }
fail_test() { echo "  ❌ FAIL: $*" >&2; fail=1; }

# --- 1. library lookup through the parent directory -------------------------
WS="$TMP/ws"
mkdir -p "$WS/.claude/hooks" "$WS/FMT/scripts" "$TMP/home"
cp "$ROOT/.claude/hooks/secret-bypass-lib.sh" "$WS/.claude/hooks/"
cp "$ROOT/.claude/hooks/secret-bypass-analyzer.py" "$WS/.claude/hooks/" 2>/dev/null || true
cp "$ROOT/scripts/pre-commit-secret-scan.sh" "$WS/FMT/scripts/"
git -C "$WS/FMT" init -q
out=$(cd "$WS/FMT" && env -u IWE_ROOT HOME="$TMP/home" bash scripts/pre-commit-secret-scan.sh 2>&1); rc=$?
if printf '%s' "$out" | grep -q 'canonical pattern library is missing'; then
    fail_test "library not found next to the repo (rc=$rc): $out"
else
    pass "library is found in the directory above the repo without IWE_ROOT"
fi

# --- 2. case-insensitive memory path comparison on Windows only -------------
fn=$(sed -n '/^memory_paths_equal() {/,/^}/p' "$ROOT/update.sh")
[ -n "$fn" ] || { fail_test "memory_paths_equal not found in update.sh"; exit 1; }
cmp_with() { OSTYPE="$1" bash -c "$fn"'
    memory_paths_equal "$2" "$3"; echo $?' _ "$1" "$2" "$3"; }
[ "$(cmp_with msys 'C:/Work/IWE/memory' 'c:/Work/IWE/memory')" = 0 ] \
    && pass "msys: drive letter case does not matter" || fail_test "msys: C: vs c: treated as different"
[ "$(cmp_with linux-gnu '/home/u/Memory' '/home/u/memory')" = 1 ] \
    && pass "linux: comparison stays exact" || fail_test "linux: case difference ignored"
[ "$(cmp_with linux-gnu '/home/u/memory' '/home/u/memory')" = 0 ] \
    && pass "identical paths are equal" || fail_test "identical paths differ"

# --- 3. memory backup pruning ----------------------------------------------
prune=$(sed -n '/^prune_memory_backups() {/,/^}/p' "$ROOT/update.sh")
[ -n "$prune" ] || { fail_test "prune_memory_backups not found in update.sh"; exit 1; }
WSB="$TMP/wsb"
B="$WSB/.backups/memory-pre-update"
mkdir -p "$B"
mk() { mkdir -p "$B/$1"; touch -t "$2" "$B/$1"; }
mk 20260101T000000Z-1 202601010000     # old
mk 20260102T000000Z-2 202601020000     # old
mk 20260103T000000Z-3 202601030000     # old
mk 20260104T000000Z-4 202601040000     # old, but one of the newest three after sorting
mk not-a-run-dir 202601050000          # foreign name, never touched
touch -t 202601010000 "$B/not-a-run-dir"
mk 20261012T080000Z-9 202610120800     # fresh
WORKSPACE_DIR="$WSB" bash -c "$prune"'
    prune_memory_backups' >/dev/null 2>&1
left=$(ls -1 "$B" | sort | tr '\n' ' ')
# newest three by mtime survive (fresh, not-a-run-dir is skipped by name but counts in order),
# the rest are older than 30 days and run-shaped, so they go.
if [ -d "$B/20261012T080000Z-9" ] && [ -d "$B/not-a-run-dir" ] && [ ! -d "$B/20260101T000000Z-1" ]; then
    pass "old run directories are removed, fresh and foreign ones stay ($left)"
else
    fail_test "unexpected content after prune: $left"
fi
# newest three are never removed even when old
mkdir -p "$TMP/wsc/.backups/memory-pre-update"
C="$TMP/wsc/.backups/memory-pre-update"
for i in 1 2 3; do mkdir -p "$C/2026010${i}T000000Z-$i"; touch -t "20260101000$i" "$C/2026010${i}T000000Z-$i" 2>/dev/null || touch -t 202601010000 "$C/2026010${i}T000000Z-$i"; done
WORKSPACE_DIR="$TMP/wsc" bash -c "$prune"'
    prune_memory_backups' >/dev/null 2>&1
[ "$(ls -1 "$C" | wc -l | tr -d ' ')" = 3 ] \
    && pass "the newest three runs are kept even when old" || fail_test "newest three were pruned: $(ls -1 "$C")"

# --- 4. security notification: real commit count ---------------------------
WF="$ROOT/.github/workflows/notify-security.yml"
if grep -q 'PUSH_COMMIT_COUNT: ${{ length(github.event.commits) }}' "$WF" \
   && ! grep -q -- '--arg commit_count "1"' "$WF"; then
    pass "notify-security passes the push commit count"
else
    fail_test "notify-security still hardcodes commit_count 1"
fi

exit $fail
