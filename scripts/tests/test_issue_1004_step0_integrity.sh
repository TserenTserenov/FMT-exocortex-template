#!/usr/bin/env bash
# Issue #1004, Step 0 integrity verdict on a downloaded update.sh (step0_integrity_check, extracted
# from update.sh): tag tolerance (CRLF, trailing blanks), minimum size for an untagged file, the
# tag staying inside the first 40 lines of the real update.sh.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
fails=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*" >&2; fails=$((fails + 1)); }

eval "$(grep -E '^UPDATE_SH_(INTEGRITY_TAG|END_MARKER|MIN_LINES)=' "$ROOT/update.sh")"
eval "$(awk '$0 == "step0_integrity_check() {" {c=1} c {print} c && /^}$/ {exit}' "$ROOT/update.sh")"
declare -F step0_integrity_check >/dev/null || { echo "FATAL: cannot extract step0_integrity_check" >&2; exit 2; }
verdict() { step0_integrity_check "$1" && echo accepted || echo refused; }

echo "== the tag sits in the first 40 lines of the real update.sh"
if head -n 40 "$ROOT/update.sh" | grep -qxF "$UPDATE_SH_INTEGRITY_TAG"; then pass "tag within 40 lines"; else fail "tag not in the first 40 lines of update.sh"; fi
[ "$(awk 'NF {l = $0} END {print l}' "$ROOT/update.sh")" = "$UPDATE_SH_END_MARKER" ] && pass "real update.sh ends with the marker" || fail "real update.sh does not end with the marker"
[ "$(verdict "$ROOT/update.sh")" = accepted ] && pass "the real update.sh is accepted" || fail "the real update.sh is refused"

echo "== CRLF and trailing blanks"
printf '#!/bin/bash\r\n%s\r\necho x\r\n%s\r\n' "$UPDATE_SH_INTEGRITY_TAG" "$UPDATE_SH_END_MARKER" > "$TMP/crlf.sh"
[ "$(verdict "$TMP/crlf.sh")" = accepted ] && pass "CRLF file with tag and marker is accepted" || fail "CRLF file refused"
printf '#!/bin/bash\n%s  \necho x\n%s \t\n\n' "$UPDATE_SH_INTEGRITY_TAG" "$UPDATE_SH_END_MARKER" > "$TMP/blank.sh"
[ "$(verdict "$TMP/blank.sh")" = accepted ] && pass "trailing blanks and blank last lines are tolerated" || fail "trailing blanks refused"
printf '#!/bin/bash\r\n%s\r\necho x\r\necho tail\r\n' "$UPDATE_SH_INTEGRITY_TAG" > "$TMP/crlf-cut.sh"
[ "$(verdict "$TMP/crlf-cut.sh")" = refused ] && pass "CRLF file without the closing marker is refused" || fail "CRLF cut file accepted"

echo "== untagged files (older releases): minimum size"
printf '#!/bin/bash\n# truncated\n# answer\n' > "$TMP/stub.sh"
[ "$(verdict "$TMP/stub.sh")" = refused ] && pass "3-line stub without the tag is refused" || fail "3-line stub accepted"
{ echo '#!/bin/bash'; i=0; while [ $i -lt 150 ]; do echo "# line $i"; i=$((i + 1)); done; } > "$TMP/gen.sh"
[ "$(verdict "$TMP/gen.sh")" = accepted ] && pass "150-line untagged file is accepted" || fail "150-line untagged file refused"
if git -C "$ROOT" show v0.40.2:update.sh > "$TMP/old.sh" 2>/dev/null && [ -s "$TMP/old.sh" ]; then
  [ "$(verdict "$TMP/old.sh")" = accepted ] && pass "update.sh of release v0.40.2 is accepted" || fail "update.sh of v0.40.2 refused"
else
  echo "  skip: tag v0.40.2 not available"
fi

echo
if [ "$fails" -eq 0 ]; then echo "PASS: #1004 step 0 integrity"; else echo "FAILED: $fails check(s)"; exit 1; fi
