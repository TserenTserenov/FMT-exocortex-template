---
name: bottleneck-pick
description: "Аналитик ограничений (DP.ROLE.054): находит главное ограничение (bottleneck) конкретного конвейера через TOC Five Steps + EC + NBR и строит Stage Dependency Map. Используй ТОЛЬКО при работе с конкретным WP, эпиком, проектом или weekplan (--target WP-NNN|weekplan|pilot:id). НЕ используй для общих вопросов приоритизации без явного системного контекста."
version: 1.0.0
layer: L1
status: active
triggers:
  slash: [/bottleneck-pick]
  phrases:
    - "выбери bottleneck"
    - "какое ограничение сейчас"
    - "горлышко системы"
    - "bottleneck-pick"
routing:
  executor: agent
  deterministic: false
---

# Skill: /bottleneck-pick

> # see DP.SC.045, DP.ROLE.054, DP.WP.016
>
> Носитель методики TOC для пилота: Goldratt Five Focusing Steps + Tendon TameFlow Replenishment Cycle + Dettmer Thinking Processes.
> Реализует роль **Аналитика ограничений (DP.ROLE.054)** через пятифазный ВДВ-каскад.
> Источник: WP-313 (Ф1 research: Tendon «Tame Your Work Flow», Dettmer, Schragenheim, Goldratt S&T; Ф11 IntegrationGate).

## Триггеры

- Пользователь открывает зонтичный РП, эпик, проект и спрашивает «что делать сначала»
- Запрос «выбери bottleneck», «что важнее», «с чего начать»
- Стратегическая сессия с отбором НЭП («какое направление сейчас bottleneck»)
- Диагност (R28) запрашивает анализ для учебного конвейера пилота
- Явный вызов `/bottleneck-pick --target WP-NNN`

## Принцип SC-first (главное правило)

> **Документо-центричный подход — анти-паттерн.** Начинать со списка pending-РП = риск принять канал доставки за продукт.

**Правильно:** Ф2 сканирует функциональные обещания (DP.SC) ДО Ф3 (signal-scan по структуре работ).
**Тест:** если в Constraint Brief нет ссылок на конкретные DP.SC, которые «не работают» — это провал Ф2.

## API

```
/bottleneck-pick --target <ref> [--layer intra|platform] [--horizon <горизонт>] [--depth <1|2|3>] [--scope <direct|direct+related|full>]
```

### Параметры

| Параметр | Default | Описание |
|----------|---------|----------|
| `--target` | обязательный | `WP-NNN` (зонтичный РП), `weekplan` (текущая неделя), `pilot:<account_id>` (учебный конвейер пилота), `b2:aisystant` (вся экосистема — требует `--layer=platform`), `c2:platform` (только техника — требует `--layer=platform`), project-name, repo-path |
| `--layer` | intra | `intra` = внутри одной системы (constraint = фаза / РП / блок). `platform` = между подсистемами C2 (constraint = подсистема / handover / роль B3). Опора: `memory/project_iwe_systems_map.md` |
| `--horizon` | all | day, week, month, wave-1, wave-2, quarter, next-stage |
| `--depth` | 2 | 1 = Five Steps only; 2 = + EC для конфликтующих кандидатов; 3 = + Coupling-analysis SOTA.011 для top-3 handovers (только при `--layer=platform`) |
| `--scope` | direct+related | direct = только target; direct+related = + связанные РП из frontmatter; full = + reachable через граф связей ≤2 hops |

### Источники по типу `--target`

| Target | Что читает скилл | Где живёт источник |
|--------|------------------|---------------------|
| `WP-NNN` | `${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/WP-NNN-*.md` + связанные РП + git за 7d | governance |
| `weekplan` | `${IWE_GOVERNANCE_REPO:-DS-strategy}/current/WeekPlan W{N}.md` + active-wp.md + DP.SC поверх активных РП | governance |
| `pilot:<id>` | `learning.activity_log` + `learning.cp_assessments` + `learning.bh_metrics` (Neon) | платформа (учебный конвейер) |
| `b2:aisystant` | `03-our-systems-map.md` (S2R) + `DP.MAP.002` + `project_iwe_systems_map.md` + cross-system SC | governance + Pack |
| `c2:platform` | `DP.MAP.002` (12 подсистем) + 15 новых Q2 из `project_iwe_systems_map.md` | Pack + memory |

