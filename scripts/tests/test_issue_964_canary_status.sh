#!/usr/bin/env bash
# Regression for issue #964: the registry canary (`wp-sync-bundle.sh --self-test`, run by
# `update.sh --check`) took the FIRST inbox card in sort order and failed with exit 5 when
# that card's registry status was outside the platform vocabulary (a user's own "❄️ frozen"):
# a fact about the data, not proof that the reader is broken, yet it blocked the update.
# The canary now walks the cards in sort order and passes over ONLY a card whose registry row
# is found but whose status is outside the vocabulary. A card with no registry row (or any
# other "cannot resolve" answer) is NOT passed over: the search stops on it and the canary
# fails as before -- that is the signal "the registry is not read" (#954 A was caught exactly
# so) and #717/#718 depend on it. When every card has an unknown status the first one is
# refused. "↗️ merged" (the template legend) is recognised too. Frozen is NOT added to the
# platform vocabulary: that is the pilot's decision.
#
# Synthetic fixtures under a temporary HOME/TMPDIR; every failure is collected and reported.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/canary-964.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/tmp"
export HOME="$TMP/home" TMPDIR="$TMP/tmp"
unset IWE_ROOT IWE_WORKSPACE IWE_GOVERNANCE_REPO IWE_TEMPLATE IWE_SCRIPTS STRATEGY_DIR

GOV=DS-strategy
BUNDLE="$ROOT/.claude/scripts/wp-sync-bundle.sh"
PASSES=0
FAILS=0
ok()  { echo "  ✅ PASS: $*"; PASSES=$((PASSES + 1)); }
bad() { echo "  ❌ FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
expect_eq() {  # <description> <expected> <got>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2], got [$3]"; fi
}
expect_has() {  # <description> <needle> <haystack>
  case "$3" in *"$2"*) ok "$1" ;; *) bad "$1: [$2] not found in: $3" ;; esac
}
expect_lacks() {  # <description> <needle> <haystack>
  case "$3" in *"$2"*) bad "$1: unexpected [$2] in: $3" ;; *) ok "$1" ;; esac
}

new_ws() {  # a workspace with a governance skeleton; prints its path
  local d
  d=$(mktemp -d "$TMP/ws.XXXXXX")
  mkdir -p "$d/$GOV/docs" "$d/$GOV/inbox"
  printf '%s\n' "$d"
}

card() {  # <workspace> <number> [extra frontmatter lines] [body]
  local pad f
  pad=$(printf '%03d' "$2")
  f="$1/$GOV/inbox/WP-$pad/WP-$pad.md"
  mkdir -p "$(dirname "$f")"
  {
    printf -- '---\nwp: %s\nstatus: in_progress\ncreated: 2026-09-30\n' "$2"
    printf '%s' "${3:-}"
    printf -- '---\n%s\n' "${4:-# card}"
  } > "$f"
}

registry() {  # <workspace> <rows...> where a row is "<cell>|<status cell>"
  local ws="$1" row
  shift
  {
    printf '| # | Название | Статус |\n|---|----------|--------|\n'
    for row in "$@"; do printf '| %s | Demo | %s |\n' "${row%%|*}" "${row#*|}"; done
  } > "$ws/$GOV/docs/WP-REGISTRY.md"
}

selftest() {  # <workspace> [args...]: prints stdout+stderr, returns the exit code
  local ws="$1"
  shift
  IWE_WORKSPACE="$ws" IWE_GOVERNANCE_REPO="$GOV" bash "$BUNDLE" --self-test "$@" 2>&1
}

echo "--- (1) a status outside the vocabulary on the first card does not block the canary ---"
WS=$(new_ws)
registry "$WS" "13|❄️ frozen" "44|🔄 in_progress"
card "$WS" 13
card "$WS" 44
out=$(selftest "$WS"); rc=$?
expect_eq "WP-13 (❄️) first by sort, WP-44 in progress: exit code" 0 "$rc"
expect_has "the canary checked the recognised card" "WP-044 registry_status: 🔄 in_progress" "$out"
expect_lacks "no failure message" "Canary FAILED" "$out"
expect_has "the skipped card is named on stdout" "WP-013 _статус неизвестен_" "$(printf '%s\n' "$out" | grep 'пропущ')"

out=$(selftest "$WS" 13); rc=$?
expect_eq "an explicitly requested WP is still checked strictly (❄️ -> exit 1)" 1 "$rc"
expect_has "the explicit request names the unresolved status" "Canary FAILED: registry status unresolved for WP-13" "$out"

echo "--- (1b) several cards with an unknown status in a row are all passed over ---"
WS=$(new_ws)
registry "$WS" "13|❄️ frozen" "20|🧊 on ice" "44|🔄 in_progress"
card "$WS" 13
card "$WS" 20
card "$WS" 44
out=$(selftest "$WS"); rc=$?
expect_eq "two unknown-status cards first, a working WP third: exit code" 0 "$rc"
expect_has "the third card is the one checked" "WP-044 registry_status: 🔄 in_progress" "$out"
expect_has "both skipped cards are reported" "WP-013 _статус неизвестен_, WP-020 _статус неизвестен_" "$out"

