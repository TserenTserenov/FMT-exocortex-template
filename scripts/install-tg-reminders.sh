#!/usr/bin/env bash
# install-tg-reminders.sh — устанавливает LaunchAgent-ы для повторяющихся Telegram-напоминаний
# see WP-024, docs/tg-recurring-reminders.md
#
# Что делает:
#   1. Проверяет ~/.config/aist/env (нужны TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID).
#   2. TZ sanity check: macOS system TZ vs params.yaml user_timezone.
#   3. Подставляет абсолютный путь tg-notify.sh в plist (placeholder __TG_NOTIFY_PATH__).
#   4. Копирует plist-ы в ~/Library/LaunchAgents/ и launchctl load.
#
# Использование:
#   bash install-tg-reminders.sh           # установить все 3
#   bash install-tg-reminders.sh --unload  # снять все
#   bash install-tg-reminders.sh --dry-run # показать что будет
#
# Напоминания, которые ставятся (можно отредактировать plist перед установкой):
#   - day-plan:   будни 10:30 — план дня
#   - day-close:  будни 22:00 — закрытие дня
#   - week-close: воскресенье 22:30 — закрытие недели
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FMT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_PLIST_DIR="$FMT_ROOT/setup/optional"
TARGET_DIR="$HOME/Library/LaunchAgents"
TG_NOTIFY_PATH="$SCRIPT_DIR/tg-notify.sh"
ENV_FILE="$HOME/.config/aist/env"

REMINDER_LABELS=(
  "iwe.tg-reminder.day-plan"
  "iwe.tg-reminder.day-close"
  "iwe.tg-reminder.week-close"
)

MODE="${1:-install}"

# === TZ sanity check ===
if [ -f "$FMT_ROOT/params.yaml" ]; then
  expected_tz=$(grep -E '^user_timezone:' "$FMT_ROOT/params.yaml" 2>/dev/null | sed -E 's/user_timezone: *//; s/ *#.*//; s/^"//; s/"$//' || true)
  if [ -n "${expected_tz:-}" ]; then
    current_tz=$(readlink /etc/localtime 2>/dev/null | sed 's:.*/zoneinfo/::' || echo "unknown")
    if [ "$expected_tz" != "$current_tz" ]; then
      echo "⚠️  TZ mismatch: macOS = '$current_tz', params.yaml user_timezone = '$expected_tz'"
      echo "    LaunchAgent triggers fire по macOS local time. Сначала синхронизируй TZ:"
      echo "    System Settings → Date & Time → Time Zone (или: sudo systemsetup -settimezone '$expected_tz')"
      echo ""
    fi
  fi
fi

# === Unload mode ===
if [ "$MODE" = "--unload" ]; then
  for label in "${REMINDER_LABELS[@]}"; do
    target="$TARGET_DIR/${label}.plist"
    if [ -f "$target" ]; then
      launchctl unload "$target" 2>/dev/null || true
      rm -f "$target"
      echo "✓ unloaded $label"
    else
      echo "  $label не установлен"
    fi
  done
  exit 0
fi

# === Pre-flight checks for install ===
if [ ! -f "$ENV_FILE" ]; then
  cat >&2 <<EOF
ERROR: $ENV_FILE not found.

Создай его с переменными:
  TELEGRAM_BOT_TOKEN=<токен от @BotFather>
  TELEGRAM_CHAT_ID=<твой chat_id от @userinfobot>

Затем chmod 600 $ENV_FILE.
Подробнее: docs/tg-recurring-reminders.md
EOF
  exit 1
fi

# Sanity-check token + chat_id are present
# shellcheck disable=SC1090
( set +u; source "$ENV_FILE"; [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ] ) || {
  echo "ERROR: TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not set in $ENV_FILE" >&2
  exit 1
}

if [ ! -f "$TG_NOTIFY_PATH" ]; then
  echo "ERROR: tg-notify.sh not found at $TG_NOTIFY_PATH" >&2
  exit 1
fi
chmod +x "$TG_NOTIFY_PATH"

mkdir -p "$TARGET_DIR"

# === Install ===
for label in "${REMINDER_LABELS[@]}"; do
  src="$SOURCE_PLIST_DIR/${label}.plist"
  if [ ! -f "$src" ]; then
    echo "ERROR: source plist not found: $src" >&2
    exit 1
  fi
  target="$TARGET_DIR/${label}.plist"

  # Substitute __TG_NOTIFY_PATH__ with absolute path
  sed "s|__TG_NOTIFY_PATH__|$TG_NOTIFY_PATH|g" "$src" > "$target"

  if [ "$MODE" = "--dry-run" ]; then
    echo "[dry-run] would install: $target"
    continue
  fi

  launchctl unload "$target" 2>/dev/null || true
  launchctl load "$target"
  echo "✓ installed $label"
done

if [ "$MODE" != "--dry-run" ]; then
  echo ""
  echo "Готово. Проверь: launchctl list | grep iwe.tg-reminder"
  echo "Тест отправки: bash $TG_NOTIFY_PATH 'test'"
  echo "Логи: /tmp/iwe.tg-reminder.*.log /tmp/iwe.tg-reminder.*.err"
fi
