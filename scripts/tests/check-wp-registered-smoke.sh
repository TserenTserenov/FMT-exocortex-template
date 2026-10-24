#!/usr/bin/env bash
# Behavioural tests for scripts/check-wp-registered.sh (issue #1257).
# Each case builds a real governance fixture and asserts exit code + message.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CHECK="$ROOT/scripts/check-wp-registered.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAILS=0

# new_fixture <dir>: empty registry + plan, no cards
new_fixture() {
  mkdir -p "$1/docs" "$1/current" "$1/inbox"
  printf '%s\n' '| # | P | Название | Ст | Репо | Бюджет |' '|---|---|----------|----|------|--------|' > "$1/docs/WP-REGISTRY.md"
  printf '%s\n' '# WeekPlan W1' '' '| 🚦 | # | РП | h | Источник | P | Статус | Результат |' \
    '|----|---|-----|---|----------|---|--------|-----------|' > "$1/current/WeekPlan W1.md"
}

add_card() { # dir number title [wp-field]
  mkdir -p "$1/inbox/WP-$(printf '%03d' "$2")"
  printf -- '---\nwp: %s\ntitle: "%s"\n---\n' "${4:-$2}" "$3" > "$1/inbox/WP-$(printf '%03d' "$2")/WP-$(printf '%03d' "$2").md"
}
add_registry() { printf '| %s | P2 | **%s** | ⏳ | DS | 1h |\n' "$2" "$3" >> "$1/docs/WP-REGISTRY.md"; }
add_plan() { printf '| 🟡 | %s | %s | 1 | ПС | P2 | pending | — |\n' "$2" "$3" >> "$1/current/WeekPlan W1.md"; }

# expect <name> <want-rc> <want-substring-in-output> -- <args...>
expect() {
  local name=$1 want_rc=$2 want_msg=$3
  shift 4
  local out rc
  out=$(bash "$CHECK" "$@" 2>&1); rc=$?
  if [ "$rc" -ne "$want_rc" ] || ! printf '%s' "$out" | grep -qF -- "$want_msg"; then
    echo "FAIL: $name (rc=$rc, want $want_rc; want «${want_msg}»)"; printf '%s\n' "$out" | sed 's/^/    /'
    FAILS=$((FAILS + 1))
  else
    echo "PASS: $name"
  fi
}

# --- success and number equivalence ---
G="$TMP/ok"; new_fixture "$G"; add_card "$G" 1 "Первый"; add_registry "$G" 1 "Первый"; add_plan "$G" 1 "Первый"
PLAN="$G/current/WeekPlan W1.md"
for form in 1 WP-1 WP-001; do
  expect "эквивалентность $form" 0 "согласованы" -- "$form" "$G" "$PLAN"
done

# --- WP-1 is not WP-10 ---
G="$TMP/sub"; new_fixture "$G"; add_card "$G" 1 "Первый"; add_registry "$G" 10 "Первый"; add_plan "$G" 10 "Первый"
expect "WP-1 не находит WP-10" 1 "в реестре строк с номером 1: 0" -- 1 "$G" "$G/current/WeekPlan W1.md"
G="$TMP/sub2"; new_fixture "$G"; add_card "$G" 10 "Десятый"; add_registry "$G" 1 "Десятый"; add_plan "$G" 1 "Десятый"
expect "WP-10 не находит WP-1" 1 "в таблице «План»" -- 10 "$G" "$G/current/WeekPlan W1.md"

# --- missing card, wrong wp field, title mismatch ---
G="$TMP/nocard"; new_fixture "$G"; add_registry "$G" 1 "Первый"; add_plan "$G" 1 "Первый"
expect "нет карточки" 1 "нет карточки" -- 1 "$G" "$G/current/WeekPlan W1.md"
G="$TMP/badwp"; new_fixture "$G"; add_card "$G" 1 "Первый" 2; add_registry "$G" 1 "Первый"; add_plan "$G" 1 "Первый"
expect "неверное поле wp" 1 "поле wp карточки равно" -- 1 "$G" "$G/current/WeekPlan W1.md"
G="$TMP/badtitle"; new_fixture "$G"; add_card "$G" 1 "Первый"; add_registry "$G" 1 "Другое"; add_plan "$G" 1 "Первый"
expect "название в реестре не совпадает" 1 "название в реестре" -- 1 "$G" "$G/current/WeekPlan W1.md"
G="$TMP/badtitle2"; new_fixture "$G"; add_card "$G" 1 "Первый"; add_registry "$G" 1 "Первый"; add_plan "$G" 1 "Другое"
expect "название в плане не совпадает" 1 "название в плане" -- 1 "$G" "$G/current/WeekPlan W1.md"

