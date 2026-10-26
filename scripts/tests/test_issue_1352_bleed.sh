#!/usr/bin/env bash
# test_issue_1352_bleed.sh — memory-bleed must not report the instruction files
# that day-close copies next to memory in the exocortex/ backup (issue #1352).
# CLAUDE.md/AGENTS.md carry no memory frontmatter by design; a memory file
# without frontmatter must still be reported.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BLEED="$ROOT/scripts/memory-bleed.sh"

FAIL=0
pass() { echo "  ✅ PASS: $*"; }
fail() { echo "  ❌ FAIL: $*"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
DIR="$TMP/exocortex"
mkdir -p "$DIR"
printf '# Instructions\n' > "$DIR/CLAUDE.md"
printf '# Instructions\n' > "$DIR/AGENTS.md"
printf '# Index\n' > "$DIR/MEMORY.md"
printf -- '---\nname: ok\ndescription: has frontmatter\n---\nbody\n' > "$DIR/feedback_ok.md"

OUT="$TMP/clean.out"
bash "$BLEED" --dir "$DIR" > "$OUT" 2>&1
if grep -q 'Файлы без frontmatter' "$OUT"; then
    fail "instruction files are reported as memory without frontmatter: $(grep -A3 'Файлы без frontmatter' "$OUT" | tr '\n' ' ')"
else
    pass "CLAUDE.md, AGENTS.md and MEMORY.md are not reported"
fi

printf 'no frontmatter here\n' > "$DIR/lessons_orphan.md"
OUT="$TMP/orphan.out"
bash "$BLEED" --dir "$DIR" > "$OUT" 2>&1
if grep -q 'lessons_orphan.md' "$OUT" && ! grep -qE -- '- (CLAUDE|AGENTS)\.md' "$OUT"; then
    pass "a memory file without frontmatter is still reported, instruction files are not"
else
    fail "orphan memory file not reported or instruction files listed again"
fi

[ "$FAIL" -eq 0 ] && echo "PASS: issue #1352 memory-bleed exclusions" || { echo "FAIL: issue #1352 has $FAIL violation(s)"; exit 1; }
