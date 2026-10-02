#!/usr/bin/env bash
# Issue #1003 regression:
#  (1) update.sh replaces a KNOWN earlier template copy of ds-publish.sh even when it lies
#      untracked in the governance repo; a foreign publisher is never touched;
#  (2) ds-publish.sh proves delivery by the tree: an equivalent patch that origin later
#      reverted must NOT read as "already published".
# Real git, local bare origin, no network. Bash 3.2 compatible.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
UPDATE_SH="$ROOT/update.sh"
PUB="$ROOT/seed/strategy/scripts/ds-publish.sh"
OLD="$ROOT/scripts/tests/fixtures/ds-publish-637a526.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

FAILS=0
ok()   { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
g()    { git -C "$1" "${@:2}"; }

echo "== (1) update path for a known earlier copy"
FUNCS="$TMP/funcs.sh"
for fn in hash_file agent_fault_git atomic_copy_executable backfill_governance_seed_script backfill_ds_publish; do
  awk -v sig="$fn() {" '$0 == sig {found=1} found {print} found && /^}$/ {exit}' "$UPDATE_SH" >> "$FUNCS"
  grep -q "^$fn() {" "$FUNCS" || { echo "FATAL: cannot extract $fn" >&2; exit 2; }
done
run_backfill() {
  OUT=$(SCRIPT_DIR="$ROOT" WORKSPACE_DIR="$1" EFFECTIVE_GOVERNANCE_REPO=DS-test \
        bash -c '. "$1"; backfill_ds_publish' _ "$FUNCS" 2>&1); RC=$?
}
new_gov() {
  WS="$TMP/$1"; mkdir -p "$WS/DS-test/scripts"
  g "$WS/DS-test" init -q 2>/dev/null
  g "$WS/DS-test" commit -q --allow-empty -m init
}
new_gov old
cp "$OLD" "$WS/DS-test/scripts/ds-publish.sh"          # untracked, like a real install
run_backfill "$WS"
if [ "$RC" -eq 0 ] && cmp -s "$PUB" "$WS/DS-test/scripts/ds-publish.sh" && [ -x "$WS/DS-test/scripts/ds-publish.sh" ]; then
  ok "untracked earlier template copy replaced by the current one (executable)"
else
  fail "earlier copy not replaced (rc=$RC): $OUT"
fi
new_gov foreign
printf '#!/bin/sh\n# my own publisher\n' > "$WS/DS-test/scripts/ds-publish.sh"
run_backfill "$WS"
if [ "$RC" -eq 0 ] && grep -q 'my own publisher' "$WS/DS-test/scripts/ds-publish.sh"; then
  ok "a foreign publisher is left alone"
else
  fail "foreign publisher touched (rc=$RC): $OUT"
fi

echo "== (2) a reverted equivalent patch is not 'already published'"
ORIGIN="$TMP/origin.git"; A="$TMP/a"; B="$TMP/b"
git init -q --bare -b main "$ORIGIN"
git clone -q "$ORIGIN" "$A" 2>/dev/null; g "$A" checkout -q -b main 2>/dev/null
printf 'base\n' > "$A/base.txt"; g "$A" add base.txt; g "$A" commit -q -m base; g "$A" push -q origin main 2>/dev/null
git clone -q "$ORIGIN" "$B" 2>/dev/null
# the commit to publish (local in A)
printf 'feature\n' > "$A/f.txt"; g "$A" add f.txt; g "$A" commit -q -m feature
SHA=$(g "$A" rev-parse HEAD)
# elsewhere, an equivalent patch lands on origin, then somebody reverts it
g "$B" cherry-pick "$SHA" >/dev/null 2>&1 || { g "$B" fetch -q "$A" main 2>/dev/null; g "$B" cherry-pick "$SHA" >/dev/null 2>&1; }
if [ ! -f "$B/f.txt" ]; then printf 'feature\n' > "$B/f.txt"; g "$B" add f.txt; g "$B" commit -q -m feature-equiv; fi
g "$B" revert --no-edit HEAD >/dev/null 2>&1
g "$B" push -q origin main 2>/dev/null
if git --git-dir="$ORIGIN" cat-file -e main:f.txt 2>/dev/null; then fail "fixture: f.txt still on origin"; fi
OUT=$(cd "$TMP" && bash "$PUB" "$A" normal --from-commit "$SHA" 2>&1); RC=$?
if [ "$RC" -eq 0 ] && git --git-dir="$ORIGIN" cat-file -e main:f.txt 2>/dev/null; then
  ok "the commit reached origin's tree after the revert"
else
  fail "false publish success (rc=$RC), f.txt not on origin: $OUT"
fi

echo "== (2b) a commit really present by tree (equivalent patch, no revert) stays a no-op"
printf 'g1\n' > "$A/g.txt"; g "$A" add g.txt; g "$A" commit -q -m g1
SHA2=$(g "$A" rev-parse HEAD)
g "$B" pull -q --rebase origin main >/dev/null 2>&1
printf 'g1\n' > "$B/g.txt"; g "$B" add g.txt; g "$B" commit -q -m g1-equiv; g "$B" push -q origin main 2>/dev/null
BEFORE=$(git --git-dir="$ORIGIN" rev-parse main)
OUT=$(cd "$TMP" && bash "$PUB" "$A" normal --from-commit "$SHA2" 2>&1); RC=$?
AFTER=$(git --git-dir="$ORIGIN" rev-parse main)
if [ "$RC" -eq 0 ] && [ "$BEFORE" = "$AFTER" ]; then ok "no extra commit pushed"; else fail "rc=$RC before=$BEFORE after=$AFTER: $OUT"; fi

echo
if [ "$FAILS" -eq 0 ]; then echo "PASS: #1003"; else echo "FAILED: $FAILS check(s)"; exit 1; fi
