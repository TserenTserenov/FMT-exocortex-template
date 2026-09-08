# ResidencyGate — Как использовать механизм согласия на доступ к данным

## Обзор

ResidencyGate — универсальный механизм для функций, которые работают с персональными данными типов 2.1-2.4. Функция объявляет, какие данные ей нужны, а ResidencyGate гарантирует, что:

1. **Point A (activation-time):** при включении функции → проверка согласия пилота
2. **Point B (lazy):** при реальном запросе данных → интерактивная проверка, если согласия нет

---

## Шаг 1. Объявить потребности в данных

### Для SKILL.md

В frontmatter или body добавить блок:

```yaml
data_needs:
  - type: 2.1, flow: inbound, name: digital-twin
  - type: 2.2, flow: outbound, name: health-export, schema_version: 1
```

**Поля:**
- `type`: один из типов 2.1/2.2/2.3/2.4 (из WP-475)
- `flow`: `inbound` (платформа → IWE) или `outbound` (IWE → платформа)
- `name`: уникальное имя потребности (для логирования)
- `schema_version` (опц.): версия схемы (default: 1)

### Для bash-hook

```bash
#!/bin/bash
# --- data-needs
# type: 2.2, flow_direction: inbound, name: daily-summary, schema_version: 1
# ---

# Ваш код hook'а
```

---

## Шаг 2. Интегрировать Point A в startup

**Скилл, вызываемый через Claude Code (Skill tool) — ничего интегрировать не нужно.** С 09.08.2026 хук `residency-gate-skill-adapter.sh` (PreToolUse, matcher `Skill`) проверяет `data_needs` из `SKILL.md` автоматически, до того как код скилла запустится — достаточно объявить блок в Шаге 1. Раньше эта проверка была когнитивной (автор мог забыть вставить `source`), теперь она механическая: тест чистой установки — `scripts/tests/test_residency_gate_skill_adapter.py`.

Если функция работает **вне Claude Code** (day-open pipeline на launchd, bot handler, любой процесс, который Claude Code не запускает) — Claude Code не видит её старт, автоматической проверки нет, интегрируйте вручную:

```bash
#!/bin/bash

# В начале скрипта: проверка согласия
source ~/.claude/hooks/residency-gate-init.sh "day-open" "$HOME/.claude/skills/day-open/SKILL.md"

# Если согласие дано — продолжать
# Если нет — скрипт вернёт 1 и выведет причину
```

---

## Шаг 3. Интегрировать Point B в код доступа к данным

Если функция **интерактивна** или требует согласия в конкретный момент:

```bash
#!/bin/bash

# При попытке чтения данных:
bash ~/.claude/hooks/residency-gate-lazy.sh "render-guides" "2.1" "inbound" "digital-twin"

# Если exit code = 0 → доступ разрешён
# Если exit code = 1 → доступ запрещён
```

---

## Шаг 4. Управление согласием (для пилота)

### Выдать согласие

```bash
python3 ~/.claude/skills/residency-gate/residency-gate.py grant \
  <function_id> <type> <flow_direction> <name>
```

Пример:
```bash
python3 ~/.claude/skills/residency-gate/residency-gate.py grant \
  day-open 2.2 inbound daily-summary
```

### Отозвать согласие

```bash
python3 ~/.claude/skills/residency-gate/residency-gate.py revoke \
  <function_id> <type> <flow_direction> <name> "reason"
```

### Список всех согласий

```bash
python3 ~/.claude/skills/residency-gate/residency-gate.py list
```

### Для конкретной функции

```bash
python3 ~/.claude/skills/residency-gate/residency-gate.py list day-open
```

---

## Состояние согласия

Согласие хранится локально вне Git и рабочего пространства:
`${IWE_STATE_HOME:-$HOME/.iwe/state}/data-residency.yaml`. Каталог доступен
только владельцу (`0700`), файл — `0600`.

