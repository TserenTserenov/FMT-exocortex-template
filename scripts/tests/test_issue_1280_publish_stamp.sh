#!/usr/bin/env bash
# Issue #1280: backfill_ds_publish decides by the "# ds-publish version: N" stamp,
# not by a hand-maintained list of known hashes.
#   no stamp + hash of a pre-stamp template copy → replaced, backup kept
#   no stamp + unknown hash                       → kept, loud warning
#   lower stamp                                   → replaced, backup kept
#   equal stamp, different content                → kept (deliberate local edit)
#   higher stamp                                  → kept
#   malformed stamp ("1a")                        → treated as no stamp
# backfill_ds_publish and its helpers are extracted from update.sh (same
# approach as test_issue_1003_ds_publish.sh). Bash 3.2 compatible.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
UPDATE_SH="${UPDATE_SH:-$ROOT/update.sh}"
PUB="$ROOT/seed/strategy/scripts/ds-publish.sh"
OLD="$ROOT/scripts/tests/fixtures/ds-publish-637a526.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

FAILS=0
ok()   { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*" >&2; FAILS=$((FAILS + 1)); }

SHIPPED=$(grep -m1 '^# ds-publish version:' "$PUB" | sed 's/^# ds-publish version: //')
case "$SHIPPED" in
  ""|*[!0-9]*) echo "FATAL: shipped seed has no well-formed version stamp: '$SHIPPED'" >&2; exit 2 ;;
esac

FUNCS="$TMP/funcs.sh"
for fn in hash_file agent_fault_git atomic_copy_executable backfill_governance_seed_script \
          ds_publish_version replace_ds_publish_with_backup backfill_ds_publish; do
  awk -v sig="$fn() {" '$0 == sig {found=1} found {print} found && /^}$/ {exit}' "$UPDATE_SH" >> "$FUNCS"
  grep -q "^$fn() {" "$FUNCS" || { echo "FATAL: cannot extract $fn" >&2; exit 2; }
done

# new_case NAME — a workspace with an initialised governance repo; sets WS/TARGET.
new_case() {
  WS="$TMP/$1"; TARGET="$WS/DS-test/scripts/ds-publish.sh"
  mkdir -p "$WS/DS-test/scripts"
  git -C "$WS/DS-test" init -q 2>/dev/null
}
run_backfill() {
  OUT=$(SCRIPT_DIR="$ROOT" WORKSPACE_DIR="$WS" EFFECTIVE_GOVERNANCE_REPO=DS-test \
        bash -c '. "$1"; backfill_ds_publish' _ "$FUNCS" 2>&1); RC=$?
}
# stamped COPY_OF_SEED VERSION — the shipped seed with its stamp line set to VERSION
# plus a marker line, so "content differs from the shipped copy" is guaranteed.
stamped() {
  sed "s/^# ds-publish version: .*/# ds-publish version: $1/" "$PUB"
  printf '# local edit marker\n'
}
backup_of() { find "$WS/.backups/ds-publish-pre-update" -type f -name ds-publish.sh 2>/dev/null | head -1; }

echo "== no stamp + hash of a pre-stamp template copy → replaced with backup"
new_case known
cp "$OLD" "$TARGET"
run_backfill
BK=$(backup_of)
if [ "$RC" -eq 0 ] && cmp -s "$PUB" "$TARGET" && [ -x "$TARGET" ] && [ -n "$BK" ] && cmp -s "$OLD" "$BK"; then
  ok "replaced by the shipped copy, old one saved in $BK"
else
  fail "known old copy (rc=$RC, backup='$BK'): $OUT"
fi

echo "== the last pre-stamp shipped copy (97a65121, 15.10) is recognised too"
# Without its hash on the frozen list every install current before the stamp
# would read as "user's own publisher" and never receive a stamped version.
if git -C "$ROOT" cat-file -e 97a65121:seed/strategy/scripts/ds-publish.sh 2>/dev/null; then
  new_case last_prestamp
  git -C "$ROOT" show 97a65121:seed/strategy/scripts/ds-publish.sh > "$TARGET"
  run_backfill
  if [ "$RC" -eq 0 ] && cmp -s "$PUB" "$TARGET" && [ -n "$(backup_of)" ]; then
    ok "last unstamped template copy replaced, backup kept"
  else
    fail "last unstamped template copy not replaced (rc=$RC): $OUT"
  fi
