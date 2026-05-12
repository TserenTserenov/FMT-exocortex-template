---
name: day-close
description: "Протокол закрытия дня (Day Close). Алиас для /run-protocol close day — симметрия с /day-open."
argument-hint: ""
version: 1.0.0
---

# Day Close (протокол закрытия дня)

> **Роль:** R1 Стратег. **Бюджет:** ~10 мин.
> **Принцип:** SKILL.md = L1 платформенный файл. Пользователь не редактирует напрямую — только через `extensions/`.

## БЛОКИРУЮЩЕЕ: пошаговое исполнение

Day Close = протокол. Исполнять ТОЛЬКО пошагово через TodoWrite.
**Шаг 0 — ПЕРВОЕ действие:** создать список задач прямо сейчас (до любых других действий).
Каждый шаг алгоритма → отдельная задача (pending → in_progress → completed).
Переход к следующему — ТОЛЬКО после отметки текущего. Шаг невозможен → blocked (не пропускать молча).

## Алгоритм

### 0. Extensions (before)
Загрузить: `bash .claude/scripts/load-extensions.sh day-close before`. Exit 0 → `Read` каждый файл из вывода (alphabetic) → выполнить как первые шаги. Exit 1 → пропустить. Поддерживает `extensions/day-close.before.md` И `extensions/day-close.before.<suffix>.md`.

### 1. Сбор данных

```bash
for repo in $(ls {{HOME_DIR}}/IWE/); do
  if [ -d {{HOME_DIR}}/IWE/$repo/.git ]; then
    commits=$(git -C {{HOME_DIR}}/IWE/$repo log --since="today 00:00" --oneline --no-merges 2>/dev/null \
      | grep -vE "^(docs|chore|ci|style|perf|test)(\\(|:| )" \
      | grep -vE "memory/|\.claude/rules/|template-sync|backup|reindex" \
      || true)
    [ -n "$commits" ] && echo "=== $repo ===" && echo "$commits"
  fi
done
```

Сопоставить коммиты с таблицей «На сегодня» из DayPlan → определить статусы.

### 2. Governance batch

**2a.** Обновить WeekPlan (`{{GOVERNANCE_REPO}}/current/Plan W{N}...`): статусы РП. **Grep по номеру РП** — обновить ВСЕ упоминания.

**2b.** Обновить DayPlan `{{GOVERNANCE_REPO}}/current/DayPlan YYYY-MM-DD.md`: статусы ВСЕХ строк (РП + ad-hoc). Done → зачеркнуть.

**2c.** Обновить `{{GOVERNANCE_REPO}}/docs/WP-REGISTRY.md`: статусы + даты.

**2d.** Обновить `{{GOVERNANCE_REPO}}/inbox/open-sessions.log`: удалить строки закрытых сессий.

**2e.** Governance-синхронизация: новые репо/сервисы за день? → REPOSITORY-REGISTRY, navigation.md, MAP.002.

**2f. WeekReport — ФАКТЫ ДНЯ (ОПТ-5):** Если есть WeekReport W{N} YYYY-MM-DD.md:
  - Открыть `{{GOVERNANCE_REPO}}/current/WeekReport W{N} YYYY-MM-DD.md`
  - Добавить новый раздел `<details><summary><b>Итоги {День} {Дата}</b></summary>` **перед** существующими `Итоги ...` (в обратном порядке дат: сегодня → старше). Проверять: вставлять сразу ниже `</details>` W18-summary, а не в конец файла.
  - Содержимое: коммиты по репо, РП-статусы за день, мультипликатор
  - **Правило ОПТ-5:** WeekPlan содержит ТОЛЬКО намерения, WeekReport содержит ТОЛЬКО факты
  - **strategy_day (Пн без DayPlan):** Итоги пишутся как обычный день — только факты. Плановые строки (`strategy_day → план живёт в WeekPlan`) в WeekReport НЕ копировать. Позиция: Пн всегда в конец (самый старый день недели).
  - Если файла нет (старый цикл) — fallback в WeekPlan, пометить «требует split при следующей strategy-session»

**EXTENSION POINT (day-close checks):** `bash .claude/scripts/load-extensions.sh day-close checks` — exit 0 → `Read` каждый файл из вывода (alphabetic) → выполнить. Exit 1 → пропустить. Поддерживает `extensions/day-close.checks.md` И `extensions/day-close.checks.<suffix>.md`.

### 3. Архивация

