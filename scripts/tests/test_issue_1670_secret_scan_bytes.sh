#!/usr/bin/env bash
# issue #1670: the pre-commit secret scan answered "clean" for a whole commit
# when (1) any staged file was not UTF-8 - BSD sed under a UTF-8 locale stops
# on the first such byte and the empty result read as "nothing added" - and
# (2) the key sat in a file git treats as binary (a NUL byte, or "-diff" in
# .gitattributes), whose diff is one "Binary files differ" line. Also covered:
# a failed sed and a pattern library that fails to load stop the commit with
# exit 2 instead of passing it.
#
# Runs the real scanner on staged files in a throwaway repo. The probe key is
# assembled at runtime so this file holds no literal the scanner would flag.
# SECRET_SCAN_SOURCE_ROOT points at another tree with the same layout (the
# author copy of the scanner) to run the same cases against it.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${SECRET_SCAN_SOURCE_ROOT:-$ROOT}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The bug shows under a UTF-8 locale; force one so the test reproduces it on
# any machine, not only on a Mac with LANG=C.UTF-8.
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

pass=0
fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

KEY="gh""p_$(printf 'Ab1%.0s' 1 2 3 4 5 6 7 8 9 10 11 12)"
CP1251_WORD=$'\xcf\xf0\xe8\xe2\xe5\xf2'   # "Привет" in Windows-1251, not valid UTF-8

REPO="$TMP/repo"
mkdir -p "$REPO/.claude/hooks" "$REPO/scripts"
# The template library calls secret-bypass-analyzer.py, the author copy calls
# secret_patterns.py; copy whichever helpers the source tree has.
cp "$SRC/.claude/hooks/secret-bypass-lib.sh" "$REPO/.claude/hooks/"
for helper in secret-bypass-analyzer.py secret_patterns.py; do
    [ -f "$SRC/.claude/hooks/$helper" ] && cp "$SRC/.claude/hooks/$helper" "$REPO/.claude/hooks/"
done
cp "$SRC/scripts/pre-commit-secret-scan.sh" "$REPO/scripts/"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@test
git -C "$REPO" config user.name test
git -C "$REPO" add .claude scripts
git -C "$REPO" commit -q -m base

# reset_stage: unstage and delete every probe file of the previous case.
reset_stage() {
    git -C "$REPO" rm -q -r --cached --ignore-unmatch probe-* .gitattributes >/dev/null
    rm -f "$REPO"/probe-* "$REPO/.gitattributes"
}

# scan [script]: runs the scanner on what is staged; returns its exit code.
scan() {
    local script="${1:-scripts/pre-commit-secret-scan.sh}"
    ( cd "$REPO" && bash "$script" ) >"$TMP/scan.out" 2>&1
}

# expect <rc> <name> [script]: the scan of the staged probes exits with <rc>.
expect() {
    local want="$1" name="$2"
    scan "${3:-}"
    local rc=$?
    if [ "$rc" -eq "$want" ]; then
        ok "$name"
    else
        sed 's/^/    /' "$TMP/scan.out"
        bad "$name (rc=$rc, want $want)"
    fi
    reset_stage
}

stage() { git -C "$REPO" add -- "$@"; }

# 1. Key inside a Windows-1251 CSV.
printf '%s;%s\n' "$CP1251_WORD" "$KEY" > "$REPO/probe-export.csv"
stage probe-export.csv
expect 1 "key inside a Windows-1251 CSV blocks"

# 2. Key in a UTF-8 file, any Windows-1251 file next to it in the same commit.
printf 'token = %s\n' "$KEY" > "$REPO/probe-note.md"
printf '%s\n' "$CP1251_WORD" > "$REPO/probe-other.csv"
stage probe-note.md probe-other.csv
expect 1 "key in a UTF-8 file next to a Windows-1251 file blocks"

# 3. Key in a file with a NUL byte (git shows it as binary).
printf 'head\0%s\n' "$KEY" > "$REPO/probe-blob.bin"
stage probe-blob.bin
expect 1 "key inside a file with a NUL byte blocks"

# 4. Text file declared binary by -diff in .gitattributes.
printf 'probe-*.dat -diff\n' > "$REPO/.gitattributes"
printf 'token = %s\n' "$KEY" > "$REPO/probe-config.dat"
stage .gitattributes probe-config.dat
expect 1 "key in a file marked -diff in .gitattributes blocks"

# 5. Clean files in the encodings and formats above pass.
printf '%s;%s\n' "$CP1251_WORD" "42" > "$REPO/probe-clean.csv"
stage probe-clean.csv
expect 0 "clean Windows-1251 CSV passes"

printf 'Заметка без секретов: план на неделю.\n' > "$REPO/probe-ru.md"
stage probe-ru.md
expect 0 "clean UTF-8 Russian note passes"

printf '\x89PNG\r\n\x1a\n\0\0\0\rIHDR\xff\xfe\xfd\x80\x81' > "$REPO/probe-image.png"
stage probe-image.png
expect 0 "clean binary file with invalid UTF-8 bytes passes"

# 6. A failed sed stops the commit (exit 2), not "nothing added".
sed "s/| sed -n '\/^+++ \/d; s\/^+\/\/p')/| false)/" "$REPO/scripts/pre-commit-secret-scan.sh" \
    > "$REPO/scripts/scan-sed-fails.sh"
if grep -q '| false)' "$REPO/scripts/scan-sed-fails.sh"; then
    printf 'token = %s\n' "$KEY" > "$REPO/probe-note.md"
    stage probe-note.md
    expect 2 "failed diff filtering stops the commit" scripts/scan-sed-fails.sh
else
    bad "could not build the failing-sed copy of the scanner (sed line changed?)"
fi

# 7. A pattern library that fails to load stops the commit (exit 2).
cp "$REPO/.claude/hooks/secret-bypass-lib.sh" "$TMP/lib.orig"
printf 'return 1\n' > "$REPO/.claude/hooks/secret-bypass-lib.sh"
printf 'harmless\n' > "$REPO/probe-note.md"
stage probe-note.md
expect 2 "pattern library that fails to load stops the commit"
cp "$TMP/lib.orig" "$REPO/.claude/hooks/secret-bypass-lib.sh"

echo "issue #1670 secret scan: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
