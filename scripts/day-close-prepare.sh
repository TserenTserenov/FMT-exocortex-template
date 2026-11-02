#!/bin/bash
# routing: helper  skill=day-close  called-by=sonnet  deterministic=true
# see DP.SC.159, DP.ROLE.059
# day-close-prepare.sh — one-call data digest for the Day Close protocol (issue #234).
# Replaces ~10 separate agent round-trips (commit scan, drift scan, index health,
# lesson stats, WakaTime, dirty repos) with a single compact digest, so Day Close
# cost does not scale with the size of the day's conversation.
#
# Usage:
#   day-close-prepare.sh                      # full digest (SKILL.md step 0б)
#   day-close-prepare.sh --date 2026-11-01    # the day being closed (Day Close after midnight)
#   day-close-prepare.sh --verify [--date D]  # postconditions 9a/9b + dirty-repo recheck
#
# The closed day comes from --date, else from day_boundary in
# memory/day-rhythm-config.yaml (before that hour the previous calendar day is
# still open), else from the clock. Every dated section uses that one day.
#
# Exit codes: digest mode 0; --verify returns 1 if any check FAILs;
# invalid arguments return 2.
#
# Contributed by @maxborovik (issue #234), adapted to iwe-env-bootstrap conventions.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../.claude/lib/iwe-env-bootstrap.sh" || exit 1

GOV="$IWE_DS_MY_STRATEGY"

VERIFY=false
CLOSE_DATE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --verify) VERIFY=true; shift ;;
    # --for-date: the name the governance-repo port of this script uses.
    --date|--for-date)
      [ $# -ge 2 ] || { echo "ERR: --date ожидает YYYY-MM-DD" >&2; exit 2; }
      CLOSE_DATE="$2"; shift 2 ;;
    *) echo "ERR: неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done

# Calendar arithmetic on YYYY-MM-DD: BSD date first, GNU date as fallback.
shift_date() {
  date -j -v"$2"d -f "%Y-%m-%d" "$1" "+%Y-%m-%d" 2>/dev/null \
    || date -d "$1 $2 day" "+%Y-%m-%d" 2>/dev/null
}

