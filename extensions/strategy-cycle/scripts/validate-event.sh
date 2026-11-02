#!/bin/bash
# validate-event.sh — form checker for a strategy-cycle contract event
# see: extensions/strategy-cycle/SPEC.md §3, live acceptance of WP-518
#   (session 2026-08-16-22-wp518-strategy-cycle-acceptance)
#
# Purpose: mechanically check that the event's YAML block (from a producer of any
# closing/reconciliation) contains all 5 required contract fields in a valid
# form — before the consumer reads it (decision package §4 or the
# strategy-session-weekly step). It does not check the meaning of summary and does not restrict
# the event_type list — SPEC.md §3 deliberately keeps it open for new
# producers (see item 3 of the acceptance discussion).
#
# Portability: POSIX awk/grep only (see coordination-pattern-weekly-stats.sh —
# the same norm for scripts of this contract).
#
# Usage:
#   bash validate-event.sh <file>   # looks for the field block in the file, prints a verdict
#
# Exit: 0 = valid, 1 = invalid (list of reasons on stderr), 2 = usage error.

set -uo pipefail

if [ $# -ne 1 ] || [ ! -f "$1" ]; then
  echo "Использование: validate-event.sh <файл с YAML-блоком события>" >&2
  exit 2
fi

FILE="$1"
ERRORS=0

get_field() {
  # First match of a top-level field — not deep inside another block,
  # the value up to the end of the line, without outer quotes.
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