else
  echo "  SKIP: commit 97a65121 not in this clone (shallow checkout)"
fi

echo "== no stamp + unknown content → kept, loud warning"
new_case foreign
printf '#!/bin/sh\n# my own publisher\n' > "$TARGET"
cp "$TARGET" "$TMP/foreign.orig"
run_backfill
if [ "$RC" -eq 0 ] && cmp -s "$TMP/foreign.orig" "$TARGET" && [ -z "$(backup_of)" ] \
   && printf '%s' "$OUT" | grep -Fq 'ВНИМАНИЕ' && printf '%s' "$OUT" | grep -Fq "$TARGET" \
   && printf '%s' "$OUT" | grep -Fq "cp \"$ROOT/seed/strategy/scripts/ds-publish.sh\""; then
  ok "own publisher untouched; warning names the path and the manual accept command"
else
  fail "foreign copy (rc=$RC): $OUT"
fi

echo "== lower stamp → replaced with backup"
if [ "$SHIPPED" -gt 0 ]; then
  new_case lower
  stamped $((SHIPPED - 1)) > "$TARGET"
  cp "$TARGET" "$TMP/lower.orig"
  run_backfill
  BK=$(backup_of)
  if [ "$RC" -eq 0 ] && cmp -s "$PUB" "$TARGET" && [ -n "$BK" ] && cmp -s "$TMP/lower.orig" "$BK"; then
    ok "version $((SHIPPED - 1)) < $SHIPPED replaced, backup kept"
  else
    fail "lower stamp (rc=$RC): $OUT"
  fi
else
  fail "shipped stamp is 0: the lower-stamp case cannot be exercised"
fi

echo "== equal stamp, different content → kept"
new_case equal
stamped "$SHIPPED" > "$TARGET"
cp "$TARGET" "$TMP/equal.orig"
run_backfill
if [ "$RC" -eq 0 ] && cmp -s "$TMP/equal.orig" "$TARGET" && [ -z "$(backup_of)" ]; then
  ok "local edit with the same stamp left alone ($(printf '%s' "$OUT" | tail -1))"
else
  fail "equal stamp (rc=$RC): $OUT"
fi

echo "== higher stamp → kept"
new_case higher
stamped $((SHIPPED + 7)) > "$TARGET"
cp "$TARGET" "$TMP/higher.orig"
run_backfill
if [ "$RC" -eq 0 ] && cmp -s "$TMP/higher.orig" "$TARGET" && [ -z "$(backup_of)" ]; then
  ok "higher stamp left alone"
else
  fail "higher stamp (rc=$RC): $OUT"
fi

echo "== malformed stamp \"1a\" → treated as no stamp (unknown hash → kept with warning)"
new_case malformed
stamped "1a" > "$TARGET"
cp "$TARGET" "$TMP/malformed.orig"
run_backfill
if [ "$RC" -eq 0 ] && cmp -s "$TMP/malformed.orig" "$TARGET" && printf '%s' "$OUT" | grep -Fq 'ВНИМАНИЕ'; then
  ok "malformed stamp falls into the no-stamp branch"
else
  fail "malformed stamp (rc=$RC): $OUT"
fi
# A malformed FIRST stamp is not rescued by a later well-formed one.
new_case malformed2
{ stamped "1a"; printf '# ds-publish version: 0\n'; } > "$TARGET"
cp "$TARGET" "$TMP/malformed2.orig"
run_backfill
if [ "$RC" -eq 0 ] && cmp -s "$TMP/malformed2.orig" "$TARGET" && printf '%s' "$OUT" | grep -Fq 'ВНИМАНИЕ'; then
  ok "a later well-formed stamp does not override a malformed first one"
else
  fail "malformed first stamp rescued by a later one (rc=$RC): $OUT"
fi

echo
if [ "$FAILS" -eq 0 ]; then echo "PASS: #1280 ds-publish version stamp"; else echo "FAILED: $FAILS check(s)"; exit 1; fi
