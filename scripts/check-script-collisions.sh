#!/usr/bin/env bash
# routing: utility  deterministic=true
# see DP.SC.159, DP.ROLE.059
# check-script-collisions.sh — check script collisions between the author zone and the FMT template.
#
# Purpose: runs BEFORE promoting a script L3→L1 (author → universal in FMT)
# and periodically (Month Close) to track drift.
#
# Script types (DP.KR.001 §5.6):
#   Type 1 (universal): FMT/scripts/ → WORKSPACE/scripts/ via update.sh
#   Type 2 (author):    only in WORKSPACE/scripts/ (not in FMT)
# Collision: the name exists in both places → must be resolved (merge or rename).
#
# Usage:
#   check-script-collisions.sh              # show collisions
#   check-script-collisions.sh --verbose    # + diff for each collision
#   check-script-collisions.sh --quiet      # exit code only (0=no collisions, 1=there are)

set -euo pipefail

WORKSPACE="${WORKSPACE_DIR:-$HOME/IWE}"
AUTHOR_SCRIPTS="${WORKSPACE}/scripts"
FMT_PATH="${FMT_PATH:-${WORKSPACE}/FMT-exocortex-template}"
FMT_SCRIPTS="${FMT_PATH}/scripts"

VERBOSE=0
QUIET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verbose) VERBOSE=1; shift ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -d "$AUTHOR_SCRIPTS" ]]; then
  [[ $QUIET -eq 0 ]] && echo "ERR: не найдена $AUTHOR_SCRIPTS" >&2
  exit 2
fi
if [[ ! -d "$FMT_SCRIPTS" ]]; then
  [[ $QUIET -eq 0 ]] && echo "ERR: не найдена $FMT_SCRIPTS" >&2
  exit 2
fi

AUTHOR_FILES=$(cd "$AUTHOR_SCRIPTS" && find . -maxdepth 1 -type f \( -name "*.sh" -o -name "*.py" \) | sed 's|^\./||' | sort)
FMT_FILES=$(cd "$FMT_SCRIPTS" && find . -maxdepth 1 -type f \( -name "*.sh" -o -name "*.py" \) | sed 's|^\./||' | sort)

COLLISIONS=$(comm -12 <(echo "$AUTHOR_FILES") <(echo "$FMT_FILES"))

if [[ -z "$COLLISIONS" ]]; then
  [[ $QUIET -eq 0 ]] && echo "✓ коллизий нет ($(echo "$AUTHOR_FILES" | wc -l | tr -d ' ') в author, $(echo "$FMT_FILES" | wc -l | tr -d ' ') в FMT)"
  exit 0
fi

COUNT=$(echo "$COLLISIONS" | wc -l | tr -d ' ')

if [[ $QUIET -eq 1 ]]; then
  exit 1
fi

echo "⚠️  Коллизий: $COUNT"
echo ""
echo "Скрипты, существующие одновременно в ${AUTHOR_SCRIPTS}/ и ${FMT_SCRIPTS}/:"
echo ""

while IFS= read -r name; do
  AUTHOR_FILE="$AUTHOR_SCRIPTS/$name"
  FMT_FILE="$FMT_SCRIPTS/$name"
  AUTHOR_SIZE=$(wc -c < "$AUTHOR_FILE" | tr -d ' ')
  FMT_SIZE=$(wc -c < "$FMT_FILE" | tr -d ' ')

  if cmp -s "$AUTHOR_FILE" "$FMT_FILE"; then
    STATUS="идентичны"
  else
    STATUS="различаются"
  fi

  echo "  • $name — $STATUS (author: ${AUTHOR_SIZE}b, FMT: ${FMT_SIZE}b)"

  if [[ $VERBOSE -eq 1 && "$STATUS" == "различаются" ]]; then
    echo ""
    diff -u "$AUTHOR_FILE" "$FMT_FILE" | head -30 | sed 's/^/      /'
    echo ""
  fi
done <<< "$COLLISIONS"

echo ""
echo "Решение (по каждой коллизии):"
echo "  1. Merge: какая версия правильная → оставить одну, удалить другую"
echo "  2. Rename: переименовать author-версию (если нужны обе функции)"
echo ""
echo "Правило (DP.KR.001 §5.6):"
echo "  Тип 1 (universal) живёт только в FMT/scripts/"
echo "  Тип 2 (author) живёт только в WORKSPACE/scripts/"

exit 1
