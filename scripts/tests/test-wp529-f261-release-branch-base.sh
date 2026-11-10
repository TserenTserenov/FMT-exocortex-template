#!/usr/bin/env bash
# WP-529 Ф261: scripts/check-release-branch-base.sh passes only while the tip of main is part
# of the release branch history. Throwaway repos with a local bare "origin", no network.
set -uo pipefail
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/scripts/check-release-branch-base.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/iwe-f261-base.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()   { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS + 1)); }

git init -q --bare "$TMP/origin.git"
git init -q -b main "$TMP/work"
git -C "$TMP/work" remote add origin "$TMP/origin.git"
commit() { printf '%s\n' "$2" > "$TMP/work/$1"; git -C "$TMP/work" add "$1"; git -C "$TMP/work" commit -qm "$3"; }

commit a one "main 1"
git -C "$TMP/work" push -q origin main
git -C "$TMP/work" checkout -q -b release/v0.42.0
commit r release "release bump"
git -C "$TMP/work" push -q origin release/v0.42.0
git -C "$TMP/work" checkout -q main

run() { (cd "$TMP/work" && bash "$SCRIPT" "$@") >/dev/null 2>"$TMP/err"; echo $?; }

echo "== main did not move since the cut =="
[ "$(run 0.42.0)" = "0" ] && ok "main tip is the base of the branch -> exit 0" \
  || fail "main unchanged: expected 0"

echo "== main moved after the cut =="
commit b two "main 2"
git -C "$TMP/work" push -q origin main
rc=$(run 0.42.0)
[ "$rc" = "1" ] && ok "main moved -> exit 1" || fail "main moved: expected 1, got $rc"
grep -q "mode=next-rc" "$TMP/err" && ok "recovery names next-rc" || fail "recovery text must name next-rc"

echo "== main brought into the branch =="
git -C "$TMP/work" checkout -q release/v0.42.0
git -C "$TMP/work" merge -q --no-edit main
git -C "$TMP/work" push -q origin release/v0.42.0
[ "$(run 0.42.0)" = "0" ] && ok "branch contains the new main tip -> exit 0" \
  || fail "after merging main: expected 0"

echo "== --head pins the checkout to the remote tip =="
git -C "$TMP/work" checkout -q release/v0.42.0
(cd "$TMP/work" && bash "$SCRIPT" 0.42.0 origin --head) >/dev/null 2>&1 \
  && ok "HEAD is the remote tip -> exit 0" || fail "--head at the tip: expected 0"
commit r2 more "release fix"
(cd "$TMP/work" && bash "$SCRIPT" 0.42.0 origin --head) >/dev/null 2>"$TMP/err"
rc=$?
[ "$rc" -eq 1 ] && grep -q "is not the remote tip" "$TMP/err" \
  && ok "local HEAD ahead of the remote tip -> exit 1" || fail "--head with an unpushed commit: expected 1, got $rc"
git -C "$TMP/work" checkout -q main

echo "== bad input =="
[ "$(run abc)" = "1" ] && ok "non-numeric version -> exit 1" || fail "bad version: expected 1"
[ "$(run 9.9.9)" = "1" ] && ok "missing release branch -> exit 1" || fail "missing branch: expected 1"

echo
if [ "$FAILS" -gt 0 ]; then
  echo "FAILED: $FAILS check(s)"
  exit 1
fi
echo "PASS"
