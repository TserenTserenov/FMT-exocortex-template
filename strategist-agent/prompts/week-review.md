Выполни сценарий Week Review для агента Стратег.

> **Триггер:** Автоматический — Пн 00:00 (полночь Вс→Пн, launchd).
> Создаёт WeekReport для клуба. Служит входом для session-prep (Пн 4:00).

Источник сценария: {{WORKSPACE_DIR}}/PACK-digital-platform/pack/digital-platform/02-domain-entities/DP.AGENT.012-strategist/scenarios/scheduled/03-week-review.md

## Контекст

- **WeekPlan:** {{WORKSPACE_DIR}}/DS-strategy/current/WeekPlan W*.md
- **Шаблон:** {{WORKSPACE_DIR}}/PACK-digital-platform/pack/digital-platform/02-domain-entities/DP.AGENT.012-strategist/templates/reviews/weekly-review.md

## Алгоритм

### 1. Сбор данных (Стратег собирает сам)

```bash
# Для КАЖДОГО репо в {{WORKSPACE_DIR}}/:
git -C {{WORKSPACE_DIR}}/<repo> log --since="last monday 00:00" --until="today 00:00" --oneline --no-merges
```

- Пройди по ВСЕМ репозиториям в `{{WORKSPACE_DIR}}/`
- Загрузи текущий WeekPlan из `DS-strategy/current/`
- Сопоставь коммиты с РП из WeekPlan
- Определи статус каждого РП: done / partial / not started

### 2. Статистика

- Completion rate: X/Y РП (N%)
- Коммитов всего
- Активных дней (дни с коммитами)
- По репозиториям (таблица)
- По системам (Созидатель, Экосистема, ИТ-платформа, Бот)

### 3. Инсайты

- Что получилось хорошо
- Что можно улучшить
- Блокеры (если были)
- Carry-over на следующую неделю

### 4. Формат для клуба

- Используй шаблон `weekly-review.md` (если есть)
- Добавь хештеги
- Формат: компактный, читаемый, с метриками

### 5. Сохранение

1. Создай `current/WeekReport W{N} YYYY-MM-DD.md`
2. Закоммить в DS-strategy

**Шаблон WeekReport:**

```markdown
---
type: week-report
week: W{N}
date: YYYY-MM-DD
status: final
agent: Стратег
---

# WeekReport W{N}: DD мес — DD мес YYYY

## Метрики
- **РП:** X/Y завершено (N%)
- **Коммитов:** N в M репо
- **Активных дней:** N/7

## По репозиториям

| Репо | Коммиты | Основные изменения |
|------|---------|-------------------|
| ... | ... | ... |

## РП

| # | РП | Статус | Комментарий |
|---|-----|--------|-------------|
| ... | ... | done/partial/⬜ | ... |

## Инсайты
- ...

## Carry-over
- ...

---

*Создан: YYYY-MM-DD (Week Review)*
```

Результат: WeekReport в `current/` — для клуба и как вход для session-prep.
