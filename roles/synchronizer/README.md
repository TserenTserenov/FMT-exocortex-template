# Синхронизатор (Synchronizer, R8)

> Центральный диспетчер агентов экзокортекса: расписание, уведомления, мониторинг.

## Что делает

Синхронизатор — это bash-инструмент (не ИИ-агент), который:
1. **Dispatcher:** Запускает Стратега и Экстрактора по расписанию
2. **Code Scan:** Еженочно сканирует downstream-репо на активность
3. **Notify:** Отправляет результаты в Telegram
4. **Report:** Генерирует ежедневный отчёт здоровья системы

## Компоненты

| Скрипт | Что делает | Триггер |
|--------|-----------|---------|
| `scheduler.sh` | Центральный диспетчер: проверяет расписание, запускает агентов | launchd (11 раз/день) |
| `code-scan.sh` | Сканирует DS-* репо на коммиты за 24ч | scheduler (00:00) |
| `daily-report.sh` | Отчёт здоровья: светофор, ошибки, рекомендации | scheduler (после утра) |
| `sync-files.sh` | Точечная синхронизация файлов из remote | scheduler (каждые 2 мин) |
| `notify.sh` | Отправка в Telegram через шаблоны агентов | После каждого процесса |

## Установка

```bash
cd {{WORKSPACE_DIR}}/FMT-exocortex-template/roles/synchronizer
bash install.sh
```

### Telegram уведомления (опционально)

Создай файл `~/.config/aist/env`:

```bash
export TELEGRAM_BOT_TOKEN="your-bot-token"
export TELEGRAM_CHAT_ID="your-chat-id"
```

Без этого файла уведомления просто не отправляются (скрипты не падают).

## Расписание

| Время (UTC) | Агент | Сценарий | Catch-up |
|-------------|-------|----------|----------|
| 00:00 | Синхронизатор | code-scan | весь день |
| 04:00 | Стратег | morning (Пн=session-prep, Вт-Вс=day-plan) | до 22:00 |
| 23:00 | Стратег | note-review | с 22:00 |
| Пн 00:00 | Стратег | week-review | весь Пн |
| Каждые 3ч (07-23) | Экстрактор | inbox-check | интервальный |
| После утра | Синхронизатор | daily-report | после 06:00 |

> **Catch-up:** Если компьютер спал и пропустил время — при пробуждении запустит пропущенные задачи (в пределах окна).
>
> **Предотвращение сна:** Скрипты `scheduler.sh` и `strategist.sh` автоматически блокируют засыпание на время работы (macOS: `caffeinate -diu`, Linux: `systemd-inhibit`). Для ноутбуков рекомендуется также настроить запрет idle sleep на уровне ОС — см. [SETUP-GUIDE.md](../../docs/SETUP-GUIDE.md).

## Файлы

```
roles/synchronizer/
├── README.md
├── install.sh
├── config.yaml                    # Расписание (reference)
├── scripts/
│   ├── scheduler.sh               # Центральный диспетчер
│   ├── code-scan.sh               # Ночной скан
│   ├── daily-report.sh            # Отчёт здоровья
│   ├── sync-files.sh              # Точечная синхронизация
│   ├── notify.sh                  # Telegram dispatch
│   ├── templates/
│   │   ├── strategist.sh          # Шаблон TG для Стратега
│   │   ├── extractor.sh           # Шаблон TG для Экстрактора
│   │   └── synchronizer.sh        # Шаблон TG для Синхронизатора
│   └── launchd/
│       └── com.exocortex.scheduler.plist
└── configs/
    └── systems/
        └── .gitkeep               # Будущие системные конфигурации
```

## Состояние

Маркеры запуска: `~/.local/state/exocortex/`
- `{agent}-{YYYY-MM-DD}` — ежедневные
- `{agent}-W{NN}` — еженедельные
- `{agent}-last` — интервальные (timestamp)

Логи: `~/logs/synchronizer/`

---

*Source-of-truth: DP.SYS.016 (PACK-digital-platform)*
