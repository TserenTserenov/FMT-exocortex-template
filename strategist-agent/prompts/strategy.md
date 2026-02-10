Выполни сценарий Strategy Session для агента Стратег.

## Контекст

- **HUB (личные планы):** ~/Github/my-strategy/current/
- **SPOKE (планы репо):** ~/Github/*/WORKPLAN.md
- **Стратегические карты:** ~/Github/*/MAPSTRATEGIC.md (если есть в репо)
- **Неудовлетворённости:** ~/Github/my-strategy/docs/Dissatisfactions.md
- **MEMORY:** MEMORY.md (автозагрузка)

## Именование файлов в current/

```
my-strategy/
├── current/
│   ├── WeekPlan W{N} YYYY-MM-DD.md    # план недели (Пн дата)
│   ├── WeekReport W{N} YYYY-MM-DD.md  # отчёт недели (авто, Пн 00:00)
│   └── DayPlan YYYY-MM-DD.md          # план дня
├── archive/                            # старые файлы
```

В `current/` — только актуальные файлы. Старые перемещаются в `my-strategy/archive/`.

## Предусловие

> **WeekReport уже создан** сценарием week-review (за 4 часа до strategy).
> Strategy Session НЕ собирает коммиты сам — читает готовый WeekReport.

## Процесс (две фазы)

### Фаза 1: Формирование черновика (автоматически, headless)

#### 1. Прочитать WeekReport

- Найди `WeekReport W*.md` в `my-strategy/current/`
- Извлеки: completion rate, carry-over, инсайты

> Если WeekReport не найден — собрать коммиты самостоятельно (fallback).

#### 2. Обход WORKPLAN.md (Hub-and-Spoke)

- Прочитай `~/Github/*/WORKPLAN.md` из каждого репо
- Собери все РП со статусом pending/in-progress
- Выяви расхождения с HUB-планом

#### 3. Сверка со стратегией

- Прочитай `~/Github/*/MAPSTRATEGIC.md` (если файл есть в репо)
- Проверь: соответствуют ли РП недели стратегическому направлению?

#### 4. Сдвиг месячного окна

- Учти неудовлетворённости из `docs/Dissatisfactions.md`
- Предложи обновления приоритетов месяца

#### 5. План на неделю (предложение)

- Выбери РП из месячных приоритетов + WORKPLAN.md + carry-over
- Сформируй таблицу с бюджетом

#### 6. Сохрани черновик

1. Перемести предыдущий `WeekPlan W*.md` из `current/` в `archive/`
2. Перемести предыдущий `DayPlan *.md` из `current/` в `archive/`
3. WeekReport оставь в `current/`
4. Создай `current/WeekPlan W{N} YYYY-MM-DD.md`
5. Закоммить в my-strategy

---

### Фаза 2: Стратегирование с пользователем (интерактивно)

#### 7. Обсуждение и корректировка

- Пользователь читает черновик, корректирует

#### 8. Утверждение и синхронизация

- Смени `status: draft` → `status: confirmed`
- Обнови WORKPLAN.md в целевых репо
- **ОБЯЗАТЕЛЬНО:** Обнови MEMORY.md → секция «РП текущей недели»
- Закоммить

Результат: утверждённый WeekPlan, синхронизированные WORKPLAN.md и MEMORY.md.
