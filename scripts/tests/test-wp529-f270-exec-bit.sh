#!/usr/bin/env bash
# WP-529 Ф270, F1 of the v0.42.0-rc.3 red team: update.sh sets +x on a delivered file only when
# update_needs_exec_bit() says so. Its path patterns missed 54 programs that are 755 in git, so an
# upgrade from 0.41.11 left scripts/iwe-notify non-executable and every Telegram notification of
# the synchronizer and the strategist stopped (a fresh install had the bit). Contract: every
# manifest path that is 100755 in git and starts with `#!` gets +x on delivery. Drives the real
# function extracted from update.sh; the repository file stands in for the downloaded payload.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
UPDATE_SH="${UPDATE_SH:-$ROOT/update.sh}"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/iwe-f270-exec.XXXXXX")
trap 'rm -rf "${TMP:?}"' EXIT

awk '$0 == "update_needs_exec_bit() {" { found=1 } found { print } found && /^}$/ { exit }' \
  "$UPDATE_SH" > "$TMP/funcs.sh"
grep -q '^update_needs_exec_bit() {' "$TMP/funcs.sh" || { echo "FATAL: update_needs_exec_bit not found" >&2; exit 2; }
# shellcheck disable=SC1091
. "$TMP/funcs.sh"

python3 - "$ROOT" > "$TMP/exec-paths" <<'PY' || { echo "FATAL: cannot list manifest paths" >&2; exit 2; }
import json, subprocess, sys
root = sys.argv[1]
modes = {}
for line in subprocess.run(["git", "-C", root, "ls-files", "-s"], capture_output=True, text=True,
                           check=True).stdout.splitlines():
    meta, path = line.split("\t", 1)
    modes[path] = meta.split()[0]
with open(f"{root}/update-manifest.json", encoding="utf-8") as fh:
    paths = [entry["path"] for entry in json.load(fh)["files"]]
for path in paths:
    if modes.get(path) != "100755":
        continue
    with open(f"{root}/{path}", "rb") as fh:
        if fh.read(2) == b"#!":
            print(path)
PY

FAILS=0
TOTAL=0
while IFS= read -r rel; do
  TOTAL=$((TOTAL + 1))
  update_needs_exec_bit "$rel" "$ROOT/$rel" || { echo "  FAIL: $rel is 755 with #! but arrives without +x"; FAILS=$((FAILS + 1)); }
done < "$TMP/exec-paths"
[ "$TOTAL" -gt 100 ] || { echo "FATAL: only $TOTAL executable manifest paths found" >&2; exit 2; }
grep -qx 'scripts/iwe-notify' "$TMP/exec-paths" || { echo "  FAIL: scripts/iwe-notify is not in the checked set"; FAILS=$((FAILS + 1)); }

# WP-529 F275: update.sh runs top to bottom, so a call above the definition is 'command not
# found' (= false) and the unchanged-program +x repair silently never fires (rc.4/rc.5: NOEXEC 27).
DEF_LINE=$(grep -n '^update_needs_exec_bit() {' "$UPDATE_SH" | head -1 | cut -d: -f1)
FIRST_CALL=$(grep -n 'update_needs_exec_bit "' "$UPDATE_SH" | head -1 | cut -d: -f1)
if [ -z "$FIRST_CALL" ] || [ "$DEF_LINE" -ge "$FIRST_CALL" ]; then
  echo "  FAIL: update_needs_exec_bit is defined at line $DEF_LINE, first called at line ${FIRST_CALL:-none}"
  FAILS=$((FAILS + 1))
fi
# The pre-download filter must not skip an unchanged program that lacks +x.
grep -q 'if ! \$UPDATE_EXEC_REPAIR || \[ -x "\$SCRIPT_DIR/\$fpath" \] || ! update_needs_exec_bit "\$fpath" "\$SCRIPT_DIR/\$fpath"; then' "$UPDATE_SH" \
  || { echo "  FAIL: the download filter skips unchanged programs without checking +x"; FAILS=$((FAILS + 1)); }
# rc.6 red team F2: on Git Bash chmod is a no-op, so the repair must be off there (no endless re-delivery).
grep -E '^UPDATE_EXEC_REPAIR=|^case "\$\(uname -s 2>/dev/null\)" in MINGW\* \| MSYS\*\) UPDATE_EXEC_REPAIR=false' "$UPDATE_SH" > "$TMP/repair-switch.sh"
for os_name in Darwin Linux MINGW64_NT-10.0 MSYS_NT-10.0; do
  got=$(uname() { echo "$os_name"; }; . "$TMP/repair-switch.sh"; echo "${UPDATE_EXEC_REPAIR:-}")
  case "$os_name" in MINGW* | MSYS*) want=false ;; *) want=true ;; esac
  [ "$got" = "$want" ] || { echo "  FAIL: UPDATE_EXEC_REPAIR on $os_name is '$got', want $want"; FAILS=$((FAILS + 1)); }
done

# A plain document stays non-executable.
update_needs_exec_bit "README.md" "$ROOT/README.md" && { echo "  FAIL: README.md would get +x"; FAILS=$((FAILS + 1)); }
# No payload path: the path patterns alone decide, as before.
update_needs_exec_bit "scripts/iwe-notify" && { echo "  FAIL: without a payload a non-pattern path got +x"; FAILS=$((FAILS + 1)); }

if [ "$FAILS" -gt 0 ]; then
  echo "FAILED: $FAILS of $TOTAL"
  exit 1
fi
echo "PASS: $TOTAL executable manifest paths get +x on delivery"