- **DayPlan сегодняшнего дня** → `git mv current/DayPlan $(date +%Y-%m-%d).md archive/day-plans/`. Если есть DayPlan'ы прошлых дней в `current/` (накопленный мусор) — заархивировать их тоже одной командой.
- Done WP context files → `mv inbox/WP-{N}-*.md → archive/wp-contexts/`
- Done РП → удалить строку из MEMORY.md (они уже в WP-REGISTRY и WeekPlan)

> MEMORY.md хранит ТОЛЬКО активные РП (in_progress + pending). Done = удалить.
> Архивация DayPlan ОБЯЗАТЕЛЬНА: следующий Day Open читает carry-over из `archive/day-plans/DayPlan {вчера}.md` и предполагает, что `current/` чистый.

### 4б. Memory Drift Scan

> Страховочная сетка — ловит то, что не обновили в Quick Close сессий за день.

```bash
grep -nE "→ ждёт|ждёт|dep:|блокер|blocked:|остановлен|ждёт согласования" \
  {{HOME_DIR}}/.claude/projects/*/memory/MEMORY.md 2>/dev/null
```

Для каждого найденного паттерна:
1. Определить номер РП (WP-NNN) из контекста строки
2. Найти WP-context: `ls {{GOVERNANCE_REPO}}/inbox/WP-{N}-*.md` (если заархивирован — `archive/wp-contexts/`)
3. Прочитать секцию «Что узнали» / «Осталось» / финальный статус
4. Если там есть признак закрытия (`DONE`, `РЕШЕНО`, `✅`, `починил`, `закрыт`, `снят`) рядом с тем же именем/системой → обновить MEMORY.md, анонс: *«Memory drift: [факт] устарел → обновлён»*
5. Если WP-context не найден → отметить в итогах: *«Memory drift: WP-N — context не найден, проверить вручную»*

Анонс при 0 изменениях: *«Drift-scan: проверено N паттернов, устаревших фактов не найдено»*

### 4в. Index Health Check

> Ловит раздутие индекс-файлов (MEMORY.md, WP-REGISTRY.md, MAPSTRATEGIC.md, *-registry.md, *-index.md, *-catalog.md). Правило: hook-строки в индексах, не дамп контекста.
> **Условный шаг:** скрипт опционален. Если `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/scripts/check-index-health.py` отсутствует — пропустить.

```bash
SCRIPT="{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/scripts/check-index-health.py"
[ -f "$SCRIPT" ] && python3 "$SCRIPT" || echo "check-index-health.py не установлен — шаг пропущен"
```

Для каждого FAIL/WARN в отчёте:
1. Открыть файл, посмотреть конкретные строки/ячейки из отчёта.
2. Диагностика: это дамп контекста (болезнь) или методологическая таблица (жанр)?
   - Дамп → перенести контекст в source-of-truth (inbox/WP-NNN-*.md, WeekPlan, отдельный `*-changelog.md`); в индексе — hook + ссылка.
   - Жанр (таблица-матрица, каталог доменных сущностей) → пометить в начале файла: `<!-- index-health: skip-cells -->` или `<!-- index-health: skip -->` с обоснованием в комментарии.
3. Если FAIL в Pack-файле — не чистить автоматически, это вопрос к владельцу домена (только пометить skip с обоснованием).

Анонс при 0 WARN/FAIL: *«Index-health: N файлов OK, M skip»*. При наличии — перечислить FAIL/WARN с кратким действием.

### 4. Lesson Hygiene

- Просмотреть секцию «Уроки» в MEMORY.md
- Урок применялся сегодня? → оставить
- Урок не применялся >1 нед и есть в тематическом файле (`lessons_*.md`)? → удалить из MEMORY.md
- Новый урок за день? → записать в MEMORY.md (краткая строка) + тематический файл (подробно)
- Цель: ≤8 уроков в MEMORY.md

### 5. Автоматические шаги

```bash
"$IWE_SCRIPTS/day-close.sh"
```

Скрипт выполняет: Linear sync, downstream sync (update.sh), backup (memory/ + CLAUDE.md).

### 6. Мультипликатор IWE

> Условный шаг: если `params.yaml → multiplier_enabled: false` → пропустить.

**Алгоритм:**

