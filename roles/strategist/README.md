# Стратег (R1)

> **Модуль шаблона:** `roles/strategist/` в [FMT-exocortex-template](../../README.md)
> **Роль:** R1 Стратег — планирование и отслеживание (DP.D.033 §7, DP.ROLE.001)

Роль Стратег автоматизирует операционное планирование: утренние планы, вечерние итоги, недельные обзоры. Текущий исполнитель: Claude (A1, Grade 3-4).

---

## Архитектура: Промпты → Стратег → Результаты

```
FMT-exocortex-template/              DS-strategy/ (отдельный репо)
  roles/strategist/                     current/
    prompts/                              WeekPlan W{N}.md
      add-wp.md                           WeekReport W{N} YYYY-MM-DD.md (факты недели, WP-297)
      check-plan.md                       DayPlan YYYY-MM-DD.md
      evening.md                        docs/
    scripts/                              Strategy.md
      strategist.sh                       Dissatisfactions.md
  memory/                              inbox/
    protocol-open.md  (← day-plan)       WP-{N}-*.md (контексты задач)
    protocol-close.md (← day-close)    archive/
```

> **Примечание:** Промпты `session-prep`, `strategy-session`, `day-plan`, `week-review`, `day-close`, `note-review` вынесены из шаблона. `day-plan` и `day-close` мигрировали в протоколы `memory/protocol-open.md` и `memory/protocol-close.md`. Остальные создаются пользователем в его DS-репо при установке.

**Потоки данных:**
- Промпты (PLATFORM) → `prompts/` (3 базовых) + `memory/protocol-*.md`
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
| 1 | Подготовка к сессии | DS: `session-prep.md` | Пн утро (headless) | Создаётся пользователем |
| 1b | Сессия стратегирования | DS: `strategy-session.md` | Вручную (интерактив) | Создаётся пользователем |
| 2 | План на день | `memory/protocol-open.md` | Вт-Вс утро + вручную | В шаблоне |
| 3 | Вечерний итог | `prompts/evening.md` | Вручную | В шаблоне |
| 4 | Итоги недели | DS: `week-review.md` | Вс ночь | Создаётся пользователем |
| 5 | Добавить РП | `prompts/add-wp.md` | Вручную | В шаблоне |
| 6 | Проверить задачу (WP Gate) | `prompts/check-plan.md` | WP Gate | В шаблоне |
| 7 | Закрытие дня | `memory/protocol-close.md` | Вручную | В шаблоне |
| 8 | Обзор заметок | DS: `note-review.md` | По необходимости | Создаётся пользователем |

---

## Расписание (launchd, macOS)

| Время (местное время машины) | День | Сценарий | Plist |
|-------------|------|----------|-------|
| {{TIMEZONE_HOUR}}:00 | Понедельник | `session-prep` (headless) | `com.strategist.morning` |
| {{TIMEZONE_HOUR}}:00 | Вт-Вс | `day-plan` | `com.strategist.morning` |
| 00:00 | Понедельник | `week-review` | `com.strategist.weekreview` |

> `day-plan` по расписанию собирает только конвейер Открытия дня (`scripts/day-open-pipeline.sh`). Если он не собрал план, свободный промпт вместо него не запускается: в Telegram приходит одно сообщение «План дня не собран» с причиной, а план собирается в сессии командой «открывай». Сбой установки (конвейер не установлен; шлюза модели нет и каркас без модели не собрался) завершает попытки на этот день, но только когда тревога доставлена: пока настроенный Telegram её не принял, запуск выходит с кодом 74 и записывает, на чём сдался; следующий запуск планировщика только шлёт тревогу снова, не запуская конвейер (не больше трёх отправок за день); иной сбой повторяет планировщик Синхронизатора, если он установлен, не больше трёх попыток за день. Отсрочка конвейера (код 7: вчерашний день ещё не закрыт) — не сбой: тревоги нет, попыткой она не считается, конвейер сам сообщает об отсрочке.

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
