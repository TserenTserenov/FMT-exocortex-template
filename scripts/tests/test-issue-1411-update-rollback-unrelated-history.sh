#!/usr/bin/env bash
# Issue #1411 item 1: an install created with GitHub "Use this template" has an origin
# of its own that holds no template commit, so `git fetch origin <release_sha>` always
# fails and detect_release_rollback() returned "cannot determine" (2) -> update.sh --yes
# stopped on every run. Without the release commit the decision is made by manifest
# version: a strictly newer release is a normal update; equal/newer installs stay blocked.
# Drives the real functions extracted from update.sh against throwaway git repos (no network).
set -uo pipefail
# Clones below get no repo-level identity; CI runners have no global one.
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
UPDATE_SH="$ROOT/update.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/iwe-1411.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()   { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS + 1)); }

FUNCS="$TMP/funcs.sh"
extract_function() {
  awk -v signature="$1() {" '
    $0 == signature { found=1 }
    found { print }
    found && /^}$/ { exit }
  ' "$UPDATE_SH"
}
for fn in detect_release_rollback rollback_by_version rollback_without_release_commit \
          manifest_version version_compare; do
  extract_function "$fn" >> "$FUNCS"
  grep -q "^$fn() {" "$FUNCS" || { echo "FATAL: $fn not found in update.sh" >&2; exit 2; }
done

new_repo() {
  git init -q "$1"
  git -C "$1" config user.email test@example.com
  git -C "$1" config user.name test
}
commit_file() {  # REPO FILE CONTENT MESSAGE
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -qm "$4"
}
set_manifest() { printf '{"version": "%s", "files": []}\n' "$2" > "$1/update-manifest.json"; }

# rollback_rc INSTALL RELEASE_SHA UPSTREAM_VERSION -> prints detect_release_rollback's code
rollback_rc() {
  (
    # shellcheck disable=SC1090
    . "$FUNCS"
    UPDATE_CHANNEL=release
    SCRIPT_DIR="$1"
    RELEASE_SHA="$2"
    UPSTREAM_VERSION="$3"
    PY_BIN=""
    py_available() { return 1; }
    github_api_get() { return 1; }
    rc=0
    detect_release_rollback || rc=$?
    echo "$rc"
  ) 2>/dev/null
}

# The template: its release commit is never reachable from the template-made install.
TEMPLATE="$TMP/template"
new_repo "$TEMPLATE"
commit_file "$TEMPLATE" f "template" "template release"
TEMPLATE_RELEASE=$(git -C "$TEMPLATE" rev-parse HEAD)

# "Use this template": the user's own repo (its own root) as origin, cloned in full.
USER_ORIGIN_SRC="$TMP/user-src"
new_repo "$USER_ORIGIN_SRC"
commit_file "$USER_ORIGIN_SRC" f "user copy" "Initial commit"
git clone -q --bare "$USER_ORIGIN_SRC" "$TMP/user-origin.git"
INSTALL="$TMP/install"
git clone -q "file://$TMP/user-origin.git" "$INSTALL"

echo "== fixture =="
if git -C "$INSTALL" cat-file -e "$TEMPLATE_RELEASE" 2>/dev/null \
   || git -C "$INSTALL" fetch -q origin "$TEMPLATE_RELEASE" 2>/dev/null; then
  fail "fixture: release commit must be unreachable from the install"
else
  ok "release commit is neither local nor fetchable from origin"
fi

echo "== unrelated history (no template commits in origin) =="
set_manifest "$INSTALL" 0.38.2
rc=$(rollback_rc "$INSTALL" "$TEMPLATE_RELEASE" 0.41.10)
[ "$rc" = "1" ] && ok "installed 0.38.2 < release 0.41.10 -> no rollback (1), --yes proceeds" \
  || fail "installed older: expected 1, got $rc"

set_manifest "$INSTALL" 0.41.10
rc=$(rollback_rc "$INSTALL" "$TEMPLATE_RELEASE" 0.41.10)
[ "$rc" = "2" ] && ok "equal versions -> cannot determine (2), --yes blocked" \
  || fail "equal versions: expected 2, got $rc"

set_manifest "$INSTALL" 0.42.0
rc=$(rollback_rc "$INSTALL" "$TEMPLATE_RELEASE" 0.41.10)
[ "$rc" = "0" ] && ok "installed 0.42.0 > release 0.41.10 -> rollback (0), --yes blocked" \
  || fail "installed newer: expected 0, got $rc"

set_manifest "$INSTALL" dev
rc=$(rollback_rc "$INSTALL" "$TEMPLATE_RELEASE" 0.41.10)
[ "$rc" = "2" ] && ok "unreadable installed version -> cannot determine (2)" \
  || fail "unreadable version: expected 2, got $rc"

rm -f "$INSTALL/update-manifest.json"
rc=$(rollback_rc "$INSTALL" "$TEMPLATE_RELEASE" 0.41.10)
[ "$rc" = "2" ] && ok "no installed manifest -> cannot determine (2)" \
  || fail "no manifest: expected 2, got $rc"

SHALLOW="$TMP/install-shallow"
git clone -q --depth 1 "file://$TMP/user-origin.git" "$SHALLOW"
set_manifest "$SHALLOW" 0.38.2
rc=$(rollback_rc "$SHALLOW" "$TEMPLATE_RELEASE" 0.41.10)
[ "$rc" = "2" ] && ok "shallow clone, installed older -> cannot determine (2)" \
  || fail "shallow clone: expected 2, got $rc"

echo "== shared history (ancestry decides, versions ignored) =="
SHARED_SRC="$TMP/shared-src"
new_repo "$SHARED_SRC"
commit_file "$SHARED_SRC" f "v1" "release"
SHARED_RELEASE=$(git -C "$SHARED_SRC" rev-parse HEAD)
git clone -q --bare "$SHARED_SRC" "$TMP/shared-origin.git"
AHEAD="$TMP/install-ahead"
git clone -q "file://$TMP/shared-origin.git" "$AHEAD"
commit_file "$AHEAD" f "v2" "local ahead"
# A version saying "older" must not override ancestry that proves a rollback.
set_manifest "$AHEAD" 0.1.0
rc=$(rollback_rc "$AHEAD" "$SHARED_RELEASE" 9.9.9)
[ "$rc" = "0" ] && ok "local ahead of release -> rollback (0) despite older version" \
  || fail "shared, local ahead: expected 0, got $rc"

BEHIND="$TMP/install-behind"
git clone -q "file://$TMP/shared-origin.git" "$BEHIND"
commit_file "$SHARED_SRC" f "v3" "next release"
NEXT_RELEASE=$(git -C "$SHARED_SRC" rev-parse HEAD)
git -C "$SHARED_SRC" push -q "$TMP/shared-origin.git" HEAD:refs/heads/next 2>/dev/null \
  || git -C "$TMP/shared-origin.git" fetch -q "$SHARED_SRC" "HEAD:refs/heads/next"
# A version saying "newer" must not override ancestry that proves a normal update.
set_manifest "$BEHIND" 9.9.9
rc=$(rollback_rc "$BEHIND" "$NEXT_RELEASE" 0.1.0)
[ "$rc" = "1" ] && ok "release fetched from origin and ahead -> no rollback (1) despite newer version" \
  || fail "shared, release ahead: expected 1, got $rc"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "test-issue-1411-update-rollback-unrelated-history: all checks passed"
else
  echo "test-issue-1411-update-rollback-unrelated-history: $FAILS check(s) failed"
  exit 1
fi
