#!/bin/bash
# validate-event.sh — проверяльщик формы события контракта цикла стратегирования
# see: extensions/strategy-cycle/SPEC.md §3, живая приёмка WP-518
#   (сессия 2026-08-16-22-wp518-strategy-cycle-acceptance)
#
# Назначение: механически проверить, что YAML-блок события (producer любого
# закрытия/сверки) содержит все 5 обязательных полей контракта в валидной
# форме — до того, как его прочитает consumer (пакет решений §4 или шаг
# strategy-session-weekly). Не проверяет смысл summary и не ограничивает
# список event_type — SPEC.md §3 намеренно держит его открытым для новых
# producer'ов (см. п.3 обсуждения приёмки).
#
# Портируемость: только POSIX awk/grep (см. coordination-pattern-weekly-stats.sh —
# та же норма для скриптов этого контракта).
#
# Использование:
#   bash validate-event.sh <file>   # ищет блок полей в файле, печатает вердикт
#
# Exit: 0 = валиден, 1 = невалиден (список причин в stderr), 2 = usage error.

set -uo pipefail

if [ $# -ne 1 ] || [ ! -f "$1" ]; then
  echo "Использование: validate-event.sh <файл с YAML-блоком события>" >&2
  exit 2
fi

FILE="$1"
ERRORS=0

get_field() {
  # Первое совпадение поля верхнего уровня — не в глубине другого блока,
  # значение до конца строки, без внешних кавычек.
  awk -v key="$1" '
    $0 ~ "^" key ":" {
      sub("^" key ":[ \t]*", "")
      gsub(/^"|"$/, "")
      print
      exit
    }
  ' "$FILE"
}

require_nonempty() {
  local name="$1" value="$2"
  if [ -z "$value" ]; then
    echo "ERROR: поле '$name' отсутствует или пусто" >&2
    ERRORS=$((ERRORS + 1))
  fi
}

EVENT_TYPE=$(get_field "event_type")
SOURCE=$(get_field "source")
PERIOD=$(get_field "period")
SUMMARY=$(get_field "summary")
REQUIRES=$(get_field "requires_pilot_decision")

require_nonempty "event_type" "$EVENT_TYPE"
require_nonempty "source" "$SOURCE"
require_nonempty "period" "$PERIOD"
require_nonempty "summary" "$SUMMARY"

if [ "$REQUIRES" != "true" ] && [ "$REQUIRES" != "false" ]; then
  echo "ERROR: поле 'requires_pilot_decision' должно быть буквально 'true' или 'false', получено: '${REQUIRES:-<пусто>}'" >&2
  ERRORS=$((ERRORS + 1))
fi

if [ -n "$PERIOD" ]; then
  DATE_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
  RANGE_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}\.\.[0-9]{4}-[0-9]{2}-[0-9]{2}$'
  if ! echo "$PERIOD" | grep -qE "$DATE_RE" && ! echo "$PERIOD" | grep -qE "$RANGE_RE"; then
    echo "ERROR: поле 'period' должно быть датой ГГГГ-ММ-ДД или диапазоном ГГГГ-ММ-ДД..ГГГГ-ММ-ДД, получено: '$PERIOD'" >&2
    ERRORS=$((ERRORS + 1))
  fi
fi

if [ "$ERRORS" -eq 0 ]; then
  echo "OK: событие валидно (event_type=$EVENT_TYPE, period=$PERIOD)"
  exit 0
fi

echo "НЕВАЛИДНО: $ERRORS ошибок(а) — см. выше" >&2
exit 1
