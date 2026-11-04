#!/usr/bin/env bash
# test_memory_bleed_age_batch.sh — memory-bleed computes file age in calendar
# days exactly as before (date.today() - date.fromtimestamp(mtime)), but with a
# number of python3 launches that does not grow with the number of files
# (WP-529 F248: two launches per file pushed month-close past its 180 s limit).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BLEED="$ROOT/scripts/memory-bleed.sh"
REAL_PYTHON="$(command -v python3)"

FAIL=0
pass() { echo "  ✅ PASS: $*"; }
fail() { echo "  ❌ FAIL: $*"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Local-time stamp for touch -t: today's date at hh:mm, shifted by N days.
stamp() { # <days offset> <HHMM>
    python3 -c "import datetime,sys; d=datetime.date.today()+datetime.timedelta(days=int(sys.argv[1])); print(d.strftime('%Y%m%d')+sys.argv[2])" "$1" "$2"
}
expected_age() { # <file>
    python3 -c "import datetime,os,sys; print((datetime.date.today()-datetime.date.fromtimestamp(int(os.stat(sys.argv[1]).st_mtime))).days)" "$1"
}
mkfile() { # <dir> <name>
    printf -- '---\nname: %s\ndescription: d\ntype: project\nhorizon: hot\ndomains: [memory]\nstatus: active\nvalid_from: 2026-01-01\nowner: user\nschema_version: 1\n---\nbody\n' "$2" > "$1/$2.md"
}
age_in_report() { # <report> <file name> -> age column, empty when not listed
    awk -F' \\| ' -v n="$2" '$1 == "| " n {print $4}' "$1"
}
# The fixtures are horizon hot: listed from 14 days on (HOT_DOWNGRADE_DAYS).
check_age() { # <report> <label> <file name> <expected age>
    local got
    got=$(age_in_report "$1" "$3")
    if [ "$4" -ge 14 ]; then
        [ "$got" = "$4" ] && pass "$2: age $got" || fail "$2: age '$got', expected $4"
    else
        [ -z "$got" ] && pass "$2: age $4 below threshold, not listed" || fail "$2: listed with '$got' below threshold"
    fi
}

# Case 1: ages around midnight, at the 14-day hot threshold and far back match
# the reference expression; a file one day under the threshold is not listed.
DIR="$TMP/ages"
mkdir -p "$DIR"
names=""
for spec in "late:-15:2359" "early:-15:0001" "edge:-14:0001" "recent:-13:2359" "old:-40:1200"; do
    IFS=: read -r name off hm <<< "$spec"
    mkfile "$DIR" "project_$name"
    touch -t "$(stamp "$off" "$hm")" "$DIR/project_$name.md"
    names="$names $name"
done
mkfile "$DIR" "project_with space"
touch -t "$(stamp -20 1200)" "$DIR/project_with space.md"
# Expected ages are taken before the run, so a run crossing midnight shows up
# as a mismatch of the report against them rather than passing by accident.
for name in $names; do
    eval "want_$name=$(expected_age "$DIR/project_$name.md")"
done
OUT="$TMP/ages.out"
bash "$BLEED" --dir "$DIR" > "$OUT" 2>&1
RC=$?
[ "$RC" -eq 0 ] && grep -q '^### Кандидаты на понижение горизонта' "$OUT" \
    && pass "run completed, rc 0" || fail "run rc=$RC or no candidates section"
for name in $names; do
    check_age "$OUT" "$name" "project_$name.md" "$(eval "echo \$want_$name")"
done
got=$(age_in_report "$OUT" "project_with space.md")
[ "$got" = "20" ] && pass "name with a space: listed by its full name, age 20" \
    || fail "name with a space: got '$got'"

# Case 2: python3 launches do not depend on the number of files.
# Shim mode for the age batch (the only python3 call reading sys.stdin.buffer):
# pass — run as is; fail — exit 1; dash:<name> — report "-" for that file name.
make_shim() { # <dir> <log> <mode>
    mkdir -p "$1"; : > "$2"
    {
        echo '#!/bin/sh'
        echo "echo x >> \"$2\""
        case "$3" in
            fail) echo 'case "$2" in *sys.stdin.buffer*) exit 1 ;; esac' ;;
            dash:*)
                echo 'case "$2" in *sys.stdin.buffer*)'
                echo "  \"$REAL_PYTHON\" \"\$@\" | sed 's|^[-0-9]*\\(\t.*/${3#dash:}\\)\$|-\\1|'; exit ;;"
                echo 'esac' ;;
        esac
        echo "exec \"$REAL_PYTHON\" \"\$@\""
    } > "$1/python3"
    chmod +x "$1/python3"
}
count_python() { # <dir> -> number of python3 launches during one run
    make_shim "$TMP/shim" "$TMP/py.log" pass
    PATH="$TMP/shim:$PATH" bash "$BLEED" --dir "$1" > "$TMP/count.out" 2>&1 \
        && grep -q '^### Кандидаты на понижение горизонта' "$TMP/count.out" \
        || { echo "run failed"; return; }
    wc -l < "$TMP/py.log" | tr -d ' '
}
SMALL="$TMP/small"; BIG="$TMP/big"
mkdir -p "$SMALL" "$BIG"
for i in 1 2; do mkfile "$SMALL" "project_s$i"; done
for i in $(seq 1 30); do mkfile "$BIG" "project_b$i"; done
n_small=$(count_python "$SMALL")
n_big=$(count_python "$BIG")
if [ "$n_small" = "$n_big" ] && [ "$n_small" -ge 1 ] 2>/dev/null; then
    pass "python3 launches: $n_small for 2 files, $n_big for 30"