echo "--- (1c) a card with NO registry row is not passed over: the canary fails on it, as before ---"
WS=$(new_ws)
registry "$WS" "44|🔄 in_progress"
card "$WS" 13
card "$WS" 44
out=$(selftest "$WS"); rc=$?
expect_eq "first card has no registry row, a working WP follows: exit code" 1 "$rc"
expect_has "the failure names the card that is missing from the registry" "Canary FAILED: registry status unresolved for WP-013: _не в реестре_" "$out"
expect_lacks "the working card behind it is not what gets checked" "WP-044 registry_status" "$out"

WS=$(new_ws)
registry "$WS" "13|❄️ frozen" "44|🔄 in_progress"
card "$WS" 13
card "$WS" 20
card "$WS" 44
out=$(selftest "$WS"); rc=$?
expect_eq "❄️ first, then a card with no registry row, then a working WP: exit code" 1 "$rc"
expect_has "the search stops on the card with no registry row" "Canary FAILED: registry status unresolved for WP-020: _не в реестре_" "$out"
expect_has "the ❄️ card passed over before it is still reported" "WP-013 _статус неизвестен_" "$out"
expect_lacks "the working card behind the stop is not what gets checked" "WP-044 registry_status" "$out"

echo "--- (2) when no card has a recognised status the canary still refuses ---"
WS=$(new_ws)
registry "$WS" "13|❄️ frozen" "44|🧊 on ice"
card "$WS" 13
card "$WS" 44
out=$(selftest "$WS"); rc=$?
expect_eq "every card with an unknown status: exit code" 1 "$rc"
expect_has "the refusal names the first card and its status" "Canary FAILED: registry status unresolved for WP-013: _статус неизвестен_" "$out"

WS=$(new_ws)
registry "$WS" "13|❄️ frozen" "20|🧊 on ice" "44|💤 sleeping"
card "$WS" 13
card "$WS" 20
card "$WS" 44
out=$(selftest "$WS"); rc=$?
expect_eq "three cards, all with an unknown status: exit code" 1 "$rc"
expect_has "the refusal is on the first card" "Canary FAILED: registry status unresolved for WP-013: _статус неизвестен_" "$out"
expect_lacks "nothing was recognised, so no card is announced as skipped" "пропущ" "$out"

WS=$(new_ws)
registry "$WS" "99|🔄 in_progress"
card "$WS" 44
out=$(selftest "$WS"); rc=$?
expect_eq "the only card has no registry row: exit code" 1 "$rc"
expect_has "the refusal says why" "_не в реестре_" "$out"

WS=$(new_ws)
printf '# no table here\n' > "$WS/$GOV/docs/WP-REGISTRY.md"
card "$WS" 44
out=$(selftest "$WS"); rc=$?
expect_eq "an unreadable registry (no header): exit code" 1 "$rc"
expect_has "the refusal says the status column is missing" "Canary FAILED" "$out"

echo "--- (3) the merged marker is recognised ---"
WS=$(new_ws)
registry "$WS" "50|↗️"
card "$WS" 50
out=$(selftest "$WS"); rc=$?
expect_eq "a card whose registry status is ↗️: exit code" 0 "$rc"
expect_has "↗️ is reported as merged" "WP-050 registry_status: ↗️ merged" "$out"

WS=$(new_ws)
printf '| # | Название | Статус |\n|---|----------|--------|\n| ~~51~~ | ~~Demo~~ | ↗️ |\n' > "$WS/$GOV/docs/WP-REGISTRY.md"
card "$WS" 51
out=$(selftest "$WS"); rc=$?
expect_eq "a struck-through ↗️ row: exit code" 0 "$rc"
expect_has "a struck-through ↗️ row is reported as merged, not as a bare strikethrough" "WP-051 registry_status: ↗️ merged" "$out"

echo "--- (3b) merged related WPs still count as closed for drift detection ---"
for cell in "~~61~~" "61"; do
  WS=$(new_ws)
  registry "$WS" "60|🔄 in_progress" "$cell|↗️"
  card "$WS" 60 $'related: [WP-61]\n' '- [ ] wait for WP-61 to land'
  card "$WS" 61
  out=$(IWE_WORKSPACE="$WS" IWE_GOVERNANCE_REPO="$GOV" bash "$BUNDLE" WP-60 2>&1); rc=$?
  expect_eq "bundle WP-60 (related WP-61 row '$cell' ↗️): exit code" 0 "$rc"
  expect_has "a merged related WP is reported as closed (row '$cell')" "DRIFT: WP-61 закрыт" "$out"
done

echo
if [ "$FAILS" -eq 0 ]; then
  echo "✅ test_issue_964_canary_status: $PASSES checks passed"
  exit 0
fi
echo "❌ test_issue_964_canary_status: $FAILS failed, $PASSES passed" >&2
exit 1
