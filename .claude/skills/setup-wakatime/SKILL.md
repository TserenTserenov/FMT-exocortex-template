---
name: setup-wakatime
description: Настройка WakaTime time-tracking для Claude Code и VS Code
user_invocable: true
routing:
  executor: script
  deterministic: true
  script_path: ".claude/skills/setup-wakatime/setup.sh"
---

# Setup WakaTime Time Tracking

Автоматическая настройка WakaTime для отслеживания рабочего времени.

## Что устанавливается

1. **wakatime-cli** — CLI для отправки heartbeat'ов
2. **Хук Claude Code** — автоматический трекинг при работе с Claude (категория "AI Coding")
3. **WakaTime Desktop App** (опционально) — трекинг фокуса окна (чтение, браузер)

## Инструкция для Claude

Выполни шаги последовательно. На каждом шаге проверяй, не сделано ли уже.

### Шаг 1: wakatime-cli

```bash
# Проверить наличие
~/.wakatime/wakatime-cli --version 2>/dev/null || wakatime-cli --version 2>/dev/null
```

Если не установлен:
```bash
brew install wakatime-cli
mkdir -p ~/.wakatime
ln -sf $(which wakatime-cli) ~/.wakatime/wakatime-cli
```

### Шаг 2: API Key

```bash
cat ~/.wakatime.cfg 2>/dev/null
```

Если файл не существует или нет `api_key`:
1. Скажи пользователю: «Нужен WakaTime API-ключ. Получи его на https://wakatime.com/settings/api-key (нужна регистрация). Вставь ключ сюда.»
2. Дождись ответа
3. Запиши:
```bash
# ~/.wakatime.cfg
[settings]
api_key = <ключ от пользователя>
```

### Шаг 3: Хук-скрипт

Скопируй хук-скрипт из шаблона в глобальную директорию:
```bash
mkdir -p ~/.claude/hooks
cp .claude/hooks/wakatime-heartbeat.sh ~/.claude/hooks/wakatime-heartbeat.sh
chmod +x ~/.claude/hooks/wakatime-heartbeat.sh
```

### Шаг 4: Настройка хуков в settings.json

Прочитай `~/.claude/settings.json`. Добавь в секцию `hooks` (не затирая существующие хуки):

- **UserPromptSubmit** — добавь hook group:
  ```json
  {"hooks": [{"type": "command", "command": "~/.claude/hooks/wakatime-heartbeat.sh"}]}
  ```
- **PostToolUse** — добавь:
  ```json
  {"hooks": [{"type": "command", "command": "~/.claude/hooks/wakatime-heartbeat.sh", "async": true}]}
  ```
- **Stop** — добавь:
  ```json
  {"hooks": [{"type": "command", "command": "~/.claude/hooks/wakatime-heartbeat.sh", "async": true}]}
  ```

### Шаг 5: WakaTime Desktop App (спроси пользователя)

Спроси: «Установить WakaTime Desktop App? Он трекает время фокуса окна (когда читаешь ответы, работаешь в браузере). Требует Accessibility-разрешение в macOS.»

Если да:
```bash
brew install --cask wakatime
open -a WakaTime
```
Скажи: «Разреши Accessibility доступ в System Settings → Privacy & Security → Accessibility.»

### Шаг 6: Тест

```bash
echo '{"cwd": "'$(pwd)'", "hook_event_name": "UserPromptSubmit", "prompt": "test"}' | ~/.claude/hooks/wakatime-heartbeat.sh
sleep 3
~/.wakatime/wakatime-cli --today
```

Покажи результат пользователю. Скажи: «Хуки подхватятся при следующем запуске Claude Code (хуки загружаются при старте сессии).»

### Шаг 7: Итог

Покажи таблицу:

| Компонент | Статус |
|-----------|--------|
| wakatime-cli | ✅/❌ |
| API key | ✅/❌ |
| Хук-скрипт | ✅/❌ |
| Хуки в settings.json | ✅/❌ |
| Desktop App | ✅/❌/пропущен |
| Тест heartbeat | ✅/❌ |

Скажи: «Дашборд: https://wakatime.com/dashboard. Данные появятся через 5-15 минут.»
