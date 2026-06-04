---
name: protocol-month-close
description: Slim-ядро протокола Month Close — триггеры, позиция в ВДВ v9, минимальный алгоритм
type: reference
valid_from: 2026-04-24

horizon: warm
domains: [protocol]
status: active
owner: user
schema_version: 1
---
# Протокол Month Close (ОРЗ-фрактал, 5-й масштаб)

> **Точка входа:** Вызвать Skill `month-close`. Алиас для `/run-protocol month-close`.
> **Принцип:** Month Close = стадия 7 каскада ВДВ v9 (PD.METHOD.008). Агрегация 4-5 Week Close'ов + переосмысление фазы/калибра. Не повторяет Week Close — читает его выходы.
> **Полный алгоритм:** `.claude/skills/month-close/SKILL.md`. Здесь — только триггеры и инварианты.

## Маршрутизация

| Триггер | Аргумент | Skill |
|---------|---------|-------|
| «закрываем месяц» / «итоги месяца» / `/month-close` | `month-close` | `.claude/skills/month-close/SKILL.md` |

## Позиция в ВДВ v9

| # | Стадия | Частота | Вход | Выход |
|---|--------|---------|------|-------|
| 5 | Закрытие дня | вечер | коммиты + DayPlan | DayPlan обновлён |
| 6 | Закрытие недели | Вс/Пн | DayPlan W{N}-1..7 + WeekPlan | Report W{N} |
| **7** | **Закрытие месяца** | **первый Пн месяца** | **Report W{N} прошлого месяца + Strategy.md** | **Strategy.md § R1-RN + archive/MonthClose YYYY-MM.md** |

## Инварианты

1. **Триггер = первый Пн месяца.** Запускать до Strategy Session первой недели.
2. **Предусловие:** Week Close предыдущей недели выполнен. Без свежего Report W{N-1} Month Close не запускается.
3. **Не слияние со Strategy Session.** Последовательно: сначала `/month-close`, потом Strategy Session. Разные роли (R23 Верификатор / R1 Стратег), разные артефакты.
4. **Не автозапуск.** Ручной вызов, документированный в DayPlan первого Пн (строка «Month Close YYYY-MM», 0.75h).
5. **Выход — два артефакта.** (1) обновлённый Strategy.md § Результаты месяца (R1-RN закрыты / перенесены / созданы новые). (2) `DS-strategy/archive/MonthClose YYYY-MM.md` — самостоятельный отчёт месяца.

## Минимальный алгоритм (8 шагов)

1. Предусловия (первый Пн? Week Close сделан?)
2. Сбор данных за месяц (коммиты, Week Report'ы, drift, decision log)
3. Мультипликатор месяца
4. Ретро метрик: фаза PD.FORM.078 + калибр PD.CHR.007
5. Ревизия проектов P1-P6 (ВДВ v9 § Проект)
6. R-вопросник M1-M6 (`memory/r-questionnaire.md`)
7. T-чеклист T23-T25 (`memory/t-checklist.md`) + add-ons: Decommission-триаж + Decision log review
8. Обновление Strategy.md + запись `MonthClose YYYY-MM.md` + commit + верификация R23

Полная разбивка шагов, шаблон отчёта, чеклист верификации → SKILL.md.

## Связь с другими протоколами

- **protocol-close.md** — Day/Week Close. Month Close опирается на их выходы.
- **protocol-open.md** — Session / Day Open. Не затрагивается.
- **protocol-work.md** — сессионная работа. Month Close = частный случай сессии с фиксированным алгоритмом.

## История

- 2026-04-24: протокол создан (WP-196 Ф12.2 + WP-226 Ф3). Первый прогон — 4 мая 2026 на закрытие апреля.
