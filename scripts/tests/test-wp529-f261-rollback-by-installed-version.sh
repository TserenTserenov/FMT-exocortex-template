#!/usr/bin/env bash
# WP-529 Ф261, finding 3 of the 10.11 pipeline review: update.sh never moves HEAD of the
# template folder, so a clone checked out at the old release (v0.41.11) can carry the files
# and the manifest of a newer one (0.42). detect_release_rollback() decided by ancestry only
# ("release == HEAD" -> no rollback) and the files were rewritten without ROLLBACK. The
# installed manifest version must decide first. Drives the real functions extracted from
# update.sh against throwaway git repos (no network).
set -uo pipefail
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
UPDATE_SH="$ROOT/update.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/iwe-f261-rollback.XXXXXX")
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

# The template history: the published release 0.41.11 is the tip.
REPO="$TMP/repo"
git init -q "$REPO"
set_manifest "$REPO" 0.41.11
git -C "$REPO" add update-manifest.json
git -C "$REPO" commit -qm "release 0.41.11"
RELEASE=$(git -C "$REPO" rev-parse HEAD)

echo "== folder at the release commit, manifest of a newer version =="
set_manifest "$REPO" 0.42.0
rc=$(rollback_rc "$REPO" "$RELEASE" 0.41.11)
[ "$rc" = "0" ] && ok "HEAD == release, installed 0.42.0 > release 0.41.11 -> rollback (0)" \
  || fail "HEAD == release, newer manifest: expected 0, got $rc"

echo "== folder at the release commit, manifest of the same version =="
set_manifest "$REPO" 0.41.11
rc=$(rollback_rc "$REPO" "$RELEASE" 0.41.11)
[ "$rc" = "1" ] && ok "equal versions, HEAD == release -> no rollback (1)" \
  || fail "equal versions: expected 1, got $rc"

echo "== release is newer than the installed manifest =="
set_manifest "$REPO" 0.41.10
rc=$(rollback_rc "$REPO" "$RELEASE" 0.41.11)
[ "$rc" = "1" ] && ok "installed 0.41.10 < release 0.41.11 -> no rollback (1)" \
  || fail "installed older: expected 1, got $rc"

echo "== local commits ahead of the release keep the ancestry signal (#863) =="
set_manifest "$REPO" 0.41.11
git -C "$REPO" add update-manifest.json
git -C "$REPO" commit -qm "local work" --allow-empty
rc=$(rollback_rc "$REPO" "$RELEASE" 0.41.11)
[ "$rc" = "0" ] && ok "equal versions, HEAD ahead of the release -> rollback (0)" \
  || fail "HEAD ahead: expected 0, got $rc"

echo "== unreadable installed version falls through to ancestry =="
set_manifest "$REPO" dev
git -C "$REPO" checkout -q "$RELEASE"
rc=$(rollback_rc "$REPO" "$RELEASE" 0.41.11)
[ "$rc" = "1" ] && ok "unreadable version, HEAD == release -> ancestry decides (1)" \
  || fail "unreadable version: expected 1, got $rc"

echo
if [ "$FAILS" -gt 0 ]; then
  echo "FAILED: $FAILS check(s)"
  exit 1
fi
echo "PASS"
