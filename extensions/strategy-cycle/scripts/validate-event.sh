#!/bin/bash
# validate-event.sh — event contract form validator for the strategy cycle
# see: extensions/strategy-cycle/SPEC.md §3, live acceptance WP-518
#   (session 2026-08-16-22-wp518-strategy-cycle-acceptance)
#
# Purpose: mechanically verify, that YAML-event block (producer any
# closing/reconciliation) contains all 5 required contract fields in valid
# form — before, before it is read by consumer (decision package §4 or step
# strategy-session-weekly). Does not validate the meaning of summary and does not restrict summary and does not restrict
# list event_type — SPEC.md §3 intentionally keeps it open for new
# producer's (see. item.3 acceptance discussion).
#
# Portability: only POSIX awk/grep (see. coordination-pattern-weekly-stats.sh —
# the same standard for scripts in this contract).
#
# Usage:
#   bash validate-event.sh <file>   # searches for the field block in the file, prints verdict
#
# Exit: 0 = valid, 1 = invalid (list of reasons in stderr), 2 = usage error.

set -uo pipefail

if [ $# -ne 1 ] || [ ! -f "$1" ]; then
  echo "Usage: validate-event.sh <file containing YAML-event YAML block>" >&2
  exit 2
fi

FILE="$1"
ERRORS=0

get_field() {
  # First match of a top-level field — not nested inside another block,
  # value to end of line, without surrounding quotes.
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
    echo "ERROR: field '$name' is absent or empty" >&2
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
  echo "ERROR: field 'requires_pilot_decision' must be literally 'true' or 'false', received: '${REQUIRES:-<empty>}'" >&2
  ERRORS=$((ERRORS + 1))
fi

if [ -n "$PERIOD" ]; then
  DATE_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
  RANGE_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}\.\.[0-9]{4}-[0-9]{2}-[0-9]{2}$'
  if ! echo "$PERIOD" | grep -qE "$DATE_RE" && ! echo "$PERIOD" | grep -qE "$RANGE_RE"; then
    echo "ERROR: field 'period' must be a date YYYY-MM-DD or a range YYYY-MM-DD..YYYY-MM-DD, received: '$PERIOD'" >&2
    ERRORS=$((ERRORS + 1))
  fi
fi

if [ "$ERRORS" -eq 0 ]; then
  echo "OK: event is valid (event_type=$EVENT_TYPE, period=$PERIOD)"
  exit 0
fi

echo "INVALID: $ERRORS error(s)(s) — see. above" >&2
exit 1
