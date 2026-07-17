#!/usr/bin/env bash
# routing: helper  skill=day-open  called-by=haiku  deterministic=true
# see DP.SC.159, DP.ROLE.059
# day-open-preflight.sh — pre-flight healthcheck для Day Open
# WP-7 ФDay-Open-Hardening (DOC6 3-состояния: peer-session 2026-07-14-07)
# Возвращает единый JSON: {"calendar":"ok|fail|pending","scout":"ok|fail|disabled|pending","scout_reason":"...",
#   "triage":"ok|fail|disabled|pending","triage_reason":"...","memory":"ok|stale|missing"}
# "disabled" = источник намеренно не настроен на этой машине (Scout/triage репо отсутствуют).
# "fail" = источник настроен, но данные не собрались (диагностика нужна).

set -uo pipefail

# portable_date_offset <days_back> [format] — BSD `date -v` (macOS) vs GNU `date -d` (Linux)
portable_date_offset() {
  local days="$1" fmt="${2:-%Y-%m-%d}"
  date -v-"${days}"d +"$fmt" 2>/dev/null || date -d "$days days ago" +"$fmt" 2>/dev/null
}

# Загрузка Telegram credentials (если доступны)
AIST_ENV="$HOME/.config/aist/env"
if [ -f "$AIST_ENV" ]; then
  set -a
  source "$AIST_ENV"
  set +a
fi

DATE="${1:-$(date +%Y-%m-%d)}"
IWE="${IWE_ROOT:-$HOME/IWE}"
GOV_REPO="${IWE_GOVERNANCE_REPO:-DS-strategy}"
CONFIG="${2:-$IWE/$GOV_REPO/exocortex/day-rhythm-config.yaml}"

# --- Calendar: server-calendar.sh ---
CALENDAR_STATUS="unknown"
CALENDAR_OUT=$(bash "$IWE/scripts/server-calendar.sh" "$DATE" "$CONFIG" 2>/dev/null || echo "")
if [ -n "$CALENDAR_OUT" ]; then
  if echo "$CALENDAR_OUT" | grep -q "PENDING"; then
    CALENDAR_STATUS="pending"
  elif echo "$CALENDAR_OUT" | grep -qE '(\| [0-9]{2}:[0-9]{2} \||✅)'; then
    # "✅" covers successful responses with 0 events (no | HH:MM | rows)
    CALENDAR_STATUS="ok"
  else
    CALENDAR_STATUS="fail"
  fi
else
  CALENDAR_STATUS="fail"
fi

# --- Scout: check backlog + latest log ---
SCOUT_STATUS="unknown"
SCOUT_REASON=""
BACKLOG_FILE="$IWE/DS-agent-workspace/scout/backlog.yaml"
if [ ! -d "$IWE/DS-agent-workspace" ]; then
  SCOUT_STATUS="disabled"
  SCOUT_REASON="DS-agent-workspace repo not present — Scout subsystem not installed"
fi
HAS_PENDING=false
if [ -f "$BACKLOG_FILE" ] && grep -q "status: pending" "$BACKLOG_FILE" 2>/dev/null; then
  HAS_PENDING=true
fi

SCOUT_LOG=$(ls -t "$IWE/DS-autonomous-agents/logs/scout-"*.log 2>/dev/null | head -1 || echo "")
if [ "$SCOUT_STATUS" = "disabled" ]; then
  :
elif [ -n "$SCOUT_LOG" ]; then
  LOG_DATE=$(basename "$SCOUT_LOG" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' || echo "")
  if [ "$LOG_DATE" = "$DATE" ]; then
    SCOUT_STATUS="ok"
  elif [ "$HAS_PENDING" = "false" ]; then
    # Нет заданий в backlog — отсутствие лога = норма (Scout вышел с NO_TASKS)
    SCOUT_STATUS="ok"
  else
    SCOUT_STATUS="fail"
    SCOUT_REASON="last log $LOG_DATE (expected $DATE), backlog has pending tasks"
    if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
      curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "{\"chat_id\":\"${TELEGRAM_CHAT_ID}\",\"text\":\"🚨 Scout silent failure: last log $LOG_DATE (expected $DATE), backlog has pending tasks\"}" > /dev/null
    fi
  fi
else
  if [ "$HAS_PENDING" = "false" ]; then
    SCOUT_STATUS="ok"
  else
    SCOUT_STATUS="fail"
    SCOUT_REASON="no scout logs found at all, backlog has pending tasks"
    if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
      curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "{\"chat_id\":\"${TELEGRAM_CHAT_ID}\",\"text\":\"🚨 Scout silent failure: no logs found at all, backlog has pending tasks\"}" > /dev/null
    fi
  fi
fi

# --- Triage: check file ---
TRIAGE_STATUS="unknown"
TRIAGE_REASON=""
TRIAGE_FILE="$IWE/DS-agent-workspace/scheduler/feedback-triage/$DATE.md"
if [ ! -d "$IWE/DS-agent-workspace/scheduler" ]; then
  TRIAGE_STATUS="disabled"
  TRIAGE_REASON="DS-agent-workspace/scheduler not present — feedback-triage subsystem not installed"
elif [ -f "$TRIAGE_FILE" ]; then
  TRIAGE_STATUS="ok"
else
  # Grace window: generator runs at 00:01 EEST, catch-up may be delayed
  CURRENT_HOUR=$(date +%H)
  if [ "$CURRENT_HOUR" -lt 6 ] || { [ "$CURRENT_HOUR" -eq 6 ] && [ "$(date +%M)" -lt 30 ]; }; then
    TRIAGE_STATUS="pending"
  else
    TRIAGE_STATUS="fail"
    TRIAGE_REASON="no report for $DATE"
  fi
  YESTERDAY=$(portable_date_offset 1)
  YESTERDAY_FILE="$IWE/DS-agent-workspace/scheduler/feedback-triage/$YESTERDAY.md"
  if [ ! -f "$YESTERDAY_FILE" ] && [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -H "Content-Type: application/json" \
      -d "{\"chat_id\":\"${TELEGRAM_CHAT_ID}\",\"text\":\"🚨 Feedback-triage silent failure: no reports since before $YESTERDAY\"}" > /dev/null
  fi
fi

# --- active-wp.md stale check ---
MEMORY_STATUS="ok"
ACTIVE_WP="$IWE/$GOV_REPO/current/active-wp.md"
if [ -f "$ACTIVE_WP" ]; then
  if stat -f%m "$ACTIVE_WP" > /dev/null 2>&1; then
    AGE_DAYS=$(( ( $(date +%s) - $(stat -f%m "$ACTIVE_WP") ) / 86400 ))
  else
    AGE_DAYS=$(( ( $(date +%s) - $(stat -c%Y "$ACTIVE_WP") ) / 86400 ))
  fi
  if [ "$AGE_DAYS" -gt 7 ]; then
    MEMORY_STATUS="stale"
  fi
else
  MEMORY_STATUS="missing"
fi

# Output unified JSON (flat strings — backward-compatible with existing
# consumers reading .scout/.triage as plain values; *_reason are additive)
jq -n \
  --arg calendar "$CALENDAR_STATUS" \
  --arg scout "$SCOUT_STATUS" \
  --arg scout_reason "$SCOUT_REASON" \
  --arg triage "$TRIAGE_STATUS" \
  --arg triage_reason "$TRIAGE_REASON" \
  --arg memory "$MEMORY_STATUS" \
  '{calendar: $calendar, scout: $scout, scout_reason: $scout_reason,
    triage: $triage, triage_reason: $triage_reason, memory: $memory}'
