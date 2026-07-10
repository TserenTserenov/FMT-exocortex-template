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

1. Прочитать контекст пакета (WP-контекст или frontmatter Pack-папки)
2. Извлечь:
   - `title` / `slug` / `pack_id_code` — идентификаторы пакета
   - `status` — seed / mature / deprecated
   - Наличие файлов из фаз Ф1-Ф3:
     - Ф1: `06-sota/{slug}-sota-sheet.md` (SoTA-лист)
     - Ф2: `.pfad-decision.md` (decision record с границами/альтернативами)
     - Ф3: `01B-distinctions.md` с маркером `**Maturity:** seed` и mature-lite чек-листом
3. **Особое внимание:** для seed-пакета ожидается, что некоторые координаты будут `missing(seed-expected)` — это НОРМАЛЬНО, не FAIL. Проверка честно оценивает то, что ЕСТь, не то, что еще развивается.

## Шаг 2. Проверить 11 координат D1-D11

Для каждой координаты определить: **addressed(4)** / **partial(2)** / **missing(0)**, с указанием evidence или pomeтки.

### D1 — DomainScopeAndUseAdequacy

**Проверка:** Пакет ясно определяет область домена (что в пакете), границы домена (что вне), сценарии использования.

**Evidence:**
- `.pfad-decision.md` содержит раздел про границы домена и отвергнутые альтернативы → **partial** (граница описана, но не исчерпывающе)
- Если раздел про граници отсутствует в .pfad-decision.md → **missing**
- Если .pfad-decision.md отсутствует вообще → **missing**

**Вердикт:** See evidence

### D2 — DidacticEntryAndAdoptionAdequacy

**Проверка:** Пакет содержит ясный путь для новичка (entry point), стратегию адаптации пакета к ступеням овладения.

**Evidence:** Для seed-пакета обычно отсутствует педагогический дизайн (это дело Ф5+ развития). Отсутствие = норма.

**Вердикт:** **missing(seed-expected)** — дидактика не входит в seed-обязательства

### D3 — ScalableFormalityAndAssurancePathAdequacy

**Проверка:** Пакет показывает путь от informal (мем, интуиция) к formal (спецификация, доказательство), включая промежуточные уровни. Seed-пакет должен хотя бы обозначить эту лестницу.

**Evidence:**
- Маркер `**Maturity:** seed` в 01B-distinctions.md → даёт сигнал о статусе (seed vs mature)
- Mature-lite чек-лист (Проблема / Forces / Пример / Ошибка / Последствия) → обозначает путь формализации
- Вместе они достаточны для порога → **addressed**

**Вердикт:** **addressed** если оба артефакта есть, иначе **missing**

### D4 — CoreDependencyAndDomainBoundaryAdequacy

**Проверка:** Пакет явно перечисляет зависимости от других доменов, критические для своего смысла. Что пакет ДОЛЖЕН знать/иметь от соседних доменов.

**Evidence:** Для seed-пакета обычно не дорабатывается (это Ф6+ mapping). Отсутствие = норма.

**Вердикт:** **missing(seed-expected)** — зависимости mapping = развитие пакета, не seed-foundation

### D5 — PackageFormLayeringAndRelationAdequacy

**Проверка:** Пакет описан в единообразном формате (не смешаны разные нотации, стили). Слои пакета (definitions / rules / patterns / tools) чётко разделены.

**Evidence:** Для seed-пакета структура дерева само по себе — evidence. Если Pack создан через `pack-new` → структура соответствует `SPF/pack-template/`.

**Вердикт:** **missing(seed-expected)** если явная спецификация формата отсутствует; **partial** если структура есть, но не формализована; **addressed** если есть явная формализация (редко для seed)

### D6 — DomainLexiconAndKindSettlementAdequacy

**Проверка:** Пакет ясно определяет ключевые термины домена (лексикон), различает их от похожих терминов. Определяет базовый Kind (род сущности) для основного концепта домена.

**Evidence:**
- 01B-distinctions.md содержит различения → partial evidence
- Если `.pfad-decision.md` содержит раздел «отвергнутые/выбранные термины и kind» → **partial** или **addressed**
- Если ни в одном файле нет явного решения про kind → **missing**

