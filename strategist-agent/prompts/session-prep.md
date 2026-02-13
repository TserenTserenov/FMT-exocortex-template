Выполни сценарий «Подготовка к сессии стратегирования» для агента Стратег.

Источник сценария: {{WORKSPACE_DIR}}/PACK-digital-platform/pack/digital-platform/02-domain-entities/DP.AGENT.012-strategist/scenarios/scheduled/01-strategy-session.md

## Контекст

- **HUB (личные планы):** {{WORKSPACE_DIR}}/DS-strategy/current/
- **Документы стратегии:** {{WORKSPACE_DIR}}/DS-strategy/docs/ (ВСЕ файлы: Strategy.md, Dissatisfactions.md, Session Agenda.md)
- **Inbox:** {{WORKSPACE_DIR}}/DS-strategy/inbox/ ([fleeting-notes.md](https://github.com/{{GITHUB_USER}}/DS-strategy/blob/main/inbox/fleeting-notes.md) + свежие файлы за неделю)
- **SPOKE (планы репо):** {{WORKSPACE_DIR}}/*/WORKPLAN.md
- **Стратегические карты:** {{WORKSPACE_DIR}}/*/MAPSTRATEGIC.md (если есть в репо)
- **MEMORY:** ~/.claude/projects/{{CLAUDE_PROJECT_SLUG}}/memory/MEMORY.md

## Именование файлов в current/

```
DS-strategy/
├── current/
│   ├── WeekPlan W{N} YYYY-MM-DD.md    # план недели (Пн дата)
│   ├── WeekReport W{N} YYYY-MM-DD.md  # отчёт недели (авто, Пн 00:00)
│   └── DayPlan YYYY-MM-DD.md          # план дня
├── archive/                            # старые файлы
├── docs/                               # Strategy.md, Dissatisfactions.md, Session Agenda.md
├── inbox/                              # fleeting-notes.md + входящие
```

В `current/` — только актуальные файлы. Старые перемещаются в `DS-strategy/archive/`.

## Предусловие

> **WeekReport уже создан** сценарием week-review (Пн 00:00, за 4 часа до session-prep).
> Подготовка к сессии НЕ собирает коммиты сама — читает готовый WeekReport.

## Процесс

> Результат — черновик WeekPlan с повесткой сессии в `current/`.
> Структура повестки по шаблону `docs/Session Agenda.md`.

#### 1. Прочитать WeekReport (→ блок «Ревью прошлой недели»)

- Найди `WeekReport W*.md` в `DS-strategy/current/`
- Извлеки: completion rate, carry-over, инсайты

> Если WeekReport не найден — сообщить об ошибке и собрать коммиты самостоятельно (fallback).

#### 2. Обработать inbox (→ блок «Разбор inbox и исчезающих заметок»)

- Прочитай `DS-strategy/inbox/fleeting-notes.md`
- Прочитай ВСЕ файлы из `DS-strategy/inbox/` (кроме .DS_Store и .docx)
- Для каждой заметки/файла определи: → в план недели? → capture в Pack? → в повестку для обсуждения? → удалить?
- **WP Context Files** (`WP-*.md`): обработай отдельно:
  - Проверь: РП ещё актуален? `status: active`?
  - Если РП done (по WeekReport) — предложить архивацию в повестке
  - Если РП active — учесть «Текущее состояние» при формировании WeekPlan (блокеры, следующие шаги)
- Сформируй блок повестки с рекомендациями по каждому элементу inbox

#### 3. Проверить неудовлетворённости (→ блок «НЭП»)

- Прочитай `DS-strategy/docs/Dissatisfactions.md`
- Проверь: какие операционные НЭП разрешены (можно закрыть)?
- Проверь: есть ли стратегические НЭП без привязки к РП на этой неделе?
- Сформируй блок повестки с предложениями

#### 4. Сверка со стратегией + агрегация MAPSTRATEGIC (→ блок «Стратегическая сверка»)

- Прочитай `DS-strategy/docs/Strategy.md` — фокусы года, Q1 цели, приоритеты месяца
- Прочитай `{{WORKSPACE_DIR}}/*/MAPSTRATEGIC.md` (если файл есть в репо)
- **Агрегируй** фазы из MAPSTRATEGIC.md → обнови секцию «Текущие фазы (MAPSTRATEGIC)» в Strategy.md
- Обнови «Приоритеты месяца» — статусы на основе WeekReport
- Проверь: соответствуют ли текущие РП стратегическому направлению?
- Отметь расхождения (РП без привязки к стратегии, или стратегия без РП)

#### 5. Обход WORKPLAN.md (Hub-and-Spoke)

- Прочитай `{{WORKSPACE_DIR}}/*/WORKPLAN.md` из каждого репо
- Собери все РП со статусом pending/in-progress
- Выяви расхождения с HUB-планом

#### 6. Проверить нерегулярные блоки (Session Agenda)

- Прочитай `DS-strategy/docs/Session Agenda.md`
- Определи: какие нерегулярные блоки применимы на этой неделе? (ретро, архитектура, разбор документа и др.)
- Если есть — добавь в повестку

#### 7. Сформировать черновик WeekPlan

- Выбери РП из месячных приоритетов + WORKPLAN.md + carry-over + inbox
- Сформируй таблицу с бюджетом
- Сформируй повестку сессии стратегирования (все блоки из шагов 1-6)
- Сформулируй вопросы для обсуждения с пользователем

#### 8. Сохрани черновик (ОБЯЗАТЕЛЬНО)

1. Перемести предыдущий `WeekPlan W*.md` из `current/` в `archive/`
2. Перемести предыдущий `DayPlan *.md` из `current/` в `archive/` (если есть)
3. WeekReport оставь в `current/` (для пользователя и для клуба)
4. Создай `current/WeekPlan W{N} YYYY-MM-DD.md` (Пн текущей недели)
5. Закоммить в DS-strategy

**Формат WeekPlan:**

```markdown
---
type: week-plan
week: W{N}
date_start: YYYY-MM-DD
date_end: YYYY-MM-DD
status: draft
agent: Стратег
---

# WeekPlan W{N}: DD мес — DD мес YYYY

---

## Итоги прошлой недели W{N-1}

> Источник: WeekReport W{N-1}

**Completion rate:** X/Y РП (N%)

**Carry-over:**
- #N — что осталось

**Ключевые инсайты:**
- ...

> Полные итоги: см. `WeekReport W{N-1} YYYY-MM-DD.md`

---

## Повестка сессии стратегирования

### Стандартные пункты
- [ ] Ревью прошлой недели (см. выше)
- [ ] Inbox: [N заметок, рекомендации по каждой]
- [ ] НЭП: [закрыть X, обсудить Y]
- [ ] Стратегическая сверка: [расхождения, фазы]

### Нерегулярные блоки (если применимы)
- [ ] ...

### Вопросы для обсуждения
1. ...

---

## Приоритеты месяца
[обновлённые приоритеты]

---

## План на неделю W{N}

| # | РП | Бюджет | Статус | Дедлайн | Репо |
|---|-----|--------|--------|---------|------|
| ... | ... | ... | pending | ... | ... |

**Бюджет недели:** ~Nh

---

## План на понедельник

| # | РП | Бюджет | Приоритет |
|---|-----|--------|-----------|
| — | **Сессия стратегирования: утвердить план** | 1h | обязательно |
| ... | ... | ... | ... |

---

*Создан: YYYY-MM-DD (Подготовка к сессии, draft)*
```

**Результат:** черновик WeekPlan (`status: draft`) с повесткой сессии в `current/`.

> Следующий шаг: сессия стратегирования с пользователем → `prompts/strategy-session.md`.
