#!/usr/bin/env bash
# Issue #1114: the AST encoding gate (scripts/check-python-encoding.py) must
# flag open()/Path.open() calls without encoding= and ratchet the baseline —
# a new violation fails, a fixed call makes its baseline entry stale (fail
# until --regenerate), clean state passes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
CHECKER="$ROOT/scripts/check-python-encoding.py"
# python-resolver contract: no bare python3 (stdlib suffices for the checker).
PYTHON3=$("$ROOT/scripts/lib/find-python3.sh" --stdlib-only) || {
  echo "FAIL: python3 not found (find-python3.sh)" >&2
  exit 1
}
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT
BASELINE="$FIXTURE/baseline.txt"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- Fixture repo (the checker lists files via git ls-files at cwd) ---
git -C "$FIXTURE" init -q -b main

# OK cases: explicit encoding=, positional encoding (builtin index 3,
# Path.open index 2 — the peer-verified signature positions), binary mode.
cat > "$FIXTURE/ok_cases.py" <<'PY'
from pathlib import Path

with open("a.txt", encoding="utf-8") as f:
    pass
with open("a.txt", "r", -1, "utf-8") as f:  # builtin encoding = 4th positional
    pass
with open("a.txt", "rb") as f:  # binary mode never decodes
    pass
p = Path("b.txt")
with p.open("r", -1, "utf-8") as f:  # Path.open encoding = 3rd positional
    pass
with p.open("r", -1, encoding="utf-8") as f:  # 2 positional + encoding keyword
    pass
PY

# Violations, one per file so baseline add/stale can be exercised separately.
cat > "$FIXTURE/bad_builtin.py" <<'PY'
with open("a.txt") as f:
    pass
PY
cat > "$FIXTURE/bad_path.py" <<'PY'
from pathlib import Path

with Path("b.txt").open("r") as f:
    pass
PY
cat > "$FIXTURE/bad_varmode.py" <<'PY'
mode = "r"
with open("a.txt", mode) as f:  # non-literal mode: conservatively text
    pass
PY
cat > "$FIXTURE/not_path_receiver.py" <<'PY'
import tarfile

with tarfile.open("a.tar", "r:gz") as tar:  # non-Path .open: NOT flagged (precision over recall)
    pass
PY
cat > "$FIXTURE/foreign_path.py" <<'PY'
from othermod import Path  # NOT pathlib — its .open() may lack encoding=

with Path("b.txt").open("r") as f:  # must NOT be flagged (import not provably pathlib)
    pass
PY
cat > "$FIXTURE/shadowed_path.py" <<'PY'
from pathlib import Path
from othermod import Path  # later binding shadows pathlib's — .open() not provably pathlib

with Path("b.txt").open("r") as f:  # must NOT be flagged (shadowed)
    pass
PY
cat > "$FIXTURE/unpacked_path.py" <<'PY'
from pathlib import Path

Path, unused = OtherPath, 0  # tuple-unpack rebinds Path (cold review r3)

with Path("b.txt").open("r") as f:  # must NOT be flagged
    pass
PY
cat > "$FIXTURE/bad_aliased_path.py" <<'PY'
from pathlib import Path as P  # alias of pathlib.Path — tracked

with P("b.txt").open("r") as f:
    pass
PY
cat > "$FIXTURE/bad_module_path.py" <<'PY'
import pathlib as pl

with pl.Path("b.txt").open("r") as f:
    pass
PY

git -C "$FIXTURE" add -f ok_cases.py bad_builtin.py bad_path.py bad_varmode.py not_path_receiver.py foreign_path.py shadowed_path.py unpacked_path.py bad_aliased_path.py bad_module_path.py

run_checker() {  # captures output, returns the checker's exit code
    set +e
    OUTPUT=$(cd "$FIXTURE" && "$PYTHON3" "$CHECKER" --baseline "$BASELINE" "$@" 2>&1)
    CODE=$?
    set -e
}

# --- 1. No baseline yet: all five violations reported, exit 1 ---
run_checker
[ "$CODE" -eq 1 ] || fail "expected exit 1 without baseline, got $CODE: $OUTPUT"
[ "$(printf '%s\n' "$OUTPUT" | grep -c '^NEW VIOLATION:')" -eq 5 ] \
    || fail "expected 5 new violations: $OUTPUT"
