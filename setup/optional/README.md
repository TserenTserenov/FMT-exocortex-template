# Optional Components

Optional features that enhance IWE but are not required for core functionality.

## Pomodoro Break Reminders

Monitors your coding activity via WakaTime and sends a macOS notification when you've been working continuously for too long.

### Prerequisites

- **WakaTime** installed and configured (`~/.wakatime.cfg` with `api_key`)
- **macOS** (uses `osascript` for notifications)
- **Python 3** (pre-installed on macOS)

### Installation

```bash
# 1. Replace placeholder with your workspace path
sed "s|{{WORKSPACE_DIR}}|$HOME/IWE|g" setup/optional/pomodoro-alert.plist \
  > ~/Library/LaunchAgents/com.exocortex.pomodoro-alert.plist

# 2. Load the agent (starts immediately, runs every 5 min)
launchctl load ~/Library/LaunchAgents/com.exocortex.pomodoro-alert.plist

# 3. Verify it's running
launchctl list | grep pomodoro
```

### Configuration

Edit `memory/day-rhythm-config.yaml` → section `pomodoro`:

```yaml
pomodoro:
  work_minutes: 25          # Pomodoro work interval
  break_minutes: 5           # Short break
  long_break_minutes: 15     # Long break
  sessions_before_long_break: 4
  session_alert_minutes: 50  # Alert after this many continuous minutes
```

### How it works

1. Every 5 minutes, the script calls WakaTime Durations API
2. It calculates the current continuous work block (gaps > 5 min reset the counter)
3. If continuous work exceeds `session_alert_minutes`, a macOS notification appears
4. Alerts are suppressed for 10 minutes after each notification (no spam)

### Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/com.exocortex.pomodoro-alert.plist
rm ~/Library/LaunchAgents/com.exocortex.pomodoro-alert.plist
```

### Files

| File | Purpose |
|------|---------|
| `pomodoro-alert.py` | Python script (WakaTime API + macOS notification) |
| `pomodoro-alert.plist` | launchd agent template (replace `{{WORKSPACE_DIR}}`) |

---

## Локальный шлюз координации агентов (iwe-local-gateway)

Если в одной рабочей директории работает несколько ИИ-агентов одновременно (Claude Code, Kimi, Hermes) — нужен общий менеджер файловых блокировок, чтобы они не перезаписывали правки друг друга. Полное описание сценария — [docs/AGENT-VENDOR-SETUP.md](../../docs/AGENT-VENDOR-SETUP.md).

### Установка

```bash
bash setup/optional/setup-local-gateway.sh
```

Скрипт клонирует шлюз на закреплённую версию, собирает его, запускает демон и выводит блок для ручной вставки в `.mcp.json` (существующий файл не переписывается автоматически — только показывается точная запись для копирования). Повторный запуск безопасен: уже установленный шлюз не переустанавливается.

### Uninstall

```bash
kill "$(cat ~/.iwe/gateway.pid)"          # остановить демон
rm -rf ~/IWE/DS-MCP/local-gateway         # удалить код шлюза
rm -f ~/.iwe/gateway.sock ~/.iwe/gateway-daemon.log ~/.iwe/gateway.pid
```

Затем вручную удалите запись `iwe-local-gateway` из `.mcp.json`.

### Files

| File | Purpose |
|------|---------|
| `setup-local-gateway.sh` | клон + сборка + запуск демона + инструкция для `.mcp.json` |

---

## Day Rhythm Config

The file `memory/day-rhythm-config.yaml` controls several Day Open features:

- **Strategy day** — which day of the week to suggest a strategy session
- **Self-development slot** — always first in the daily plan
- **News digest** — optional news topics at Day Open (disabled by default)
- **Pomodoro settings** — break reminder thresholds

This file is read by Claude during Day Open (`protocol-open.md § День`). No installation needed — it works automatically once present in `memory/`.

---

## Cloud Scheduler (GitHub Actions)

IWE автоматика в облаке — работает даже когда Mac выключен. Базовый уровень: backup + health check. $0/мес.

Полная инструкция (доставляется через update.sh — issue #325): [docs/CLOUD-SCHEDULER.md](../../docs/CLOUD-SCHEDULER.md)

---

## Cover Images (S48)

Автоматическая генерация обложек для постов через OpenAI GPT Image API. Каждая обложка уникальна и отражает содержание статьи.

Подробная инструкция: [COVER-IMAGES.md](COVER-IMAGES.md)

### Quick start

```bash
# 1. Положите API key
echo "sk-proj-ВАШ_КЛЮЧ" > .secrets/openai-api-key

# 2. Установите зависимости
pip install httpx pyyaml

# 3. Сгенерируйте обложку
python setup/optional/generate-post-image.py path/to/post.md
```

### Files

| File | Purpose |
|------|---------|
| `generate-post-image.py` | Python-скрипт генерации (GPT Image 1) |
| `COVER-IMAGES.md` | Подробная инструкция: промпты, параметры, стоимость |