1. **WakaTime** — физическое время за день:
   - Сначала CLI: `~/.wakatime/wakatime-cli --today` (CLI не в PATH, бинарник в `~/.wakatime/`)
   - Если CLI недоступен → **fallback Neon**: `SELECT payload->>'human_readable', payload->>'total_seconds' FROM public.domain_event WHERE event_type='coding_time' AND account_id='{DT_USER_ID}' AND external_id='wakatime:{DT_USER_ID}:{YYYY-MM-DD}'` (БД `learning`)
   - Если Neon тоже пуст (данные синхронизируются ночью) → пометить «pending Neon» и пересчитать при следующей сессии
   - Поле: `payload->>'human_readable'` (напр. «9 hrs»); `total_seconds` для мультипликатора
2. **Бюджет закрыт** — сумма бюджетов по ВСЕМ РП за день:
   - done → полный бюджет (или пропорционально фазам для зонтичных)
   - partial → % выполнения × бюджет
   - not started → 0h
   - Мелкие РП (бюджет «—» / merged) → 0.25h, не 0
3. **Мультипликатор дня** = Бюджет закрыт / WakaTime. Формат: `N.Nx`

### 7. Черновик итогов (показать пользователю)

**а) Обзор:** таблица «что сделано» (РП × статус)

**б) Что нового узнал:** captures в Pack, различения, инсайты.

**в) Похвала:** что получилось, что было непросто но сделано.

**г) Не забыто?**
- Незакоммиченные изменения: `${IWE_SCRIPTS}/check-dirty-repos.sh` (сканирует ВСЕ репо в workspace, включая вложенные DS-* директории). Если есть грязные → закоммитить и запушить ДО продолжения.
- **EXTENSION POINT:** Загрузить: `bash .claude/scripts/load-extensions.sh day-close checks` (см. шаг 2e).
- Незаписанные мысли? (спросить пользователя)
- Обещания кому-то? (спросить пользователя)

**д) Видео за день:** если `video.enabled: true` → проверить новые видео.

**е) Draft-list:** Pack обогащён → предложить черновик?

**ж) Задел на завтра — 3 варианта плана (БЛОКИРУЮЩЕЕ, WP-196 Ф11 п5):**

Сформулируй ТРИ альтернативных плана на завтра, между которыми пользователь выбирает на Day Open:
1. **Вариант A — продолжение:** что начать первым по carry-over и текущим РП
2. **Вариант B — переключение фокуса:** взять застрявший РП с другим типом работы (если сегодня была глубокая разработка → завтра контент или ритуал, и наоборот)
3. **Вариант C — экстра:** если будет «свободный» час, что взять из backlog

Каждый вариант: 1-2 предложения с конкретным next action. Без вариантов поле = неполный Day Close.

Для каждого pending РП в табличке — конкретный next action (не «продолжить работу»).

### 8. Согласование

Пользователь читает черновик → корректирует → одобряет.

### 9. Запись итогов

**9a.** Дописать секцию «Итоги дня» в DayPlan (шаблон — см. `memory/templates-dayplan.md § Шаблон итогов дня`).

**Валидация «Завтра начать с» (ADR-207):** поле не пустое + каждый pending РП упомянут + каждый содержит конкретный next action (не «продолжить работу»).

**Postcondition 9a (машинная проверка — НЕ пропускать):**
```bash
TODAY=$(date +%Y-%m-%d)
grep -l "Итоги дня" {{HOME_DIR}}/IWE/{{GOVERNANCE_REPO}}/archive/day-plans/DayPlan\ ${TODAY}.md 2>/dev/null \
  | xargs grep -l "${TODAY}" 2>/dev/null \
  | grep -q . && echo "9a OK" || echo "9a FAIL: итоги не найдены в DayPlan ${TODAY}"
```
Результат `9a FAIL` → шаг НЕ помечать completed, вернуться к записи.

**9b.** Дописать сводку итогов в WeekReport (split, ОПТ-5 WP-297):
- Файл: `<governance-repo>/current/WeekReport W{N} YYYY-MM-DD.md` (создаётся session-prep при формировании WeekPlan)
- Если файла нет (старый цикл) — fallback в WeekPlan, пометить «требует split в session-prep следующей недели»
- Формат: `<details><summary><b>Итоги {день} {дата}</b></summary>...</details>`
- Порядок: свежие итоги СВЕРХУ (обратная хронология). Проверять: вставлять сразу ниже `</details>` W18-summary, а не в конец файла.
- Содержание: таблица коммитов по репо, закрытые РП, продвинутые РП, мультипликатор