При первом запуске ResidencyGate переносит прежний
`<IWE workspace>/current/data-residency.yaml` (workspace берётся из
`IWE_WORKSPACE`, затем `IWE_ROOT`/`IWE`, иначе `$HOME/IWE`) в новое место и сохраняет
точную восстановимую копию в `migration-backups/data-residency.yaml.legacy`.
Повторный запуск идемпотентен. Если старый и новый файлы различаются или один
из них повреждён, автоматическое объединение запрещено: гейт останавливается,
а оба исходных файла остаются без изменений.

На время атомарного переноса старый файл получает карантинное имя уже в частном
`IWE_STATE_HOME`, а не внутри Git-репозитория. Если старое и новое хранилища
находятся на разных файловых системах, автоматический перенос останавливается:
между ними невозможно сделать атомарное переименование. Символьные ссылки ниже
корня старого workspace и файлы с несколькими жёсткими ссылками также
отклоняются, чтобы согласие нельзя было прочитать или изменить через иной путь.
Каждое чтение повторно проверяет старый адрес: поздно запущенная старая версия
не может незаметно вернуть отозванное согласие.

Основной файл и миграционная копия намеренно не входят в Git и автоматические
резервные копии IWE. Для переноса или резервирования скопируйте их явным
действием в защищённое локальное либо зашифрованное хранилище и сохраните права
`0600`. Команда `list` предназначена для аудита и не является восстановимой
резервной копией. Учитывайте, что состояние может содержать пользовательские
причины отказа (`denied_reason`).

Пример содержимого:

```yaml
functions:
  day-open: 
    2.2_inbound_daily-summary: {status: granted, granted_at: 2026-07-11T12:00:00Z}
    2.1_inbound_digital-twin: {status: denied, denied_reason: user denied, denied_at: 2026-07-11T12:05:00Z}
```

---

## Примеры

### Пример 1: День-open с Point A

```bash
#!/bin/bash
# ~/.claude/hooks/day-open-main.sh

source ~/.claude/hooks/residency-gate-init.sh "day-open" "$HOME/.claude/skills/day-open/SKILL.md"

# Если мы здесь — согласие дано, продолжаем
# ...rest of day-open logic...
```

### Пример 2: Персональное руководство с Point B

```python
# render-pilot-guides.py

def get_digital_twin():
    """Fetch user's digital twin from platform (with lazy consent check)."""
    import subprocess
    
    result = subprocess.run([
        "bash", 
        "~/.claude/hooks/residency-gate-lazy.sh",
        "render-guides", "2.1", "inbound", "digital-twin"
    ], capture_output=True)
    
    if result.returncode != 0:
        logger.info("User denied access to digital twin")
        return None
    
    # Access granted, fetch data
    return fetch_from_platform()
```

---

## Версионирование (schema_version)

Если схема потребности изменится (новые поля, другой формат), увеличьте `schema_version` в объявлении. ResidencyGate автоматически:

1. Обнаружит версию-несовместимость
2. Сбросит статус согласия для функции (вернёт в `not_asked`)
3. При следующем запуске потребует нового согласия

---

## Переключение режимов согласия

| Сценарий | Используй |
|----------|-----------|
| Функция автономна, нет пилота в цикле | Point A (activation-time) |
| Функция интерактивна или разовый запрос | Point B (lazy) |
| Обе потребности (rare) | Оба механизма |

---

## Аудит и прозрачность

Полная история согласий:

```bash
python3 ~/.claude/skills/residency-gate/residency-gate.py list render-guides | jq .
```

Возвращает:
```json
{
  "2.1_inbound_digital-twin": {
    "status": "granted",
    "granted_at": "2026-07-11T12:00:00Z"
  },
  "2.2_outbound_health-export": {
    "status": "denied",
    "denied_reason": "user denied export",
    "denied_at": "2026-07-11T12:05:00Z"
  }
}
```

---

## Интеграция с новой функцией: Чеклист

- [ ] Объявить `data_needs` в SKILL.md или bash frontmatter
- [ ] Добавить Point A (activation) ИЛИ Point B (lazy) в зависимости от типа функции
- [ ] Протестировать отказ согласия (denied case)
- [ ] Документировать потребности в README функции
- [ ] При релизе — пилот выполняет `grant` или `deny` для каждой нужды