### Error cases

| Ситуация | Поведение |
|----------|-----------|
| target не найден | «Не нашёл `<target>`. Проверь номер или путь.» → СТОП |
| target = done-РП | «`<target>` уже закрыт. Укажи активный РП.» → СТОП |
| target пустой (нет структуры) | «Нет структуры для анализа в `<target>`.» → СТОП |
| Данные устарели (>7 дней без git-активности) | Добавить ⚠️ к signal-scan, не останавливаться |
| EC не сходится (пустые assumptions) | Fallback к Five Steps, отметить в output |
| Все кандидаты не agent-actionable | «Все кандидаты не agent-actionable. Нужна другая точка входа.» |

---

## Алгоритм — пятифазный ВДВ-каскад

> Принцип ВДВ (DP.M.060): выход фазы = вход следующей. Каждый вход и выход — физический артефакт.

### Ф1 — Identify system

**Вход:** target-ref + `--layer` от пользователя.

**Действие:**
1. Классифицировать тип системы-конвейера по `--target` × `--layer`:
   - **Учебный конвейер пилота** — `--target pilot:<id>` (FORM.089 RCS, источник: Neon `learning.*`)
   - **Конвейер работ (intra)** — `--target WP-NNN | weekplan | project | repo-path`, `--layer=intra`. Структура = направления A-И / фазы Ф1-ФN / блоки внутри одного РП
   - **Платформенный (cross-system)** — `--target b2:aisystant | c2:platform | WP-NNN-зонтичный`, `--layer=platform`. Структура = подсистемы C2 (≈27 шт) + handovers + роли B3. ⚠️ Validation: при `--layer=platform` обязательно загрузить карту систем (`memory/project_iwe_systems_map.md` + `DP.MAP.002`)
   - **Когортный конвейер** — `--target cohort:<id> | wave-N`
2. Собрать контекст по типу:
   ```bash
   # intra
   git log --oneline --since="7 days ago" <repo>
   cat <target-context-file>
   ls <related-PROCESSES.md>

   # platform
   ls PACK-digital-platform/.../08-service-clauses/   # cross-system SC
   cat memory/project_iwe_systems_map.md              # карта 27 подсистем
   git log --oneline --since="7 days ago" --all       # активность по подсистемам
   ```
3. Зафиксировать свежесть данных. Если ≥7 дней без активности — ⚠️. При `--layer=platform`: проверить свежесть `DP.MAP.002` (стейл >30 дней → ⚠️).

**Выход:** **System Card** (в чат + calibration YAML):
```
Тип системы: учебный_конвейер | конвейер_работ_intra | конвейер_работ_platform | когортный_конвейер
Target: <target-ref>
Layer: intra | platform
Структура: <направления A-И | фазы Ф1-ФN | подсистемы C2 + handovers | RCS-слоты>
Подсистемы в scope: <N штук — только при layer=platform>
Свежесть данных: <дата + flags>
Незарегистрированные подсистемы: <list — только при layer=platform, если есть>
```

### Ф2 — Scan promises (SC-first)

**Вход:** System Card.

**Действие:**
1. Найти DP.SC по типу системы:
   - **`--layer=intra`** (WP / эпик / репо): SC из frontmatter РП + SC, потребляемые целевыми ролями + SC внутри одной подсистемы
   - **`--layer=platform`** (b2 / c2 / зонтичный РП): **cross-system SC** — DP.SC.020 retention, DP.SC.012 онбординг, DP.SC.003 обучение, Г-К1 гипотеза. Дополнительно проверить B3-to-B2 SC (команда↔экосистема) — часто не формализованы, флаг
   - **Учебный конвейер** (`pilot:`): FORM.089-разделы (специализация SC)
   - **Когортный конвейер**: SC из MAP.002 для wave-rollout, adoption, lifecycle
