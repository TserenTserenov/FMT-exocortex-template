#!/usr/bin/env bash
# test_issue_1010_detectors.sh — two integration-contract detectors had blind
# spots (issue #1010 F13): detector 3 read only the first 20 rows of the
# extensions table, detector 8 caught only `sed -e "s|{{X}}|..."`. A copy of
# the tree with one violation planted past row 20 and one plain `sed "s|{{X}}|"`
# must fail; the untouched copy must pass.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

FAIL=0
pass() { echo "  ✅ PASS: $*"; }
fail() { echo "  ❌ FAIL: $*"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
copy_tree() {
    mkdir -p "$1"
    (cd "$ROOT" && tar --exclude=.git -cf - .) | (cd "$1" && tar -xf -)
}
validate() { (cd "$1" && bash setup/integration-contract-validator.sh > "$1.out" 2>&1); }

copy_tree "$TMP/clean"
if validate "$TMP/clean"; then pass "untouched tree passes"; else fail "untouched tree fails: $(grep -E '⚠|FAIL' "$TMP/clean.out" | head -3 | tr '\n' ' ')"; fi

copy_tree "$TMP/ext"
printf '| zz-no-such-protocol | checks | planted row past the 20th |\n' >> "$TMP/ext/extensions/README.md"
validate "$TMP/ext"
if grep -q 'extensions/zz-no-such-protocol.checks.md' "$TMP/ext.out"; then
    pass "detector 3 sees a declared extension point past row 20"
else
    fail "detector 3 missed the planted row past row 20"
fi

copy_tree "$TMP/sed"
# Plant a substituted runner of our own: the overlay may list no .sh today,
# the detector must still work the moment one is added.
mkdir -p "$TMP/sed/scripts"
printf '#!/bin/bash\nsed "s|{{PLANTED_X}}|value|" /dev/null\n' > "$TMP/sed/scripts/planted-runner.sh"
python3 - "$TMP/sed/.claude/runtime-overlay.yaml" <<'PYX'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(s.replace("substituted:\n", "substituted:\n  - scripts/planted-runner.sh\n", 1))
PYX
validate "$TMP/sed"
if grep -q 'scripts/planted-runner.sh: bare {{X}}' "$TMP/sed.out"; then
    pass "detector 8 catches sed \"s|{{X}}|...|\" without -e"
else
    fail "detector 8 missed sed without -e in a substituted runner"
fi

[ "$FAIL" -eq 0 ] && echo "PASS: issue #1010 F13 detectors" || { echo "FAIL: issue #1010 F13 has $FAIL violation(s)"; exit 1; }
