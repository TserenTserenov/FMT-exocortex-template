#!/bin/bash
# Kimi Compaction Watchdog
# Отслеживает логи Kimi Code CLI и отправляет уведомления при compaction / высоком usage
# Запуск: ./scripts/kimi-compaction-watchdog.sh &

set -euo pipefail

# WP-5 Ubuntu-audit факт #4: hardcoded to the macOS VS Code log path — on Linux
# LOG_DIR silently didn't exist, `find` always returned nothing, and the main
# loop below (find_latest_log empty → sleep 5 → continue) ran forever with no
# signal that the watchdog was doing nothing at all.
case "$(uname -s)" in
  Darwin) LOG_DIR="${HOME}/Library/Application Support/Code/logs" ;;
  Linux)  LOG_DIR="${HOME}/.config/Code/logs" ;;
  *)      LOG_DIR="${HOME}/.config/Code/logs" ;;
esac
# Находим самый свежий лог-файл Kimi Code
find_latest_log() {
  find "${LOG_DIR}" -name "7-Kimi Code*.log" -type f -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1
}

send_notification() {
  local title="$1"
  local message="$2"
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"${message}\" with title \"${title}\" sound name \"Glass\"" 2>/dev/null || true
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "${title}" "${message}" 2>/dev/null || true
  fi
}

if [ ! -d "${LOG_DIR}" ]; then
  echo "kimi-compaction-watchdog: LOG_DIR not found ($LOG_DIR) — nothing to watch, exiting instead of looping silently forever." >&2
  exit 1
fi

LAST_LOG=""
LAST_POS=0
USAGE_ALERTED=false

while true; do
  CURRENT_LOG=$(find_latest_log)
  if [ -z "${CURRENT_LOG}" ]; then
    sleep 5
    continue
  fi

  # Если лог сменился — сбрасываем позицию
  if [ "${CURRENT_LOG}" != "${LAST_LOG}" ]; then
    LAST_LOG="${CURRENT_LOG}"
    LAST_POS=$(wc -c < "${CURRENT_LOG}" | tr -d ' ')
    USAGE_ALERTED=false
    continue
  fi

  CURRENT_SIZE=$(wc -c < "${CURRENT_LOG}" | tr -d ' ')
  if [ "${CURRENT_SIZE}" -le "${LAST_POS}" ]; then
    sleep 3
    continue
  fi

  # Читаем новые строки
  tail -c +$((LAST_POS + 1)) "${CURRENT_LOG}" | while IFS= read -r line; do
    # Уведомление о начале compaction
    if echo "${line}" | grep -q "CompactionBegin"; then
      send_notification "Kimi: Compaction начался" "Контекст сжимается. Экран может быть пустым 1–2 минуты."
    fi

    # Уведомление о завершении compaction
    if echo "${line}" | grep -q "CompactionEnd"; then
      send_notification "Kimi: Compaction завершён" "Можно продолжать работу."
    fi

    # Предупреждение при высоком context_usage (> 0.65)
    if echo "${line}" | grep -q '"context_usage":[0-9]\+\.[0-9]\+'; then
      usage=$(echo "${line}" | grep -o '"context_usage":[0-9]\+\.[0-9]\+' | cut -d: -f2)
      if [ -n "${usage}" ]; then
        # сравнение через awk для float
        if awk "BEGIN {exit !(${usage} > 0.65)}"; then
          if [ "${USAGE_ALERTED}" = "false" ]; then
            send_notification "Kimi: Контекст на ${usage}%" "Рекомендую /compact или новую сессию."
            USAGE_ALERTED=true
          fi
        fi
      fi
    fi
  done

  LAST_POS=${CURRENT_SIZE}
  sleep 3
done
