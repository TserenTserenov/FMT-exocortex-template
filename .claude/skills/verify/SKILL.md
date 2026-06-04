---
name: verify
description: Верификация артефакта по эталону из Pack. Загружает роль VR.R.001 (Верификатор) с context isolation — проверяет результат, а не процесс создания.
argument-hint: "[code|archgate|capture|wp|chain|adversarial|subsection|section|guide|auto] [путь или id]"
routing:
  executor: sonnet
  deterministic: false
---

# Верификация артефакта

> **Роль:** VR.R.001 Верификатор (PACK-verification)
> **Принцип:** Context isolation (VR.SOTA.002) — проверяю результат по эталону, НЕ процесс создания.
> **Архитектура:** Ядро (Pack, фиксированное) + Контекст (переменный) — AS.D.004.

Аргументы: $ARGUMENTS

## Шаг 0. Определить тип проверки

| Аргумент | Тип | Что проверяет |
|----------|-----|---------------|
| `code` | Проверка кода | Качество кода: логика, edge cases, безопасность, coupling |
| `archgate` | Проверка реализации АрхГейта | Код соответствует ЭМОГССБ-оценке, принципы воплощены |
| `capture` | Проверка capture-candidate | UL, полнота, непротиворечивость с Pack |
| `wp` | Приёмка рабочего продукта | Критерии done из WP context file |
| `chain` | Data flow check | Прочитаны ли downstream consumers? Контракты совпадают? (CoVe stage 3) |
| `adversarial` | Scope & bias check | Scope определён анализом или выводом? Что НЕ прочитано? (Pre-mortem) |
| `subsection` | Проверка подраздела руководства (SS) | 🔴 v4-lint + 🟡 нарратив/дуга/практика/аналогия (G-L) по CHECKLIST-subsection-v1.md |
| `section` | Проверка раздела руководства (S) | 🔴 v4-lint section + 🟡 связность SS, дуга по ступеням, охват темы (D-H) по CHECKLIST-section-v1.md |
| `guide` | Проверка руководства целиком | 🔴 v4-lint guide + 🟡 целостность объекта, дуга, охват узлов мастерства, эпилог (E-I) по CHECKLIST-guide-v1.md |
| `auto` или пусто | Автоопределение | По типу файла и контексту сессии |

**Автоопределение:**
- Был АрхГейт в текущей сессии → `archgate`
- Указан путь к .py/.ts/.sh файлу → `code`
- Указан путь к Pack-сущности → `capture`
- Указан путь к WP context → `wp`
- Изменения >1 файла + cross-component → предложить `chain`
- После АрхГейта + код → предложить `adversarial`
- Путь содержит `subsection_id: PD.GUIDE.N.SX.SSY` во frontmatter, или один файл подраздела руководства → `subsection`
- Путь — папка раздела (`S{N}-*/`) или указан `section_id` во frontmatter → `section`
- Путь — `structure-guide-N.md` или папка руководства целиком → `guide`
- Не определился → спросить пользователя

**Триггеры от пилота:** «проверь подраздел X» / «проверь раздел S{N}» / «проверь руководство N» → соответственно `subsection` / `section` / `guide`.

## Шаг 1. Запустить sub-agent Верификатора

Запустить Agent tool с context isolation:

**Для `code`:**
- Прочитать `git diff` (или указанные файлы)
- Прочитать `CLAUDE.md` затронутого репо
- Передать sub-agent'у: diff + CLAUDE.md + чеклист code
- Модель sub-agent'а: Sonnet

**Для `archgate`:**
- Найти ЭМОГССБ-таблицу из текущей сессии (или запросить)
- Прочитать изменённые файлы реализации
- Прочитать DP.ARCH.001 §7 (21 принцип)
- Передать sub-agent'у: файлы + таблица + принципы + чеклист archgate
- Модель sub-agent'а: Opus

**Для `capture`:**
- Прочитать capture-candidate
- Прочитать manifest целевого Pack
- Передать sub-agent'у: candidate + manifest + чеклист capture
- Модель sub-agent'а: Sonnet

