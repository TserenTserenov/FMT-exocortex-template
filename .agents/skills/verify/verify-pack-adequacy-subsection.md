---
name: verify-pack-adequacy-subsection
description: Package-адекватность верификатор по 11 координатам E.4.DPF.DA. Context isolation. Проверяет Package-качество seed-пакета и вызывается из /verify с типом `pack` или из pack-creator Шаг 4.
argument-hint: "<путь к pack или wp-контексту пакета>"
---

# Package-адекватность верификация

> **Роль:** Package-верификатор (специализированный субагент WP-474 Ф4)
> **Принцип:** Context isolation — проверяю только адекватность пакета по 11 координатам спецификации E.4.DPF.DA, не педагогику и не FPF-границы отдельно.
> **Спецификация:** E.4.DPF (Framework for Domain Package Formation), раздел DA (Domain Adequacy) — 11 координат D1-D11.

Путь к пакету или контексту: $ARGUMENTS

## Шаг 1. Загрузить материалы

1. Прочитать `00-pack-manifest.md` Pack'а (и WP-контекст, если указан)
2. Извлечь из манифеста:
   - `pack_id` (короткий код) / `pack_name` — идентификаторы пакета
   - `status` (`draft | active | deprecated`) и `name_status` (`provisional | finalized`)
   - `sota_sources` (`none | grounded`)
3. **Определение «seed-пакет» (фиксированное, для seed-expected-логики):** Pack считается seed, если манифест содержит `status: draft`. Maturity различений (`**Maturity:** seed` в 01B) — атрибут отдельного различения, НЕ Pack'а; для классификации Pack'а не используется.
4. Проверить наличие файлов-свидетельств (фазы Ф1-Ф3 WP-474):
   - `06-sota/{slug}-sota-sheet.md` (SoTA-лист, Ф1)
   - `.pfad-decision.md` (decision record: таблицы Домен/Имя/Граница/Kind + «Финальный выбор», Ф2+Ф5)
   - `01-domain-contract/01B-distinctions.md` (различения с маркерами `**Maturity:**`, Ф3)
   - `ontology.md` (термины домена, SPF/pack-template)
5. **Особое внимание:** для seed-пакета ожидается, что часть координат будет `missing(seed-expected)` — это НОРМАЛЬНО, не FAIL. Проверка честно оценивает то, что ЕСТЬ, не то, что ещё развивается.

**Плейсхолдер-конвенция (используется флагами ниже, фиксированная):** значение ячейки/поля считается плейсхолдером, если оно пустое, обёрнуто в `_..._` (курсив шаблона), `{{...}}` или `<...>`, либо равно (case-insensitive) одному из: `...`, `TBD`, `todo`, `—`. Плейсхолдером также считается: (а) отсутствие поля/строки целиком — эквивалентно пустому значению; (б) для дата-полей (`created`, `last_updated`) — буквальный шаблонный дефолт `YYYY-MM-DD` (case-insensitive); (в) для полей с шаблонным перечнем вариантов — буквальный нетронутый текст с разделителем ` | ` (например `draft | active | deprecated`), т.к. это список опций шаблона, не выбранное значение. (Пир-сессия 2026-07-11-13, находка код-ревью: без пп. а-в нетронутый скаффолд-манифест механически проходил как `addressed` в координате D9.)

## Шаг 2. Проверить 11 координат D1-D11

Для каждой координаты определить: **addressed(4)** / **partial(2)** / **missing(0)**, с указанием evidence или pomeтки.

### D1 — DomainScopeAndUseAdequacy

**Проверка:** Пакет ясно определяет область домена (что в пакете) и границы домена (что вне) решением, а не молчанием.

**Evidence (пир-сессия 2026-07-11-13, фикс bug-2026-07-10-verify-pack-d9-ignores-manifest.md §Дополнение):**
- Строка `**Граница:**` в секции «Финальный выбор» `.pfad-decision.md` заполнена не-плейсхолдерно (по плейсхолдер-конвенции Шага 1) → **addressed** (граница домена зафиксирована явным решением)
- `.pfad-decision.md` существует, но строка `**Граница:**` пуста/плейсхолдерна → **partial** (граница только подразумевается, решение не зафиксировано)
- `.pfad-decision.md` отсутствует вообще → **missing**

