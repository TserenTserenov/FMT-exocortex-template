# Telegram-напоминания: recurring канал

> **see** CLAUDE.md Правило 8 (S-44), WP-024
> **Дополняет** `send_telegram_message` (MCP) — этот канал для ad-hoc; LaunchAgent — для повторяющихся.

## Зачем

S-44 (`send_telegram_message` с `schedule_at`) покрывает разовые напоминания из сессии Claude
(«напомни через 3 часа Y»). Но MCP-инструменты работают только пока есть сессия — для
повторяющихся напоминаний по расписанию (cron-аналог) нужна system-level инфраструктура.

Этот канал = bash-скрипт `tg-notify.sh` + macOS LaunchAgent.

## Установка

### 1. Создать бота и получить секреты

1. В Telegram: [@BotFather](https://t.me/BotFather) → `/newbot` → имя → handle → получить токен.
2. Написать своему боту `/start` (без этого Bot API вернёт Forbidden).
3. В Telegram: [@userinfobot](https://t.me/userinfobot) → получить `chat_id`.

### 2. Записать секреты

```bash
mkdir -p ~/.config/aist
cat > ~/.config/aist/env <<EOF
TELEGRAM_BOT_TOKEN=<токен>
TELEGRAM_CHAT_ID=<chat_id>
EOF
chmod 600 ~/.config/aist/env
```

> Тот же `env`-файл используется существующим dispatcher'ом ролей (`roles/synchronizer/scripts/notify.sh`) — секреты пере-используются.

### 3. Установить LaunchAgent-ы

```bash
bash scripts/install-tg-reminders.sh
```

Скрипт:
1. Проверяет `~/.config/aist/env`.
2. TZ sanity check: сравнивает macOS system TZ с `user_timezone` из `params.yaml` (если есть).
3. Подставляет абсолютный путь `tg-notify.sh` в plist-шаблоны (placeholder `__TG_NOTIFY_PATH__`).
4. Копирует обработанные plist в `~/Library/LaunchAgents/`.
5. `launchctl load` каждый агент.

### 4. Тест

```bash
# Прямой тест отправки
bash scripts/tg-notify.sh "test message"

# Проверить что агенты загружены
launchctl list | grep iwe.tg-reminder

# Логи
tail -f /tmp/iwe.tg-reminder.day-plan.log /tmp/iwe.tg-reminder.day-plan.err
```

## Что устанавливается

| Label | Когда срабатывает | Сообщение |
|-------|-------------------|-----------|
| `iwe.tg-reminder.day-plan` | будни 10:30 | План дня: собери ТОС и приоритеты по РП, открой /day-open |
| `iwe.tg-reminder.day-close` | будни 22:00 | Пора закрывать день: /day-close |
| `iwe.tg-reminder.week-close` | воскресенье 22:30 | Пора закрывать неделю: /week-close |

Время в plist — **macOS local time**. См. ниже про TZ.

## Часовые пояса

LaunchAgent `StartCalendarInterval` использует local TZ системы. То есть:

- Mac на TZ `Europe/Moscow` → 10:30 = 10:30 МСК.
- Mac на TZ `America/Los_Angeles` → 10:30 = 10:30 PDT.

При переезде между TZ:
1. Поменять системный TZ в macOS: System Settings → Date & Time → Time Zone
   (или: `sudo systemsetup -settimezone "America/Los_Angeles"`).
2. (Опционально) Обновить `params.yaml`:
   ```yaml
   user_timezone: America/Los_Angeles
   ```
   Это нужно только для TZ sanity check в `install-tg-reminders.sh` — реальное расписание определяется системным TZ.
3. LaunchAgent автоматически подхватит новый TZ при следующем срабатывании, перезагружать не надо.

## Изменить расписание/текст

Редактировать соответствующий plist в `setup/optional/iwe.tg-reminder.*.plist`:
- `StartCalendarInterval` — массив словарей с `Weekday`/`Hour`/`Minute`.
   `Weekday`: 0 (или 7) = Вс, 1 = Пн, ..., 6 = Сб.
- `ProgramArguments` третий аргумент — текст сообщения.

После правки: `bash scripts/install-tg-reminders.sh` (он сначала unload потом load).

## Снять

```bash
bash scripts/install-tg-reminders.sh --unload
```

## Связь с S-44

| Случай | Канал |
|--------|-------|
| «напомни через 3 часа Y» из сессии Claude | MCP `send_telegram_message(schedule_at=...)` — S-44 |
| «каждые будни в 10:30 X» | этот канал (LaunchAgent + tg-notify.sh) |
| Уведомление от роли (Стратег, Extractor) | `roles/synchronizer/scripts/notify.sh` — отдельная инфраструктура |

Три канала, одно `~/.config/aist/env`, один Telegram-бот.

## Troubleshooting

**Сообщение не приходит.** Проверь `/tmp/iwe.tg-reminder.<label>.err` — там curl ошибка.
Частые причины: токен/chat_id неверные, бот не запущен (`/start`), HTTP-proxy не настроен (`TELEGRAM_PROXY` в env).

**LaunchAgent не срабатывает.** `launchctl list | grep iwe.tg-reminder` — должен показывать PID `-` (загружен, не запущен сейчас). Если нет — `launchctl load -w ~/Library/LaunchAgents/<label>.plist`.

**Сработало не в то время.** Проверь macOS system TZ: `date` (последние буквы — `MSK`/`PDT`/...). Если не тот — изменить в System Settings.
