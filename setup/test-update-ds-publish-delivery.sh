#!/usr/bin/env bash
# Issue #941: update.sh delivers seed/strategy/scripts/ds-publish.sh into the governance
# repo, but only when the repo has no such file. Real functions extracted from update.sh.
# Temp-only, no network. Bash 3.2 compatible.
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
for fn in agent_fault_git atomic_copy_executable backfill_governance_seed_script backfill_ds_publish; do
  awk -v sig="$fn() {" '$0 == sig {found=1} found {print} found && /^}$/ {exit}' "$UPDATE_SH" >> "$FUNCS"
  grep -q "^$fn() {" "$FUNCS" || { echo "FATAL: cannot extract $fn" >&2; exit 2; }
done

SEED="$REPO_ROOT/seed/strategy/scripts/ds-publish.sh"

# run_backfill WORKSPACE → RC, OUT
run_backfill() {
  OUT=$(SCRIPT_DIR="$REPO_ROOT" WORKSPACE_DIR="$1" EFFECTIVE_GOVERNANCE_REPO=DS-test \
        bash -c '. "$1"; backfill_ds_publish' _ "$FUNCS" 2>&1); RC=$?
}
new_governance() {  # NAME → WS; a git repo with a tracked file, like a real governance repo
  WS="$TMP/$1"; mkdir -p "$WS/DS-test/scripts"
  git -C "$WS/DS-test" init -q 2>/dev/null
  git -C "$WS/DS-test" -c user.name=t -c user.email=t@e.invalid commit -q --allow-empty -m init
}

echo "== the script is part of the delivered payload"
[ -f "$SEED" ] && [ -x "$SEED" ] && ok "seed/strategy/scripts/ds-publish.sh exists and is executable" || fail "seed script missing or not executable"
grep -q '"path": "seed/strategy/scripts/ds-publish.sh"' "$REPO_ROOT/update-manifest.json" \
  && ok "update-manifest.json lists it (with a checksum)" || fail "not in update-manifest.json"
grep -q '^    backfill_ds_publish ||' "$UPDATE_SH" && ok "the upgrade chain calls backfill_ds_publish" || fail "update.sh never calls backfill_ds_publish"

echo "== absent → delivered, executable, identical to the seed"
new_governance a
run_backfill "$WS"
[ "$RC" -eq 0 ] && ok "exit 0" || fail "exit $RC: $OUT"
[ -x "$WS/DS-test/scripts/ds-publish.sh" ] && cmp -s "$SEED" "$WS/DS-test/scripts/ds-publish.sh" && ok "delivered as an executable copy of the seed" || fail "not delivered: $OUT"

echo "== an existing publisher is never replaced"
new_governance b
printf '#!/bin/sh\n# my own, much larger publisher\n' > "$WS/DS-test/scripts/ds-publish.sh"
git -C "$WS/DS-test" add scripts/ds-publish.sh; git -C "$WS/DS-test" -c user.name=t -c user.email=t@e.invalid commit -q -m own
run_backfill "$WS"
[ "$RC" -eq 0 ] && ok "exit 0" || fail "exit $RC"
grep -q "my own" "$WS/DS-test/scripts/ds-publish.sh" && ok "user's file untouched" || fail "user's publisher was overwritten"
case "$OUT" in *"не заменяю"*) ok "the output says it was left alone" ;; *) fail "no explanation: $OUT" ;; esac

echo "== a symlink at that path is left alone"
new_governance c
ln -s /nonexistent-target "$WS/DS-test/scripts/ds-publish.sh"
run_backfill "$WS"
[ "$RC" -eq 0 ] && [ -L "$WS/DS-test/scripts/ds-publish.sh" ] && [ ! -e "$TMP/c/DS-test/scripts/.iwe-update-copy" ] && ok "symlink kept" || fail "symlink handling (rc=$RC)"

echo "== no governance repo → skipped without an error"
mkdir -p "$TMP/d"; run_backfill "$TMP/d"
[ "$RC" -eq 0 ] && ok "exit 0, nothing created" || fail "exit $RC: $OUT"
[ ! -e "$TMP/d/DS-test" ] && ok "no directory invented" || fail "created a governance directory"

echo
if [ "$FAILS" -eq 0 ]; then echo "PASS: ds-publish delivery (#941)"; else echo "FAILED: $FAILS check(s)"; exit 1; fi