# --- missing rows ---
G="$TMP/norow"; new_fixture "$G"; add_card "$G" 1 "Первый"; add_plan "$G" 1 "Первый"
expect "нет строки реестра" 1 "в реестре строк с номером 1: 0" -- 1 "$G" "$G/current/WeekPlan W1.md"
G="$TMP/noplan"; new_fixture "$G"; add_card "$G" 1 "Первый"; add_registry "$G" 1 "Первый"
expect "нет строки плана" 1 "в таблице «План»" -- 1 "$G" "$G/current/WeekPlan W1.md"

# --- duplicates ---
G="$TMP/dupreg"; new_fixture "$G"; add_card "$G" 1 "Первый"; add_registry "$G" 1 "Первый"; add_registry "$G" WP-001 "Первый"; add_plan "$G" 1 "Первый"
expect "дубль в реестре" 1 "в реестре строк с номером 1: 2" -- 1 "$G" "$G/current/WeekPlan W1.md"
G="$TMP/dupplan"; new_fixture "$G"; add_card "$G" 1 "Первый"; add_registry "$G" 1 "Первый"; add_plan "$G" 1 "Первый"; add_plan "$G" 1 "Первый"
expect "дубль в плане" 1 "строк с номером 1: 2" -- 1 "$G" "$G/current/WeekPlan W1.md"

# --- mention outside the plan table is not a record ---
G="$TMP/outside"; new_fixture "$G"; add_card "$G" 1 "Первый"; add_registry "$G" 1 "Первый"
{ printf '\nЗаметка: РП 1 «Первый» обсуждали вчера.\n\n## Итоги дня\n\n| РП | Что сделано | Статус |\n|----|----|----|\n| 1 | Первый | done |\n'; } >> "$G/current/WeekPlan W1.md"
expect "упоминание вне таблицы «План»" 1 "в таблице «План»" -- 1 "$G" "$G/current/WeekPlan W1.md"

# --- partial creation → fails, then passes after completion; number unchanged ---
G="$TMP/partial"; new_fixture "$G"; add_card "$G" 7 "Частичный"; add_plan "$G" 7 "Частичный"
expect "частичное создание: реестра нет" 1 "в реестре строк с номером 7: 0" -- 7 "$G" "$G/current/WeekPlan W1.md"
add_registry "$G" 7 "Частичный"
expect "после дозаписи проходит" 0 "согласованы" -- 7 "$G" "$G/current/WeekPlan W1.md"
if [ "$(find "$G/inbox" -name 'WP-*.md' | wc -l | tr -d ' ')" = 1 ]; then
  echo "PASS: номер не менялся (одна карточка)"
else
  echo "FAIL: после дозаписи появилась лишняя карточка"; FAILS=$((FAILS + 1))
fi

# --- alternative plan layout: no «#», number as WP-N in «РП», title in «Работа» ---
alt_fixture() {
  new_fixture "$1"
  printf '%s\n' '# WeekPlan W1' '' '## План' '' '| 🚦 | РП | Работа | Часы | Источник | Ставка | Статус | Репо |' \
    '|----|----|--------|------|----------|--------|--------|------|' > "$1/current/WeekPlan W1.md"
}
G="$TMP/alt"; alt_fixture "$G"; add_card "$G" 5 "Альтернативный"; add_registry "$G" 5 "Альтернативный"
printf '| 🟡 | WP-5 | Альтернативный | 1 | ПС | — | pending | DS |\n' >> "$G/current/WeekPlan W1.md"
expect "раскладка без «#»: успех" 0 "согласованы" -- 5 "$G" "$G/current/WeekPlan W1.md"
G="$TMP/altmiss"; alt_fixture "$G"; add_card "$G" 5 "Альтернативный"; add_registry "$G" 5 "Альтернативный"
printf '| 🟡 | WP-6 | Чужой | 1 | ПС | — | pending | DS |\n' >> "$G/current/WeekPlan W1.md"
expect "раскладка без «#»: нет строки" 1 "в таблице «План»" -- 5 "$G" "$G/current/WeekPlan W1.md"

# --- case-insensitive prefix and bold headers ---
G="$TMP/lower"; new_fixture "$G"; add_card "$G" 12 "Нижний"; add_registry "$G" wp-12 "Нижний"; add_plan "$G" wp-12 "Нижний"
expect "префикс wp-12 в нижнем регистре" 0 "согласованы" -- 12 "$G" "$G/current/WeekPlan W1.md"
G="$TMP/bold"; new_fixture "$G"; add_card "$G" 1 "Первый"
printf '%s\n' '| **#** | P | **Название** | Ст | Репо | Бюджет |' '|---|---|---|---|---|---|' > "$G/docs/WP-REGISTRY.md"
add_registry "$G" 1 "Первый"; add_plan "$G" 1 "Первый"
printf '%s\n' '| **🚦** | **#** | **РП** | h | Источник | P | **Статус** | Результат |' '|---|---|---|---|---|---|---|---|' > "$G/current/WeekPlan W1.md"
add_plan "$G" 1 "Первый"
expect "жирные заголовки реестра и плана" 0 "согласованы" -- 1 "$G" "$G/current/WeekPlan W1.md"

