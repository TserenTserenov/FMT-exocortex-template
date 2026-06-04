---
name: Memory Lifecycle & Classification Protocol
description: Спецификация онтологии памяти v1 — 4 оси, frontmatter-схема, правила архивации HOT/WARM/COLD
type: protocol
horizon: warm
domains: [protocol, behaviour]
status: active
valid_from: 2026-04-30
owner: user
schema_version: 1
---

# Memory Lifecycle & Classification Protocol v1

> **Артефакт WP-217 Ф10.1.** ArchGate пройден 2026-04-30.
> **Реализация:** Ф10.2 (memory-validate.sh), Ф10.3 (интеграция Close), Ф10.4 (миграция).

## 1. Проблема

MEMORY.md раздувается: feedback_behaviour.md = 442 строки, feedback_architecture.md = 275 строк. Файлы не классифицированы, нет TTL, нет явного владельца. OwnerIntegrity нарушена — live index (MEMORY.md) содержит и навигацию, и контент, и changelog одновременно.

Корневая причина: нет онтологии памяти. Файлы создаются ad-hoc без горизонта и статуса.

## 2. Трёхслойная архитектура

```
HOT (каждая сессия, ≤150 строк total)
 └→ WARM (14 дней без обращения, по триггеру)
     └→ COLD (30 дней без обращения, по запросу)
         └→ memory/archive/ (90 дней без обращения, физически перемещён)
```

| Слой | Загрузка | Лимит | TTL до понижения |
|------|----------|-------|-----------------|
| **HOT** | Каждая сессия автоматически | Суммарно ≤150 строк (без frontmatter) | — |
| **WARM** | По триггеру (тема, ключевое слово) | Нет | 14 дней без обращения |
| **COLD** | Только по явному запросу | Нет | 30 дней без обращения |
| **archive** | Только ретроспектива | — | Не понижается |

## 3. Frontmatter-схема v1

**Все файлы `memory/*.md` обязаны содержать frontmatter.** Файл без frontmatter = нарушение, блокируется `memory-validate.sh` (Ф10.2).

### Обязательные поля

```yaml
---
name: "Краткое название (совпадает с именем файла без расширения)"
description: "Одна строка — используется в MEMORY.md как hook-строка индекса"
type: user | feedback | project | reference | lesson | protocol
horizon: hot | warm | cold | archive
domains: [тег1, тег2]
status: active | dormant | superseded | archived
valid_from: YYYY-MM-DD
owner: user | platform
schema_version: 1
---
```

### Опциональные поля

```yaml
valid_until: YYYY-MM-DD       # когда истекает (для project-контекста)
superseded_by: filename.md    # ОБЯЗАТЕЛЕН если status: superseded
originSessionId: <uuid>       # ID сессии создания
```

### Инварианты

- `status: superseded` → поле `superseded_by` ОБЯЗАТЕЛЬНО
- `horizon: hot` → файл участвует в HOT-лимите (≤150 строк total)
- `schema_version` = 1 (текущая)
- Изменение `schema_version` → миграция через `memory-migrate.sh` (§8)

## 4. Четыре оси классификации

### Ось 1: type

| type | Что содержит | Горизонт по умолчанию |
|------|-------------|----------------------|
| `user` | Профиль: роль, цели, навыки, предпочтения | hot |
| `feedback` | Правила поведения агента: что делать/не делать | hot (если активно применяется) |
| `project` | Контекст инициатив, решений, дедлайнов | warm |
| `reference` | Ссылки на внешние системы, URL, конфиги | warm |
| `lesson` | Извлечённые уроки из конкретной работы | warm |
| `protocol` | Операционные протоколы (lazy-load) | warm |

### Ось 2: horizon

| horizon | Описание |
|---------|----------|
| `hot` | Нужен агенту в начале каждой сессии. Лимит: суммарно ≤150 строк по всем HOT-файлам |
| `warm` | Загружается при обнаружении тематического триггера (ключевое слово, сервис, РП) |
| `cold` | Загружается только по явному запросу типа «найди историю по X» |
| `archive` | Физически в `memory/archive/`. В индексе MEMORY.md не присутствует |

### Ось 3: domains (теги)

Допустимые теги: `behaviour`, `architecture`, `infrastructure`, `writing`, `protocol`, `user-profile`, `project-iwe`, `project-bot`, `project-mcp`, `neon`, `railway`, `cloudflare`, `linear`, `git`, `memory`

Несколько тегов: `domains: [behaviour, architecture]`

Добавление нового тега: просто использовать. Реестр тегов не нужен.

### Ось 4: status

| status | Условие | Следующий шаг |
|--------|---------|---------------|
| `active` | Регулярно используется | — |
| `dormant` | Не упоминалось >30 дней | При Month Close: предложить понизить horizon или supersede |
| `superseded` | Заменено другим файлом | Указать `superseded_by:`, убрать из HOT-индекса |
| `archived` | Перемещён в `memory/archive/` | Удалить из MEMORY.md активного индекса |

## 5. Правила архивации

### Понижение горизонта (предлагает агент)

| Переход | Условие | Кто решает |
|---------|---------|-----------|
| HOT → WARM | `horizon: hot` + не упоминался ≥14 дней | Агент предлагает при Week Close |
| WARM → COLD | `horizon: warm` + не упоминался ≥30 дней | Агент предлагает при Month Close |
| COLD → archive | `horizon: cold` + не упоминался ≥90 дней | Агент предлагает + пользователь подтверждает |

**Агент предлагает — не выполняет автономно.** Исключение: обновление `horizon` в frontmatter (не разрушительно) при явном Week Close шаге.

### Лимит HOT

Если новый файл с `horizon: hot` приведёт к превышению 150 строк суммарно → агент ОБЯЗАН предложить перевести один из HOT-файлов в WARM перед добавлением.

Измерение: `wc -l memory/*.md | awk` с фильтром по `horizon: hot` в frontmatter (реализация Ф10.2).

## 6. Правила создания файла memory/

1. Определить **type** (одно из 6 значений) и **horizon** (по умолчанию §4.1)
2. Заполнить все обязательные поля frontmatter
3. Добавить строку в MEMORY.md в нужную секцию: `- [Название](filename.md) — hook`
4. Проверить HOT-лимит: если превышен → понизить старый HOT-файл

При автоматическом создании через систему памяти (Write в `memory/`):
- Claude ОБЯЗАН добавить frontmatter с заполненными всеми полями
- Файл без frontmatter = нарушение OwnerIntegrity, требует немедленного исправления

## 7. Правила обновления MEMORY.md

- MEMORY.md = индекс, не хранилище контента
- Каждый файл = одна строка в секции: `- [Название](filename.md) — hook`
- `status: superseded` → строка ~~зачёркивается~~
- `status: archived` (физически перемещён) → строка удаляется из активного индекса
- HOT-файлы идут в первые секции, WARM — по тематике, COLD — только если требуют явного упоминания

## 8. Миграция схемы (v1 → v2)

При изменении обязательного поля frontmatter:
1. Обновить `schema_version: 2` в этом документе
2. Написать `memory-migrate.sh --from 1 --to 2` (шаблон: добавляет новое поле с default-значением в frontmatter каждого файла)
3. Прогнать: `for f in memory/*.md; do bash scripts/memory-migrate.sh "$f" --from 1 --to 2; done`
4. Обновить §3 Frontmatter-схема с новым полем

Шаблон-скрипт входит в Ф10.2 как `scripts/memory-migrate.sh.example`.

---

*Создано: 2026-04-30. Артефакт WP-217 Ф10.1. ArchGate: Э=⚠️ (schema_version митигирует), С=✅.*
