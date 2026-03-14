# Протокол Close (ОРЗ-фрактал)

> **Два масштаба:** День и Сессия. Триггер определяет масштаб.
> **Источник:** CLAUDE.md § 2 (slim) → этот файл.

---

## § Масштаб: День (Day Close)

> **Триггер:** «закрываю день» / «итоги дня»
> **Роль:** R1 Стратег
> **Формат:** Стратег собирает данные → показывает черновик → пользователь одобряет → Стратег записывает в DayPlan

### Алгоритм Day Close

#### 1. Сбор данных

```bash
for repo in $(ls ~/IWE/); do
  if [ -d ~/IWE/$repo/.git ]; then
    commits=$(git -C ~/IWE/$repo log --since="today 00:00" --oneline --no-merges 2>/dev/null)
    [ -n "$commits" ] && echo "=== $repo ===" && echo "$commits"
  fi
done
```

Сопоставить коммиты с таблицей «На сегодня» из DayPlan → определить статусы: done / partial / not started.

#### 2. Черновик итогов (показать пользователю)

Стратег формирует и выводит на экран:

**а) Обзор:** таблица «что сделано» (РП × статус)

**б) Что нового узнал:** Стратег подсвечивает новые знания за день:
- Captures, записанные в Pack
- Различения, добавленные в hard-distinctions
- Инсайты из сессий (архитектурные решения, паттерны)
- Новое из руководства / курса (если был слот саморазвития)

> Это экзоскелет: агент помогает увидеть, пользователь рефлексирует сам.

**в) Похвала:** Стратег предлагает формулировку — что получилось, что было непросто но сделано. Пользователь корректирует.

**г) Не забыто?** Стратег проверяет:
- Незакоммиченные изменения (`git status` по всем репо)
- Незаписанные мысли? (спросить пользователя)
- Обещания кому-то? (спросить пользователя)

**д) Задел на завтра:** Стратег предлагает — с чего начать утром, какой контекст подготовить.

#### 3. Согласование

Пользователь читает черновик → корректирует → одобряет.

#### 4. Запись

- Дописать секцию «Итоги дня» в текущий `DayPlan YYYY-MM-DD.md`:

```markdown
---

## Итоги дня

| РП | Что сделано | Статус |
|----|-------------|--------|
| #N | ... | done / partial |

**Коммиты:** N в M репо

**Что нового узнал:** ...

**Похвала:** ...

**Не забыто:** всё чисто / [что осталось]

**Завтра начать с:** ...

*Закрыто: YYYY-MM-DD HH:MM*
```

- Обновить статусы РП в WeekPlan + MEMORY.md
- Backup: `memory/ + CLAUDE.md → DS-my-strategy/exocortex/`
- Закоммитить DS-my-strategy

---

## § Масштаб: Сессия (Session Close)

> **Триггер:** «закрываю сессию», «всё», «закрывай», или РП завершён.
> **Роль:** R6 Кодировщик
> **«Закрывай» = push сразу без вопросов** (пользователь дал согласие словом).

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

0. **Pull** → `cd DS-my-strategy && git pull --rebase`
1. **Knowledge Extraction** → прочитай и выполни `DS-IT-systems/DS-ai-systems/extractor/prompts/session-close.md`:
   - Собрать отложенные captures + проверить пропущенные
   - Классифицировать → **двойной routing** (domain → Pack, implementation → DS docs/) → формализовать → валидировать
   - Показать Extraction Report (кандидаты → Pack **и** DS docs/) → получить одобрение
   - Применить одобренные (accept → Pack / DS docs/ / CLAUDE.md / memory)
2. Обновить MEMORY.md (статус РП) + **WP-REGISTRY.md** (`DS-my-strategy/docs/WP-REGISTRY.md`): обновить статус РП, дату. Если новые РП создавались в Open — проверить, что они уже в реестре
3. Зафиксировать: что сделано, что осталось
4. Закоммитить (с подтверждением)
5. Обновить `DS-my-strategy/current/Plan W{N}...` (статусы РП)
6. Синхронизировать backup: `memory/ + CLAUDE.md → DS-my-strategy/exocortex/`
7. **WP Context File:**
   - in_progress + ≥2 сессий → обновить `DS-my-strategy/inbox/WP-{N}-{slug}.md`
   - done → `mv inbox/WP-{N}-*.md → archive/wp-contexts/` (сразу, не откладывая)
   - Проверка: РП есть в WeekPlan и MEMORY.md? Нет → добавить
8. **Незавершённое и идеи:**
   - Недоделка по РП → context file (секция «Осталось»)
   - Идея развития системы → `<repo>/MAPSTRATEGIC.md`
   - Новая задача → `DS-my-strategy/inbox/captures.md` или fleeting-notes.md
   - Зерно для поста → `DS-my-strategy/drafts/draft-list.md`
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
**Деплой бота:** залито на `pilot` ✅ / на `new-architecture` не заливалось
**Осталось:** ничего / [что]
```

> Указывать только активированные роли. Ключевые (R1, R2) — указывать всегда (даже «не активирован»).
> Основание: DP.D.033 — роль ≠ исполнитель. Claude Code = исполнитель (A1), роли = маски.
> **Модель:** Указывать конкретную модель сессии — Opus 4.6, Sonnet 4.6 или Haiku 4.5. Пример: `A1 Claude Code (Opus 4.6)`.

---

## Чеклист Close

- [ ] **Session log:** удалить строку этой сессии из `DS-my-strategy/inbox/open-sessions.log`
- [ ] Все изменения закоммичены и запушены
- [ ] MEMORY.md обновлён (статусы РП)
- [ ] WP-REGISTRY.md обновлён (статусы + новые РП)
- [ ] DS-my-strategy/current/Plan обновлён
- [ ] Captures применены
- [ ] **Selective Reindex:** Pack изменены? → `selective-reindex.sh`
- [ ] **Repo CLAUDE.md:** feat-коммиты → новые правила для CLAUDE.md репо?
- [ ] **WP context:** коммиты реализуют пункт WP-плана → пункт done?
- [ ] **Draft-list:** Pack обогащён → предложить черновик? Черновики из сессии → draft-list обновлён?
- [ ] Backup → DS-my-strategy/exocortex/ синхронизирован
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
| Open, Work, Close (§ День) | R1 Стратег | protocol-*.md § День |
| Open, Work, Close (§ Сессия) | R6 Кодировщик | protocol-*.md § Сессия |
| Session-Close Extraction | R2 Экстрактор | extractor/prompts/session-close.md |
| On-Demand Extraction | R2 Экстрактор | extractor/prompts/on-demand.md |
| Bulk Extraction | R2 Экстрактор | extractor/prompts/bulk-extraction.md |
| Cross-Repo Sync | R2 Экстрактор | extractor/prompts/cross-repo-sync.md |
| Knowledge Audit | R2 Экстрактор | extractor/prompts/knowledge-audit.md |
| Inbox-Check | R2 Экстрактор | extractor/prompts/inbox-check.md |
| Ontology Sync | R2 Экстрактор | extractor/prompts/ontology-sync.md |
| Session-Prep | R1 Стратег | strategist/prompts/session-prep.md |
| Strategy-Session | R1 Стратег | strategist/prompts/strategy-session.md |
| Day-Plan | R1 Стратег | protocol-open.md § День (deprecated: strategist/prompts/day-plan.md) |
| Note-Review | R1 Стратег | strategist/prompts/note-review.md |
| Day-Close | R1 Стратег | protocol-close.md § День (deprecated: strategist/prompts/day-close.md) |
| Week-Review | R1 Стратег | strategist/prompts/week-review.md |
