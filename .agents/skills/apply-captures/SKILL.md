---
name: apply-captures
description: Разбор extraction-reports со status pending-review — решение R15 (accept/reject/defer) ЖИВЫМ ПИЛОТОМ, запись в Pack, обновление статуса, коммит. Вызывать при Close при наличии N>0 pending-review отчётов.
argument-hint: "[путь к конкретному отчёту | пусто = все pending-review]"
version: 1.1.0
layer: L1
status: active
agents: single
interaction: multi-step
triggers:
  slash: [/apply-captures]
  phrases: []
gates_required: []
gates_enforced: []
gates_rationale: "операционный скилл разбора очереди; WP Gate не нужен — вызывается автоматически из Close Gate"
routing:
  executor: agent
  deterministic: false
---

# /apply-captures — разбор кандидатов экстрактора

Полная ВДВ-карта цикла: `${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/WP-247-ke-pipeline-vdv.md`
Контракт скилла взят из шагов 5, 6, 6.5, 7 этой карты.

## When to use

### Scope

**Этот скилл делает:**
- Читает `${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/extraction-reports/*.md` со `status: pending-review` или `status: deferred`.
- Для каждого кандидата в отчёте — запрашивает решение R15 (accept / reject / defer).
- Accept → опциональная редактура → валидация → запись файла в Pack → обновление MAP → коммит.
- Reject → запись причины + паттерна в `feedback-log.md`.
- Defer → запись причины + `defer_until` в отчёт.
- Обновляет `status` отчёта на `applied` / `partially-applied` / `rejected` / `deferred`.

**Этот скилл НЕ делает:**
- Не запускает агента R2 (экстрактор) — это `/ke` и launchd `extractor.sh`.
- Не создаёт extraction-reports — это R2.
- Не редактирует содержимое captures.md / fleeting-notes.md.

### ВДВ-контракт (шаги 5–7 из ke-pipeline-vdv.md)

```
Вход:   ${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/extraction-reports/*.md  со  status: pending-review
Роль:   R15 Валидатор (accept/reject/defer)
        R4 Автор (conditional: редактура при edits_needed: yes)
        Скилл (автоматика записи, валидации, коммита)
Действие:
  Для каждого pending-review отчёта, для каждого кандидата:
    1. Показать кандидата (id, тип, предложенный target_path, текст).
    2. Запросить решение R15 по схеме ниже.
    3. Accept + edits_needed=yes → R4 редактирует текст.
    4. Шаг 6.5: валидация Pack-сущности (frontmatter, уникальность ID, путь).
    5. Accept + valid → записать файл в Pack, обновить MAP, дописать feedback-log (паттерн), коммит.
    6. Reject → записать в feedback-log причину + паттерн.
    7. Defer → записать defer_reason + defer_until в отчёт.
  Обновить status отчёта по итогам.
Выход:
  - Обновлённый Pack (новые файлы сущностей).
  - Обновлённый ${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/feedback-log.md (reject-паттерны).
  - Отчёт со финальным status (applied / partially-applied / rejected / deferred).
  - Коммит в PACK-* (при accept).
```

## Algorithm

### R15 = живой пилот, не агент (БЛОКИРУЮЩЕЕ, peer-session 2026-07-07-03)

> **Инвариант:** решение accept/reject/defer по каждому кандидату принимает человек, управляющий текущей сессией — не другой агент, не сам исполняющий скилл агент, не автоматически принятый вердикт R2 (экстрактора). Это не рекомендация — источник: `DP.ROLE.001` (держатель роли R15 — пользователь), `DP.SC.040` («финальное утверждение — за человеком... полная автоматизация не работает», со ссылкой на SOTA-провал automated rule generation, accuracy <10%).

**Запрещено:**
- Подменять решение пилота консенсусом двух агентов внутри пир-сессии (`peer-conversation`/`kimi-peer-writer`) — согласие Kimi и Claude между собой НЕ есть решение R15, независимо от качества их аргументации.
- Автоматически принимать вердикт R2 («Вердикт: accept» в отчёте) как решение R15 без факта вопроса живому пилоту — даже когда обоснование R2 выглядит убедительно.
- Присваивать агенту роль `R15-*` в `meta.yaml`/frontmatter сессии — роль R15 не переносится на агента ни при каких обстоятельствах.

**Если apply-captures вызван внутри пир-сессии** (оба участника — агенты): пир-сессия может готовить кандидатов, проверять дубли/семантику/размещение, спорить о деталях — но на этом шаге обязана остановиться и передать вопрос пилоту напрямую, в текущем интерактивном чате с ним (не через turn-файл диалога с другим агентом), прежде чем зафиксировать решение по любому кандидату.

