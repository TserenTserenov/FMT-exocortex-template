Выполни сценарий «Подготовка к сессии стратегирования» для агента Стратег.

## Контекст

- **HUB (личные планы):** ~/Github/DS-strategy/current/
- **Документы стратегии:** ~/Github/DS-strategy/docs/ (ВСЕ файлы: Strategy.md, Dissatisfactions.md, Session Agenda.md)
- **Inbox:** ~/Github/DS-strategy/inbox/ (fleeting-notes.md + свежие файлы)
- **SPOKE (планы репо):** ~/Github/*/WORKPLAN.md
- **Стратегические карты:** ~/Github/*/MAPSTRATEGIC.md (если есть в репо)
- **MEMORY:** MEMORY.md (автозагрузка)

## Именование файлов в current/

```
DS-strategy/
├── current/
│   ├── WeekPlan W{N} YYYY-MM-DD.md
│   ├── WeekReport W{N} YYYY-MM-DD.md
│   └── DayPlan YYYY-MM-DD.md
├── archive/
├── docs/       # Strategy.md, Dissatisfactions.md, Session Agenda.md
├── inbox/      # fleeting-notes.md + входящие
```

## Предусловие

> **WeekReport уже создан** сценарием week-review (за 4 часа до session-prep).
> Подготовка к сессии НЕ собирает коммиты — читает готовый WeekReport.

## Процесс

> Структура повестки по шаблону `docs/Session Agenda.md`.

#### 1. Прочитать WeekReport (→ блок «Ревью»)

- Найди `WeekReport W*.md` в `DS-strategy/current/`
- Извлеки: completion rate, carry-over, инсайты

#### 2. Обработать inbox (→ блок «Inbox»)

- Прочитай `DS-strategy/inbox/fleeting-notes.md`
- Прочитай ВСЕ файлы из inbox/
- Для каждой заметки: → в план? → capture? → обсудить? → удалить?
- **WP Context Files** (`WP-*.md`): обработай отдельно:
  - Проверь: РП ещё актуален? `status: active`?
  - Если РП done (по WeekReport) — предложить архивацию в повестке
  - Если РП active — учесть «Текущее состояние» при формировании WeekPlan (блокеры, следующие шаги)

#### 3. Проверить неудовлетворённости (→ блок «НЭП»)

- Прочитай `DS-strategy/docs/Dissatisfactions.md`
- Какие операционные НЭП разрешены? Есть ли стратегические без привязки?

#### 4. Сверка со стратегией + агрегация MAPSTRATEGIC

- Прочитай `DS-strategy/docs/Strategy.md`
- Прочитай `~/Github/*/MAPSTRATEGIC.md`
- Агрегируй фазы → обнови Strategy.md «Текущие фазы»
- Обнови «Приоритеты месяца» по факту

#### 5. Обход WORKPLAN.md (Hub-and-Spoke)

- Прочитай `~/Github/*/WORKPLAN.md` → собери pending/in-progress РП

#### 6. Проверить нерегулярные блоки (Session Agenda)

- Прочитай `DS-strategy/docs/Session Agenda.md`
- Какие нерегулярные блоки применимы на этой неделе?

#### 7. Сформировать черновик WeekPlan с повесткой

#### 8. Сохрани черновик

1. Архивировать прошлый WeekPlan + DayPlan
2. Создать `current/WeekPlan W{N} YYYY-MM-DD.md`
3. Закоммить

**Результат:** черновик WeekPlan (`status: draft`) с повесткой сессии в `current/`.

> Следующий шаг: сессия стратегирования с пользователем → `prompts/strategy-session.md`.
