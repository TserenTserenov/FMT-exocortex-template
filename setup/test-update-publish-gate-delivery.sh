#!/usr/bin/env bash
# Issue #1102: extractor.sh looks for scripts/lib/publish-gate.sh in the
# governance repo since WP-5 F48, but the template never shipped it -- every
# install silently fell back to a raw `git push` with no retry on a stale
# origin/main. update.sh now delivers it via the generic
# backfill_governance_seed_script() helper, same mechanism already proven for
# ds-publish.sh (test-update-ds-publish-delivery.sh covers the shared git-
# state edge cases -- symlink, case-alias, tracked-dirty -- for that helper;
# this test only proves THIS file is wired up and smoke-tests the plain
# absent/present cases). Temp-only, no network. Bash 3.2 compatible.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SELF_DIR")"
UPDATE_SH="$REPO_ROOT/update.sh"

FAILS=0
ok()   { echo "  ✅ PASS: $1"; }
fail() { echo "  ❌ FAIL: $1" >&2; FAILS=$((FAILS + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FUNCS="$TMP/funcs.sh"
for fn in agent_fault_git atomic_copy_executable backfill_governance_seed_script; do
  awk -v sig="$fn() {" '$0 == sig {found=1} found {print} found && /^}$/ {exit}' "$UPDATE_SH" >> "$FUNCS"
  grep -q "^$fn() {" "$FUNCS" || { echo "FATAL: cannot extract $fn" >&2; exit 2; }
done

SEED="$REPO_ROOT/seed/strategy/scripts/lib/publish-gate.sh"

# run_backfill WORKSPACE → RC, OUT
run_backfill() {
  OUT=$(SCRIPT_DIR="$REPO_ROOT" WORKSPACE_DIR="$1" EFFECTIVE_GOVERNANCE_REPO=DS-test \
        bash -c '. "$1"; backfill_governance_seed_script "scripts/lib/publish-gate.sh"' _ "$FUNCS" 2>&1); RC=$?
}
new_governance() {  # NAME → WS; a git repo with a tracked file, like a real governance repo
  WS="$TMP/$1"; mkdir -p "$WS/DS-test/scripts/lib"
  git -C "$WS/DS-test" init -q 2>/dev/null
  git -C "$WS/DS-test" -c user.name=t -c user.email=t@e.invalid commit -q --allow-empty -m init
}

echo "== the script is part of the delivered payload"
[ -f "$SEED" ] && [ -x "$SEED" ] && ok "seed/strategy/scripts/lib/publish-gate.sh exists and is executable" || fail "seed script missing or not executable"
grep -q '"path": "seed/strategy/scripts/lib/publish-gate.sh"' "$REPO_ROOT/update-manifest.json" \
  && ok "update-manifest.json lists it (with a checksum)" || fail "not in update-manifest.json"
grep -q 'backfill_governance_seed_script "scripts/lib/publish-gate.sh"' "$UPDATE_SH" \
  && ok "the upgrade chain calls backfill_governance_seed_script for it" || fail "update.sh never backfills publish-gate.sh"

echo "== absent → delivered, executable, identical to the seed"
new_governance a
run_backfill "$WS"
[ "$RC" -eq 0 ] && ok "exit 0" || fail "exit $RC: $OUT"
[ -x "$WS/DS-test/scripts/lib/publish-gate.sh" ] && cmp -s "$SEED" "$WS/DS-test/scripts/lib/publish-gate.sh" \
  && ok "delivered as an executable copy of the seed" || fail "not delivered: $OUT"

echo "== no governance repo → skipped without an error"
mkdir -p "$TMP/b"; run_backfill "$TMP/b"
[ "$RC" -eq 0 ] && ok "exit 0, nothing created" || fail "exit $RC: $OUT"
[ ! -e "$TMP/b/DS-test" ] && ok "no directory invented" || fail "created a governance directory"

echo
if [ "$FAILS" -eq 0 ]; then echo "PASS: publish-gate.sh delivery (#1102)"; else echo "FAILED: $FAILS check(s)"; exit 1; fi