# issue #924 day_boundary, read the same way as day-open-pipeline.sh: scoped
# to the day_open: block, commented-out lines skipped, live memory/ copy.
DAY_BOUNDARY=$(awk '
  /^[^[:space:]]/ && !/^day_open:/ { f=0 }
  /^day_open:/ { f=1 }
  f && /day_boundary:/ && !/^[[:space:]]*#/ { print; exit }
' "$WORKSPACE_DIR/memory/day-rhythm-config.yaml" 2>/dev/null \
  | sed -E 's/.*day_boundary:[[:space:]]*"?([0-9]{1,2}:[0-9]{2})"?.*/\1/')

# A Day Close after midnight used to digest the new calendar day: commits,
# sessions, WakaTime and the 9a/9b checks all looked at the wrong date.
DATE_SOURCE="--date"
if [ -z "$CLOSE_DATE" ]; then
  CLOSE_DATE=$(date +%Y-%m-%d)
  DATE_SOURCE="clock"
  if [[ "$DAY_BOUNDARY" =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
    boundary_min=$(( 10#${BASH_REMATCH[1]} * 60 + 10#${BASH_REMATCH[2]} ))
    now_min=$(( 10#$(date +%H) * 60 + 10#$(date +%M) ))
    if [ "$now_min" -lt "$boundary_min" ]; then
      CLOSE_DATE=$(shift_date "$CLOSE_DATE" -1)
      DATE_SOURCE="day_boundary $DAY_BOUNDARY"
    fi
  fi
fi
# Round trip, not a single parse: BSD date rolls 2026-02-30 over to March
# without an error, GNU date rejects it.
NEXT_DATE=""
if [[ "$CLOSE_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  NEXT_DATE=$(shift_date "$CLOSE_DATE" +1)
fi
if [ -z "$NEXT_DATE" ] || [ "$(shift_date "$NEXT_DATE" -1)" != "$CLOSE_DATE" ]; then
  if [ "$DATE_SOURCE" = "--date" ]; then
    echo "ERR: --date ожидает YYYY-MM-DD, получено: $CLOSE_DATE" >&2
  else
    echo "ERR: не удалось вычислить закрываемый день (date не умеет -v/-d?)" >&2
  fi
  exit 2
fi
DAY_NUM=$(( 10#${CLOSE_DATE##*-} ))

# Half-open commit window of the closed day, [D <boundary>, D+1 <boundary>).
# KEEP IN SYNC with day-open-pipeline.sh / day-open-scaffold.sh
# (test_issue_924 compares all three copies).
iwe_day_window() {
  local yday="$1" today="$2" b="${3:-}" bm=0 em
  if [[ "$b" =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
    bm=$(( 10#${BASH_REMATCH[1]} * 60 + 10#${BASH_REMATCH[2]} ))
  fi
  if [ "$bm" -eq 0 ]; then
    printf '%s 00:00:00|%s 23:59:59' "$yday" "$yday"
    return 0
  fi
  em=$(( bm - 1 ))
  printf '%s %02d:%02d:00|%s %02d:%02d:59' \
    "$yday" $(( bm / 60 )) $(( bm % 60 )) "$today" $(( em / 60 )) $(( em % 60 ))
}
DAY_WINDOW=$(iwe_day_window "$CLOSE_DATE" "$NEXT_DATE" "$DAY_BOUNDARY")

# MEMORY.md location: workspace symlink first, auto-memory glob as fallback.
memory_files() {
  if [ -f "$WORKSPACE_DIR/memory/MEMORY.md" ]; then
    echo "$WORKSPACE_DIR/memory/MEMORY.md"
  else
    ls "$HOME"/.claude/projects/*/memory/MEMORY.md 2>/dev/null
  fi
}

dirty_scan() {
  if [ -x "$IWE_TEMPLATE/scripts/check-dirty-repos.sh" ]; then
    bash "$IWE_TEMPLATE/scripts/check-dirty-repos.sh" 2>/dev/null
  else
    local d n
    for d in "$WORKSPACE_DIR"/*/; do
      [ -d "$d/.git" ] || continue
      n=$(git -C "$d" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
      [ "$n" -gt 0 ] && echo "dirty: $(basename "$d") ($n files)"
    done
    echo "(fallback scan — top-level repos only)"
  fi
}

# ---------------------------------------------------------------- --verify --
# Postcondition patterns mirror SKILL.md step 9 (language-tolerant, 1c62621):
# 9a "Итоги дня|Day summary", 9b "Итоги|Сводка|Results" + day number.
if $VERIFY; then
  FAIL=0

  DP="$GOV/archive/day-plans/DayPlan $CLOSE_DATE.md"
  if [ -f "$DP" ] && grep -qE "Итоги дня|Day summary" "$DP" && grep -q "$CLOSE_DATE" "$DP"; then
    echo "9a OK: day summary present in archived DayPlan $CLOSE_DATE"
  else
    echo "9a FAIL: no day summary in $DP (file missing, not archived, or summary heading absent)"
    FAIL=1
  fi

  if grep -lE "(Итоги|Сводка|Results).*${DAY_NUM}" "$GOV/current/"WeekReport*.md >/dev/null 2>&1 \
     || grep -lE "(Итоги|Сводка|Results).*${DAY_NUM}" "$GOV/current/"WeekPlan*.md >/dev/null 2>&1; then
    echo "9b OK: day results found in WeekReport (or WeekPlan fallback)"
  else
    echo "9b FAIL: day results not found in WeekReport or WeekPlan"
    FAIL=1
  fi

  DIRTY=$(dirty_scan)
  if echo "$DIRTY" | grep -qE "⚠️|dirty:"; then
    echo "dirty FAIL:"
    echo "$DIRTY"
    FAIL=1
  else
    echo "dirty OK: all repos clean and pushed"
  fi

  exit $FAIL
fi

# ----------------------------------------------------------------- digest --
echo "=== DAY CLOSE DIGEST $CLOSE_DATE (now $(date '+%Y-%m-%d %H:%M'), date from: $DATE_SOURCE) ==="
# Hint only, never a guess: without day_boundary the clock decides, and in the
# small hours that is usually the day after the one being closed.
if [ "$DATE_SOURCE" = "clock" ] && [ -z "$DAY_BOUNDARY" ] && [ "$(( 10#$(date +%H) ))" -lt 6 ]; then
  echo "⚠️ после полуночи: если закрываешь вчерашний день — перезапусти с --date $(shift_date "$CLOSE_DATE" -1) или задай day_boundary"
fi

echo "--- 1. COMMITS TODAY (filtered) ---"
FOUND=0
for d in "$WORKSPACE_DIR"/*/; do
  [ -d "$d/.git" ] || continue
  commits=$(git -C "$d" log --since="${DAY_WINDOW%%|*}" --until="${DAY_WINDOW##*|}" \
    --oneline --no-merges 2>/dev/null \
    | grep -vE "^[a-f0-9]+ (docs|chore|ci|style|perf|test)(\(|:| )" \
    | grep -vE "memory/|\.claude/rules/|template-sync|backup|reindex" || true)
  if [ -n "$commits" ]; then
    echo "=== $(basename "$d") ==="
    echo "$commits"
    FOUND=1
  fi
done
[ "$FOUND" -eq 0 ] && echo "(no substantive commits on $CLOSE_DATE)"

echo "--- 2. DIRTY REPOS ---"
dirty_scan

echo "--- 3. OPEN SESSIONS LOG ---"
# The log is append-only history (issue #1266): head showed the oldest lines.
# Show today's openings; lines start with "YYYY-MM-DD HH:MM |".
if [ -s "$GOV/inbox/open-sessions.log" ]; then
  grep "^$CLOSE_DATE " "$GOV/inbox/open-sessions.log" || echo "(no sessions opened on $CLOSE_DATE)"
else
  echo "(empty or absent)"
fi

echo "--- 4. MEMORY DRIFT ---"
HITS=""
for m in $(memory_files); do
  H=$(grep -nE "→ ждёт|ждёт|dep:|блокер|blocked:|остановлен|ждёт согласования|waiting on|blocked by" "$m" 2>/dev/null || true)
  [ -n "$H" ] && HITS="$HITS$m:
$H
"
done
if [ -n "$HITS" ]; then echo "$HITS"; else echo "(no drift patterns found)"; fi

echo "--- 5. INDEX HEALTH ---"
IH="$IWE_TEMPLATE/.claude/scripts/check-index-health.py"
if [ -f "$IH" ]; then
  python3 "$IH" 2>&1 | head -60
else
  echo "skip: check-index-health.py not found"
fi

echo "--- 6. LESSON / MEMORY STATS ---"
for m in $(memory_files); do
  [ -f "$m" ] || continue
  LINES=$(wc -l < "$m" | tr -d ' ')
  # issue #1314: the "lessons_" filename grep always counted against a section
  # ("Уроки" in MEMORY.md) that no longer exists under the frontmatter-based
  # memory scheme (memory/memory-lifecycle-spec.md) -- it printed a number but
  # no close protocol ever acted on it. memory-bleed.sh --hot-only is the real,
  # already-wired signal (same one Week/Month Close already run for their own
  # cadence); reuse it here instead of a second, disconnected counter.
  # --hot-only still prints the (unconditional) orphan-files warning before the
  # HOT-limit line when any memory/*.md lacks frontmatter -- a plain "first ###
  # line" grep picked that warning up instead of the HOT status (cold-review).
  BLEED_HOT=$(bash "$IWE_TEMPLATE/scripts/memory-bleed.sh" --hot-only --dir "$(dirname "$m")" 2>/dev/null | grep -E '^### .*HOT-лимит' | head -1)
  echo "MEMORY.md: $LINES lines (flag if >200). ${BLEED_HOT:-memory-bleed.sh: нет данных}"
done

echo "--- 7. WAKATIME ---"
# Summaries endpoint, not `wakatime-cli --today` (issues #859, #1414):
# scripts/wakatime-day-total.py prints seconds, or a reason in parentheses.
if ! WAKA_PY=$(bash "$SCRIPT_DIR/lib/find-python3.sh" --stdlib-only); then
  echo "(python3 not found — use Neon fallback: domain_event coding_time)"
elif WAKA_OUT=$("$WAKA_PY" "$SCRIPT_DIR/wakatime-day-total.py" "$CLOSE_DATE"); then
  awk -v s="$WAKA_OUT" 'BEGIN { printf "%.2f h (WakaTime summaries)\n", s / 3600 }'
else
  echo "$WAKA_OUT"
fi

echo "--- 8. PEER SESSIONS TODAY ---"
if [ -f "$GOV/sessions/00-index.md" ]; then
  grep "$CLOSE_DATE" "$GOV/sessions/00-index.md" || echo "(none on $CLOSE_DATE)"
else
  echo "(no sessions index)"
fi

echo "--- 9. DAYPLANS IN current/ (to archive) ---"
ls "$GOV/current/"DayPlan*.md 2>/dev/null || echo "(none — already archived)"

echo "--- 10. DONE WP CONTEXTS IN inbox/ (to archive) ---"
# ^status matches only the top-level frontmatter key; indented phase entries
# don't count. Both layouts supported: inbox/WP-N.md and inbox/WP-N/WP-N.md.
grep -lE "^status: (done|closed)" "$GOV/inbox/"WP-*.md "$GOV/inbox/"WP-*/WP-*.md 2>/dev/null || echo "(none)"

echo "--- 11. WEEKREPORT ---"
ls "$GOV/current/"WeekReport*.md 2>/dev/null || echo "(absent — fallback: write day facts to WeekPlan, flag for split)"

echo "=== END DIGEST ==="
