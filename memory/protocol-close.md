# Протокол Close (Закрытие сессии)

> **Триггер:** «закрываю сессию», «всё», «закрывай», или РП завершён.
> **Источник:** CLAUDE.md § 2 (slim) → этот файл.
> **«Закрывай» = push сразу без вопросов** (пользователь дал согласие словом).

---

## Exit Protocol (ОБЯЗАТЕЛЬНО при завершении каждой роли)

> При завершении единицы работы в любой роли — ОБЯЗАН выполнить 3 шага.
> Тест: если роль не выполнит шаги — узнает ли кто-то, что работа выполнена? Нет → нарушен.

| # | Шаг | Что делать |
|---|-----|-----------|
| 1 | **Артефакт** | Зафиксировать результат (коммит, файл, запись) |
| 2 | **Статус** | Обновить трекер (WeekPlan, WP context, MEMORY.md) |
| 3 | **Уведомление** | Сообщить следующему (пользователь, агент, Стратег) |

---

## Алгоритм Close

0. **Pull** → `cd DS-strategy && git pull --rebase`
1. **Knowledge Extraction** → прочитай и выполни `roles/extractor/prompts/session-close.md`:
   - Собрать отложенные captures + проверить пропущенные
   - Классифицировать → маршрутизировать → формализовать → валидировать
   - **MCP-проверка:** `knowledge-mcp search` → нет дубликатов в Pack
   - Показать Extraction Report → получить одобрение
   - Применить одобренные (accept → Pack/CLAUDE.md/memory)
2. Обновить MEMORY.md (статус РП)
3. Зафиксировать: что сделано, что осталось
4. Закоммитить (с подтверждением)
5. Обновить `DS-strategy/current/Plan W{N}...` (статусы РП)
6. Синхронизировать backup: `memory/ + CLAUDE.md → DS-strategy/exocortex/`
7. **WP Context File:**
   - in_progress + ≥2 сессий → обновить `DS-strategy/inbox/WP-{N}-{slug}.md`
   - done → `mv inbox/WP-{N}-*.md → archive/wp-contexts/` (сразу, не откладывая)
   - Проверка: РП есть в WeekPlan и MEMORY.md? Нет → добавить
8. **Незавершённое и идеи:**
   - Недоделка по РП → context file (секция «Осталось»)
   - Идея развития системы → `<repo>/MAPSTRATEGIC.md`
   - Новая задача → `DS-strategy/inbox/captures.md` или fleeting-notes.md
   - Зерно для поста → `DS-strategy/drafts/draft-list.md`
9. **Draft-list проверка:**
   - Были captures в Pack? → Предложить: «Pack обогащён — добавить черновик для поста?»
   - Обновить draft-list.md если создавались черновики в этой сессии

---

## Шаблон отчёта Close

```
**РП:** #N — [название]
**Статус:** done / in_progress

**Исполнитель:** A1 Claude Code (модель: Opus / Sonnet / Haiku)
**Роли в сессии:**
- R6 Кодировщик: [что сделал]
- R5 Архитектор: [АрхГейт / не активирован]
- R2 Экстрактор: [N кандидатов → куда / не активирован]
- R1 Стратег: [что обновил / не активирован]

**Сделано:** [итог]
**Captures:** [N → куда]
**Git:** закоммичено + запушено ✅
**Осталось:** ничего / [что]
```

> Указывать только активированные роли. Ключевые (R1, R2) — указывать всегда (даже «не активирован»).
> Основание: DP.D.033 — роль ≠ исполнитель. Claude Code = исполнитель (A1), роли = маски.
> **Модель:** Указывать конкретную модель сессии — Opus 4.6, Sonnet 4.6 или Haiku 4.5. Пример: `A1 Claude Code (Opus 4.6)`.

---

## Чеклист Close

- [ ] Все изменения закоммичены и запушены
- [ ] MEMORY.md обновлён (статусы РП)
- [ ] DS-strategy/current/Plan обновлён
- [ ] Captures применены
- [ ] **MCP-проверка:** `knowledge-mcp search` → captures не дублируют существующее в Pack
- [ ] **Selective Reindex:** Pack изменены? → `selective-reindex.sh`
- [ ] **Repo CLAUDE.md:** feat-коммиты → новые правила для CLAUDE.md репо?
- [ ] **WP context:** коммиты реализуют пункт WP-плана → пункт done?
- [ ] **Draft-list:** Pack обогащён → предложить черновик? Черновики из сессии → draft-list обновлён?
- [ ] Backup → DS-strategy/exocortex/ синхронизирован
- [ ] Context file: done → `mv inbox/WP-*.md → archive/wp-contexts/` (сразу при Close)
- [ ] Отчёт Close сформирован
- [ ] WP Context File создан/обновлён при ПЕРВОМ Close
- [ ] Новое репо → MAPSTRATEGIC.md + Strategy.md

Все ✅ → «Сессия закрыта.» Иначе — указать, что осталось.

**Исключения:** сессия ≤15 мин, сессия-вопрос без изменений.

---

## Владельцы протоколов

> Владелец = роль (DP.D.033). Исполнитель всех ролей: A1 Claude Code (указывать модель: Opus / Sonnet / Haiku).

| Протокол | Роль-владелец | Где описан |
|----------|---------------|-----------|
| Open, Work, Close | R6 Кодировщик | CLAUDE.md + protocol-*.md |
| Session-Close Extraction | R2 Экстрактор | extractor/prompts/session-close.md |
| On-Demand Extraction | R2 Экстрактор | extractor/prompts/on-demand.md |
| Bulk Extraction | R2 Экстрактор | extractor/prompts/bulk-extraction.md |
| Cross-Repo Sync | R2 Экстрактор | extractor/prompts/cross-repo-sync.md |
| Knowledge Audit | R2 Экстрактор | extractor/prompts/knowledge-audit.md |
| Inbox-Check | R2 Экстрактор | extractor/prompts/inbox-check.md |
| Ontology Sync | R2 Экстрактор | extractor/prompts/ontology-sync.md |
| Session-Prep | R1 Стратег | strategist/prompts/session-prep.md |
| Strategy-Session | R1 Стратег | strategist/prompts/strategy-session.md |
| Day-Plan | R1 Стратег | strategist/prompts/day-plan.md |
| Note-Review | R1 Стратег | strategist/prompts/note-review.md |
| Day-Close | R1 Стратег | strategist/prompts/day-close.md |
| Week-Review | R1 Стратег | strategist/prompts/week-review.md |
