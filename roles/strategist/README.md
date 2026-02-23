# Стратег (R1)

> **Модуль шаблона:** `roles/strategist/` в [FMT-exocortex-template](../../README.md)
> **Роль:** R1 Стратег — планирование и отслеживание (DP.D.033 §7, DP.AGENT.001)

Роль Стратег автоматизирует операционное планирование: утренние планы, вечерние итоги, недельные обзоры. Текущий исполнитель: Claude (A1, Grade 3-4).

---

## Архитектура: Промпты → Стратег → Результаты

```
FMT-exocortex-template/              DS-strategy/ (отдельный репо)
  roles/strategist/                     current/
    prompts/                              WeekPlan W{N}.md
      session-prep.md                     WeekReport W{N}.md
      strategy-session.md                 DayPlan YYYY-MM-DD.md
      day-plan.md                       docs/
      evening.md                          Strategy.md
      week-review.md                      Dissatisfactions.md
      add-wp.md                         inbox/
      check-plan.md                       WP-{N}-*.md (контексты задач)
      day-close.md                      archive/
      note-review.md
    scripts/
      strategist.sh
```

**Потоки данных:**
- Промпты (PLATFORM) → обновляются через `update.sh`
- Результаты (PERSONAL) → DS-strategy/ (отдельный приватный репо, не затрагивается обновлениями)
- Входные данные: MEMORY.md, MAPSTRATEGIC.md (из каждого репо), WakaTime

---

## Два режима работы

| | Операционный (реализован) | Стратегический (реализован) |
|---|---|---|
| **Что делает** | Планирует, отслеживает, отчитывается | Помогает осознать НЭП, выбрать методы |
| **Горизонт** | День → неделя | Неделя → месяц → год |
| **Взаимодействие** | Headless (session-prep) + интерактив (strategy-session) | Глубоко интерактивный |

---

## Сценарии

| # | Сценарий | Промпт | Триггер | Статус |
|---|----------|--------|---------|--------|
| 1 | Подготовка к сессии | `session-prep.md` | Пн утро (headless) | Реализован |
| 1b | Сессия стратегирования | `strategy-session.md` | Вручную (интерактив) | Реализован |
| 2 | План на день | `day-plan.md` | Вт-Вс утро + вручную | Реализован |
| 3 | Вечерний итог | `evening.md` | Вручную | Реализован |
| 4 | Итоги недели | `week-review.md` | Вс ночь | Реализован |
| 5 | Добавить РП | `add-wp.md` | Вручную | Реализован |
| 6 | Проверить задачу (WP Gate) | `check-plan.md` | WP Gate | Реализован |
| 7 | Закрытие дня | `day-close.md` | Вручную | Реализован |
| 8 | Обзор заметок | `note-review.md` | По необходимости | Реализован |

---

## Расписание (launchd, macOS)

| Время (UTC) | День | Сценарий | Plist |
|-------------|------|----------|-------|
| {{TIMEZONE_HOUR}}:00 | Понедельник | `session-prep` (headless) | `com.strategist.morning` |
| {{TIMEZONE_HOUR}}:00 | Вт-Вс | `day-plan` | `com.strategist.morning` |
| 00:00 | Понедельник | `week-review` | `com.strategist.weekreview` |

> На Linux: настройте cron вручную (`crontab -e`). Без автоматизации Стратег запускается вручную.

## Установка

```bash
./install.sh          # Установить launchd агенты

# Ручной запуск
./scripts/strategist.sh morning           # session-prep (Пн) или day-plan (Вт-Вс)
./scripts/strategist.sh evening           # вечерний итог
./scripts/strategist.sh week-review       # итоги недели
./scripts/strategist.sh strategy-session  # сессия стратегирования (интерактив)
./scripts/strategist.sh day-close         # закрытие дня
./scripts/strategist.sh note-review       # обзор заметок
```
