#!/usr/bin/env bash
# test_issue_596_weekreport_filename.sh — regression for issue #596.
#
# The Sunday-night Week Close race guard in day-open-pipeline.sh built
# WEEK_REPORT_REL as "current/WeekReport {ISO-year}-W{ISO-week}.md" (e.g.
# "WeekReport 2026-W35.md"), but the real convention used everywhere else
# (memory/routing-vocab.md, week-close/SKILL.md, archive/week-reports/) is
# "WeekReport W{N} YYYY-MM-DD.md" with N = ISO week number and the date =
# that week's Monday (e.g. "WeekReport W35 2026-08-24.md"). The guard could
# never find the file it was checking for and always deferred Day Open.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PIPELINE="$ROOT/scripts/day-open-pipeline.sh"

fail=0
check() { # <desc> <expected> <actual>
    if [ "$2" = "$3" ]; then
        echo "PASS: $1"
    else
        echo "FAIL: $1 — ожидалось [$2], получено [$3]"
        fail=$((fail + 1))
    fi
}
check_grep() { # <desc> <pattern> <file>
    if grep -qF "$2" "$3"; then echo "PASS: $1"; else echo "FAIL: $1 — нет строки: $2"; fail=$((fail + 1)); fi
}
check_grep_absent() {
    if grep -qF "$2" "$3"; then echo "FAIL: $1 — строки не должно быть: $2"; fail=$((fail + 1)); else echo "PASS: $1"; fi
}

# --- Юнит: сама формула (та же, что в pipeline) на известных датах ---
week_report_rel() { # <sunday-date>
    local d="$1" num monday
    num=$((10#$(date -j -f "%Y-%m-%d" "$d" "+%V" 2>/dev/null || date -d "$d" "+%V" 2>/dev/null)))
    monday=$(date -j -v-6d -f "%Y-%m-%d" "$d" "+%Y-%m-%d" 2>/dev/null \
        || date -d "$d - 6 day" "+%Y-%m-%d" 2>/dev/null)
    printf 'current/WeekReport W%s %s.md' "$num" "$monday"
}

check "воскресенье 30.08.2026 -> W35, понедельник 24.08" \
    "current/WeekReport W35 2026-08-24.md" "$(week_report_rel 2026-08-30)"
check "воскресенье 06.09.2026 -> W36, понедельник 31.08" \
    "current/WeekReport W36 2026-08-31.md" "$(week_report_rel 2026-09-06)"
check "воскресенье 01.02.2026 -> W5 (без ведущего нуля), понедельник 26.01" \
    "current/WeekReport W5 2026-01-26.md" "$(week_report_rel 2026-02-01)"

# --- Скрипт: правильная формула присутствует, сломанная — нет ---
check_grep "pipeline строит корректное имя файла" \
    'WEEK_REPORT_REL="current/WeekReport ${TARGET_WEEK}.md"' "$PIPELINE"
check_grep_absent "pipeline больше не использует ISO-год-неделю в имени файла" \
    'TARGET_WEEK=$(portable_date_field "$DATE" "+%Y-W%V")' "$PIPELINE"
check_grep "pipeline вычисляет номер недели без ведущего нуля" \
    'TARGET_WEEK_NUM=$((10#$(portable_date_field "$DATE" "+%V")))' "$PIPELINE"

if [ "$fail" -eq 0 ]; then
    echo "issue #596 weekreport filename: все проверки пройдены"
else
    echo "issue #596 weekreport filename: $fail провал(ов)"
    exit 1
fi