else
    fail "python3 launches: '$n_small' for 2 files, '$n_big' for 30"
fi

# Case 3: when the age batch cannot run, the report says so and fails instead
# of showing an empty table as a clean result.
make_shim "$TMP/broken" "$TMP/broken.log" fail
OUT="$TMP/broken.out"
PATH="$TMP/broken:$PATH" bash "$BLEED" --dir "$BIG" > "$OUT" 2>&1
RC=$?
[ "$RC" -eq 1 ] && grep -q '^❌ Возраст посчитан для 0 из 30 файлов' "$OUT" \
    && pass "broken age batch: reported, rc 1" || fail "broken age batch: rc=$RC, no incomplete-table line"

# Case 4: one file whose age cannot be computed falls back to valid_from
# (2026-01-01) and the files after it are still processed.
FB="$TMP/fallback"
mkdir -p "$FB"
for n in a_first b_dash c_after; do mkfile "$FB" "project_$n"; touch -t "$(stamp -30 1200)" "$FB/project_$n.md"; done
want_fb=$(python3 -c "from datetime import date; print((date.today()-date.fromisoformat('2026-01-01')).days)")
make_shim "$TMP/dash" "$TMP/dash.log" "dash:project_b_dash.md"
OUT="$TMP/fallback.out"
PATH="$TMP/dash:$PATH" bash "$BLEED" --dir "$FB" > "$OUT" 2>&1
got_fb=$(age_in_report "$OUT" "project_b_dash.md")
got_after=$(age_in_report "$OUT" "project_c_after.md")
[ "$got_fb" = "$want_fb" ] && [ "$got_after" = "30" ] && ! grep -q '^❌ Возраст посчитан' "$OUT" \
    && pass "fallback: age from valid_from ($got_fb), next file still 30" \
    || fail "fallback: got '$got_fb' (want $want_fb), next '$got_after' (want 30)"

# Case 5: around both 2026 DST switches in an explicit zone and for a future
# mtime the age equals the reference expression in the same zone.
DST="$TMP/dst"
mkdir -p "$DST"
for spec in "spring:202603290030" "spring_eve:202603282330" "autumn:202610250030" "autumn_eve:202610242330"; do
    IFS=: read -r name ts <<< "$spec"
    mkfile "$DST" "project_$name"
    TZ=Europe/Nicosia touch -t "$ts" "$DST/project_$name.md"
done
mkfile "$DST" "project_future"
touch -t "$(stamp 1 1200)" "$DST/project_future.md"
OUT="$TMP/dst.out"
TZ=Europe/Nicosia bash "$BLEED" --dir "$DST" > "$OUT" 2>&1
for name in spring spring_eve autumn autumn_eve future; do
    check_age "$OUT" "DST/future $name" "project_$name.md" "$(TZ=Europe/Nicosia expected_age "$DST/project_$name.md")"
done

[ "$FAIL" -eq 0 ] && echo "PASS: memory-bleed age batch" || { echo "FAIL: $FAIL"; exit 1; }