2. Для каждого SC применить тест работоспособности:
   ```
   - «Работает?» (свежесть события, наличие потребителей, отсутствие active incidents)
   - «Сломано?» (явный open incident, отсутствие events за N дней, негативный feedback)
   - «Частично?» (some consumers получают, другие — нет)
   ```
   **При `--layer=platform`** дополнительный тест: «Сломано на handover'е?» — одна подсистема даёт выход, другая не принимает (зазор между Bot и GitHub App, между Profiler и Stage Evaluator, и т.д.).
3. Пометить SC-failing и SC-partial как кандидатов в bottleneck.

**Выход:** **SC-status map** (формат зависит от `--layer`):

**Для `--layer=intra`:**
```
| SC ID         | Обещание                          | Статус       | Сигнал                                |
|---------------|------------------------------------|--------------|----------------------------------------|
| DP.SC.020     | Доставка персонального руководства| ⚠️ Partial  | 5/9 пилотов не активировали репо       |
| DP.SC.132     | Диагностика ученика                | ✅ Works    | cp_assessments записываются ежедневно  |
| DP.SC.044     | Event ingest                       | ⚠️ Partial  | subscription.contract_event = 0 строк  |
```

**Для `--layer=platform` (cross-system path):**
```
| SC          | Cross-system path                                  | Статус       | Слабое звено                              |
|-------------|----------------------------------------------------|--------------|-------------------------------------------|
| DP.SC.020   | Bot → /personal-guide-start → GitHub App → repo    | ⚠️ Partial  | handover Bot↔GitHub App (6/9 не активир.) |
| Г-К1        | Bot → Onboarding → Profiler → Stage Eval → Nudge   | ❌ FAIL     | отсутствует Nudge (WP-117 не запущен)     |
| DP.SC.112   | YooKassa → Bot → CRM → Access Manager              | ✅ Works    | стабильно                                  |
```

### Ф3 — Identify constraint

**Вход:** SC-status map + структура работ из System Card.

**Действие:**
1. Для каждого SC-failing/partial и каждого блока структуры (направление / фаза / РП / подсистема / handover) — signal-scan по сигналам TameFlow (порядок по predictive value):

| # | Сигнал | Триггер | Применим |
|---|--------|---------|----------|
| 1 | Queue accumulation rate | Δ queue length / 7d ≥30% рост | все |
| 2 | Flow Efficiency drop | touch/lead <15% или Δ −10pp/неделю | все |
| 3 | Dependency fan-in / handover count | >3 handover в одном user journey = policy issue | все |
| 4 | Buffer consumption rate | CCPM fever chart: Жёлтый→monitor, Красный→act | все |
| 5 | Policy freeze markers | NLP-поиск: «требует согласования», «у нас принято», «правило» | все |
| 6 | Cognitive freeze | рост открытых вопросов без решений, признаки прокрастинации | все |
| 7 | **Cross-system handover count** | handovers >3 на user journey между подсистемами C2 = systemic | **`--layer=platform` only** |
| 8 | **Coupling tightness (SOTA.011)** | SC одного слоя зависит от внутренней реализации другого = tight coupling, candidate handover-constraint | **`--layer=platform` only** |

2. Top-3 кандидата по суммарному сигналу.
3. Классифицировать каждого:
   - **Trichotomy (Tendon):** Work Flow / Work Process / Work Execution
   - **Class:** Policy / Resource / Cognitive
   - **При `--layer=platform`** дополнительно — **Locus** (где сидит ограничение): `Subsystem` (одна подсистема C2 — узкое место) / `Handover` (две подсистемы работают, между ними рвётся SC) / `Role(B3)` (подсистема есть, но роль в команде не назначена / перегружена)
4. FILTER: убрать не agent-actionable (внешняя блокировка, нет actionable шагов в 2-4h, done-блок).

**Выход:** **Constraint Brief draft** (top-3 + классификация + сигналы; для `--layer=platform` также Locus).

### Ф4 — Choose TOC tool

**Вход:** Constraint Brief draft.

**Действие — Decision tree:**

