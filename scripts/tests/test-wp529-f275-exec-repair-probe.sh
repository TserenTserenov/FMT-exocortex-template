#!/usr/bin/env bash
# WP-529 F275, F7 of the v0.42.1-rc.8 red team: the unchanged-program +x repair of update.sh
# re-delivered the same programs on every run where `chmod +x` takes no effect — umask 177, 111
# or 133 (the planned mode has no x bit), a noexec mount, Cygwin. Contract: update.sh probes once
# whether +x takes effect in the installation and turns the repair off when it does not, and the
# skipped programs are named in one warning. Drives the real block extracted from update.sh in a
# scratch directory; nothing is updated.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
UPDATE_SH="${UPDATE_SH:-$ROOT/update.sh}"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/iwe-f275-exec-probe.XXXXXX")
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "${TMP:?}"' EXIT
FAILS=0
fail() { echo "  FAIL: $*"; FAILS=$((FAILS + 1)); }

awk '$0 == "UPDATE_EXEC_REPAIR=true" { found=1 } found { print } found && $0 == "EXEC_REPAIR_SKIPPED=()" { exit }' \
  "$UPDATE_SH" > "$TMP/block.sh"
grep -q '^EXEC_REPAIR_SKIPPED=()$' "$TMP/block.sh" || { echo "FAIL: the +x probe block is not found in update.sh"; exit 1; }

# probe UNAME UMASK CHECK_ONLY DIR -> prints "<UPDATE_EXEC_REPAIR> <UPDATE_EXEC_REPAIR_OFF_HERE>"
probe() {
  (
    _os=$1
    uname() { echo "$_os"; }
    umask "$2"
    # shellcheck disable=SC2034  # read by the sourced block
    CHECK_ONLY=$3
    # shellcheck disable=SC2034  # read by the sourced block
    SCRIPT_DIR=$4
    # shellcheck disable=SC1091
    . "$TMP/block.sh"
    echo "$UPDATE_EXEC_REPAIR $UPDATE_EXEC_REPAIR_OFF_HERE"
  )
}

mkdir -p "$TMP/ws"
[ "$(probe Darwin 022 false "$TMP/ws")" = "true false" ] || fail "umask 022: the repair must stay on"
[ "$(probe Linux 077 false "$TMP/ws")" = "true false" ] || fail "umask 077: the repair must stay on"
for um in 177 111 133; do
  [ "$(probe Linux "$um" false "$TMP/ws")" = "false true" ] || fail "umask $um: +x cannot take effect, the repair must be off"
  [ "$(probe Linux "$um" true "$TMP/ws")" = "false true" ] || fail "umask $um in --check: the repair must be off"
done
[ "$(probe CYGWIN_NT-10.0 022 false "$TMP/ws")" = "false false" ] || fail "Cygwin: chmod is a no-op, the repair must be off"
[ -z "$(ls -A "$TMP/ws")" ] || fail "the probe left a file in the installation: $(ls -A "$TMP/ws")"
[ "$(probe Linux 022 true "$TMP/ws")" = "true false" ] || fail "--check, umask 022: the repair must stay on"
# A directory where no probe file can be made (stands in for a mount where the bit does not stick).
if [ "$(id -u)" != 0 ]; then
  mkdir -p "$TMP/ro"; chmod 555 "$TMP/ro"
  [ "$(probe Linux 022 false "$TMP/ro")" = "false true" ] || fail "an unwritable installation: the repair must be off"
fi

# The download filter names the programs it leaves without +x, and update.sh warns once.
grep -q 'EXEC_REPAIR_SKIPPED+=("$fpath")' "$UPDATE_SH" || fail "the download filter does not collect the skipped programs"
grep -q 'if \[ ${#EXEC_REPAIR_SKIPPED\[@\]} -gt 0 \]; then' "$UPDATE_SH" || fail "no warning for the skipped programs"

if [ "$FAILS" -gt 0 ]; then
  echo "FAILED: $FAILS"
  exit 1
fi
echo "PASS: the +x repair is off where +x cannot take effect"
