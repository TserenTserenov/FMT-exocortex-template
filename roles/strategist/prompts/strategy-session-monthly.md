---
step: dispatcher
title: "Сессия стратегирования (monthly, полный вариант)"
mode: monthly
client: claude-code
---

# Диспетчер: Сессия стратегирования (monthly)

> **Роль:** Стратег (R1) · **Частота:** 1 раз в месяц (первая неделя) · **Длительность:** ~45–60 мин
>
> Это **полный вариант** с каскадом ВДВ. Еженедельный короткий вариант — `strategy-session-weekly.md`.

## Предусловие

Черновик WeekPlan (`status: draft`) уже создан сценарием `session-prep` (Пн 04:00). Если черновика нет — сообщи пользователю и предложи запустить `session-prep`.

## Инструкция для Claude (execution semantics)

**ЗАПРЕЩЕНО:** Read `strategy-session-weekly/steps/*`, glob по папке `strategy-session-weekly/steps/`, чтение нескольких файлов шагов за один ход.
**РАЗРЕШЕНО:** Read только файл шага, явно указанного на текущей позиции последовательности.

Каждый шаг — отдельный файл. Claude читает один шаг, выполняет, ждёт ответа пилота, затем читает следующий.

## Последовательность шагов

| # | Шаг | Gate | Файл |
|---|-----|------|------|
| 0 | Открытие + MonthClose gate | skip-if-empty | `strategy-session-weekly/steps/00-open.md` |
| 1 | Ревью недели + стоп-лист | user | `strategy-session-weekly/steps/01-review.md` |
| 2 | Inbox Triage | user | `strategy-session-weekly/steps/02-inbox.md` |
| 3 | Неудовлетворённости | user | `strategy-session-weekly/steps/03-dissatisfactions.md` |
| 4 | Стратегическая сверка | user | `strategy-session-weekly/steps/04-strategy-sync.md` |
| 5a | Калибр: измерение | auto | `strategy-session-weekly/steps/05a-measurement.md` |
| 5b | Калибр: рекомендация | user | `strategy-session-weekly/steps/05b-recommendation.md` |
| 5c | Калибр: трекинг | user | `strategy-session-weekly/steps/05c-tracking.md` |
| 6a | План: candidate pool | user | `strategy-session-weekly/steps/06a-pool.md` |
| 6b | План: бюджет + ТОС | user | `strategy-session-weekly/steps/06b-budget.md` |
| 6c | План: финализация | user | `strategy-session-weekly/steps/06c-finalize.md` |
| 7 | Нерегулярные блоки | skip-if-empty | `strategy-session-weekly/steps/07-irregular.md` |
| 8 | Утверждение и синхронизация | user | `strategy-session-weekly/steps/08-confirm.md` |

## Jump-обработка

Если пилот во время сессии решает вернуться к шагу 03:
1. Прочитай `jump-handler.md`
2. Следуй алгоритму jump-handler
3. После обработки jump — вернись к шагу 04

## Софт-гейт при ad-hoc jump

Если пилот пишет «назад к шагу 3» без явного сигнала critical — предупреди:
> «Возврат к НЭП сбросит шаги 4 (стратегическая сверка) и 5a/5b/5c (калибр). Продолжить?»
