#!/usr/bin/env bash
# Issue #1401: the Day Close backup copies the memory the agents actually
# write — the workspace memory/ link, the same source the PostToolUse mirror
# hook uses — not a stale Claude project folder that only matches by slug.
# Runs the real day-close.sh step 1 (--exocortex-snapshot) on a throwaway
# workspace with a fake HOME.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
DAY_CLOSE="$ROOT/scripts/day-close.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PYTHONUSERBASE="${PYTHONUSERBASE:-$(python3 -m site --user-base 2>/dev/null || true)}"
export PYTHONUSERBASE

FAILS=0
ok()   { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS + 1)); }

WS="$TMP/IWE"
HOME_DIR="$TMP/home"
FRESH="$TMP/fresh-memory"
mkdir -p "$WS/DS-strategy" "$FRESH" "$HOME_DIR"
git -C "$WS/DS-strategy" init -q

SLUG=$(python3 -c 'import re,sys; print(re.sub("[^A-Za-z0-9]", "-", sys.argv[1]))' "$WS")
STALE="$HOME_DIR/.claude/projects/$SLUG/memory"
mkdir -p "$STALE"
printf 'version: old (13.04)\n' > "$STALE/r-questionnaire.md"
printf 'version: new\n' > "$FRESH/r-questionnaire.md"
ln -s "$FRESH" "$WS/memory"

snapshot() {  # snapshot <dir> [extra env...]
  local dir=$1; shift
  env -i PATH="$PATH" HOME="$HOME_DIR" PYTHONUSERBASE="$PYTHONUSERBASE" \
    WORKSPACE_DIR="$WS" IWE_WORKSPACE="$WS" IWE_GOVERNANCE_REPO=DS-strategy \
    IWE_DAY_CLOSE_LOG="$TMP/day-close.log" "$@" \
    bash "$DAY_CLOSE" --exocortex-snapshot "$dir" > "$TMP/out" 2>&1
}

echo "== link and slug folder disagree: the link wins, with a warning =="
snapshot "$TMP/snap1"
if grep -q 'version: new' "$TMP/snap1/r-questionnaire.md" 2>/dev/null; then
  ok "snapshot holds the fresh memory/ file"
else
  fail "snapshot does not hold the fresh file: $(cat "$TMP/snap1/r-questionnaire.md" 2>&1)"
  cat "$TMP/out"
fi
grep -q 'issue #1401' "$TMP/out" \
  && ok "disagreement is reported" || fail "no warning about the disagreement"

echo "== explicit IWE_MEMORY_SRC still overrides the link =="
snapshot "$TMP/snap2" IWE_MEMORY_SRC="$STALE"
grep -q 'version: old' "$TMP/snap2/r-questionnaire.md" 2>/dev/null \
  && ok "override respected" || fail "override ignored"

echo "== link and slug folder are the same directory: no warning =="
rm -rf "$STALE" && ln -s "$FRESH" "$STALE"
snapshot "$TMP/snap3"
grep -q 'issue #1401' "$TMP/out" && fail "spurious warning" || ok "no warning"
grep -q 'version: new' "$TMP/snap3/r-questionnaire.md" 2>/dev/null \
  && ok "fresh file copied" || fail "fresh file not copied"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "test_issue_1401_memory_source: all checks passed"
else
  echo "test_issue_1401_memory_source: $FAILS check(s) failed"
  exit 1
fi
