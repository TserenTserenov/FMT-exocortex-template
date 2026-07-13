---
valid_from: 2026-06-21
originSessionId: 9a0e726a-951e-4408-9e02-94d7eeffbf74
last_sync_commit: fe0df9dcb06cfc87c8a6cb2f7cce3ac0d3b64d5e

type: reference
horizon: warm
domains: [reference]
status: active
owner: user
schema_version: 1

name: "fpf-reference"
description: "Справочник FPF паттернов применимых в IWE: структура, ключевые Part C (C.11-C.28), трансляция терминов"
---
# FPF (First Principles Framework) — справочник

> Источник: `{{HOME_DIR}}/IWE/FPF/FPF-Spec.md` (4.6 MB, ~83000 строк, commit `093d30e`)
> Автообновление: см. WP-364 Direction 1 «Конвейер синхронизации FPF upstream»

## Когда читать FPF

- При работе с концепциями Level 1 (мета-онтология)
- При неясности базовых различений (Role/Method/Work, System/Episteme)
- При необходимости точной формулировки паттерна (A.*, B.*, etc.)
- При создании/проверке Pack на соответствие FPF

## Как читать

- НЕ читать целиком
- Сначала оглавление (первые 300 строк), потом нужную секцию
- Grep для конкретных паттернов (например, `A.7` для Strict Distinction)

## Структура FPF

- **Part A** — Kernel: Holon, BoundedContext, Role-Method-Work, Signature Stack
- **Part B** — Aggregation (Γ), Trust (F-G-R), Evolution Loop
- **Part C** — Domain extensions: Sys-CAL, KD-CAL, Kind-CAL, NQD-CAL, CausalUse-CAL
- **Part D** — Ethics & Conflict
- **Part E** — Constitution & Authoring
- **Part F** — Terminology unification (UTS, Bridges)
- **Part G** — SoTA Kit

### Ключевые паттерны Part C (актуальные для IWE)

| Код | Название | Статус | Назначение в IWE |
|-----|----------|--------|-----------------|
| C.11 | Decision Theory (Decsn-CAL) | Stable | Выбор альтернатив в ArchGate, Strategy Session |
| C.16 | MM-CHR Measurement & Metrics | Stable | Измерения RCS, baseline, показатели пилота |
| C.19 | Explore–Exploit Governor | Stable | Pool-политика экспериментов и методов |
| C.21 | Discipline-CHR (Field Health & Structure) | Stable | Здоровье научного поля, воспроизводимость, стандартизация |
| C.24 | Agentic Tool-Use & Call-Planning | Stable | Протокол Claude Code tool-use бюджет |
| C.26 | Quantum-Like Modeling Lens | Stable | Probe-coupled взаимодействия, order effects |
| C.27 | Temporal Claim Adequacy | Stable | Утверждения о скорости, ритме, трендах |
| C.28 | **CausalUse-CAL** | Stable | **Причинные утверждения: M1 улучшает X, рычаг даёт Y** |

### Новые и обновлённые паттерны (май–июнь 2026)

| Код | Название | Статус | Почему важно для IWE |
|-----|----------|--------|---------------------|
| C.2.P | Epistemic Precision Restoration | Stable | Восстановление точности эпистемы: EntityOfConcern, ClaimGraph, Viewpoint |
| A.19.ECS | Evaluation CharacteristicSpace Construction | Stable | Построение пространства характеристик для оценки объектов |
| A.19.SPR | State-Family Precision Restoration | Stable | Восстановление точности состояний: status, posture, readiness |
| E.18.1 | Problem-to-Work Carry-Through (P2W) | Stable | Как проблема переносится в работу без преждевременного выбора метода (обобщено с «только принципы» на любую проблему, 12.07.2026) |
| E.21 | FPF Pattern-Quality Evaluation CharacteristicSpace | Stable | Оценка качества паттернов FPF для declared reader/use/scope |
| F.19 | Ontology-First Plain Technical Rewriting | Stable | Онтология-first переписывание: phrase apparatus, boilerplate, negative catalogue |

## Системная терминология

| Русский | English (FPF) | Описание |
|---------|---------------|----------|
| Надсистема | Suprasystem | Содержит SoI (∋) |
| Целевая система | System-of-Interest (SoI) | То, что создаём |
| Система создания | Constructor | Создаёт SoI (→) |
| Объект озабоченности | EntityOfConcern | То, о чём речь в эпистеме; ≠ Description |

## Универсальные различения

| Различение | Почему важно |
|------------|--------------|
| Объект ≠ Модель | Модель — упрощение реальности |
| Модель ≠ Данные | Структура vs значения |
| Данные ≠ Представление | Внутреннее vs внешнее |
| Метод ≠ Инструмент | Способ действия vs средство |
| Метод ≠ Сценарий | Что делать vs пошаговый план |
| Знание ≠ Обучение | Pack vs курс |
| Знание ≠ Информация | Формализовано vs сырые данные |
| Виды ≠ Характеристики | Классификация vs измеряемое качество |
| EntityOfConcern ≠ Description | Объект озабоченности ≠ его описание (A.7, A.6.2–A.6.4) |

## Принципы работы

| Принцип | Код | Описание |
|---------|-----|----------|
| Холонический подход | A.1 | Всё — часть и целое одновременно |
| Ограниченный контекст | A.1.1 | Термин определён в границах контекста |
| Строгие различения | A.7 | Роль ≠ Метод ≠ Работа; EntityOfConcern ≠ Description |
| ADI-цикл | B.5 | Абдукция → Дедукция → Индукция |
| CausalUse-CAL | C.28 | Причинные утверждения: рунг, доказательная база, допустимое использование |
| Epistemic Precision Restoration | C.2.P | Восстановление точности эпистемических формулировок |

