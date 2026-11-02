#!/usr/bin/env bash
# routing: helper  skill=week-close  called-by=sonnet
# see DP.SC.159, DP.ROLE.059
# week-draft-append.sh — update the current day's metrics in the weekly post draft.
#
# Collects for the day being closed: WakaTime (summaries API, fallback —
# wakatime-cli --today, only if the day = today), commits (all repos, within
# the day's bounds), closed WPs (from commits "close/done WP-NNN").
#
# Usage:
#   week-draft-append.sh                       # today, the week of this day
#   week-draft-append.sh --date 2026-10-28     # the day being closed (Day Close after midnight)
#   week-draft-append.sh --week 16             # explicit week
#   week-draft-append.sh --dry-run             # show, but do not write
#
# Parameters (params.yaml):
#   knowledge_repo: <path relative to WORKSPACE_DIR>  # path to the knowledge-index repo
# If not set — the script is skipped with a hint.

set -euo pipefail

WORKSPACE="${WORKSPACE_DIR:-$HOME/IWE}"
WAKATIME_CLI="${WAKATIME_CLI:-$HOME/.wakatime/wakatime-cli}"
if [[ ! -x "$WAKATIME_CLI" ]]; then
  # issue #1151: the VS Code WakaTime extension on Windows downloads the
  # binary as wakatime-cli-windows-amd64.exe, not the bare name above.
  WAKATIME_CLI=$(ls -d "$HOME"/.wakatime/wakatime-cli* 2>/dev/null | head -1 || true)
  WAKATIME_CLI="${WAKATIME_CLI:-$HOME/.wakatime/wakatime-cli}"
fi

PARAMS_FILE="${WORKSPACE}/params.yaml"
KNOWLEDGE_REPO_REL=""
if [[ -f "$PARAMS_FILE" ]]; then
  KNOWLEDGE_REPO_REL=$(grep -E "^knowledge_repo:" "$PARAMS_FILE" | sed 's/^knowledge_repo:[[:space:]]*//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//' || echo "")
fi

if [[ -z "$KNOWLEDGE_REPO_REL" ]]; then
  echo "ℹ️ week-draft-append.sh: knowledge_repo не задан в params.yaml — пропуск"
  exit 0
fi

KNOWLEDGE="${WORKSPACE}/${KNOWLEDGE_REPO_REL}"
if [[ ! -d "$KNOWLEDGE" ]]; then
  echo "⚠️ week-draft-append.sh: knowledge_repo не найден: $KNOWLEDGE" >&2
  exit 1
fi

DRY_RUN=0
WEEK_ARG=""
DATE_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --week) WEEK_ARG="$2"; shift 2 ;;
    --date) DATE_ARG="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# issue #1398: every date field comes from the closed day, not the clock —
