> **Тип репозитория:** `Downstream/instrument`

# Strategist Agent (Агент Стратег)

Инструмент запуска агента Стратег — скрипты, промпты и расписание.

---

## Треугольник: Pack → Code → Results

```
Pack (source-of-truth)          Code (инструмент)              Results (результаты)
──────────────────────          ─────────────────              ────────────────────
Ваш Pack-репо/                  DS-strategist/              DS-strategy/
  agent-passport.md               prompts/                       current/
  scenarios/                        session-prep.md                WeekPlan W{N}.md
    scheduled/                      day-plan.md                    WeekReport W{N}.md
    on-demand/                      evening.md                     DayPlan YYYY-MM-DD.md
                                    week-review.md               docs/
                                    add-wp.md                      Strategy.md
                                    check-plan.md                  Dissatisfactions.md
                                  scripts/                       archive/
                                    strategist.sh
                                  WORKPLAN.md
```

---

## Два режима работы

| | Операционный (реализован) | Стратегический (будущее) |
|---|---|---|
| **Что делает** | Планирует, отслеживает, отчитывается | Помогает осознать НЭП, выбрать методы |
| **Горизонт** | День → неделя | Неделя → месяц → год |
| **Взаимодействие** | Headless (session-prep) + интерактив (strategy-session) | Глубоко интерактивный |

---

## Скилы

| # | Скил | Промпт | Триггер | Статус |
|---|------|--------|---------|--------|
| 1 | Подготовка к сессии | `session-prep.md` | Пн утро (headless) | Реализован |
| 1b | Сессия стратегирования | `strategy-session.md` | Вручную (интерактив) | Реализован |
| 2 | План на день | `day-plan.md` | Вт-Вс утро + вручную | Реализован |
| 3 | Вечерний итог | `evening.md` | Вручную | Реализован |
| 4 | Итоги недели | `week-review.md` | Вс ночь | Реализован |
| 5 | Добавить РП | `add-wp.md` | Вручную | Реализован |
| 6 | Проверить задачу (WP Gate) | `check-plan.md` | WP Gate | Реализован |
| 7 | Закрытие дня | `day-close.md` | Вручную | Реализован |
| ~~8~~ | ~~Каскадное обновление~~ | — | — | **Поглощён session-prep + strategy-session** |

---

## Расписание (launchd, macOS)

| Время (UTC) | День | Сценарий | Plist |
|-------------|------|----------|-------|
| {{TIMEZONE_HOUR}}:00 | Понедельник | `session-prep` (headless) | `com.strategist.morning` |
| {{TIMEZONE_HOUR}}:00 | Вт-Вс | `day-plan` | `com.strategist.morning` |
| 00:00 | Понедельник | `week-review` | `com.strategist.weekreview` |

## Установка

```bash
./install.sh          # Установить launchd агенты

# Ручной запуск
./scripts/strategist.sh morning       # strategy (Пн) или day-plan (Вт-Вс)
./scripts/strategist.sh evening       # вечерний итог
./scripts/strategist.sh week-review   # итоги недели
./scripts/strategist.sh strategy-session  # сессия стратегирования (интерактив)
./scripts/strategist.sh day-close           # закрытие дня
```