```
[Все --layer]

Очевиден слабейший этап + данные есть?
  → Five Steps (linear)

≥2 policy-markers ИЛИ cognitive-freeze сигнал высокий?
  → Five Steps + EC

2 кандидата равны, нет явного «кто слабее»?
  → EC (core conflict)

«Exploit» интуитивно = «нанять/купить» (инстинкт к Elevate)?
  → EC first (маркер: policy-constraint)

Решение очевидно, но есть риск side-effects?
  → Five Steps + NBR

[--layer=platform только]

Locus = Subsystem отсутствует (WP не существует под нужную SC)?
  → Five Steps + WP Gate Ритуал (нужно новое РП на создание подсистемы)

Locus = Handover между 2 подсистемами?
  → EC обязательно: D = «починить подсистему A» vs D' = «починить подсистему B»
  → + Coupling-analysis SOTA.011 при --depth=3: можно ли убрать handover вообще?

Locus = Role(B3) перегружена?
  → EC: D = «нанять» vs D' = «автоматизировать роль»
  → NBR обязательно (риск heavy-coordination overhead)

Все подсистемы стабильны, но cross-system SC не выполняется?
  → Goldratt S&T Tree: missing assumptions (нет SC, не зафиксировано обещание)
```

**Если EC:** Quality gate ≥2 assumption на сторону:
```
A (Common Goal): ...
B (Need): ...      C (Need): ...
D (Want): ...      D' (Want): ...
Assumptions D→B: ...
Assumptions D'→C: ...
Injection: ... (в assumption, не в action)
```
Пустые / абстрактные assumptions → retry или fallback к Five Steps. EC только на actions, не на values.

**NBR (обязательно после injection):** 3 negative branches + trim:
```
1. [риск 1] → trim: [как нейтрализовать]
2. [риск 2] → trim: [как нейтрализовать]
3. [риск 3] → trim: [как нейтрализовать]
```

**Выход:** **TOC tool trace** (инструмент + EC details если применён + NBR-trims).

### Ф5 — Compose stage map

**Вход:** Constraint Brief + TOC tool trace + список зависимостей (включая external).

**Действие:**
1. Идентифицировать этапы достижения целевого состояния (устранения ограничения):
   - Этап = состояние системы, не действие («Активация ≥5 пилотов» ≠ «Активировать пилотов»)
   - Внутри узла — параллельные работы по **жёсткому шаблону 4 категорий** (см. ниже)
   - Между узлами — жёсткая зависимость («иначе не сможем», не «желательно»)
2. Внутри каждого этапа распределить параллельные работы по **4 канонам TOC/Dettmer** (всегда показывать все 4, пустая = «—»):
   - **Техника (Platform/Technical)** — код, инфраструктура, архитектура, интеграции, CI/CD, data pipelines
   - **Процессы (Organizational/Process)** — процессы, коммуникации, координация между ролями, пользовательское тестирование, onboarding
   - **Правила (Policy/Governance)** — стандарты, архитектурные решения, согласования, изменения политики
   - **Навыки (Cognitive/Capability)** — обучение, документация, ментальные модели, формирование различений
3. Определить external-зависимости — от работ в других РП, репо, внешних поставщиков (отдельный блок, всегда показывать)
4. **При `--layer=platform`** — параллельная ось **Locus** для каждого этапа: Subsystem / Handover / Role(B3) — кто конкретно меняется
5. Построить граф (формат DP.WP.016): узлы=этапы, рёбра=hard_dependency, external-рёбра явные
6. Топологическая сортировка обязательна (нет циклов)

**Принцип жёсткого шаблона:** все 4 категории всегда показываются, даже пустые («—»). Аналогия: чек-лист безопасности самолёта — пункт «проверить шасси» оставляется даже для гидросамолёта, чтобы видно было что не забыли. Жёсткий шаблон ставит аудит-надёжность выше краткости.

**Выход:** **Stage Dependency Map** (формат DP.WP.016) — в чате как markdown + опционально в `${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/WP-NNN/stage-map.md`:

