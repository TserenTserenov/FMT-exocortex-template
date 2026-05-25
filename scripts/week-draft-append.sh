#!/usr/bin/env bash
# routing: helper  skill=week-close  called-by=sonnet
# see DP.SC.159, DP.ROLE.059
# week-draft-append.sh — обновить метрики текущего дня в черновике недельного поста.
#
# Собирает: WakaTime (--today), коммиты (all repos, since today 00:00),
# закрытые РП (из коммитов "close/done WP-NNN").
#
# Использование:
#   week-draft-append.sh              # текущий день, текущая неделя
#   week-draft-append.sh --week 16    # явная неделя
#   week-draft-append.sh --dry-run    # показать, но не писать
#
# Параметры (params.yaml):
#   knowledge_repo: <path относительно WORKSPACE_DIR>  # путь к knowledge-index репо
# Если не задан — скрипт пропускается с подсказкой.

set -euo pipefail

WORKSPACE="${WORKSPACE_DIR:-$HOME/IWE}"
WAKATIME_CLI="${WAKATIME_CLI:-$HOME/.wakatime/wakatime-cli}"

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
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --week) WEEK_ARG="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

TODAY_ISO=$(date +%Y-%m-%d)
DOW=$(date +%u)
DOM=$(date +%d)
MONTH_NUM=$(date +%m)
YEAR=$(date +%Y)

DOW_RU=("Пн" "Вт" "Ср" "Чт" "Пт" "Сб" "Вс")
DOW_LABEL="${DOW_RU[$((DOW-1))]} ${DOM#0}"

WEEK=${WEEK_ARG:-$(date +%V)}

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

# 1. WakaTime
WAKA="—"
if [[ -x "$WAKATIME_CLI" ]]; then
  WAKA=$("$WAKATIME_CLI" --today 2>/dev/null | awk -F'[ ,]' '{
    total=0
    for(i=1;i<=NF;i++){
      if($i=="hrs"||$i=="hr") total += $(i-2)*60 + ($(i-1)=="and"?0:$(i-1))
      else if($i=="mins"||$i=="min") total += $(i-1)
    }
    if(total>=60) printf "%dh %02dmin", int(total/60), total%60
    else printf "%dmin", total
  }')
  [[ -z "$WAKA" ]] && WAKA="—"
fi

# 2. Commits across all repos since today 00:00
COMMITS=0
for repo in "$WORKSPACE"/*/; do
  if [[ -d "${repo}.git" ]]; then
    count=$(git -C "$repo" log --since="today 00:00" --oneline --no-merges 2>/dev/null | wc -l | tr -d ' ')
    COMMITS=$((COMMITS + count))
  fi
done

# 3. Closed WPs today (best effort — by commit message)
WPS_CLOSED=0
for repo in "$WORKSPACE"/*/; do
  if [[ -d "${repo}.git" ]]; then
    count=$(git -C "$repo" log --since="today 00:00" --pretty=%s 2>/dev/null | grep -ciE "(close|done|complete).*(wp-|WP-)[0-9]+" || true)
    WPS_CLOSED=$((WPS_CLOSED + count))
  fi
done

# Поля «Бюджет закрыт» и «Прогресс месяца» — для ручного заполнения
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
