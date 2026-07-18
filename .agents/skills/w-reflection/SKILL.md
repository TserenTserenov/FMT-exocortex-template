---
name: w-reflection
description: Записать W-рефлексию (мировоззренческий слот RCS) в learning.w_reflections. Используется Диагностом R28 (MIM.R.009) или вызывается пользователем после рефлексивной сессии. Влияет на gate Д→П (FORM.089 §5.2).
argument-hint: "<quality 1..5> [depth 1..3]"
version: 1.0.0
layer: L1
status: active
triggers:
  slash: [/w-reflection]
  phrases: []
routing:
  executor: script
  deterministic: true
  script_path: "scripts/iwe-w-reflection.sh"
  optimization_priority: 1
agents: none
interaction: one-shot
gates_required: []
gates_enforced: []
gates_rationale: "операционный скилл; WP Gate применим только при создании нового РП, не для операционных вызовов"
---

# W-Reflection — запись мировоззренческого индикатора

> **Назначение:** populate `learning.w_reflections` для расчёта `W.idx` в SR-алгоритме (FORM.089 §5).
> **Когда вызывать:** после рефлексивной сессии (диалог с Диагностом R28, индивидуальный самоанализ, разбор мировоззренческой ошибки). Не для рутинной фиксации настроения — это калибровка.
> **Влияние:** W ≥ 4 обязательно для перехода Дисциплинированный → Проактивный (gate Д→П).

## When to use

Записать W-рефлексию (мировоззренческий слот RCS) в learning.w_reflections. Используется Диагностом R28 (MIM.R.009) или вызывается пользователем после рефлексивной сессии. Влияет на gate Д→П (FORM.089 §5.2).

## Аргументы

- `$1 = quality_score` — 1..5 по рубрике:
  - 1 — поверхностная (констатация без причин)
  - 2 — описательная (есть «что было», нет «почему»)
  - 3 — анализирующая (причины, последствия)
  - 4 — системная (видение себя как системы, agency)
  - 5 — мета-системная (видение себя как роли в надсистеме)
- `$2 = depth_level` (опционально, default 2) — 1..3:
  - 1 — поверхностная
  - 2 — средняя (стандарт)
  - 3 — глубокая (>30 мин разбора)

## Algorithm

### Шаг 1. Вызвать скрипт маршрутизации

```bash
bash "$IWE_SCRIPTS/route-task.sh" --skill w-reflection --args "$ARGUMENTS"
```

Скрипт читает `IWE_OWNER_ORY_UUID` из окружения (account_id) и пишет в `learning.w_reflections` через роль `w_reflection_writer` (миграция 112). При отсутствии writer-URL — fallback на `DATABASE_URL_LEARNING_DIRECT`.

### Шаг 2. Проверить exit code

Exit codes и их значения — в разделе **Выход** ниже.

### Шаг 3. Вернуть ответ пилоту

При exit 0 — вывести OK-строку из stdout. При ненулевом exit — вывести ошибку.

## Выход

- exit 0 + `[w-reflection] OK: account=... quality=N depth=M` — успех
- exit 1 — невалидные аргументы
- exit 2 — отсутствует `IWE_OWNER_ORY_UUID` или DB URL
- exit 3 — ошибка БД (constraint violation, network)

## Пример

```bash
/w-reflection 3        # quality=3, depth=2 (default)
/w-reflection 4 3      # quality=4, глубокая
```

## Зависимости

- Миграция `112-w-reflection-writer-grants.sql` (в директории миграций инфраструктурного репозитория)
- Источник логики: [`PD.FORM.089-learner-rcs.md`](../../../PACK-personal/pack/personal-development/02-domain-entities/formalizations/PD.FORM.089-learner-rcs.md) §5
- Читатель: `learning.stage_evaluator` worker (WP-253 Блок 2 Ф1.3)

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
