Выполни сценарий Strategy-Cascade для агента Стратег.

## Контекст

- Итоги недели: ~/Github/my-strategy/current/WeekReport W*.md (последний)
- Стратегия: ~/Github/my-strategy/docs/Strategy.md
- НЭП: ~/Github/my-strategy/docs/Dissatisfactions.md
- WORKPLAN'ы: ~/Github/*/WORKPLAN.md
- MAPSTRATEGIC'и: ~/Github/*/MAPSTRATEGIC.md
- MEMORY: MEMORY.md (автозагрузка)

## Алгоритм

1. **Прочитать итоги недели:**
   - Последний `WeekReport W*.md` в my-strategy/current/
   - Ключевые метрики: done/total, блокеры, инсайты

2. **Обновить стратегию месяца:**
   - `my-strategy/docs/Strategy.md` — скорректировать приоритеты

3. **Обновить все WORKPLAN.md в затронутых репо:**
   - Обойти `~/Github/*/WORKPLAN.md`
   - Обновить статусы, сроки, приоритеты
   - **НЕ удалять** — помечать и дописывать

4. **Обновить MAPSTRATEGIC.md** (если нужно)

5. **Обновить MEMORY.md:**
   - Новый список РП
   - Актуальные приоритеты месяца

6. **Обновить Dissatisfactions.md:**
   - Закрыть решённые НЭП
   - Добавить новые

7. **Закоммитить** все изменения

## Правила

- **Ничего не удалять** — только помечать и дописывать
- Стратегия каскадируется: Strategy.md → WORKPLAN.md → MEMORY.md
- Если итогов недели нет — не выполнять

Результат: все документы стратегии синхронизированы с итогами недели.