# a Day Close after midnight used to write the next day's row and commits.
TODAY_ISO=$(date +%Y-%m-%d)
DAY_ISO="${DATE_ARG:-$TODAY_ISO}"
if ! DAY_FIELDS=$(python3 -c '
import sys
from datetime import date, timedelta
d = date.fromisoformat(sys.argv[1])
monday = d - timedelta(days=d.isoweekday() - 1)
print(d.isoweekday(), d.day, monday.month, monday.year, d.isocalendar()[1])
' "$DAY_ISO" 2>/dev/null); then
  echo "ERR: --date ожидает YYYY-MM-DD, получено: $DAY_ISO" >&2
  exit 2
fi
# MONTH_NUM/YEAR are the week's Monday: week-draft-init.sh creates the draft
# on Monday in that month's folder, so a week across a month boundary keeps
# one draft.
read -r DOW DOM MONTH_NUM YEAR ISO_WEEK <<< "$DAY_FIELDS"

DOW_RU=("Пн" "Вт" "Ср" "Чт" "Пт" "Сб" "Вс")
DOW_LABEL="${DOW_RU[$((DOW-1))]} ${DOM}"

WEEK=${WEEK_ARG:-$(printf "%02d" "$ISO_WEEK")}

MONTH_REVERSE=$((13 - 10#$MONTH_NUM))
MONTH_REVERSE_PADDED=$(printf "%02d" "$MONTH_REVERSE")
MONTH_NAME_RU=("январь" "февраль" "март" "апрель" "май" "июнь" "июль" "август" "сентябрь" "октябрь" "ноябрь" "декабрь")
MONTH_NAME="${MONTH_NAME_RU[$((10#$MONTH_NUM-1))]}"

DRAFT_DIR="${KNOWLEDGE}/docs/${YEAR}/${MONTH_REVERSE_PADDED}-${MONTH_NAME}"
DRAFT_FILE="${DRAFT_DIR}/week-draft-w${WEEK}.md"

if [[ ! -f "$DRAFT_FILE" ]]; then
  echo "ERR: черновик не найден: $DRAFT_FILE" >&2
  echo "Запусти week-draft-init.sh (W${WEEK}) на Пн Day Close." >&2
  exit 1
fi

# 1. WakaTime. Summaries API for the closed day; the CLI answers only for the
# current day and returns an empty line on some installs (issue #1414).
# No value is shown as "—", never as a fabricated 0min (issue #1398).
waka_format() {
  local mins=$1
  if (( mins >= 60 )); then
    printf "%dh %02dmin" $((mins / 60)) $((mins % 60))
  else
    printf "%dmin" "$mins"
  fi
}

# Minutes from `wakatime-cli --today` text such as "4 hrs 22 mins" or
# "Today: 1 hr 5 mins": take the number right before each unit word.
waka_cli_minutes() {
  awk '{
    total = 0
    for (i = 2; i <= NF; i++) {
      unit = $i; gsub(/[^a-z]/, "", unit)
      if (unit == "hrs" || unit == "hr") total += $(i-1) * 60
      else if (unit == "mins" || unit == "min") total += $(i-1)
    }
    print total
  }'
}

WAKA="—"
WAKA_SECONDS="python3 not found"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if WAKA_PY=$(bash "$SCRIPT_DIR/lib/find-python3.sh" --stdlib-only 2>/dev/null) \
   && WAKA_SECONDS=$("$WAKA_PY" "$SCRIPT_DIR/wakatime-day-total.py" "$DAY_ISO"); then
  WAKA=$(waka_format $((WAKA_SECONDS / 60)))
elif [[ "$DAY_ISO" == "$TODAY_ISO" && -x "$WAKATIME_CLI" ]]; then
  WAKA_RAW=$("$WAKATIME_CLI" --today 2>/dev/null || true)
  WAKA_MIN=$(printf '%s\n' "$WAKA_RAW" | waka_cli_minutes)
  if [[ "${WAKA_MIN:-0}" -gt 0 ]]; then
    WAKA=$(waka_format "$WAKA_MIN")
  else
    echo "ℹ️ WakaTime: нет значения (API: ${WAKA_SECONDS}; CLI: «${WAKA_RAW}»)" >&2
  fi
else
  echo "ℹ️ WakaTime: нет значения за ${DAY_ISO} (${WAKA_SECONDS})" >&2
fi

# iwe_repo_dirs — prints subdirectories with .git, deduplicated by real
# physical path (a repo-symlink alias would otherwise be counted as a separate repository
# on a par with the original — an inflated commit count, found 2026-07-17).
iwe_repo_dirs() {
  local repo real seen=""
  for repo in "$@"; do
    [ -d "$repo/.git" ] || continue
    real=$(cd -P "$repo" 2>/dev/null && pwd) || continue
    case " $seen " in
      *" $real "*) continue ;;
    esac
    seen="$seen $real"
    echo "$repo"
  done
}

# 2. Commits across all repos within the closed day
COMMITS=0
while IFS= read -r repo; do
  count=$(git -C "$repo" log --since="$DAY_ISO 00:00:00" --until="$DAY_ISO 23:59:59" --oneline --no-merges 2>/dev/null | wc -l | tr -d ' ')
  COMMITS=$((COMMITS + count))
done < <(iwe_repo_dirs "$WORKSPACE"/*/)

# 3. Closed WPs that day (best effort — by commit message)
WPS_CLOSED=0
while IFS= read -r repo; do
  count=$(git -C "$repo" log --since="$DAY_ISO 00:00:00" --until="$DAY_ISO 23:59:59" --pretty=%s 2>/dev/null | grep -ciE "(close|done|complete).*(wp-|WP-)[0-9]+" || true)
  WPS_CLOSED=$((WPS_CLOSED + count))
done < <(iwe_repo_dirs "$WORKSPACE"/*/)

# The fields "Бюджет закрыт" and "Прогресс месяца" are for manual filling
BUDGET="—"
PROGRESS="—"

NEW_ROW="| ${DOW_LABEL} | ${WAKA} | ${COMMITS} | ${WPS_CLOSED} | ${BUDGET} | ${PROGRESS} |"

echo "== Черновик: $DRAFT_FILE"
echo "== Новая строка:"
echo "$NEW_ROW"
echo

if [[ $DRY_RUN -eq 1 ]]; then
  echo "(dry-run — изменения не записаны)"
  exit 0
fi

if grep -qE "^\| ${DOW_LABEL} \|" "$DRAFT_FILE"; then
  python3 - "$DRAFT_FILE" "$DOW_LABEL" "$NEW_ROW" <<'PYEOF'
import sys, re
path, label, new_row = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    content = f.read()
pattern = re.compile(r"^\| " + re.escape(label) + r" \|[^\n]*$", re.MULTILINE)
if pattern.search(content):
    content = pattern.sub(new_row, content, count=1)
    with open(path, "w") as f:
        f.write(content)
    print(f"OK: строка «{label}» обновлена")
else:
    print(f"ERR: не нашёл строку «{label}»", file=sys.stderr)
    sys.exit(1)
PYEOF
else
  echo "ERR: не нашёл строку для ${DOW_LABEL} в таблице черновика" >&2
  exit 1
fi