printf '%s\n' "$OUTPUT" | grep -q 'bad_builtin.py' || fail "bad_builtin.py not flagged: $OUTPUT"
printf '%s\n' "$OUTPUT" | grep -q 'bad_path.py' || fail "bad_path.py not flagged: $OUTPUT"
printf '%s\n' "$OUTPUT" | grep -q 'bad_varmode.py' || fail "bad_varmode.py not flagged: $OUTPUT"
printf '%s\n' "$OUTPUT" | grep -q 'bad_aliased_path.py' || fail "aliased pathlib.Path not flagged: $OUTPUT"
printf '%s\n' "$OUTPUT" | grep -q 'bad_module_path.py' || fail "pl.Path not flagged: $OUTPUT"
if printf '%s\n' "$OUTPUT" | grep -q 'ok_cases.py'; then
    fail "ok_cases.py falsely flagged: $OUTPUT"
fi
if printf '%s\n' "$OUTPUT" | grep -q 'not_path_receiver.py'; then
    fail "tarfile.open falsely flagged as Path.open: $OUTPUT"
fi
if printf '%s\n' "$OUTPUT" | grep -q 'foreign_path.py'; then
    fail "foreign Path falsely flagged: $OUTPUT"
fi
if printf '%s\n' "$OUTPUT" | grep -q 'shadowed_path.py'; then
    fail "shadowed Path falsely flagged: $OUTPUT"
fi
if printf '%s\n' "$OUTPUT" | grep -q 'unpacked_path.py'; then
    fail "tuple-unpacked Path falsely flagged: $OUTPUT"
fi

# --- 2. --regenerate writes the baseline; rerun passes ---
run_checker --regenerate
[ "$CODE" -eq 0 ] || fail "--regenerate failed: $OUTPUT"
[ "$(grep -cv '^#' "$BASELINE")" -eq 5 ] || fail "baseline must have 5 entries: $(cat "$BASELINE")"
run_checker
[ "$CODE" -eq 0 ] || fail "clean run must exit 0: $OUTPUT"
printf '%s\n' "$OUTPUT" | grep -q '^PASS:' || fail "missing PASS summary: $OUTPUT"

# --- 3. A NEW violation on top of the baseline fails ---
cat > "$FIXTURE/bad_new.py" <<'PY'
with open("c.txt", "w") as f:
    pass
PY
git -C "$FIXTURE" add -f bad_new.py
run_checker
[ "$CODE" -eq 1 ] || fail "new violation must exit 1: $OUTPUT"
printf '%s\n' "$OUTPUT" | grep -q '^NEW VIOLATION: bad_new.py' || fail "bad_new.py not flagged: $OUTPUT"

# --- 4. Fixing a baselined call makes its entry stale (ratchet hygiene) ---
git -C "$FIXTURE" rm -q -f bad_new.py
cat > "$FIXTURE/bad_builtin.py" <<'PY'
with open("a.txt", encoding="utf-8") as f:
    pass
PY
git -C "$FIXTURE" add -f bad_builtin.py
run_checker
[ "$CODE" -eq 1 ] || fail "stale baseline entry must exit 1: $OUTPUT"
printf '%s\n' "$OUTPUT" | grep -q '^stale baseline entry: bad_builtin.py' \
    || fail "stale entry not reported: $OUTPUT"

# --- 5. --regenerate shrinks the ratchet; clean run passes again ---
run_checker --regenerate
[ "$CODE" -eq 0 ] || fail "--regenerate after fix failed: $OUTPUT"
[ "$(grep -cv '^#' "$BASELINE")" -eq 4 ] || fail "baseline must shrink to 4: $(cat "$BASELINE")"
run_checker
[ "$CODE" -eq 0 ] || fail "post-regenerate run must exit 0: $OUTPUT"

# --- 6. Unrelated edit does not shift entries (match is path+line, not lineno) ---
cat >> "$FIXTURE/bad_path.py" <<'PY'

# trailing comment shifts nothing relevant, but prepend 10 lines instead
PY
{ for i in 1 2 3 4 5 6 7 8 9 10; do echo "# filler $i"; done; cat "$FIXTURE/bad_path.py"; } > "$FIXTURE/tmp.py"
mv "$FIXTURE/tmp.py" "$FIXTURE/bad_path.py"
git -C "$FIXTURE" add -f bad_path.py
run_checker
[ "$CODE" -eq 0 ] || fail "line-number shift must not break baseline match: $OUTPUT"

echo "PASS: issue #1114 encoding gate — violations flagged, baseline add/stale/line-shift ratchet works"
