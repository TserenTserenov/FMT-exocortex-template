#!/usr/bin/env bash
# WP-529 Ф261, Ф268: scripts/check-release-branch-base.sh. Since Ф268 (release from the release
# branch) a main that moved after the cut is reported, not refused; the branch must still be cut
# from main, contain the previous release tag, and (--head) be checked out at its remote tip.
# Throwaway repos with a local bare "origin", no network.
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
git -C "$TMP/work" tag -a v0.41.0 -m "Release v0.41.0"
git -C "$TMP/work" push -q origin main v0.41.0
git -C "$TMP/work" checkout -q -b release/v0.42.0
commit r release "release bump"
git -C "$TMP/work" push -q origin release/v0.42.0
git -C "$TMP/work" checkout -q main

run() { (cd "$TMP/work" && bash "$SCRIPT" "$@") >/dev/null 2>"$TMP/err"; echo $?; }

echo "== main did not move since the cut =="
[ "$(run 0.42.0)" = "0" ] && ok "main tip is the base of the branch -> exit 0" \
  || fail "main unchanged: expected 0"
grep -q "contains the previous release\|contains v0.41.0" "$TMP/err" && ok "names the previous release it contains" \
  || fail "success text must name v0.41.0"

echo "== main moved after the cut (Ф268: not a refusal any more) =="
commit b two "main 2"
git -C "$TMP/work" push -q origin main
rc=$(run 0.42.0)
[ "$rc" = "0" ] && ok "main moved -> exit 0" || fail "main moved: expected 0, got $rc"
grep -q "main moved after the cut" "$TMP/err" && ok "moved main is reported" || fail "moved main must be reported"

echo "== --head pins the checkout to the remote tip =="
git -C "$TMP/work" checkout -q release/v0.42.0
(cd "$TMP/work" && bash "$SCRIPT" 0.42.0 origin --head) >/dev/null 2>&1 \
  && ok "HEAD is the remote tip -> exit 0" || fail "--head at the tip: expected 0"
commit r2 more "release fix"
(cd "$TMP/work" && bash "$SCRIPT" 0.42.0 origin --head) >/dev/null 2>"$TMP/err"
rc=$?
[ "$rc" -eq 1 ] && grep -q "is not the remote tip" "$TMP/err" \
  && ok "local HEAD ahead of the remote tip -> exit 1" || fail "--head with an unpushed commit: expected 1, got $rc"
git -C "$TMP/work" reset -q --hard HEAD~1
git -C "$TMP/work" checkout -q main

echo "== branch cut before the previous release came back to main =="
# v0.42.0 is released on its branch (tag on the branch, not yet in main); a branch for 0.42.1 cut
# from main now does not contain v0.42.0.
git -C "$TMP/work" tag -a v0.42.0 -m "Release v0.42.0" release/v0.42.0
git -C "$TMP/work" push -q origin v0.42.0
git -C "$TMP/work" checkout -q -b release/v0.42.1 main
commit r3 next "next release bump"
git -C "$TMP/work" push -q origin release/v0.42.1
rc=$(run 0.42.1)
[ "$rc" = "1" ] && grep -q "does not contain the previous release v0.42.0" "$TMP/err" \
  && ok "previous release tag missing from the branch -> exit 1" || fail "stale cut: expected 1, got $rc"
echo "== previous release merged back and brought into the branch =="
git -C "$TMP/work" checkout -q main
git -C "$TMP/work" merge -q --no-edit release/v0.42.0
git -C "$TMP/work" push -q origin main
git -C "$TMP/work" checkout -q release/v0.42.1
git -C "$TMP/work" merge -q --no-edit main
git -C "$TMP/work" push -q origin release/v0.42.1
git -C "$TMP/work" checkout -q main
[ "$(run 0.42.1)" = "0" ] && ok "branch contains v0.42.0 after the back-merge -> exit 0" \
  || fail "after the back-merge: expected 0"

echo "== branch not cut from main =="
git -C "$TMP/work" checkout -q --orphan release/v0.43.0
git -C "$TMP/work" rm -rqf . >/dev/null
commit o orphan "unrelated history"
git -C "$TMP/work" push -q origin release/v0.43.0
git -C "$TMP/work" checkout -q main
rc=$(run 0.43.0)
[ "$rc" = "1" ] && grep -q "shares no history with main" "$TMP/err" \
  && ok "unrelated branch -> exit 1" || fail "unrelated branch: expected 1, got $rc"

echo "== bad input =="
[ "$(run abc)" = "1" ] && ok "non-numeric version -> exit 1" || fail "bad version: expected 1"
[ "$(run 9.9.9)" = "1" ] && ok "missing release branch -> exit 1" || fail "missing branch: expected 1"

echo
if [ "$FAILS" -gt 0 ]; then
  echo "FAILED: $FAILS check(s)"
  exit 1
fi
echo "PASS"
