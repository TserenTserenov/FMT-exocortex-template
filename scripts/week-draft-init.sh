#!/usr/bin/env bash
# routing: helper  skill=week-close  called-by=sonnet
# see DP.SC.159, DP.ROLE.059
# week-draft-init.sh -- create an empty weekly post draft for a new week.
#
# Usage:
#   week-draft-init.sh              # current week
#   week-draft-init.sh --week 17    # explicit week
#
# Runs on Monday Day Close (first entry of the week day).
# If the draft already exists -- exits without changes.
#
# Parameters (params.yaml):
#   knowledge_repo: <path relative to WORKSPACE_DIR>  # path to the knowledge-index repo
# If not set -- the script is skipped with a hint.

set -euo pipefail

WORKSPACE="${WORKSPACE_DIR:-$HOME/IWE}"

PARAMS_FILE="${WORKSPACE}/params.yaml"
KNOWLEDGE_REPO_REL=""
if [[ -f "$PARAMS_FILE" ]]; then
  KNOWLEDGE_REPO_REL=$(grep -E "^knowledge_repo:" "$PARAMS_FILE" | sed 's/^knowledge_repo:[[:space:]]*//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//' || echo "")
fi

if [[ -z "$KNOWLEDGE_REPO_REL" ]]; then
  echo "ℹ️ week-draft-init.sh: параметр knowledge_repo не задан в params.yaml — пропуск"
  echo "   Чтобы включить накопительный черновик недельного поста, добавь в params.yaml:"
  echo "   knowledge_repo: \"DS-Knowledge-Index\""
  exit 0
fi

KNOWLEDGE="${WORKSPACE}/${KNOWLEDGE_REPO_REL}"
if [[ ! -d "$KNOWLEDGE" ]]; then
  echo "⚠️ week-draft-init.sh: knowledge_repo не найден: $KNOWLEDGE" >&2
  exit 1
fi

WEEK_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --week) WEEK_ARG="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

YEAR=$(date +%Y)
MONTH_NUM=$(date +%m)
WEEK=${WEEK_ARG:-$(date +%V)}