## C.28 CausalUse-CAL — практическое применение в IWE

> Добавлен в FPF 2026-05-05 (pull +4138 строк). Источник ailev: systemsworld.club.
> Полный текст: `FPF-Spec.md:45197`

**Суть.** Три коллапса, которые C.28 предотвращает:
1. **Rung collapse** — ассоциация, интервенция и контрфактик смешаны в одном «причина X→Y»
2. **Support collapse** — наблюдение, эксперимент, симуляция — одна «доказательная база»
3. **Use collapse** — результат, допустимый для reporting, используется для деплоя/сертификации

**Лестница причинности (Pearl Causal Hierarchy):**
| Рунг | Вопрос | Пример в IWE |
|------|--------|-------------|
| 1 Ассоциация | «Что вместе встречается?» | «Пилоты с M1 чаще достигают ступени 3» |
| 2 Интервенция | «Что случится, если сделать X?» | «Добавив M1, пилот поднимет baseline» |
| 3 Контрфактик | «Что было бы, если бы X?» | «Без M4 пилот бы не достиг калибра 3» |

**Активация C.28** — когда утверждение меняет то, что допустимо для публикации, деплоя, аудита, бенчмарка.

**Быстрый тест (CausalUseTriageRecord):**
1. Есть ли каузальное использование? yes/no/unclear
2. Какой рунг? (1=ассоциация / 2=интервенция / 3=контрфактик)
3. Какая доказательная база? (observational / interventional / realized-counterfactual / identified-estimate / simulation-only)
4. Что допустимо? Что НЕ допустимо? (supportedUse / unsupportedUse — всегда пара)
5. nextMove: cheapStop (переформулировать как ассоциацию) или escalate (открыть DurableCard)

**Применения в IWE/Pack:**

| Контекст | Типичная ошибка | C.28 fix |
|---------|----------------|---------|
| WP-151 рычаги (M1/M4) | «M1 поднимает собранность» — рунг 2 без доказательства | Переписать как рунг 1: «ассоциировано с ростом baseline в выборке N» |
| Портной рекомендации | «Добавь помидоры — улучшишь ступень» — rung 2 pretend | Добавить: «по корреляции в N=k пилотов, интервенционных данных нет» |
| ArchGate аргументы | «Если внедрить X, получим Y» — рунг 3 без SCM | Явно указать рунг, basis, unsupportedUse |
| Strategy Session | «Эта практика сработала в апреле» | Rung 1 (ассоциация), rival causes не исключены |
| Измерения dt_snapshot_rcs | Snapshot ≠ каузальное доказательство | basis = observationalAssociation, не interventional |

**Маршрут в FPF:** C.28 → **builds on** A.10, B.3, C.11, C.19, C.24, C.26, C.27, D.5, G.5, G.9

## Трансляция FPF → engineering-язык

> Используй при выводе результатов `/fpf`. Пользователь работает в engineering-терминах, не в FPF-жаргоне.

| FPF-термин | Engineering-эквивалент | Когда встретишь |
|------------|----------------------|-----------------|
| Holon | Компонент с определённой границей (часть и целое) | A.1 — декомпозиция систем |
| Bounded Context (A.1.1) | Контекст с чётким scope: свой язык, свои правила | DDD, микросервисы |
| F-G-R (Fact/Guess/Rumor) | Факт / предположение / слух — уровень доверия к данным | B.3 — оценка решений |
| Role ≠ Method ≠ Work (A.7) | Кто делает ≠ как делает ≠ конкретное выполнение | Проектирование процессов |
| Role Assignment (A.2.1) | Система в роли: `система#роль:контекст` — функциональное участие системы; роль сама не работает | Pack-онтология ролей, distinctions.md HD #26 |
| Service Polysemy (A.6.8) | Сервис = обещание + провайдерская роль + метод оказания + работа оказания + свидетельства. Сервис ≠ метод | DP сервисы MAP.002 vs FPF ситуация оказания |
| Mastery as Role (A.2) | Мастерство::роль — роль части экзокортекса/организма в деятельности. ≠ степень мастерства (характеристика) | PACK-personal cp.skl, distinctions.md HD #32 |
| Alpha | Ключевой рабочий продукт, по которому отслеживается прогресс | Управление проектами |
| Mereology | Отношение «часть-целое» между компонентами | Архитектура, composition |
| Affordance | Что компонент позволяет делать пользователю | API design, UX |
| ADI-цикл (B.5) | Гипотеза → проверка логикой → проверка данными | Принятие решений (/think) |
| Lawful Comparison (A.19) | Сравнение вариантов по одинаковым критериям | Выбор архитектуры (/archgate) |
| Strict Distinction (A.7) | Разные вещи — разные имена. Не смешивать в одном типе/enum | Code review, именование |
| EntityOfConcern | Объект озабоченности — то, о чём речь в эпистеме; ≠ Description | C.2.P, A.6.2–A.6.4 |
| P2W (E.18.1) | Problem-to-Work: как проблема (не только с принципами) становится работой без преждевременного выбора метода | Стратегические сессии, ArchGate |
| ECS (A.19.ECS) | Evaluation CharacteristicSpace: пространство характеристик оценки | Метрики, benchmark, QA |

## Обновление

- **Ручное:** `cd {{HOME_DIR}}/IWE/FPF && git pull`
- **Автоматическое:** WP-364 Direction 1 «Конвейер синхронизации FPF upstream» — еженедельный delta-report + автообновление кеша
- **Текущая версия:** sync commit `44dd88188a07646ef23aca32627a3f670525853f` (2026-07-13)
- **Словарь дрейфа терминов:** `memory/fpf-term-map.yaml` (WP-481 Ф11) — проверять после каждого pull, не чинить молча найденное
