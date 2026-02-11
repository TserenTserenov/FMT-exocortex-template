Выполни сценарий Day-Close для агента Стратег.

> **Триггер:** Ручной — по запросу пользователя.
> Отдельный файл отчёта НЕ создаётся. Итоги дня войдут в DayPlan следующего утра.

## Контекст

- **WeekPlan:** ~/Github/DS-strategy/current/WeekPlan W*.md
- **MEMORY:** MEMORY.md (автозагрузка)
- **Exocortex backup:** ~/Github/DS-strategy/exocortex/

## Алгоритм

### 1. Сбор коммитов за сегодня

```bash
# Для КАЖДОГО репо в ~/Github/:
git -C ~/Github/<repo> log --since="today 00:00" --oneline --no-merges
```

- Пройди по ВСЕМ репозиториям в `~/Github/`
- Сгруппируй коммиты по репозиториям
- Сопоставь с РП из недельного плана

### 2. Обновить WeekPlan

- Пометь завершённые РП как **done**
- Обнови статусы partial
- **НЕ удаляй** ничего

### 3. Обновить MEMORY.md

Синхронизируй статусы РП в MEMORY.md с обновлённым WeekPlan.

### 4. Backup экзокортекса

```bash
# Корневой CLAUDE.md
cp ~/Github/CLAUDE.md ~/Github/DS-strategy/exocortex/CLAUDE.md

# Memory (Слой 3)
cp ~/.claude/projects/*/memory/*.md ~/Github/DS-strategy/exocortex/
```

### 5. Закоммитить

- Закоммить все изменения в `DS-strategy`
- Запуши

## Правила

- **Ничего не удалять** из WeekPlan
- **Не создавать отдельный файл отчёта**
- Если коммитов за день нет — написать «Нет активности» и всё равно сделать backup

Результат: обновлённый WeekPlan + MEMORY.md + backup экзокортекса.
