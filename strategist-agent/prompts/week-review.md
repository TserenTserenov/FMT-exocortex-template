Выполни сценарий Week Review для агента Стратег.

> **Триггер:** Автоматический — Пн 00:00 (полночь Вс→Пн, launchd).
> Создаёт WeekReport. Служит входом для Strategy Session.

## Контекст

- **WeekPlan:** ~/Github/my-strategy/current/WeekPlan W*.md

## Алгоритм

### 1. Сбор данных (Стратег собирает сам)

```bash
# Для КАЖДОГО репо в ~/Github/:
git -C ~/Github/<repo> log --since="last monday 00:00" --until="today 00:00" --oneline --no-merges
```

- Пройди по ВСЕМ репозиториям в `~/Github/`
- Сопоставь коммиты с РП из WeekPlan

### 2. Статистика

- Completion rate: X/Y РП (N%)
- Коммитов всего
- Активных дней
- По репозиториям (таблица)

### 3. Инсайты

- Что получилось хорошо
- Что можно улучшить
- Carry-over на следующую неделю

### 4. Сохранение

1. Создай `current/WeekReport W{N} YYYY-MM-DD.md`
2. Закоммить в my-strategy

Результат: WeekReport в `current/` — как вход для Strategy Session.