```markdown
## Stage Dependency Map: <target> (layer: intra | platform)

### Этап 1: <label-существительное-артефакт>
**Цель:** <состояние после этапа>

**Категории работ (жёсткий шаблон — всегда 4):**

**1. Техника (Platform):**
- работа A
- работа B (WP-NNN)

**2. Процессы (Process):**
- —

**3. Правила (Policy):**
- работа C → требует /archgate

**4. Навыки (Cognitive):**
- —

**External-зависимости:** <target в другом репо | нет>

[Только при --layer=platform — дополнительная ось:]

**Locus:**
- Subsystem: <подсистема X> — изменение внутри одной системы
- Handover: <A↔B> — изменение в зазоре между системами
- Role(B3): <роль> — изменение в команде

### → Этап 2: <label>
> Может начаться только после завершения Этапа 1 (причина: <reason>)
...
```

---

## Output (полный артефакт, выводится в чат)

```markdown
## System Card
**Тип системы:** учебный_конвейер | конвейер_работ_intra | конвейер_работ_platform | когортный_конвейер
**Target:** <target-ref>
**Layer:** intra | platform
**Структура:** <направления A-И | фазы | подсистемы C2 + handovers>
**Подсистемы в scope:** <N — только при layer=platform>
**Свежесть данных:** <дата + flags>

## SC-status map (Ф2 SC-first)
[--layer=intra:]
| SC | Обещание | Статус | Сигнал |
| --- | --- | --- | --- |
| DP.SC.NNN | ... | ✅/⚠️/❌ | ... |

[--layer=platform — cross-system path:]
| SC | Cross-system path | Статус | Слабое звено |
| --- | --- | --- | --- |
| DP.SC.020 | A → B → C → D | ⚠️ | handover B↔C |

## Constraint Brief
**Bottleneck:** <блок / направление / фаза / подсистема / handover / роль>
**Trichotomy:** Work Flow | Work Process | Work Execution
**Class:** Policy | Resource | Cognitive
**Locus:** Subsystem | Handover | Role(B3)  [только при layer=platform]
**Затронутые SC:** [DP.SC.NNN, ...]

### Signal-scan
- Queue accumulation: <Δ за 7d или «нет данных»>
- Flow Efficiency: <% или «нет данных»>
- Dependency fan-in: <N handovers>
- Policy markers: <keywords или «нет»>
- Buffer: <статус или «нет данных»>
- Cognitive freeze: <признаки или «нет»>
- Handover count (cross-system): <N на user journey>          [только при layer=platform]
- Coupling tightness (SOTA.011): low | medium | high         [только при layer=platform]

## TOC tool: Five Steps | EC | Five Steps + EC | + Coupling-analysis

[Если EC:]
### EC — core conflict
**A:** ...    **B:** ...    **C:** ...    **D:** ...    **D':** ...
**Assumptions D→B:** ...
**Assumptions D'→C:** ...
**Injection:** ...

### NBR
1. <риск> → trim: ...
2. <риск> → trim: ...
3. <риск> → trim: ...

## Stage Dependency Map (DP.WP.016)

### Этап 1: <label>
**Цель:** ...

**Категории работ (жёсткий шаблон — всегда 4):**

**1. Техника (Platform):** ...
**2. Процессы (Process):** ...
**3. Правила (Policy):** ...
**4. Навыки (Cognitive):** ...

**External-зависимости:** ...

**Locus:** Subsystem | Handover | Role(B3)  [только при layer=platform]

### → Этап 2: <label>
> Может начаться только после завершения Этапа 1 (причина: ...)
...

## Альтернативы (P2/P3 кандидаты)
- ...

## Skipped (не agent-actionable)
- ...

**Бюджет первого этапа: ~Nh**

---
Делаем Этап 1 «<label>» или хочешь начать с альтернативы P2 «<...>»?
```

---

## Anti-patterns

