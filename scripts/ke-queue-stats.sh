#!/bin/bash
# ke-queue-stats.sh — статистика очереди Knowledge Extraction
# see: peer-сессия 2026-05-30-07-gap-list-day-open подэтап 5
# see: WP-356 «Pipeline Day Open: auto-run checks»
#
# Назначение: предоставить день-Open скаффолду реальные цифры по очереди captures.
# Заменяет литерал «apply-captures 1h pending» на вычисленный бюджет.
#
# Вывод: JSON или human-format
#   count: количество отчётов со status: pending-review
#   oldest_age_days: возраст самого старого pending-отчёта (-1 если очередь пуста)
#   estimated_minutes: оценка времени (5 мин/отчёт по эпизодам 25 мая)
#   sla_status: "ok" (oldest <3d) | "warning" (3-5d) | "critical" (>=6d)
#
# Использование:
#   bash ke-queue-stats.sh
#   bash ke-queue-stats.sh --human                  # формат для светофора DayPlan
#   bash ke-queue-stats.sh --dayplan-row            # строка для «План на сегодня»

set -uo pipefail

MODE="json"
case "${1:-}" in
  --human) MODE="human" ;;
  --dayplan-row) MODE="dayplan-row" ;;
esac

IWE_BASE="${IWE_BASE:-$HOME/IWE}"
KE_DIR="$IWE_BASE/${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/extraction-reports"
EST_MIN_PER_REPORT=5   # эмпирически — 5 мин/отчёт (эпизод 25 мая)

if [ ! -d "$KE_DIR" ]; then
  case "$MODE" in
    json) echo '{"count":0,"oldest_age_days":-1,"estimated_minutes":0,"sla_status":"ok"}' ;;
    human) echo "| KE-очередь | 🟢 | директория отсутствует, 0 отчётов |" ;;
    dayplan-row) echo "" ;;
  esac
  exit 0
fi

# Parse frontmatter only; support both legacy 'pending-review' and current 'pending'.
# Body mentions like '# status: pending' must not be counted.
PENDING_FILES=$(
  for f in "$KE_DIR"/*.md; do
    [ -f "$f" ] || continue
    awk '/^---/{if(seen){exit} seen=1; next} seen && /^status:[[:space:]]*pending(-review)?$/{print FILENAME; exit}' "$f"
  done
)
if [ -z "$PENDING_FILES" ]; then
  COUNT=0
else
  COUNT=$(echo "$PENDING_FILES" | grep -c .)
fi

if [ "$COUNT" -eq 0 ]; then
  case "$MODE" in
    json) echo '{"count":0,"oldest_age_days":0,"estimated_minutes":0,"sla_status":"ok"}' ;;
    human) echo "| KE-очередь | 🟢 | 0 отчётов |" ;;
    dayplan-row) echo "" ;;
  esac
  exit 0
fi

# Age comes from the report's frontmatter `date:` — file mtime lies after any
# clone/checkout/history rewrite (a fresh `git clone` resets every mtime to
# checkout time, so a 13-day-old pending report reads as "0 days" right after
# a restore or a machine move — found 2026-08-30, WP-170). mtime is the
# fallback for reports without a parsable date.
oldest_report_ts() {
  local ts best=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    local fm_date
    fm_date=$(awk '/^---/{if(seen)exit;seen=1;next} seen && /^date:/{gsub(/["'\'' ]/,"",$2);print $2;exit}' "$f")
    if [[ "$fm_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
      ts=$(date -d "$fm_date" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$fm_date" +%s 2>/dev/null)
    else
      if [[ "$(uname -s)" == "Darwin" ]]; then
        ts=$(stat -f "%m" "$f" 2>/dev/null)
      else
        ts=$(stat -c "%Y" "$f" 2>/dev/null)
      fi
    fi
    [ -n "$ts" ] && { [ -z "$best" ] || [ "$ts" -lt "$best" ]; } && best="$ts"
  done <<<"$1"
  echo "$best"
}

OLDEST_TS=$(oldest_report_ts "$PENDING_FILES")
NOW_TS=$(date +%s)
if [ -z "$OLDEST_TS" ]; then
  OLDEST_DAYS=-1
else
  OLDEST_DAYS=$(( (NOW_TS - OLDEST_TS) / 86400 ))
fi
EST_MIN=$(( COUNT * EST_MIN_PER_REPORT ))

# SLA status (DP.SC.004 ≤24h)
if [ "$OLDEST_DAYS" -ge 6 ]; then
  SLA="critical"
  EMOJI="🔴"
elif [ "$OLDEST_DAYS" -ge 3 ]; then
  SLA="warning"
  EMOJI="🔴"
elif [ "$OLDEST_DAYS" -ge 1 ]; then
  SLA="approaching"
  EMOJI="🟡"
else
  SLA="ok"
  EMOJI="🟢"
fi

EST_HOURS=$(awk "BEGIN {printf \"%.1f\", $EST_MIN / 60}")

case "$MODE" in
  json)
    echo "{\"count\":$COUNT,\"oldest_age_days\":$OLDEST_DAYS,\"estimated_minutes\":$EST_MIN,\"estimated_hours\":$EST_HOURS,\"sla_status\":\"$SLA\"}"
    ;;
  human)
    echo "| KE-очередь | $EMOJI | $COUNT отчётов, oldest ${OLDEST_DAYS}д, оценка ~${EST_HOURS}h, SLA=$SLA |"
    ;;
  dayplan-row)
    case "$SLA" in
      critical|warning) status_emoji="🔴" ;;
      approaching) status_emoji="🟡" ;;
      ok) status_emoji="⚪" ;;
    esac
    echo "| $status_emoji | — | **apply-captures** — $COUNT pending reports, oldest ${OLDEST_DAYS}д, SLA=$SLA | $EST_HOURS | pending | — |"
    ;;
esac
