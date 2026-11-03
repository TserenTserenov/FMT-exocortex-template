#!/usr/bin/env bash
# test_issue_1425_bleed_lifecycle_fields.sh — memory-bleed must not silently
# drop auto-memory files that lack valid_from/horizon (issue #1425): they take
# part in demotion with the default horizon for their type, and the report says
# they lack lifecycle fields instead of "no violations".
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BLEED="$ROOT/scripts/memory-bleed.sh"

FAIL=0
pass() { echo "  ✅ PASS: $*"; }
fail() { echo "  ❌ FAIL: $*"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

set_old_mtime() { # <file> <days ago>
    local stamp
    stamp=$(python3 -c "import datetime,sys; d=datetime.datetime.now()-datetime.timedelta(days=int(sys.argv[1])); print(d.strftime('%Y%m%d%H%M'))" "$2")
    touch -t "$stamp" "$1"
}

# Case 1: a complete flat file only — the summary stays green, no warning.
CLEAN="$TMP/clean"
mkdir -p "$CLEAN"
printf -- '---\nname: full\ndescription: d\ntype: project\nhorizon: warm\ndomains: [memory]\nstatus: active\nvalid_from: 2026-10-01\nowner: user\nschema_version: 1\n---\nbody\n' > "$CLEAN/project_full.md"
OUT="$TMP/clean.out"
bash "$BLEED" --dir "$CLEAN" > "$OUT" 2>&1; RC=$?
if [ "$RC" -eq 0 ] && grep -q '^✅ Нарушений не найдено' "$OUT" && ! grep -q 'без полей жизненного цикла' "$OUT"; then
    pass "complete files: green summary, no lifecycle warning"
else
    fail "complete files: rc=$RC, report: $(tr '\n' ' ' < "$OUT")"
fi

# Case 2: auto-memory nested form without valid_from/horizon/status, 40 days old.
AUTO="$TMP/auto"
mkdir -p "$AUTO"
printf -- '---\nname: auto-project\ndescription: written by the harness\nmetadata:\n  type: project\n---\nbody\n' > "$AUTO/project_auto.md"
printf -- '---\nname: no-type\ndescription: no type at all\n---\nbody\n' > "$AUTO/note_untyped.md"
set_old_mtime "$AUTO/project_auto.md" 40
set_old_mtime "$AUTO/note_untyped.md" 40
OUT="$TMP/auto.out"
bash "$BLEED" --dir "$AUTO" > "$OUT" 2>&1; RC=$?

if grep -qE '^\| project_auto\.md \| warm \(по умолч\.\) \| — \| [0-9]+ \| → COLD' "$OUT"; then
    pass "auto-memory project file is a demotion candidate with the default horizon"
else
    fail "auto-memory project file missing from candidates: $(grep '^|' "$OUT" | tr '\n' ' ')"
fi
if grep -q '^| note_untyped.md' "$OUT"; then
    fail "file without type got a guessed horizon"
else
    pass "file without type is not given a guessed horizon"
fi
if grep -q '^- project_auto.md: нет horizon valid_from status' "$OUT" \
    && grep -q '^- note_untyped.md: нет horizon valid_from status' "$OUT"; then
    pass "both files listed in the lifecycle-fields warning"
else
    fail "lifecycle-fields warning incomplete: $(grep -A4 'без полей жизненного цикла' "$OUT" | tr '\n' ' ')"
fi
if [ "$RC" -eq 0 ] && grep -q '^⚠️ Предупреждений: 2 файлов без полей жизненного цикла' "$OUT" \
    && ! grep -q 'Нарушений не найдено' "$OUT"; then
    pass "summary reports the warning instead of 'no violations', exit 0"
else
    fail "summary wrong: rc=$RC, $(tail -2 "$OUT" | tr '\n' ' ')"
fi

[ "$FAIL" -eq 0 ] && echo "PASS: issue #1425 memory-bleed lifecycle fields" || { echo "FAIL: issue #1425 has $FAIL violation(s)"; exit 1; }
