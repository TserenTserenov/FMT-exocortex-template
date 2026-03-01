# Контракт роли (Role Contract)

> Формальная спецификация: что должна содержать директория роли в `roles/`.
> Теория: [DP.D.033](https://github.com/TserenTserenov/PACK-digital-platform/blob/main/pack/digital-platform/01-domain-contract/DP.D.033-role-centric-architecture.md) (Role-Centric Architecture).
> Каталог ролей: [DP.AGENT.001 §3.2](https://github.com/TserenTserenov/PACK-digital-platform/blob/main/pack/digital-platform/02-domain-entities/DP.AGENT.001-ai-agents.md).

---

## Обязательные файлы

| Файл | Назначение |
|------|-----------|
| `role.yaml` | Машиночитаемый манифест: идентичность, тип, установка |
| `README.md` | Человекочитаемое описание: назначение, сценарии, когда устанавливать |
| `install.sh` | Точка входа установки (launchd/cron/no-op) |

## Опциональная структура

| Путь | Когда нужен |
|------|------------|
| `prompts/*.md` | Роль использует ИИ-агента (Grade 2+) |
| `scripts/{role}.sh` | Роль имеет runner-скрипт |
| `scripts/launchd/*.plist` | Роль использует macOS-расписание (независимо от синхронизатора) |
| `config/` | Роль-специфичная конфигурация |

## Полная структура

```
roles/{name}/
├── role.yaml              # ОБЯЗАТЕЛЬНО — манифест
├── README.md              # ОБЯЗАТЕЛЬНО — документация
├── install.sh             # ОБЯЗАТЕЛЬНО — установщик
├── prompts/               # Для ИИ-агентов
│   └── {scenario}.md      # Один файл = один сценарий
├── scripts/
│   ├── {name}.sh          # Runner (вызывает AI CLI с промптом)
│   └── launchd/           # macOS scheduling (опц.)
│       └── com.exocortex.{name}.plist
└── config/                # Роль-специфичная конфигурация
```

---

## Схема role.yaml

```yaml
# === Обязательные поля ===
name: string              # Имя директории (lowercase, без пробелов)
id: string                # ID роли из DP.AGENT.001 (R1, R2, R8, ...)
type: agential|functional # agential = Grade 2+ (ИИ), functional = Grade 0-1 (bash)
display_name: string      # Человеческое имя ("Стратег", "Экстрактор")

# === Runner (опц. — роли без скриптов могут опустить) ===
runner: string            # Путь к runner-скрипту (относительно директории роли)
# ИЛИ для мульти-скриптовых ролей:
scripts:
  - string                # Список скриптов

# === Установка ===
install:
  auto: boolean           # true = setup.sh ставит автоматически
  priority: integer       # Порядок установки (меньше = раньше)

# === Уведомления (опц.) ===
notify_template: string   # Имя файла в synchronizer/scripts/templates/
```

### Пример (Стратег)

```yaml
name: strategist
id: R1
type: agential
display_name: "Стратег"
runner: scripts/strategist.sh
install:
  auto: true
  priority: 1
notify_template: strategist.sh
```

---

## Как setup.sh использует role.yaml

1. Сканирует `roles/*/role.yaml`
2. `install.auto: true` → устанавливает автоматически (в порядке `priority`)
3. `install.auto: false` → выводит инструкцию для ручной установки
4. Без `role.yaml` → пропускает (не роль, а служебная директория)

## Как scheduler.sh использует role.yaml

1. Читает `runner:` → определяет путь к скрипту запуска
2. Fallback: `scripts/{name}.sh` (если role.yaml отсутствует)
3. Расписание: `synchronizer/config.yaml` (единый источник расписания)

---

## Как добавить новую роль

1. Создай `roles/<name>/`
2. Создай `role.yaml` по схеме выше
3. Добавь `README.md` (шаблон описания: [DP.D.033 §3](https://github.com/TserenTserenov/PACK-digital-platform/blob/main/pack/digital-platform/01-domain-contract/DP.D.033-role-centric-architecture.md))
4. Добавь `install.sh` (скопируй из существующей роли, адаптируй)
5. Если ИИ-агент: добавь `prompts/` со сценариями
6. Если нужно расписание: добавь секцию в `synchronizer/config.yaml`
7. Для уведомлений: добавь шаблон `synchronizer/scripts/templates/<name>.sh`
8. `setup.sh` обнаружит роль автоматически

---

*Последнее обновление: 2026-03-01*
