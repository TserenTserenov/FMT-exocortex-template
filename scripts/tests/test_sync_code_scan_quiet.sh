#!/usr/bin/env bash
# Regression: code-scan must stay silent when no repo had new commits --
# it used to always send "Репо с коммитами: 0 / Без изменений: N" even on
# a routine, nothing-happened run (same smell as the Knowledge Feeder fix,
# found in the same 09.10 pilot notification dump). A run that actually
# found something (found>0) keeps sending -- that's real information, not
# noise, and whether it should move to a digest is a separate decision.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
TEMPLATE="$ROOT/roles/synchronizer/scripts/templates/synchronizer.sh"
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
fails=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*" >&2; fails=$((fails + 1)); }

[ -f "$TEMPLATE" ] || { echo "template not found: $TEMPLATE" >&2; exit 1; }

DATE_NOW=$(date +%Y-%m-%d)
mkdir -p "$TMP/logs/synchronizer"
LOG="$TMP/logs/synchronizer/code-scan-$DATE_NOW.log"

echo "== 1 no FOUND lines (nothing changed) -> empty message"
{
  echo "=== Code Scan Started ==="
  echo "SKIP: repo-a (no changes)"
  echo "SKIP: repo-b (no changes)"
} > "$LOG"
OUT=$(bash -c '
  HOME="$2"
  source "$1"
  build_message "code-scan"
' _ "$TEMPLATE" "$TMP")
if [ -z "$OUT" ]; then pass "empty message when found=0"; else fail "expected empty message, got: $OUT"; fi

echo "== 2 at least one FOUND line -> non-empty message naming the repo"
{
  echo "=== Code Scan Started ==="
  echo "FOUND: repo-a"
  echo "SKIP: repo-b (no changes)"
} > "$LOG"
OUT=$(bash -c '
  HOME="$2"
  source "$1"
  build_message "code-scan"
' _ "$TEMPLATE" "$TMP")
if [ -z "$OUT" ]; then
  fail "expected a non-empty message when a repo had commits, got empty"
elif echo "$OUT" | grep -qF "Репо с коммитами: 1" && echo "$OUT" | grep -qF "repo-a"; then
  pass "non-empty message names the repo count and the repo"
else
  fail "message is non-empty but missing the count/repo: $OUT"
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "ALL PASS"
  exit 0
else
  echo "$fails check(s) FAILED"
  exit 1
fi
