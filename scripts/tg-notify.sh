#!/usr/bin/env bash
# tg-notify.sh — отправка произвольного сообщения в Telegram (для recurring-напоминаний)
# see WP-024, complements CLAUDE.md Правило 8 (S-44)
#
# Назначение: этот канал используется LaunchAgent-ами для повторяющихся
# напоминаний по расписанию (cron-аналог). Для ad-hoc напоминаний
# из сессии Claude используй MCP-инструмент `send_telegram_message`
# с параметром `schedule_at` (см. CLAUDE.md Правило 8).
#
# Использование:
#   tg-notify.sh "Текст сообщения"
#
# Требует ~/.config/aist/env с переменными:
#   TELEGRAM_BOT_TOKEN=...
#   TELEGRAM_CHAT_ID=...
#   (опционально) TELEGRAM_PROXY=http://...
set -euo pipefail

ENV_FILE="${HOME}/.config/aist/env"
if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: $ENV_FILE not found. Configure TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID." >&2
  exit 1
fi
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
  echo "ERROR: TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not set in $ENV_FILE" >&2
  exit 1
fi

MSG="${1:?usage: tg-notify.sh \"text\"}"

curl_args=(-sS --fail)
if [ -n "${TELEGRAM_PROXY:-}" ]; then
  curl_args+=(--proxy "$TELEGRAM_PROXY")
elif [ -n "${ALL_PROXY:-}" ]; then
  curl_args+=(--proxy "$ALL_PROXY")
fi

curl "${curl_args[@]}" -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -d chat_id="${TELEGRAM_CHAT_ID}" \
  --data-urlencode "text=${MSG}" \
  -d parse_mode="HTML" \
  -d disable_web_page_preview="true" >/dev/null

echo "[tg-notify] sent: ${MSG:0:60}"