MONTH_REVERSE=$((13 - 10#$MONTH_NUM))
MONTH_REVERSE_PADDED=$(printf "%02d" "$MONTH_REVERSE")
MONTH_NAME_RU=("январь" "февраль" "март" "апрель" "май" "июнь" "июль" "август" "сентябрь" "октябрь" "ноябрь" "декабрь")
MONTH_NAME="${MONTH_NAME_RU[$((10#$MONTH_NUM-1))]}"

DRAFT_DIR="${KNOWLEDGE}/docs/${YEAR}/${MONTH_REVERSE_PADDED}-${MONTH_NAME}"
DRAFT_FILE="${DRAFT_DIR}/week-draft-w${WEEK}.md"

if [[ -f "$DRAFT_FILE" ]]; then
  echo "Черновик уже существует: $DRAFT_FILE"
  exit 0
fi

mkdir -p "$DRAFT_DIR"

# Compute the Mon-Sun dates of the current ISO week
# Bug fix 24.07: "monday this week"/"sunday this week" in GNU date do not anchor to the current
# calendar week -- it is "the next occurrence of the weekday", which depends on whether
# that weekday has already passed today. On Friday (%u=5) Mon (day 1) has already passed → "monday this week"
# jumps to the NEXT Monday, while Sun (day 7) has not yet come → "sunday this week" stays
# in the CURRENT week -- the output is an inconsistent range (e.g. "27-26 July", Mon from a future week
# + Sun from the current). Fix: the same offset in days from today that already works correctly in the -v branch (BSD).
MON_DATE=$(date -v-$(($(date +%u)-1))d +%Y-%m-%d 2>/dev/null || date -d "today - $(($(date +%u)-1)) days" +%Y-%m-%d)
SUN_DATE=$(date -v+$((7-$(date +%u)))d +%Y-%m-%d 2>/dev/null || date -d "today + $((7-$(date +%u))) days" +%Y-%m-%d)

# issue #155: || fallback to GNU date (Linux) -- otherwise date -j fails, 2>/dev/null silences it, the day is empty
MON_DAY=$(date -j -f %Y-%m-%d "$MON_DATE" +%d 2>/dev/null || date -d "$MON_DATE" +%d 2>/dev/null); MON_DAY=${MON_DAY#0}
SUN_DAY=$(date -j -f %Y-%m-%d "$SUN_DATE" +%d 2>/dev/null || date -d "$SUN_DATE" +%d 2>/dev/null); SUN_DAY=${SUN_DAY#0}
MONTH_FOR_DATES="${MONTH_NAME:0:3}"

# Generate the metrics table rows with Mon-Sun dates (WD1 fix: compatibility with week-draft-append.sh)
DOW_RU=("Пн" "Вт" "Ср" "Чт" "Пт" "Сб" "Вс")
TABLE_ROWS=""
for i in 0 1 2 3 4 5 6; do
  day_date=$(date -v+${i}d -j -f %Y-%m-%d "$MON_DATE" +%Y-%m-%d 2>/dev/null || date -d "$MON_DATE + $i days" +%Y-%m-%d)
  # issue #245: `||` after a pipe into sed did not fire if only `date -j` (GNU date) failed --
  # sed on empty input succeeds, so the fallback never ran.
  day_num=$(date -j -f %Y-%m-%d "$day_date" +%d 2>/dev/null || date -d "$day_date" +%d 2>/dev/null); day_num=${day_num#0}
  TABLE_ROWS="${TABLE_ROWS}| ${DOW_RU[$i]} ${day_num} | | | | | |"$'\n'
done

cat > "$DRAFT_FILE" <<EOF
---
type: week-draft
week: W${WEEK}
dates: ${MON_DAY}-${SUN_DAY} ${MONTH_FOR_DATES} ${YEAR}
status: draft-internal
created: $(date +%Y-%m-%d)
---

# Черновик недельного поста W${WEEK} (${MON_DAY}-${SUN_DAY} ${MONTH_FOR_DATES} ${YEAR})

> **Назначение:** накопительный черновик для недельного поста. Заполняется каждый день на Day Close.
> **Не публикуется.** На Week Close автор пишет финальный пост на основе этого черновика.
> **Структура:** 4 уровня влияния (мир → сообщество → человек → личное) + метрики + carry-over.

---

## Мир (идеи/принципы универсальные)

> Что из сделанного за день — универсальный подход/принцип, применимый за пределами проекта?

- [Пн] —
- [Вт] —
- [Ср] —
- [Чт] —
- [Пт] —
- [Сб] —
- [Вс] —

## Сообщество (что поможет участникам)

> Что из сделанного может помочь участникам сообщества в их обучении/проектах?

- [Пн] —
- [Вт] —
- [Ср] —
- [Чт] —
- [Пт] —
- [Сб] —
- [Вс] —

## Человек (что один читатель может попробовать прямо сейчас)

> Какой один совет/инструмент/метод из дня читатель может попробовать сегодня?

- [Пн] —
- [Вт] —
- [Ср] —
- [Чт] —
- [Пт] —
- [Сб] —
- [Вс] —

## Личное (что я сам понял / что изменилось)

> Что я сам понял за день? Что у меня изменилось? Честно, без приукрашивания.

- [Пн] —
- [Вт] —
- [Ср] —
- [Чт] —
- [Пт] —
- [Сб] —
- [Вс] —

## Инсайты / находки / цитаты (разное)

> Свободная корзина: фразы, ссылки, сквозные темы недели. ⭐ — пометка кандидата в главный инсайт.

-

## Опубликованные посты недели

-

## Идеи для W$((WEEK + 1)) (carry-over)

-

---

## Метрики недели

| День | WakaTime | Коммиты | Закрыто РП | Бюджет закрыт | Прогресс месяца |
|------|----------|---------|------------|---------------|-----------------|
${TABLE_ROWS}| **Итого W${WEEK}** | | | | | |

---

## Что войдёт в финальный пост (заполняется на Week Close)

### Заголовок (3-5 вариантов)

1.
2.
3.

### Главный инсайт недели

>

### Финал (что дальше, 2-3 предложения)

>

### Итоговая строка-метрики

>
EOF

echo "Создан черновик: $DRAFT_FILE"