# --- a column index must not leak from a previous table ---
G="$TMP/leak"; new_fixture "$G"; add_card "$G" 1 "Первый"; add_registry "$G" 1 "Первый"; add_plan "$G" 1 "Первый"
printf '\n| Статус | Расшифровка |\n|---|---|\n| 1 | done |\n' >> "$G/docs/WP-REGISTRY.md"
expect "колонка номера не тянется из прошлой таблицы" 0 "согласованы" -- 1 "$G" "$G/current/WeekPlan W1.md"

# --- «План» wins over another candidate table with the same РП ---
G="$TMP/two"; new_fixture "$G"; add_card "$G" 1 "Первый"; add_registry "$G" 1 "Первый"
printf '%s\n' '# WeekPlan W1' '' '## План' '' '| 🚦 | # | РП | h | Источник | P | Статус | Результат |' '|---|---|---|---|---|---|---|---|' > "$G/current/WeekPlan W1.md"
add_plan "$G" 1 "Первый"
printf '\n## Перенос\n\n| 🚦 | # | РП | h | Источник | P | Статус | Результат |\n|---|---|---|---|---|---|---|---|\n' >> "$G/current/WeekPlan W1.md"
add_plan "$G" 1 "Первый"
expect "таблицы «План» и «Перенос»" 0 "согласованы" -- 1 "$G" "$G/current/WeekPlan W1.md"
G="$TMP/twodup"; new_fixture "$G"; add_card "$G" 1 "Первый"; add_registry "$G" 1 "Первый"
printf '%s\n' '## План' '' '| 🚦 | # | РП | h | Источник | P | Статус | Результат |' '|---|---|---|---|---|---|---|---|' > "$G/current/WeekPlan W1.md"
add_plan "$G" 1 "Первый"; add_plan "$G" 1 "Первый"
printf '\n## Перенос\n\n| 🚦 | # | РП | h | Источник | P | Статус | Результат |\n|---|---|---|---|---|---|---|---|\n' >> "$G/current/WeekPlan W1.md"
add_plan "$G" 1 "Первый"
expect "дубль внутри «План» при таблице «Перенос»" 1 "строк с номером 1: 2" -- 1 "$G" "$G/current/WeekPlan W1.md"

# A row in «Перенос» cannot replace a missing row in the existing «План» table.
G="$TMP/planmiss"; new_fixture "$G"; add_card "$G" 1 "Первый"; add_registry "$G" 1 "Первый"
printf '%s\n' '## План' '' '| 🚦 | # | РП | h | Источник | P | Статус | Результат |' \
  '|---|---|---|---|---|---|---|---|' '| — | — | — | — | — | — | — | — |' '' \
  '## Перенос' '' '| 🚦 | # | РП | h | Источник | P | Статус | Результат |' \
  '|---|---|---|---|---|---|---|---|' > "$G/current/WeekPlan W1.md"
add_plan "$G" 1 "Первый"
expect "пустой План не заменяется Переносом" 1 "в таблице «План»" -- 1 "$G" "$G/current/WeekPlan W1.md"

# A matching title in another column does not repair the wrong title cell.
G="$TMP/regtitle"; new_fixture "$G"; add_card "$G" 1 "Первый"; add_plan "$G" 1 "Первый"
printf '| 1 | P2 | **Другое** | ⏳ | Первый | 1h |\n' >> "$G/docs/WP-REGISTRY.md"
expect "название в репозитории не заменяет название реестра" 1 "название в реестре" -- 1 "$G" "$G/current/WeekPlan W1.md"
G="$TMP/plantitle"; new_fixture "$G"; add_card "$G" 1 "Первый"; add_registry "$G" 1 "Первый"
printf '| 🟡 | 1 | Другое | 1 | ПС | P2 | pending | Первый |\n' >> "$G/current/WeekPlan W1.md"
expect "название в результате не заменяет название плана" 1 "название в плане" -- 1 "$G" "$G/current/WeekPlan W1.md"

# --- long title: the registry cuts it to 80 characters ---
LONG="Очень длинное название рабочего продукта которое заведомо превышает восемьдесят символов и режется реестром"
G="$TMP/long"; new_fixture "$G"; add_card "$G" 1 "$LONG"
add_registry "$G" 1 "${LONG:0:80}"; add_plan "$G" 1 "$LONG"
expect "длинное название: реестр режет до 80" 0 "согласованы" -- 1 "$G" "$G/current/WeekPlan W1.md"

# --- bad arguments ---
expect "неверный номер" 2 "Неверный номер" -- abc "$G" "$G/current/WeekPlan W1.md"
expect "нет аргументов" 2 "Использование" --

[ "$FAILS" -eq 0 ] || { echo "$FAILS failed"; exit 1; }
echo "all passed"
