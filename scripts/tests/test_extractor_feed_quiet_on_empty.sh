#!/usr/bin/env bash
# Regression: extractor.sh's git-diff-feed/session-close-feed scenario must
# stay silent (empty message, notify.sh skips sending) when there is nothing
# new to report -- it used to always send "Новых кандидатов нет.", which the
# pilot's live notification dump (09.10) caught sending twice 16 minutes
# apart with nothing changed in between. The inbox-check scenario right
# above it already does the right thing (empty report -> empty message);
# this locks the same behavior in for the feed scenarios.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
TEMPLATE="$ROOT/roles/synchronizer/scripts/templates/extractor.sh"
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
fails=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*" >&2; fails=$((fails + 1)); }

[ -f "$TEMPLATE" ] || { echo "template not found: $TEMPLATE" >&2; exit 1; }

DATE_NOW=$(date +%Y-%m-%d)
MONTH_NOW=$(date +%Y-%m)
mkdir -p "$TMP/DS-strategy/inbox/captures"

echo "== 1 nothing captured today -> empty message (notify.sh would skip)"
OUT=$(bash -c '
  source "$1"
  IWE_WORKSPACE="$2"
  IWE_GOVERNANCE_REPO="DS-strategy"
  build_message "git-diff-feed"
' _ "$TEMPLATE" "$TMP")
if [ -z "$OUT" ]; then pass "empty message when captures file is absent"; else fail "expected empty message, got: $OUT"; fi

echo "== 2 captures file exists but has no entry for today -> still empty"
printf '[feed:git-diff 2026-01-01] stale entry from another day\n' > "$TMP/DS-strategy/inbox/captures/$MONTH_NOW.md"
OUT=$(bash -c '
  source "$1"
  IWE_WORKSPACE="$2"
  IWE_GOVERNANCE_REPO="DS-strategy"
  build_message "git-diff-feed"
' _ "$TEMPLATE" "$TMP")
if [ -z "$OUT" ]; then pass "empty message when today has no captured entries"; else fail "expected empty message, got: $OUT"; fi

echo "== 3 something captured today -> non-empty message naming the count and file"
printf '[feed:git-diff %s] a real capture\n' "$DATE_NOW" >> "$TMP/DS-strategy/inbox/captures/$MONTH_NOW.md"
OUT=$(bash -c '
  source "$1"
  IWE_WORKSPACE="$2"
  IWE_GOVERNANCE_REPO="DS-strategy"
  build_message "git-diff-feed"
' _ "$TEMPLATE" "$TMP")
if [ -z "$OUT" ]; then
  fail "expected a non-empty message when something was captured today, got empty"
elif echo "$OUT" | grep -qF "Захвачено кандидатов за сегодня: 1" && echo "$OUT" | grep -qF "captures/$MONTH_NOW.md"; then
  pass "non-empty message names the count and the file"
else
  fail "message is non-empty but missing the count/file: $OUT"
fi

echo "== 4 session-close-feed does not pick up git-diff's marker (own feed marker, scoped correctly)"
OUT=$(bash -c '
  source "$1"
  IWE_WORKSPACE="$2"
  IWE_GOVERNANCE_REPO="DS-strategy"
  build_message "session-close-feed"
' _ "$TEMPLATE" "$TMP")
if [ -z "$OUT" ]; then
  pass "session-close-feed empty: today's captures file only has a feed:git-diff entry, not feed:session-close"
else
  fail "session-close-feed should not match git-diff's marker, got: $OUT"
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "ALL PASS"
  exit 0
else
  echo "$fails check(s) FAILED"
  exit 1
fi
