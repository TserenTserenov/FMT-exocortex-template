#!/usr/bin/env bash
# shellcheck disable=SC2034  # the subshells set variables that functions sourced from update.sh read
# WP-529 Ф270, F4 of the v0.42.0-rc.4 red team: a confirmed ROLLBACK 0.42 -> 0.41.11 left the 24
# files only 0.42 delivers and kept the candidate's update.sh until the next run. Contract: files
# of the installed manifest that the target manifest lacks are queued for the backup when still
# byte-identical to the installed manifest, kept when the user edited them, and pass the same
# guards as deprecated files; after the rollback the target release's update.sh is in place.
# Drives the real functions extracted from update.sh against a throwaway folder (no network).
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
UPDATE_SH="${UPDATE_SH:-$ROOT/update.sh}"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/iwe-f270-rollback-cleanup.XXXXXX")
trap 'rm -rf "${TMP:?}"' EXIT

FAILS=0
ok()   { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS + 1)); }

FUNCS="$TMP/funcs.sh"
for fn in queue_deprecated queue_rollback_leftovers replace_updater_after_rollback; do
  awk -v signature="$fn() {" '$0 == signature { found=1 } found { print } found && /^}$/ { exit }' \
    "$UPDATE_SH" >> "$FUNCS"
  grep -q "^$fn() {" "$FUNCS" || { echo "FATAL: $fn not found in update.sh" >&2; exit 2; }
done

# Installed 0.42: a.sh (untouched, 0.42 only), b.sh (edited by the user, 0.42 only),
# keep.sh (in both releases), sessions/own.md (protected user file, 0.42 only),
# tracked.sh (0.42 only, tracked by git of the template folder).
TPL="$TMP/tpl"
mkdir -p "$TPL/scripts" "$TPL/sessions"
for f in scripts/a.sh scripts/b.sh scripts/keep.sh sessions/own.md scripts/tracked.sh; do
  echo "0.42 $f" > "$TPL/$f"
done
python3 - "$TPL" <<'PY'
import hashlib, json, sys
root = sys.argv[1]
paths = ["scripts/a.sh", "scripts/b.sh", "scripts/keep.sh", "sessions/own.md", "scripts/tracked.sh"]
files = [{"path": p, "sha256": hashlib.sha256(open(f"{root}/{p}", "rb").read()).hexdigest()} for p in paths]
json.dump({"version": "0.42.0", "files": files}, open(f"{root}/update-manifest.json", "w"))
json.dump({"version": "0.41.11", "files": [{"path": "scripts/keep.sh", "sha256": "x"}]},
          open(f"{root}/../target-manifest.json", "w"))
PY
echo "user edit" >> "$TPL/scripts/b.sh"
git -C "$TPL" init -q
git -C "$TPL" add scripts/tracked.sh

out=$(
  # shellcheck disable=SC1090
  . "$FUNCS"
  SCRIPT_DIR="$TPL"
  MANIFEST="$TMP/target-manifest.json"
  UPSTREAM_VERSION=0.41.11
  PY_BIN=python3
  py_available() { return 0; }
  is_upstream_git_mirror() { return 1; }
  is_protected_user_file() { [ "${1#sessions/}" != "$1" ]; }
  is_fork_owned_path() { return 1; }
  DEPRECATED_FOUND=(); DEPRECATED_REASONS=(); DEPRECATED_TRACKED_KEPT=()
  queue_rollback_leftovers
  echo "FOUND=${DEPRECATED_FOUND[*]-}"
  echo "TRACKED=${DEPRECATED_TRACKED_KEPT[*]-}"
  echo "REASON=${DEPRECATED_REASONS[0]-}"
)

echo "== files only the newer installed release delivered =="
grep -qx 'FOUND=scripts/a.sh' <<<"$out" && ok "untouched 0.42-only file queued, nothing else" \
  || fail "queued set: $(grep '^FOUND=' <<<"$out")"
grep -q 'изменены вами — оставлены: scripts/b.sh' <<<"$out" && ok "edited 0.42-only file kept and named" \
  || fail "edited file not reported: $out"
grep -qx 'TRACKED=scripts/tracked.sh' <<<"$out" && ok "git-tracked file kept by the shared guard" \
  || fail "tracked file: $(grep '^TRACKED=' <<<"$out")"
grep -q 'REASON=.*откат' <<<"$out" && ok "reason names the rollback" || fail "reason: $(grep '^REASON=' <<<"$out")"
grep '^FOUND=' <<<"$out" | grep -q 'own.md' && fail "protected file queued" || ok "protected user file not queued"

echo "== updater after a confirmed rollback =="
echo '#!/bin/bash
echo candidate' > "$TPL/update.sh"
echo '#!/bin/bash
echo release-0.41.11' > "$TMP/older-update.sh"
run_replace() (
  # shellcheck disable=SC1090
  . "$FUNCS"
  SCRIPT_DIR="$TPL"; UPSTREAM_VERSION=0.41.11
  ROLLBACK_DETECTED="$1"; STEP0_OLDER_UPDATER="$2"
  replace_updater_after_rollback
)
run_replace false "$TMP/older-update.sh" >/dev/null
grep -q candidate "$TPL/update.sh" && ok "no rollback -> updater untouched" || fail "updater replaced without rollback"
msg=$(run_replace true "$TMP/older-update.sh")
grep -q 'release-0.41.11' "$TPL/update.sh" && [ -x "$TPL/update.sh" ] \
  && ok "rollback -> updater of 0.41.11 in place, executable" || fail "updater after rollback: $(cat "$TPL/update.sh")"
grep -q 'заменён версией выпуска v0.41.11' <<<"$msg" && ok "replacement reported" || fail "message: $msg"
[ -z "$(find "$TPL" -maxdepth 1 -name '.update.sh.staged.*')" ] && ok "no staged file left" || fail "staged file left"

echo
if [ "$FAILS" -gt 0 ]; then
  echo "FAILED: $FAILS check(s)"
  exit 1
fi
echo "PASS"