**Вердикт:** Условно partial; уточнить по файлам

### D7 — PracticeUtilityAndProblemResolutionAdequacy

**Проверка:** Пакет содержит практики (методы, инструменты) решения конкретных проблем домена. Утилитарность — сразу применимо.

**Evidence:** Для seed-пакета обычно отсутствует (это Ф7+ реализация методов). Отсутствие = критично для FAIL.

**Вердикт:** **missing(seed-expected)** — практики = развитие, не seed. **КРИТИЧНА ДЛЯ АГРЕГАТНОГО FAIL**

### D8 — HeterogeneousCaseAndTransferAdequacy

**Проверка:** Пакет показывает применимость к разным ситуациям (не один Case, а вариативность). Transfer тест — применение в новом домене.

**Evidence:** Для seed-пакета обычно отсутствует. Отсутствие = норма.

**Вердикт:** **missing(seed-expected)** — случаи и трансфер = развитие пакета, не seed-foundation

### D9 — EditionStateAndCurrentnessAdequacy

**Проверка:** Пакет указывает текущую edition (версию), дату создания, указатель на последнее обновление. Читатель знает, актуален ли это.

**Evidence:**
- Маркер `**Maturity:** seed` в frontmatter/тексте → даёт статус (seed, не deprecated)
- Дата создания в WP-контексте или Git date → есть
- НО: edition и currentness отдельны. seed-маркер даёт только status, не edition/currentness информацию → **partial**

**Вердикт:** **partial** — статус известен, но edition/currentness неявны

### D10 — ImprovementAndRefreshAdequacy

**Проверка:** Пакет определяет цикл обновления (как часто пакет пересматривается), policy устаревания (когда уходит в deprecated).

**Evidence:** Для seed-пакета обычно не определено (это дело Ф8+ operations). Отсутствие = норма.

**Вердикт:** **missing(seed-expected)** — refresh cycle/deprecation = operations, не seed

### D11 — DomainSoTAAlignmentAdequacy

**Проверка:** Пакет явно ссылается на современное state-of-art знание в домене (источники). Пакет не живёт в вакууме — он response на реальный статус knowledge.

**Evidence:**
- `06-sota/{slug}-sota-sheet.md` содержит список источников (минимум 3 источника + claims/evidence) → **addressed**
- Если файл отсутствует → **missing**
- Если файл есть, но источники неполные (0-2 источника) → **partial**

**Вердикт:** Зависит от наличия и качества 06-sota файла. **КРИТИЧНА ДЛЯ АГРЕГАТНОГО FAIL**

## Шаг 3. Построить таблицу оценок

| Координата | Статус | Маппинг (addressed/partial/missing) | Evidence / Комментарий |
|---|---|---|---|
| D1 DomainScopeAndUseAdequacy | — | 4/2/0 | проверено выше |
| D2 DidacticEntryAndAdoptionAdequacy | — | missing(seed-expected) | педагогика — развитие |
| D3 ScalableFormalityAndAssurancePathAdequacy | — | 4/2/0 | маркер seed + чек-лист |
| D4 CoreDependencyAndDomainBoundaryAdequacy | — | missing(seed-expected) | зависимости — mapping |
| D5 PackageFormLayeringAndRelationAdequacy | — | 4/2/0 | структура по SPF шаблону |
| D6 DomainLexiconAndKindSettlementAdequacy | — | 4/2/0 | различения + PFAD раздел |
| D7 PracticeUtilityAndProblemResolutionAdequacy | — | missing(seed-expected) | практики — Ф7+ **КРИТ** |
| D8 HeterogeneousCaseAndTransferAdequacy | — | missing(seed-expected) | трансфер — развитие |
| D9 EditionStateAndCurrentnessAdequacy | — | 4/2/0 | маркер + дата |
| D10 ImprovementAndRefreshAdequacy | — | missing(seed-expected) | operations — Ф8+ |
| D11 DomainSoTAAlignmentAdequacy | — | 4/2/0 | SoTA-лист **КРИТ** |

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
