#!/usr/bin/env bash
# Regression (WP-568 F11): extractor.sh must not resend a message that is
# byte-identical to the last one built for the same scenario. Live logs on the
# server showed 7-10 extractor messages a day, most of them the same
# "Захвачено кандидатов за сегодня: N" or the same "Кандидатов: X, Accept: Y"
# repeated by the next scheduler tick.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
TEMPLATE="$ROOT/roles/synchronizer/scripts/templates/extractor.sh"
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
export IWE_NOTIFY_STATE_DIR="$TMP/notify-state"
fails=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*" >&2; fails=$((fails + 1)); }

[ -f "$TEMPLATE" ] || { echo "template not found: $TEMPLATE" >&2; exit 1; }

DATE_NOW=$(date +%Y-%m-%d)
MONTH_NOW=$(date +%Y-%m)
CAPTURES="$TMP/DS-strategy/inbox/captures/$MONTH_NOW.md"
REPORTS="$TMP/DS-strategy/inbox/extraction-reports"
mkdir -p "$(dirname "$CAPTURES")" "$REPORTS"

build() {  # <scenario>
  bash -c '
    source "$1"
    IWE_WORKSPACE="$2"
    IWE_GOVERNANCE_REPO="DS-strategy"
    REPORTS_DIR="$2/DS-strategy/inbox/extraction-reports"
    build_message "$3"
  ' _ "$TEMPLATE" "$TMP" "$1" 2>/dev/null
}

echo "== 1 feed: first message with N=1 goes out"
printf '[feed:git-diff %s] first\n' "$DATE_NOW" > "$CAPTURES"
OUT=$(build git-diff-feed)
if echo "$OUT" | grep -qF "Захвачено кандидатов за сегодня: 1"; then pass "N=1 sent"; else fail "expected N=1 message, got: $OUT"; fi

echo "== 2 feed: next tick with the same N is silent"
OUT=$(build git-diff-feed)
if [ -z "$OUT" ]; then pass "same N not resent"; else fail "expected empty message, got: $OUT"; fi

echo "== 3 feed: N grows -> message goes out again"
printf '[feed:git-diff %s] second\n' "$DATE_NOW" >> "$CAPTURES"
OUT=$(build git-diff-feed)
if echo "$OUT" | grep -qF "Захвачено кандидатов за сегодня: 2"; then pass "N=2 sent"; else fail "expected N=2 message, got: $OUT"; fi

echo "== 4 feed: the record is per scenario, session-close-feed is unaffected"
printf '[feed:session-close %s] one\n' "$DATE_NOW" >> "$CAPTURES"
OUT=$(build session-close-feed)
if echo "$OUT" | grep -qF "Knowledge Feeder: session-close-feed"; then pass "other scenario sent"; else fail "expected session-close-feed message, got: $OUT"; fi

echo "== 5 feed: a new day with the same N goes out (the date is part of the text)"
printf '%s' "${OUT//$DATE_NOW/2000-01-01}" > "$IWE_NOTIFY_STATE_DIR/extractor-session-close-feed.last"
OUT=$(build session-close-feed)
if echo "$OUT" | grep -qF "Захвачено кандидатов за сегодня: 1"; then pass "yesterday's identical count does not silence today"; else fail "expected today's message, got: $OUT"; fi

echo "== 6 inbox-check: same X/Y in a newer report is silent, new numbers go out"
printf '## Кандидат 1\nВердикт: accept\n' > "$REPORTS/$DATE_NOW-a.md"
OUT1=$(build inbox-check)
sleep 1
printf '## Кандидат 1\nВердикт: accept\n' > "$REPORTS/$DATE_NOW-b.md"
OUT2=$(build inbox-check)
sleep 1
printf '## Кандидат 1\n## Кандидат 2\nВердикт: accept\n' > "$REPORTS/$DATE_NOW-c.md"
OUT3=$(build inbox-check)
if echo "$OUT1" | grep -qF "Кандидатов: 1, Accept: 1" && [ -z "$OUT2" ] && echo "$OUT3" | grep -qF "Кандидатов: 2, Accept: 1"; then
  pass "inbox-check: 1/1 sent, repeated 1/1 silent, 2/1 sent"
else
  fail "inbox-check sequence wrong: [$OUT1] [$OUT2] [$OUT3]"
fi

echo "== 7 state dir not writable -> message still goes out (fail open)"
OUT=$(IWE_NOTIFY_STATE_DIR=/proc/nonexistent/state bash -c '
  source "$1"
  IWE_WORKSPACE="$2"
  IWE_GOVERNANCE_REPO="DS-strategy"
  build_message git-diff-feed
' _ "$TEMPLATE" "$TMP" 2>/dev/null)
if echo "$OUT" | grep -qF "Захвачено кандидатов за сегодня: 2"; then pass "unrecordable state does not swallow the message"; else fail "expected message despite unwritable state, got: $OUT"; fi

echo
if [ "$fails" -eq 0 ]; then
  echo "ALL PASS"
  exit 0
else
  echo "$fails check(s) FAILED"
  exit 1
fi
