#!/usr/bin/env bash
# shellcheck disable=SC2034  # the subshells set variables that the functions sourced from update.sh read
# WP-529 Ф270, F3 of the v0.42.0-rc.6 red team: a memory file edited right in the template clone
# was replaced by Step 5 and the edit was lost, while the line pointed at a backup that never
# held it. Contract: before Step 5, a clone memory file whose hash differs from the previous
# release's manifest is copied into .backups/memory-pre-update/<run>/template-clone/ and named;
# an unedited file is not copied; author_mode copies nothing. Drives the real functions extracted
# from update.sh.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
UPDATE_SH="${UPDATE_SH:-$ROOT/update.sh}"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/iwe-f270-clone-memory.XXXXXX")
trap 'rm -rf "${TMP:?}"' EXIT

FAILS=0
ok()   { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS + 1)); }

FUNCS="$TMP/funcs.sh"
for fn in hash_file manifest_sha256_of backup_clone_memory_edits_before_apply; do
  awk -v name="$fn() {" '$0 == name { found=1 } found { print } found && /^}$/ { exit }' "$UPDATE_SH" >> "$FUNCS"
  grep -q "^$fn() {" "$FUNCS" || { echo "FATAL: $fn not found in update.sh" >&2; exit 2; }
done

sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi; }

# setup_ws — a clone with two memory files: navigation.md edited after the release, protocol.md as shipped.
setup_ws() {
  rm -rf "$TMP/ws"
  mkdir -p "$TMP/ws/FMT-exocortex-template/memory"
  local clone="$TMP/ws/FMT-exocortex-template"
  printf 'released navigation\n' > "$clone/memory/navigation.md"
  printf 'released protocol\n' > "$clone/memory/protocol.md"
  python3 - "$clone" <<'PYEOF'
import hashlib, json, sys, pathlib
clone = pathlib.Path(sys.argv[1])
files = [{"path": f"memory/{n}", "sha256": hashlib.sha256((clone / "memory" / n).read_bytes()).hexdigest()}
         for n in ("navigation.md", "protocol.md")]
(clone / "update-manifest.json").write_text(json.dumps({"files": files}))
PYEOF
  printf 'released navigation\nSENTINEL-PILOT-EDIT\n' > "$clone/memory/navigation.md"
}

# run_backup AUTHOR(true|false) -> output; rc in $TMP/rc
run_backup() (
  # shellcheck disable=SC1090
  . "$FUNCS"
  PY_BIN=python3
  py_available() { [ -n "$PY_BIN" ]; }
  author="$1"
  is_author_mode() { [ "$author" = true ]; }
  SCRIPT_DIR="$TMP/ws/FMT-exocortex-template" WORKSPACE_DIR="$TMP/ws" MEMORY_BACKUP_RUN=""
  UPDATED_FILES=(memory/navigation.md memory/protocol.md CLAUDE.md)
  backup_clone_memory_edits_before_apply 2>&1
  echo "rc=$?" > "$TMP/rc"
)

echo "== an edit in the template clone is saved before Step 5 =="
setup_ws
out=$(run_backup false)
saved=$(find "$TMP/ws/.backups/memory-pre-update" -path '*/template-clone/navigation.md' 2>/dev/null | head -1)
[ -n "$saved" ] && grep -q SENTINEL-PILOT-EDIT "$saved" && ok "edited navigation.md saved with the edit" \
  || fail "edit not saved (out: $out)"
grep -qF "правка сохранена: $saved" <<<"$out" && ok "the line names the saved copy" || fail "line does not name the copy: $out"
[ -z "$(find "$TMP/ws/.backups" -name protocol.md 2>/dev/null)" ] && ok "unedited protocol.md not copied" \
  || fail "unedited file copied"
grep -q 'rc=0' "$TMP/rc" && ok "returns 0" || fail "rc: $(cat "$TMP/rc")"

echo "== author_mode copies nothing =="
setup_ws
out=$(run_backup true)
[ ! -d "$TMP/ws/.backups" ] && [ -z "$out" ] && ok "author_mode: no backup, no line" || fail "author_mode: $out"

echo "== the copy cannot be saved: the update does not start =="
setup_ws
mkdir -p "$TMP/ws/.backups"
printf 'not a directory\n' > "$TMP/ws/.backups/memory-pre-update"
out=$(run_backup false)
grep -q 'rc=1' "$TMP/rc" && grep -q 'обновление не начато' <<<"$out" && ok "refuses with rc=1 and says why" \
  || fail "no refusal: rc $(cat "$TMP/rc"), out: $out"

echo
if [ "$FAILS" -gt 0 ]; then
  echo "FAILED: $FAILS check(s)"
  exit 1
fi
echo "PASS"
