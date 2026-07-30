#!/usr/bin/env bash
# routing: helper  skill=week-close  called-by=sonnet
# see DP.SC.159, DP.ROLE.059
# week-draft-init.sh — создать пустой черновик недельного поста для новой недели.
#
# Использование:
#   week-draft-init.sh              # текущая неделя
#   week-draft-init.sh --week 17    # явная неделя
#
# Запускается на Пн Day Close (первая запись дня недели).
# Если черновик уже существует — выходит без изменений.
#
# Параметры (params.yaml):
#   knowledge_repo: <path относительно WORKSPACE_DIR>  # путь к knowledge-index репо
# Если не задан — скрипт пропускается с подсказкой.

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

# Вычисляем даты Пн-Вс текущей ISO-недели
# Баг-фикс 24.07: "monday this week"/"sunday this week" в GNU date не якорятся на текущую
# календарную неделю — это "следующее вхождение дня недели", которое зависит от того, прошёл
# ли этот день недели уже сегодня. В пятницу (%u=5) Пн (день 1) уже прошёл → "monday this week"
# прыгает на СЛЕДУЮЩИЙ понедельник, а Вс (день 7) ещё не наступило → "sunday this week" остаётся
# в ТЕКУЩЕЙ неделе — на выходе несогласованный диапазон (напр. «27-26 июля», Пн из будущей недели
# + Вс из текущей). Фикс: то же смещение в днях от сегодня, что уже верно работает в ветке -v (BSD).
MON_DATE=$(date -v-$(($(date +%u)-1))d +%Y-%m-%d 2>/dev/null || date -d "today - $(($(date +%u)-1)) days" +%Y-%m-%d)
SUN_DATE=$(date -v+$((7-$(date +%u)))d +%Y-%m-%d 2>/dev/null || date -d "today + $((7-$(date +%u))) days" +%Y-%m-%d)

# issue #155: || fallback на GNU date (Linux) — иначе date -j падает, 2>/dev/null глушит, день пустой
MON_DAY=$(date -j -f %Y-%m-%d "$MON_DATE" +%d 2>/dev/null || date -d "$MON_DATE" +%d 2>/dev/null); MON_DAY=${MON_DAY#0}
SUN_DAY=$(date -j -f %Y-%m-%d "$SUN_DATE" +%d 2>/dev/null || date -d "$SUN_DATE" +%d 2>/dev/null); SUN_DAY=${SUN_DAY#0}
MONTH_FOR_DATES="${MONTH_NAME:0:3}"

# Генерируем строки таблицы метрик с датами Пн-Вс (WD1 fix: совместимость с week-draft-append.sh)
DOW_RU=("Пн" "Вт" "Ср" "Чт" "Пт" "Сб" "Вс")
TABLE_ROWS=""
for i in 0 1 2 3 4 5 6; do
  day_date=$(date -v+${i}d -j -f %Y-%m-%d "$MON_DATE" +%Y-%m-%d 2>/dev/null || date -d "$MON_DATE + $i days" +%Y-%m-%d)
  # issue #245: `||` за пайпом на sed не срабатывал, если падал только `date -j` (GNU date) —
  # sed на пустом вводе завершается успешно, поэтому фолбэк никогда не запускался.
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
