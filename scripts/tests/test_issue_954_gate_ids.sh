#!/usr/bin/env bash
# Regression for issue #954 (session-guard half): the WP-518 hypothesis gate looked the card
# up by the id exactly as typed (inbox/<id>/<id>.md), so `open --wp 44`, `--wp 044` and
# `--wp WP-44` walked past it and opened a session on a card still marked
# `hypothesis_relation: unclassified`; only the one spelling that happens to equal the folder
# name (`WP-044`) was blocked. The card must be found by the NORMALISED number, whatever form
# the caller typed. Every blocking check also demands the gate's own message, so a session
# that fails for some other reason cannot pass for a blocked one.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/gate-ids-954.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/tmp"
export HOME="$TMP/home" TMPDIR="$TMP/tmp"
unset IWE_ROOT IWE_WORKSPACE IWE_GOVERNANCE_REPO IWE_TEMPLATE IWE_SCRIPTS IWE_SESSIONS_ROOT

GUARD="$ROOT/scripts/session-guard.sh"
GOV=DS-strategy
PASSES=0
FAILS=0
ok()  { echo "  ✅ PASS: $*"; PASSES=$((PASSES + 1)); }
bad() { echo "  ❌ FAIL: $*" >&2; FAILS=$((FAILS + 1)); }

new_ws() {  # a workspace whose governance repo is a git repository; prints its path
  local d
  d=$(mktemp -d "$TMP/ws.XXXXXX")
  mkdir -p "$d/$GOV/inbox"
  git -C "$d/$GOV" init -q
  git -C "$d/$GOV" config user.name "Gate Test"
  git -C "$d/$GOV" config user.email "gate-test@example.invalid"
  printf '%s\n' "$d"
}

open_session() {  # <workspace> <wp as typed>; prints stdout+stderr, returns the exit code
  IWE_ROOT="$1" IWE_GOVERNANCE_REPO="$GOV" bash "$GUARD" open --wp "$2" --agent kimi \
    --slug gate-ids --session-id gate-ids --owner-pid "$$" --close-path peer-session 2>&1
}

check_forms() {  # <card path under inbox> <relation> <expect: blocked|open> <forms...>
  local card="$1" relation="$2" expect="$3" form ws out rc
  shift 3
  for form in "$@"; do
    ws=$(new_ws)
    mkdir -p "$(dirname "$ws/$GOV/inbox/$card")"
    printf -- '---\nwp: 44\nhypothesis_relation: "%s"\n---\n# card\n' "$relation" > "$ws/$GOV/inbox/$card"
    out=$(open_session "$ws" "$form"); rc=$?
    if [ "$expect" = blocked ]; then
      if [ "$rc" -ne 0 ] && [[ "$out" == *"не классифицирована по гипотезе"* ]]; then
        ok "--wp $form on $card (unclassified): blocked by the gate"
      else
        bad "--wp $form on $card (unclassified) must be blocked by the gate (rc=$rc): $out"
      fi
    else
      if [ "$rc" -eq 0 ] && [ -f "$ws/.iwe-runtime/sessions/kimi-gate-ids.open" ]; then
        ok "--wp $form on $card ($relation): opens"
      else
        bad "--wp $form on $card ($relation) must open (rc=$rc): $out"
      fi
    fi
  done
}

echo "--- unclassified card in the canonical padded folder: every spelling is blocked ---"
check_forms "WP-044/WP-044.md" unclassified blocked WP-044 44 044 WP-44 wp-044

echo "--- unclassified card in an older unpadded folder: every spelling is blocked ---"
check_forms "WP-45/WP-45.md" unclassified blocked WP-45 45 045 WP-045

echo "--- unclassified flat legacy card: every spelling is blocked ---"
check_forms "WP-046.md" unclassified blocked WP-046 46 046 WP-46

echo "--- the same cards once classified: every spelling opens (the block is not a side effect of the form) ---"
check_forms "WP-044/WP-044.md" tests open WP-044 44 044 WP-44
check_forms "WP-45/WP-45.md" operational open 45 045

echo "--- an id that is not a number keeps the old exact-id lookup ---"
ws=$(new_ws)
mkdir -p "$ws/$GOV/inbox/WP-X"
printf -- '---\nhypothesis_relation: "unclassified"\n---\n' > "$ws/$GOV/inbox/WP-X/WP-X.md"
out=$(open_session "$ws" WP-X); rc=$?
if [ "$rc" -ne 0 ] && [[ "$out" == *"не классифицирована по гипотезе"* ]]; then
  ok "--wp WP-X: still blocked by the exact-id lookup"
else
  bad "--wp WP-X must still be blocked (rc=$rc): $out"
fi

echo
if [ "$FAILS" -eq 0 ]; then
  echo "✅ test_issue_954_gate_ids: $PASSES checks passed"
  exit 0
fi
echo "❌ test_issue_954_gate_ids: $FAILS failed, $PASSES passed" >&2
exit 1
