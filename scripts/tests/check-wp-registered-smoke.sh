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
    echo "FAIL: $name (rc=$rc, want $want_rc; want «$want_msg»)"; printf '%s\n' "$out" | sed 's/^/    /'
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

# --- bad arguments ---
expect "неверный номер" 2 "Неверный номер" -- abc "$G" "$G/current/WeekPlan W1.md"
expect "нет аргументов" 2 "Использование" --

[ "$FAILS" -eq 0 ] || { echo "$FAILS failed"; exit 1; }
echo "all passed"