**Найдено при аудите (2026-07-07):** минимум 4 исторические сессии (`2026-05-24-apply-captures-bulk-review`, `2026-06-11-02-ke-candidates-review-pack`, `2026-06-26-14-apply-captures-r15`, `2026-06-28-09-peer-apply-captures-dp`) зафиксировали решения по 90+ кандидатам целиком внутри диалога Kimi↔Claude, без единой реплики пилота. Полный разбор → `${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/bugs/bug-2026-07-07-r15-decisions-bypassed-pilot.md`.

### Формат решения R15

Каждый кандидат — структурированное решение:

```yaml
candidate_id: 3
decision: accept        # accept | reject | defer
decision_source: pilot   # ОБЯЗАТЕЛЬНО — единственное валидное значение. Заполняется только по факту прямого вопроса пилоту (см. блок выше).
# --- при accept ---
edits_needed: no        # yes | no
target_path: PACK-digital-platform/pack/.../02-domain-entities/DP.D.NNN.md
# --- при reject ---
reason: "дубликат PD.METHOD.006"
pattern: "проверять существующие METHOD перед предложением нового"
# --- при defer ---
reason: "ждёт ArchGate WP-245"
defer_until: "после WP-245 Ф22"     # ОБЯЗАТЕЛЬНО — дата YYYY-MM-DD или событие
```

**Инвариант decision_source (peer-session 2026-07-07-03):** `decision_source: pilot` — обязательное поле при ЛЮБОМ решении (accept/reject/defer). Отсутствует или указано иное значение → решение invalid, Шаг 5 (запись в Pack) обязан отказать и вернуть кандидата на Шаг 2.

**Инвариант defer (peer-session 2026-05-31-22):** `defer_until` — обязательное поле при `decision: defer`. Без него решение invalid. Reason: `deferred` без `defer_until` = masked cancel (см. `memory/lessons_defer_with_explicit_triggers.md`). Формат: дата `YYYY-MM-DD` ИЛИ привязка к событию («после WP-NNN Ф{N}», «при следующем Week Close»).

### Шаг 1. Найти pending-review отчёты

```bash
find ~/IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/extraction-reports -name "*.md" \
  -exec grep -l -E "^status: (pending-review|deferred)" {} \; | sort
```

Если `$ARGUMENTS` задан путь — работать только с ним.
Если отчётов нет → сообщить «Нет pending-review отчётов. Ничего делать не нужно.»

### Шаг 2. Для каждого отчёта: показать кандидатов

Прочитать отчёт. Для каждого кандидата (frontmatter + тело) показать пилоту напрямую в текущем чате:
- `id`, `type`, предложенный `target_path`
- Первые 15-20 строк текста (без служебного frontmatter)
- Флаг `edits_needed` из отчёта (если проставлен R2)

Запросить решение R15 у пилота — реальным вопросом в текущей интерактивной сессии (`AskUserQuestion` при работе через Claude Code, обычное сообщение в чате при другом интерфейсе). Один вопрос = один кандидат, ЛИБО (при большом количестве однотипных пред-одобренных R2 кандидатов) одна сводка на весь отчёт с явным перечислением каждого — пилот подтверждает/отклоняет по номерам. В любом случае ответ должен исходить от пилота, не быть выведен агентом из контекста разговора с другим агентом.

### Шаг 3. Accept — редактура (conditional)

Если `edits_needed: yes` → предложить отредактировать текст совместно с пользователем.
Если `edits_needed: no` → использовать текст as-is из отчёта.

### Шаг 4 (= ВДВ шаг 6.5). Валидация Pack-сущности

Перед записью проверить три условия:

### 4а. Frontmatter по шаблону Pack

Обязательные поля (для большинства Pack-сущностей):
- `id:` — присутствует и соответствует типу (DP.D.NNN, PD.METHOD.NNN и т.д.)
- `type:` — присутствует
- `status:` — присутствует (обычно `draft` или `active`)
- `created:` — присутствует

Источник шаблонов: `DP.ROLE.033` и соседние сущности целевой директории.

### 4б. Уникальность ID

```bash
grep -r "^id: <ID>" ~/IWE/PACK-* | head -5
```

Если совпадение найдено → вернуть R15 на reject: паттерн `«ID уже занят: <путь>»`.

### 4в. Расположение файла

Путь `target_path` должен соответствовать типу сущности:
- `DP.D.*` → `.../02-domain-entities/`
- `DP.METHOD.*` → `.../03-methods/`
- `DP.ROLE.*` → `.../02-domain-entities/` или `.../roles/`
- `DP.SOTA.*` → `.../06-sota/`
- `PD.*` → аналогичная структура в `PACK-personal/` или другом Pack-репо домена

