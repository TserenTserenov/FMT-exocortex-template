---
step: dispatcher
title: "Сессия стратегирования (weekly, короткий вариант)"
mode: weekly
client: claude-code
---

# Диспетчер: Сессия стратегирования (weekly)

> **Роль:** Стратег (R1) · **Частота:** еженедельно (Пн) · **Длительность:** ~15–20 мин
>
> Это **короткий вариант** для еженедельного ритма. Полный вариант (monthly) — `strategy-session-monthly.md`.

## Предусловие

Черновик WeekPlan (`status: draft`) уже создан сценарием `session-prep` (Пн 04:00). Если черновика нет — сообщи пользователю и предложи запустить `session-prep`.

## Инструкция для Claude (execution semantics)

**ЗАПРЕЩЕНО:** Read `strategy-session-weekly/steps/*`, glob по папке `strategy-session-weekly/steps/`, чтение нескольких файлов шагов за один ход.
**РАЗРЕШЕНО:** Read только файл шага, явно указанного на текущей позиции последовательности.

Каждый шаг — отдельный файл. Claude читает один шаг, выполняет, ждёт ответа пилота, затем читает следующий.

## Последовательность шагов

| # | Шаг | Gate | Файл |
|---|-----|------|------|
| 0 | Открытие | skip-if-empty | `strategy-session-weekly/steps/00-open.md` |
| 1 | Ревью недели + стоп-лист | user | `strategy-session-weekly/steps/01-review.md` |
| 7 | Нерегулярные блоки | skip-if-empty | `strategy-session-weekly/steps/07-irregular.md` |
| 3 | Неудовлетворённости | user | `strategy-session-weekly/steps/03-dissatisfactions.md` |
| — | **Weekly-stop gate** | — | Если любой сигнал (из 07 или 03) требует пересмотра состава РП текущей недели (убрать или добавить ≥1 РП) → **стоп**, предложи `strategy-session-monthly.md` |
| 6a | План: candidate pool | user | `strategy-session-weekly/steps/06a-pool.md` |
| 6b | План: бюджет + ТОС | user | `strategy-session-weekly/steps/06b-budget.md` |
| 8 | Утверждение | user | `strategy-session-weekly/steps/08-confirm.md` |

## Weekly-stop gate (операционный критерий)

После шага 03 оцени:
> Требуется ли пересмотр состава РП текущей недели (убрать или добавить хотя бы один РП)?

- **Да** → сообщи пилоту:
  > «Обнаружен сигнал, требующий пересмотра РП текущей недели. Предлагаю перейти к полной сессии (`strategy-session-monthly.md`) для стратегической сверки.»
  - Если пилот согласен → заверши weekly, предложи monthly
  - Если пилот отказывается → зафиксируй риск в WeekPlan («пилот отказался от monthly при пересмотре РП») и продолжай
- **Нет** → продолжай к 06a

## Jump-обработка

В weekly-режиме jump-handler не используется. Критическая НЭП обрабатывается weekly-stop gate.