**Для `wp`:**
- Прочитать WP context file (`DS-strategy/inbox/WP-{N}-*.md`)
- Прочитать артефакт РП
- Передать sub-agent'у: артефакт + критерии done + чеклист wp
- Модель sub-agent'а: по verification_class:
  - `trivial` → Haiku
  - `closed-loop` / `open-loop` → Sonnet
  - `problem-framing` → Opus

**Для `chain` (CoVe — Chain-of-Verification, Meta ACL 2024):**
- Прочитать `git diff` изменённых файлов
- Для каждого изменённого output: `grep` по codebase — найти все файлы, которые import/require/вызывают изменённые функции
- Прочитать каждый downstream consumer
- Передать sub-agent'у: diff + consumers + чеклист chain
- Модель sub-agent'а: Sonnet
- **Чеклист chain:**
  1. Для каждого изменённого output — кто потребляет?
  2. Прочитан ли каждый потребитель?
  3. Типы/формат output совпадают с ожиданиями потребителя?
  4. Переменные, используемые в предложенном коде — откуда определены? Существуют ли в scope?
  5. Env vars / конфиги, на которые опирается код — определены ли в том же файле или переданы явно?

**Для `adversarial` (Pre-mortem + Devil's Advocate, PROClaim 2026):**
- Прочитать `git diff` изменённых файлов
- Составить список файлов, которые автор НЕ прочитал, но которые могут быть затронуты (`git diff --stat` vs файлы из diff)
- Прочитать описание задачи (из WP context или commit message)
- Передать sub-agent'у: diff + unread files list + task description + чеклист adversarial
- Модель sub-agent'а: Sonnet
- **Чеклист adversarial:**
  1. Scope определён анализом кода или подогнан под заранее выбранный вывод?
  2. Какие файлы/компоненты НЕ прочитаны, но могут быть затронуты?
  3. Предположи, что этот фикс сломается в production. 3 наиболее вероятные причины?
  4. Есть ли альтернативные объяснения проблемы, которые не были рассмотрены?
  5. Заявленный scope («1 файл», «не архгейт», «простой фикс») — соответствует реальному?

**Для `subsection` (один подраздел руководства, WP-322 Ф0.10):**

> Двухэтапная проверка: 🔴 машинная (оркестратор) → 🟡 семантическая (sub-agent). 🟢 пилот не делается агентом.

**Переменные окружения:**
- `IWE_ROOT` — корень рабочей директории (default: `$HOME/IWE`). Используется для путей к Pack и `DS-principles-curriculum`.

**Hotfix-исключение:** если последний коммит содержит `[hotfix]` в message — запускается только 🔴, без 🟡 (см. CHECKLIST-subsection-v1.md §«Правило»).

**Auxiliary-режим:** если frontmatter подраздела содержит `format_version: 4.1-aux` — это auxiliary-подраздел (.08-concepts, .09-exercises, .10-review-questions, .11-section-conclusions). Применяется **упрощённая** проверка: только 🔴 B (минимальный frontmatter: `subsection_id`, `title`, `order`) + 🟡 проверка типа содержимого (concepts = сводка, exercises = практики, review = вопросы, conclusions = выводы). Полный G-L НЕ применяется (auxiliary не вводит понятий, не имеет цепочки мем→метод→мировоззрение).

- **Этап 🔴 (оркестратор, локально):**
  ```bash
  IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
  cd "$IWE_ROOT/DS-principles-curriculum"
  PACK_FORM_089="$IWE_ROOT/PACK-personal/pack/personal-development/02-domain-entities/formalizations/PD.FORM.089-learner-rcs.md"
  # 1. Структура (A.1-A.11) + контракт Портного (B.1-B.9)
  python3 tools/v4-lint.py porter <subsection.md>
  # 2. Кросс-руководная согласованность
  python3 tools/v4-lint.py cross-guide specs/v4-reference/
  # 3. Pack-drift (cp/bh)
  python3 tools/v4-lint.py pack-drift specs/v4-reference/ --pack "$PACK_FORM_089"
  # 4. Граф понятий
  python3 tools/v4-lint.py graph build specs/v4-reference/ --out-json /tmp/graph.json
  # 5. Блок F (Git-целостность + F.4 формат степеней) — вне v4-lint:
  git -C "$IWE_ROOT/DS-principles-curriculum" status --porcelain specs/v4-reference/   # F.1 чисто
  grep -l "$(basename <subsection.md>)" "$IWE_ROOT/aisystant/docs" 2>/dev/null || \
    echo "F.3 WARN: файл может быть не в правильном репо"
  # F.4 (формат «Степени мастерства» — таблица, не список) проверяется вручную или в 🟡
  ```
  - Любой FAIL → verdict `FAIL` с диагностикой из stderr, sub-agent НЕ запускается
  - Все PASS → перейти к 🟡

- **Этап 🟡 (два специализированных sub-agent, Opus, context isolation) — WP-322 Ф14:**

  > Разделение на два субагента: смешанный промпт снижает качество обеих веток. FPF-агент видит только FPF; педагог-агент видит только педагогику.

  **Пропустить auxiliary:** если `format_version: 4.1-aux` — Этап 🟡 заменяется упрощённой проверкой типа содержимого.

  **Порядок: FPF → педагог** (FPF-нарушения часто блокируют педагогическую оценку).

  **Sub-agent 1 — verify-fpf (промпт: `verify-fpf-subsection.md`):**
  - Вход: файл подраздела
  - Промпт: `.claude/skills/verify/verify-fpf-subsection.md`
  - Модель: Opus
  - Проверяет: G (границы понятий, A.6), H (нарратив мем→метод→мировоззрение), L (Pack-согласованность), border-objects
  - Если FPF-Verdict = FAIL → остановиться, вернуть FAIL автору, Sub-agent 2 не запускать

  **Sub-agent 2 — verify-pedagogy (промпт: `verify-pedagogy-subsection.md`):**
  - Вход: файл подраздела
  - Промпт: `.claude/skills/verify/verify-pedagogy-subsection.md`
  - Модель: Opus
  - Проверяет: I (дуга по ступени, нет дидактических запрещённых слов), J (практика и время), K (аналогия), transfer test

- **Итоговый Verdict (агрегированный):**
  - PASS = FPF-PASS + Педагог-PASS → готов к 🟢 пилот-тесту (вывести шаблон issue `pilot-feedback.yml`)
  - CONDITIONAL = любой CONDITIONAL без FAIL → можно к 🟢 с оговорками
  - FAIL = любой FAIL → диагностика автору с разбивкой по блокам

**Для `section` (раздел руководства S, WP-322 Ф0.10):**

> Предусловие: ВСЕ подразделы раздела уже прошли `verify subsection` (🔴+🟡 PASS). Если нет — остановиться, попросить сначала закрыть SS.

**Hotfix-исключение:** если последний коммит содержит `[hotfix]` в message И затронут только один SS — запускается `verify subsection` для этого SS, без полного `verify section`.

- **Этап 🔴 (оркестратор):**
  ```bash
  IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
  cd "$IWE_ROOT/DS-principles-curriculum"
  # 1. Структурная полнота раздела (A.1-A.4, B.1-B.3, C.1-C.2)
  python3 tools/v4-lint.py section --id <section-id> specs/v4-reference/
  # 2. Связность prerequisites внутри раздела (отдельная проверка B.1-B.3, дублирует часть section)
  python3 tools/v4-lint.py prerequisites-graph --scope section --id <section-id> specs/v4-reference/
  ```
  - Любой FAIL → verdict `FAIL`
  - PASS → перейти к 🟡

- **Этап 🟡 (sub-agent, Opus, context isolation):**
  - Прочитать: ВСЕ SS раздела (в порядке оглавления) + frontmatter раздела + `CHECKLIST-section-v1.md` §🟡 (D-H)
  - Объём: типично 5-12 SS × 0.5-1.5K слов = 3-20K слов
  - Передать sub-agent'у промпт: все SS подряд + frontmatter + чек-лист §D-H
  - **Модель: Opus** — по эталону `CHECKLIST-section-v1.md` §🟡 («Claude Opus, context isolation»). Sonnet справляется по объёму, но связность нарратива и согласованность метафор раздела требуют глубокого анализа — Opus.
  - **Чеклист D-H (5 блоков по 3-4 пункта):**
    - D. Нарративная связность подразделов (логический переход, нет «висящих» SS, нет повторов)
    - E. Дуга по ступеням внутри раздела (stage_relevant согласован, тональность, сложность нарастает)
    - F. Охват темы (обещанное раскрыто, нет «дыры» в зоне раздела, нет «лишнего»)
    - G. Аналогии в разделе (согласованность сквозных метафор, нет конкурирующих)
    - H. Связь с другими разделами (ссылки корректны, нет противоречий)
  - Sub-agent для каждого пункта: PASS/FAIL + конкретные SS-ссылки

- **Verdict:** PASS = 🔴+🟡 PASS → готов к 🟢 пилот-тесту раздела (≥3 пилота × 6/6). FAIL = диагностика по конкретным SS.

**Для `guide` (руководство целиком, WP-322 Ф0.10):**

> Предусловие: ВСЕ разделы руководства уже прошли `verify section`. Если нет — остановиться.
> Это **самый дорогой** тип проверки — Opus, объём 20-100K слов.

**Hotfix-исключение:** при `[hotfix]` в коммите — только `verify subsection` затронутых файлов; полный `verify guide` не запускается. Полный запуск guide — ежеквартально (content-аудит) или при релизе нового руководства.

- **Этап 🔴 (оркестратор):**
  ```bash
  IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
  cd "$IWE_ROOT/DS-principles-curriculum"
  PACK_FORM_089="$IWE_ROOT/PACK-personal/pack/personal-development/02-domain-entities/formalizations/PD.FORM.089-learner-rcs.md"
  GUIDE_ID="<guide-id>"   # PD.GUIDE.<N> или N (1-4)
  # 1. Структурная полнота руководства (A.1-A.5, B.1-B.4, C.1-C.3)
  python3 tools/v4-lint.py guide --id "$GUIDE_ID" --pack "$PACK_FORM_089" specs/v4-reference/
  # 2. Кросс-руководная согласованность (внутри guide + между guides)
  python3 tools/v4-lint.py cross-guide --scope guide --id "$GUIDE_ID" specs/v4-reference/
  # 3. Граф понятий руководства
  python3 tools/v4-lint.py graph build --scope guide --id "$GUIDE_ID" --out-json /tmp/guide-graph.json specs/v4-reference/
  # 4. Pack-drift на масштабе руководства (если не прошло через cmd_guide --pack)
  python3 tools/v4-lint.py pack-drift --scope guide --id "$GUIDE_ID" --pack "$PACK_FORM_089" specs/v4-reference/
  ```
  - Любой FAIL → verdict `FAIL`
  - PASS → перейти к 🟡

- **Этап 🟡 (sub-agent, Opus, context isolation):**
  - Прочитать: ВСЕ S/SS руководства + структуру (`structure-guide-N.md`) + README + `CHECKLIST-guide-v1.md` §🟡 (E-I) + frontmatter руководства
  - Объём: типично 4-8 разделов × 5-12 SS × 0.5-1.5K слов = 20-100K слов — нужен Opus с большим контекстом
  - **Стратегия для большого объёма (20-100K слов):**
    - Если объём ≤ 30K слов — передать всё руководство одним промптом Opus с extended thinking
    - Если объём > 30K — батчинг: sub-agent читает разделы по 2-3 за раз, аккумулирует findings, в финале — meta-pass на согласованность дуги (E-I критерии требуют видения всего руководства)
    - Альтернатива: разделить guide-чек-лист на «целостность объекта + дуга» (E, F — требуют целостного видения, один проход) и «охват + связность + эпилог» (G, H, I — можно по частям)
  - Передать sub-agent'у промпт: руководство целиком + структура + чек-лист §E-I
  - Модель: Opus (объём + глубина анализа мировоззренческого сдвига)
  - **Чеклист E-I (5 блоков по 3-4 пункта):**
    - E. Целостность объекта (с первого раздела ясно, не подменяется, границы соблюдены)
    - F. Дуга нарратива (прогрессия 1-2 → 3-5, нет «прыжков», мировоззренческий сдвиг отчётлив, тональность согласована)
    - G. Охват узлов мастерства (cp/bh-измерения покрыты, нет «дыр» по ступеням, bottleneck-узлы помечены)
    - H. Связность с другими руководствами (cross-references, нет дублирования, точки сопряжения объяснены)
    - I. Эпилог и навигация (эпилог есть, связь со ступенями, README с картой)
  - Sub-agent для каждого пункта: PASS/FAIL + конкретные S/SS-ссылки

- **Verdict:** PASS = 🔴+🟡 PASS → готов к 🟢 пилот-тесту руководства (≥3 пилота × 6/6, типично 2-4 недели). FAIL = диагностика по конкретным S/SS.

## Шаг 2. Sub-agent: промпт

Sub-agent получает промпт с заполненными данными из шага 1.

**⛔ Sub-agent НЕ получает:**
- Историю обсуждения текущей сессии
- Задание создателя
- Промежуточные рассуждения

**Для `code`, `capture`, `wp`, `archgate`** — определить эталон:

| Тип артефакта | Эталон |
|---------------|--------|
| Pack-сущность | SPF pack-template + доменные принципы Pack |
| Описание метода | SPF process/07 + Pack |
| Код (DS) | CLAUDE.md репо + Pack-описания сервисов |
| Архитектурное решение | DP.ARCH.001 §7 (→ используй /archgate вместо /verify) |
| План (WeekPlan/DayPlan) | Протоколы Open/Close |
| Подраздел руководства (SS) | `DS-principles-curriculum/specs/v4-reference/CHECKLIST-subsection-v1.md` (v1.2+) |
| Раздел руководства (S) | `DS-principles-curriculum/specs/v4-reference/CHECKLIST-section-v1.md` |
| Руководство целиком | `DS-principles-curriculum/specs/v4-reference/CHECKLIST-guide-v1.md` |

Если эталон не определяется → **СТОП.** Сообщи: «Эталон не найден. Нужен рецензент, не верификатор.»

**Для `chain`, `adversarial`** — эталон = сам код (downstream consumers, scope analysis). Чеклисты встроены в шаг 1.

## Шаг 3. Verdict

Sub-agent возвращает verdict:

```
## Verdict: [PASS / FAIL / CONDITIONAL]

**Контекст:** [тип проверки]
**Артефакт:** [что проверялось]
**Эталон:** [по чему проверялось]

### Несоответствия

| # | Severity | Файл | Строка | Что | Почему (reasoning) | Эталон |
|---|----------|------|--------|-----|-------------------|--------|
| 1 | критический / высокий / средний / низкий | path | N | описание | почему проблема | принцип/правило |

### Сводка

- **Критических:** N
- **Высоких:** N
- **Средних:** N
- **Низких:** N

### Рекомендация

[1-3 предложения]
```

**Правила verdict:**
- **PASS:** 0 критических, 0 высоких
- **CONDITIONAL:** 0 критических, ≥1 высоких
- **FAIL:** ≥1 критических

## Шаг 4. Показать пользователю

Вывести verdict. Пользователь решает:
- **Принять** → продолжить работу
- **Исправить** → внести изменения по рекомендациям
- **Отклонить verdict** → аргументировать почему (→ feedback для обучения)