При сомнении — проверить соседние файлы в целевой директории.

**Результат валидации:**
- `valid` → переходить к Шагу 4г
- `invalid` + причина → reject этого кандидата, записать в feedback-log, продолжить следующий кандидат

### 4г. Семантическая проверка (содержательная непротиворечивость)

Перед записью проверить содержательную совместимость кандидата с соседними Pack-сущностями того же типа:

**Шаг 1 — прочитать ±5 соседних ID** того же типа в целевой директории:
```bash
ls <target_dir>/ | sort | grep -A5 -B5 "<ID-slug>"
```
Для каждого соседнего файла: прочитать `summary:` или первые 3 строки тела — проверить на пересечение.

**Шаг 2 — grep ключевых существительных**. Взять 2-3 ключевых существительных из имени кандидата. Искать в целевом Pack-репо:
```bash
grep -ri "<ключевое_слово>" ~/IWE/<PACK-repo>/pack/ --include="*.md" -l | head -10
```
Если найдено совпадение: прочитать файл. Проверить:
- **Перекрытие**: кандидат описывает то же самое другими словами → reject (дубликат), паттерн для R2.
- **Противоречие**: кандидат утверждает обратное существующему → выяснить, какой новее/точнее; если новый кандидат вытесняет старый — accept + пометить в отчёте `supersedes: <ID>`.
- **Уточнение**: кандидат добавляет деталь без конфликта → accept, добавить `see_also: [<ID>]` в frontmatter.

**Результат 4г:**
- `clear` → переходить к Шагу 4д
- `overlap` → reject; паттерн + ссылка на существующий ID в feedback-log
- `contradiction` → выявить новейший; при accept добавить `supersedes:`
- `refinement` → accept + `see_also:` в frontmatter кандидата

### 4д. Semantic Gate — WP-429 Контур A (write-time soft gate)

> **Когда применяется:** кандидат с `decision: accept` и тип `DP.*` (DP.D.*, DP.ROLE.*, DP.SC.*, DP.METHOD.*) или `PD.*` в `PACK-digital-platform` или `PACK-personal`.
> **Soft gate:** не блокирует — информирует R15. R15 принимает финальное решение.
> **Когда пропускается:** `decision: reject` / `defer`, или тип не Pack-сущность (скрипт, шаблон, docs).

**Шаг 1 — семантический поиск соседей** (inline, без внешнего скрипта):

Вызвать MCP-инструмент `knowledge_search` с текстом кандидата:
```
knowledge_search(query=<первые 400 символов текста кандидата>, limit=5)
```

Отфильтровать из результатов: только сущности с ID типа `DP.*` или `PD.*` (game концепты, не гайды).
Взять top-3 с наибольшей близостью.

**Шаг 2 — inline LLM-оценка** каждой пары (кандидат × сосед):

Для каждого из top-3 соседей вынести суждение:
- Кандидат: `<name> — <первые 500 символов текста>`
- Сосед: `<neighbor_id> «<neighbor_name>» — <первые 500 символов>`
- Вердикт: `duplicate | contradiction | related | unrelated`

Критерии (из detector.py):
- `duplicate` — оба описывают то же понятие с тем же смыслом; держать оба = путаница
- `contradiction` — несовместимые утверждения об одном понятии
- `related` — связаны, но явно различны; конфликта нет
- `unrelated` — разные темы

**Шаг 3 — результат gate:**

| Вердикт | Действие |
|---------|---------|
| Все `related`/`unrelated` | `clear` → перейти к Шагу 5 |
| Найден `duplicate` | Предупредить R15 (формат ниже) |
| Найдено `contradiction` | Предупредить R15 (формат ниже) |
| `partial` | Предупредить R15 «судья недоступен, ручная проверка или повтор» |

**Формат предупреждения R15:**
```
⚠️  Semantic Gate (WP-429 Контур A): возможный <дубль/противоречие>
Кандидат: <id/name>
Конфликт с: <neighbor_id> «<neighbor_name>»
Оценка: <verdict> (уверенность ~<confidence>%)
Причина: <reasoning>

Варианты:
  А. Reject кандидата → паттерн в feedback-log: «дубль <neighbor_id>»
  Б. Accept как уточнение → добавить `see_also: [<neighbor_id>]` в frontmatter
  В. Accept как замена → добавить `supersedes: <neighbor_id>` + пометить старый как superseded
R15 выбирает вариант:
```