1. **WP-сканирование без SC-first** — начать со списка pending-РП без проверки функциональных обещаний. Риск: принять канал доставки за продукт.
2. **Stage Map с датами/часами** — формат структурный, не временной. Даты → premature commitment.
3. **Soft-зависимости в edges** — только `hard_dependency`. «Желательно сначала» = они в одном этапе или независимы.
4. **Skip Subordinate → Elevate** («нанять больше людей» как первый вывод) — exploit capacity сначала.
5. **Policy mis-classified as Resource** — нанимать когда надо менять правила. Применять discriminator из Schragenheim.
6. **Moving Herbie без policy-диагноза** — если bottleneck мигрировал 2+ раз → policy-driven, не resource.
7. **EC с пустыми assumptions** — retry или fallback к Five Steps.
8. **Five Steps на cognitive freeze** — не ускорять flow, а упростить challenge или нарастить навык.
9. **Output >1 экрана для Constraint Brief** — сжимать, не разворачивать дерево целиком (Stage Map может быть длиннее).
10. **EC на values** (D/D' = «гибкость» vs «стабильность») — переформулировать в actions.
11. **Stage Dependency Map без external-зависимостей** — если этап реально зависит от работ в другом РП — явное external-ребро.
12. **Stage Map с пустой категорией без «—» (мягкий шаблон)** — нельзя отличить «забыл подумать» от «решил пропустить». Жёсткий шаблон: всегда 4 категории, пустая = «—».
13. **[platform-only] Сводить platform к одной системе** — выбирать одну подсистему C2 как bottleneck без проверки cross-system SC. Симптом: ответ «WP-117 = bottleneck» без объяснения какие SC он закрывает.
14. **[platform-only] B3-blindness** — bottleneck в роли (Юля, Ильшат, Tseren bus-factor) пропускается, потому что роли не в MAP.002. Force: явно проверить B3 в Ф3.
15. **[platform-only] Handover-blindness** — обе подсистемы работают, но между ними рвётся SC. Force: handover = отдельная единица анализа в Locus.
16. **[platform-only] «Нанять менеджера» как первый Elevate для Role-constraint** — Role(B3) решается через автоматизацию роли (subsystem), не через найм. Force: EC обязателен для Role-constraint.
17. **[platform-only] Coupling debt accumulation** — Subordinate-plan не учитывает coupling-debt после фикса (SOTA.011). Force: `--depth=3` с Coupling Model для Handover-constraint.

---

## Calibration (после каждого применения)

Сохранить в `${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/bottleneck-pick-runs/<YYYY-MM-DD>-<target>.yaml`:

```yaml
date: YYYY-MM-DD
target: <target-ref>
layer: intra | platform
system_type: учебный_конвейер | конвейер_работ_intra | конвейер_работ_platform | когортный_конвейер
subsystems_in_scope: N                    # только при layer=platform
sc_failing: [DP.SC.NNN, ...]              # из Ф2
identified_constraint:
  location: <блок | подсистема | handover | роль>
  trichotomy: work_flow | work_process | work_execution
  class: policy | resource | cognitive
  locus: subsystem | handover | role_b3   # только при layer=platform
instruments_used: [five_steps, ec, nbr, coupling_analysis]
stage_dependency_map:
  num_stages: N
  has_external_deps: true | false
  categories_filled: [platform, process, policy, cognitive]  # какие из 4 не пустые
action_taken: <что сделали>
was_correct: null          # заполняется на Week Close
observed_throughput_change_after_2w: null
bottleneck_shifted_to: null                # заполняется через 2 недели
```

После 5–10 runs → анализ precision на Week Close, recalibration весов сигналов.

---

## Интеграция

- **Bottleneck = архитектурное решение** (тип Policy с alternatives) → предложить `/archgate`
- **Stage Map содержит open-loop работу ≥3h** → предложить Декомпозитору (`/decompose`) для декомпозиции на физические артефакты
- **Bottleneck = нет покрывающего РП** → предложить WP Gate ритуал
- **Bottleneck-shift detection** (повторное применение к той же target после fix) → DP.M.061 переоценка слоя (tech/operational/usage/поведенческий)

---

## Связанные документы (Pack)

- **DP.ROLE.054** — Аналитик ограничений (носитель методики)
- **DP.SC.045** — обещание Constraint Analysis (что выдаём потребителю)
- **DP.WP.016** — формат Stage Dependency Map
- **DP.M.061** — Bottleneck-Shift Detection (поддерживающий метод после устранения ограничения)
- **PD.PRINC.046** — Mental Model as Constraint (Tendon)

---

## Staging

`STAGING.md`: S-42, `status: testing`
Промоция после: ≥2 smoke (выполнено) + ≥1 калибровочная сессия + пилот принял ≥3 выбора без редиректа + Pack-артефакты оформлены (выполнено Ф11).

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