**9b2. Записать сводку в session-log (WP-196 Ф11 п1):**
- Файл: `<governance-repo>/sessions/YYYY-MM-DD.md` (создан утром в Day Open шаге 7a2)
- Дописать секции «Сессии дня» (Quick Close сессии + ключевые рубежи) и «Day Close» (ссылка на архивный DayPlan + 3 варианта плана на завтра)
- Если файла нет (Day Open пропущен) — создать с шапкой и заполнить только Day Close секцию

**Postcondition 9b (машинная проверка — НЕ пропускать):**
```bash
TODAY=$(date +%Y-%m-%d)
DAY_NUM=$(date +%-d)
# Сначала проверь WeekReport (split ОПТ-5), fallback на WeekPlan
( grep -rl "Итоги.*${DAY_NUM}" {{HOME_DIR}}/IWE/{{GOVERNANCE_REPO}}/current/WeekReport\ W*.md 2>/dev/null \
  || grep -rl "Итоги.*${DAY_NUM}" {{HOME_DIR}}/IWE/{{GOVERNANCE_REPO}}/current/WeekPlan\ W*.md 2>/dev/null ) \
  | grep -q . && echo "9b OK" || echo "9b FAIL: итоги не найдены ни в WeekReport, ни в WeekPlan"
```
Результат `9b FAIL` → шаг НЕ помечать completed, вернуться к записи.

### 9c. Extensions (after)

Загрузить: `bash .claude/scripts/load-extensions.sh day-close after`. Exit 0 → `Read` каждый файл из вывода (alphabetic) → выполнить. Exit 1 → пропустить. Поддерживает `extensions/day-close.after.md` И `extensions/day-close.after.<suffix>.md`.

### 10. Закоммитить {{GOVERNANCE_REPO}}

### 11. Верификация (Haiku R23)

Запустить sub-agent Haiku в роли R23 Верификатор (context isolation).
Передать: (1) чеклист Day Close, (2) черновик итогов, (3) список обновлённых файлов.
По ❌ — исправить до показа пользователю.

**EXTENSION POINT:** Загрузить: `bash .claude/scripts/load-extensions.sh day-close checks`. Exit 0 → `Read` каждый файл из вывода (alphabetic) → выполнить. Exit 1 → пропустить. Поддерживает `extensions/day-close.checks.md` И `extensions/day-close.checks.<suffix>.md`.

---

## Чеклист Day Close

- [ ] Все изменения закоммичены и запушены (по всем репо)
- [ ] MEMORY.md: done-РП удалены, активные актуальны, drift-scan выполнен (шаг 4б)
- [ ] Index Health Check (шаг 4в): `check-index-health.py` — все FAIL/WARN разобраны или помечены skip
- [ ] WP-REGISTRY.md обновлён
- [ ] WeekPlan обновлён (grep по номерам РП — ВСЕ упоминания)
- [ ] DayPlan обновлён (статусы ВСЕХ строк: РП + ad-hoc)
- [ ] open-sessions.log: строки закрытых сессий удалены
- [ ] Captures за день применены (все Quick Close → KE пройден)
- [ ] Синхронизация downstream: `update.sh` выполнен
- [ ] Linear sync: статусы соответствуют git. Пост-sync чек: кол-во active РП в REGISTRY = кол-во active issues в Linear
- [ ] Repo CLAUDE.md: feat-коммиты → новые правила?
- [ ] DayPlan сегодня → `archive/day-plans/` (старые DayPlan'ы в `current/` тоже)
- [ ] WP context: done → `mv inbox/ → archive/wp-contexts/`
- [ ] Lesson Hygiene: уроки MEMORY.md ≤8
- [ ] Draft-list: Pack обогащён → черновик предложен?
- [ ] Видео: обработанные помечены (если video.enabled)
- [ ] Governance: REPOSITORY-REGISTRY, navigation.md, MAP.002
- [ ] Backup: `day-close.sh` выполнен
- [ ] Верификация compliance: /verify запускался сегодня?
- [ ] WakaTime + Мультипликатор: часы, бюджет, остаток недели
- [ ] Итоги дня записаны в DayPlan **(postcondition 9a: grep подтверждён)**
- [ ] Handoff-валидация: «Завтра начать с» содержит ВСЕ pending РП с конкретным next action
- [ ] Сводка итогов записана в WeekReport (`<details>`, обратная хронология) **(postcondition 9b: grep подтверждён)**
- [ ] Новое репо → MAPSTRATEGIC.md + Strategy.md

Все ✅ → «День закрыт.» Иначе — указать что осталось.