Дождаться ответа R15. Обновить `decision` и frontmatter кандидата согласно выбору.

**Если `knowledge_search` недоступен** (MCP offline, ошибка сети):
- Пометить в отчёте: `semantic_gate: skipped (MCP unavailable)`
- Перейти к Шагу 5 без блокировки.

**CLI-эквивалент** (для batch/автоматизации):
```bash
cd ~/IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}
OPENROUTER_API_KEY="sk-or-v1-..." WP429_DB_ID=3 WP429_TABLE=concept_graph.concepts \
  python3 inbox/WP-429/f2-poc/detector.py --check-candidate \
    --name "<имя кандидата>" \
    --text "<текст кандидата>"
```

### Шаг 5. Запись в Pack и коммит

**Gate перед записью (БЛОКИРУЮЩЕЕ):** проверить, что решение кандидата имеет `decision_source: pilot`. Нет поля или значение иное → СТОП, вернуться к Шагу 2 и получить решение от пилота напрямую. Записывать в Pack можно только решения с подтверждённым `decision_source: pilot`.

### 5а. Записать файл

```
Write target_path (из решения R15) ← текст кандидата (после редактуры если была)
```

### 5б. Обновить MAP (если есть)

Pack-реестры обычно в:
- `PACK-digital-platform/pack/.../MAP.md`
- `hard-distinctions.md` — при добавлении DP.D.*

Проверить, есть ли MAP в целевой директории. Добавить строку.

### 5в. Записать в feedback-log (при reject)

Файл: `${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/feedback-log.md` (создать если нет).
Формат записи:

```markdown
## <дата> — reject кандидата <id> из отчёта <filename>
**Причина:** <reason>
**Паттерн (для R2):** <pattern>
```

### 5г. Коммит

```bash
git add <target_path> [MAP если был] && git commit -m "feat(KE apply): <id> — <краткое название>" -- <target_path> [MAP если был]
```

Репо для коммита: то же, что `target_path` (PACK-digital-platform, PACK-personal и т.д.)

### Шаг 6. Обновить status отчёта

Правила:
- Все кандидаты resolved (accept/reject/defer) → `applied` если ≥1 applied, иначе `rejected` если все reject, `deferred` если есть defer без applied.
- Часть кандидатов pending → `partially-applied`.
- **Validation gate (peer-session 2026-05-31-22):** если хотя бы один кандидат имеет `decision: defer` без поля `defer_until` — отчёт НЕ может получить финальный статус `deferred`. Остаётся `partially-applied`. В тело отчёта добавить блок `## Unresolved candidates` со списком `candidate_id` + причиной (отсутствует `defer_until`). Следующий `/apply-captures`-запуск начинает с unresolved-блока. Это закрывает дыру «masked cancel» — отложенные кандидаты без триггера возврата.

Обновить `status:` в frontmatter отчёта и сохранить файл.

### Шаг 7. Итоговый отчёт

Вывести сводку:
```
Отчёт: <filename>
  Кандидатов всего: N
  Accept: N_a (записано в Pack)
  Reject: N_r (паттерны в feedback-log)
  Defer: N_d
  Статус отчёта: applied / partially-applied / rejected / deferred
```

## Appendix

### Состояния отчёта (справка)

| Статус | Очистка Session-Prep |
|--------|----------------------|
| `pending-review` | Не трогать |
| `partially-applied` | Не трогать |
| `deferred` | Не трогать |
| `applied` | Удалять через 7 дней |
| `rejected` | Удалять через 7 дней |
| `no-pending` | Удалять через 7 дней |

### Интеграция в рабочий процесс

**DayPlan (ежедневный обзор):** Шаблон DayPlan содержит секцию «Наработки ИИ → Экстрактор» с обзором:
- N pending-review отчётов
- Дата самого старого отчёта
- SLA-статус (✅ в норме / ⚠️ истёк)
- Напоминание: разбор в отдельной сессии `/apply-captures`

**Close Gate:** `extensions/protocol-close.checks.md` — при N > 0 pending-review выдаёт предупреждение ⚠️ и SLA-напоминание (DP.SC.004 §Hard gate). Soft gate — не блокирует Close, но требует решения ≤24ч.

**Полный цикл:**
1. Cron / `extractor.sh` → создаёт `extraction-reports/*.md` (status: `pending-review`)
2. Day Open → секция «Наработки ИИ → Экстрактор» в DayPlan показывает N ожидающих
3. Close → `protocol-close.checks.md` напоминает о SLA
4. Пользователь запускает `/apply-captures` в отдельной сессии → R15 разбор → запись в Pack

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