**Вердикт:** See evidence

**Сценарии использования — вне scope D1-lite (осознанно, пир-сессия 2026-07-11-13):** use-case-уровень пакета не материализуется ни в одном артефакте потока `pack-new`/`pack-creator` до Ф7+ (практический слой) — требовать его для addressed воспроизвело бы тот же баг, что чинится у D9 (проверка несуществующего артефакта). Кандидат для отдельной mature-grade координаты позже.

### D2 — DidacticEntryAndAdoptionAdequacy

**Проверка:** Пакет содержит ясный путь для новичка (entry point), стратегию адаптации пакета к ступеням овладения.

**Evidence:** Для seed-пакета обычно отсутствует педагогический дизайн (это дело Ф5+ развития). Отсутствие = норма.

**Вердикт:** **missing(seed-expected)** — дидактика не входит в seed-обязательства

### D3 — ScalableFormalityAndAssurancePathAdequacy

**Проверка:** Пакет показывает путь от informal (мем, интуиция) к formal (спецификация, доказательство), включая промежуточные уровни. Seed-пакет должен хотя бы обозначить эту лестницу.

**Evidence (только артефакты Pack'а — mature-lite чек-лист живёт в pack-new/SKILL.md как процесс и в Pack не материализуется, его искать НЕ нужно):**
- `01B-distinctions.md` содержит ≥1 различение, и у каждого различения maturity определена: либо строка `**Maturity:** seed` под заголовком, либо её отсутствие (= mature по конвенции Ф3) → лестница seed→mature обозначена → **addressed**
- `01B-distinctions.md` существует, но различений нет (только шаблон-заготовка) → **missing(seed-expected: различения ещё не добавлены)**
- Файла нет → **missing**

**Вердикт:** по правилам выше, детерминированно

### D4 — CoreDependencyAndDomainBoundaryAdequacy

**Проверка:** Пакет явно перечисляет зависимости от других доменов, критические для своего смысла. Что пакет ДОЛЖЕН знать/иметь от соседних доменов.

**Evidence:** Для seed-пакета обычно не дорабатывается (это Ф6+ mapping). Отсутствие = норма.

**Вердикт:** **missing(seed-expected)** — зависимости mapping = развитие пакета, не seed-foundation

### D5 — PackageFormLayeringAndRelationAdequacy

**Проверка:** Пакет описан в единообразном формате (не смешаны разные нотации, стили). Слои пакета (definitions / rules / patterns / tools) чётко разделены.

**Evidence (детерминированное правило):** проверить наличие 8 корневых элементов структуры, создаваемой `pack-new` Шаг 4 (НЕ дерева `SPF/pack-template/` — там нет README/REPO-TYPE/CLAUDE.md): `README.md`, `REPO-TYPE.md`, `CLAUDE.md`, `00-pack-manifest.md`, `ontology.md`, `01-domain-contract/`, `06-sota/` (или `sota_sources: none` в манифесте вместо директории), `07-map/`.

**Вердикт:** **partial** — все 8 элементов на месте (форма выдержана по шаблону, но собственной спецификации слоёв у Pack'а нет — для seed это потолок); **missing(seed-expected: структура частична)** — хотя бы один элемент отсутствует. `addressed` на seed-стадии недостижим (требует явной формализации слоёв — mature-уровень).

### D6 — DomainLexiconAndKindSettlementAdequacy

**Проверка:** Пакет определяет лексикон домена (термины + различения) и фиксирует решение о базовом Kind (роде сущности) основного концепта. Лексикон живёт в `ontology.md` + `01B-distinctions.md`; kind-settlement — в `.pfad-decision.md` (пир-сессия 2026-07-10-18: PFAD = decision record, дублировать в нём термины из ontology запрещено).

**Три бинарных флага (плейсхолдер-конвенция — Шаг 1):**
- **O** (лексикон, часть 1) = `ontology.md` §Domain Glossary содержит ≥1 строку, в которой ВСЕ ТРИ ячейки — Term (RU/EN), Definition, Parent Concept (SPF) — не-плейсхолдерные
- **D** (лексикон, часть 2) = `01B-distinctions.md` содержит ≥1 различение (заголовок вида `### <код>.D.NNN` или `### {{PACK_ID}}.D.NNN`)
- **S** (settlement) = строка `**Kind:**` в секции «Финальный выбор» `.pfad-decision.md` заполнена не-плейсхолдерным значением. Таблица `## Kind` (отвергнутые альтернативы) свидетельством settlement НЕ является — она может быть заполнена без принятого решения.

**Вердикт (полная таблица истинности):**
- **addressed** = O ∧ D ∧ S
- **missing** = ¬O ∧ ¬D ∧ ¬S
- **partial** = любая другая комбинация

**Отвергнутые термины (не kind) — вне scope D6-lite, осознанно:** (а) lite-прогон измеряет floor (addressed=4), реестр отвергнутых терминов — уровень зрелого пакета, покрывается полной ординальной шкалой E.4.DPF.DA на mature-стадии; (б) места для такого реестра в текущем шаблоне нет — `ontology.md` не имеет колонки отклонённых синонимов (проверено), её добавление = правка SPF/pack-template по процедуре §8.2, отдельное решение.

### D7 — PracticeUtilityAndProblemResolutionAdequacy

**Проверка:** Пакет содержит практики (методы, инструменты) решения конкретных проблем домена. Утилитарность — сразу применимо.

**Evidence:** Для seed-пакета обычно отсутствует (это Ф7+ реализация методов). Отсутствие = критично для FAIL.

**Вердикт:** **missing(seed-expected)** — практики = развитие, не seed. **КРИТИЧНА ДЛЯ АГРЕГАТНОГО FAIL**

### D8 — HeterogeneousCaseAndTransferAdequacy

**Проверка:** Пакет показывает применимость к разным ситуациям (не один Case, а вариативность). Transfer тест — применение в новом домене.

**Evidence:** Для seed-пакета обычно отсутствует. Отсутствие = норма.

**Вердикт:** **missing(seed-expected)** — случаи и трансфер = развитие пакета, не seed-foundation

### D9 — EditionStateAndCurrentnessAdequacy

**Проверка:** Пакет указывает текущую edition (версию), дату последнего обновления, состояние (state). Читатель знает, актуален ли это.

**Три бинарных флага (плейсхолдер-конвенция — Шаг 1; по образцу D6, пир-сессия 2026-07-11-13, фикс bug-2026-07-10-verify-pack-d9-ignores-manifest.md):**
- **O** (edition) = `version` в `00-pack-manifest.md` не-плейсхолдерный
- **E** (currentness) = `last_updated` в `00-pack-manifest.md` не-плейсхолдерный
- **S** (state) = `status` в `00-pack-manifest.md` не-плейсхолдерный

**Вердикт (таблица истинности):**
- **addressed** = O ∧ E ∧ S
- **missing** = ¬O ∧ ¬E ∧ ¬S
- **partial** = любая другая комбинация

Верификатор уже загружает `status` из манифеста в Шаге 1 — предыдущая версия координаты игнорировала эти же поля манифеста и держала `partial` как жёсткий потолок, из-за чего механический `addressed` был недостижим даже для полностью заполненного манифеста.

### D10 — ImprovementAndRefreshAdequacy

**Проверка:** Пакет определяет цикл обновления (как часто пакет пересматривается), policy устаревания (когда уходит в deprecated).

**Evidence:** Для seed-пакета обычно не определено (это дело Ф8+ operations). Отсутствие = норма.

**Вердикт:** **missing(seed-expected)** — refresh cycle/deprecation = operations, не seed

### D11 — DomainSoTAAlignmentAdequacy

**Проверка:** Пакет явно ссылается на современное state-of-art знание в домене (источники). Пакет не живёт в вакууме — он response на реальный статус knowledge.

**Evidence (порог = дизайн Ф1 SoTA-Sheet-lite: ОДИН источник достаточен для floor; порога «3 источника» в спецификации lite-прогона НЕТ):**
- `06-sota/*-sota-sheet.md` существует и содержит ≥1 источник с не-плейсхолдерными полями **Claims** и **Evidence** → **addressed**
- Файл существует, но Claims или Evidence плейсхолдерные → **partial**
- Файла нет И манифест `sota_sources: none` → **missing(seed-expected: sota_sources=none зафиксировано в манифесте; добрать источник или формализованную практику автора на стадии наполнения)**
- Файла нет, А манифест `sota_sources: grounded` → **missing** БЕЗ пометки (рассинхрон манифеста и факта — триггер FAIL)

**Вердикт:** по правилам выше. **КРИТИЧНА ДЛЯ АГРЕГАТНОГО FAIL**

## Шаг 3. Построить таблицу оценок

| Координата | Статус | Маппинг (addressed/partial/missing) | Evidence / Комментарий |
|---|---|---|---|
| D1 DomainScopeAndUseAdequacy | — | 4/2/0 | строка «Граница:» в Финальном выборе .pfad-decision.md |
| D2 DidacticEntryAndAdoptionAdequacy | — | missing(seed-expected) | педагогика — развитие |
| D3 ScalableFormalityAndAssurancePathAdequacy | — | 4/2/0 | maturity-маркеры в 01B |
| D4 CoreDependencyAndDomainBoundaryAdequacy | — | missing(seed-expected) | зависимости — mapping |
| D5 PackageFormLayeringAndRelationAdequacy | — | 2/0 (addressed недостижим на seed) | 8 корневых элементов шаблона |
| D6 DomainLexiconAndKindSettlementAdequacy | — | 4/2/0 | флаги O/D/S, таблица истинности |
| D7 PracticeUtilityAndProblemResolutionAdequacy | — | missing(seed-expected) | практики — Ф7+ **КРИТ** |
| D8 HeterogeneousCaseAndTransferAdequacy | — | missing(seed-expected) | трансфер — развитие |
| D9 EditionStateAndCurrentnessAdequacy | — | 4/2/0 | флаги O/E/S манифеста (version/last_updated/status), таблица истинности |
| D10 ImprovementAndRefreshAdequacy | — | missing(seed-expected) | operations — Ф8+ |
| D11 DomainSoTAAlignmentAdequacy | — | 4/2/0 | SoTA-лист, ≥1 источник **КРИТ** |

## Шаг 4. Вернуть агрегатный verdict

Агрегатный вердикт по правилам WP-474:

- **FAIL:** D1=missing ИЛИ (D7 или D11)=missing **без** `seed-expected` пометки
- **CONDITIONAL:** нет FAIL-критериев, но есть partial ИЛИ missing **без** `seed-expected`
- **PASS:** нет FAIL-критериев, все missing помечены `seed-expected`, все partial обоснованы

```
## Package-Verdict: [PASS / CONDITIONAL / FAIL]

**Пакет:** <pack_id_code> / <slug>
**Статус:** seed

### Координаты по статусам

| Координата | Статус | Оценка | Комментарий |
|---|---|---|---|
| (заполнить из Шага 3) | | | |

### Агрегированный результат

- **Критические** (D1, D7, D11): [заполнить]
- **Partial координаты:** [заполнить]
- **Missing(seed-expected):** [заполнить]
- **Вердикт:** [PASS / CONDITIONAL / FAIL]

### Рекомендации

[Если есть замечания — конкретные шаги по улучшению]
```

## Шаг 5. Контекстная изоляция

**НЕ проверяю:**
- Педагогическое качество (это verify-pedagogy-subsection)
- FPF-границы понятий (это verify-fpf-subsection)
- Качество кода или инструментов в пакете (это domain-specific review)

**ПРОВЕРЯЮ ТОЛЬКО:**
- Наличие и качество артефактов Ф1-Ф3 (SoTA-лист, decision-record, maturity маркер)
- Соответствие 11 координатам спецификации E.4.DPF.DA
- Честность оценки: seed ≠ mature, missing(seed-expected) ≠ FAIL
