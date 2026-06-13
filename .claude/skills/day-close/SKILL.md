---
name: day-close
description: "Day Close protocol. Alias for /run-protocol close day — symmetric with /day-open."
argument-hint: ""
version: 1.0.0
layer: L1
status: active
triggers:
  slash: [/day-close]
  phrases: []
routing:
  executor: haiku
  deterministic: false
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

### 1. Extensions (checks)
Загрузить: `bash .claude/scripts/load-extensions.sh day-close checks`. Exit 0 → `Read` каждый файл из вывода (alphabetic) → выполнить. Exit 1 → пропустить. Поддерживает `extensions/day-close.checks.md` И `extensions/day-close.checks.<suffix>.md`.

### 1b. Extensions (after)
Загрузить: `bash .claude/scripts/load-extensions.sh day-close after`. Exit 0 → `Read` каждый файл из вывода (alphabetic) → выполнить (smoke-тесты, week-draft-append, доп. проверки). Exit 1 → пропустить. Поддерживает `extensions/day-close.after.md` И `extensions/day-close.after.<suffix>.md`.

> **Постусловия:** если checks-файлы выполнились — `## Итоги дня` обновлён в Obsidian-заметке текущего дня; маркер `.krisp-done` за сегодня поставлен (если есть Krisp-расширение).

### 2. Сбор данных

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

### 3. Governance batch

**3a.** Обновить WeekPlan (`${IWE_GOVERNANCE_REPO:-DS-strategy}/current/Plan W{N}...`): статусы РП. **Grep по номеру РП** — обновить ВСЕ упоминания.

**3b.** Обновить DayPlan `${IWE_GOVERNANCE_REPO:-DS-strategy}/current/DayPlan YYYY-MM-DD.md`: статусы ВСЕХ строк (РП + ad-hoc). Done → зачеркнуть.

**3c.** Обновить `${IWE_GOVERNANCE_REPO:-DS-strategy}/docs/WP-REGISTRY.md`: статусы + даты + **done-форматирование**. Done-РП → зачеркнуть номер, приоритет, название, репо, бюджет (`~~...~~`); снять bold с названия; эмодзи ✅ НЕ зачёркивать (см. `.claude/rules/formatting.md §Таблицы с РП`). Тильду внутри ячеек заменить (`~6.5h` → `6.5h`).

**3d.** Обновить `${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/open-sessions.log`: удалить строки закрытых сессий.

**3e.** Governance-синхронизация: новые репо/сервисы за день? → REPOSITORY-REGISTRY, navigation.md, MAP.002.

**3f. WeekReport — ФАКТЫ ДНЯ (новый шаг, ОПТ-5):** Если Week Open завершена (есть WeekReport W{N}.md):
  - Открыть `${IWE_GOVERNANCE_REPO:-DS-strategy}/current/WeekReport W{N} YYYY-MM-DD.md`
  - Добавить новый раздел `<details><summary><b>Итоги {День} {Дата}</b></summary>` **перед** `Итоги Пн-Вс` (в обратном порядке дат: сегодня → старше)
  - Содержимое: коммиты по репо, РП-статусы за день, carry-over блокеры
  - Формат: смотреть существующие разделы в WeekReport (таблицы, метрики, мультипликатор)
  - **Правило ОПТ-5:** WeekPlan содержит ТОЛЬКО намерения (план, carry-over на завтра), WeekReport содержит ТОЛЬКО факты (что было, коммиты, результаты)
  - **strategy_day (Пн без DayPlan):** Итоги пишутся в WeekReport как обычный день — только факты (РП-результаты, коммиты, мультипликатор). Плановые строки (`strategy_day → план живёт в WeekPlan`) в WeekReport НЕ копировать. Позиция в обратной хронологии: если Пн — ставить в конец (самый старый день недели).

### 4. Архивация

- **DayPlan сегодняшнего дня** → `git mv current/DayPlan $(date +%Y-%m-%d).md archive/day-plans/`. Если есть DayPlan'ы прошлых дней в `current/` (накопленный мусор) — заархивировать их тоже одной командой.
- Done WP context files → `mv inbox/WP-{N}-*.md → archive/wp-contexts/`
- Done РП → удалить строку из MEMORY.md (они уже в WP-REGISTRY и WeekPlan)

> MEMORY.md хранит ТОЛЬКО активные РП (in_progress + pending). Done = удалить.
> Архивация DayPlan ОБЯЗАТЕЛЬНА: следующий Day Open читает carry-over из `archive/day-plans/DayPlan {вчера}.md` и предполагает, что `current/` чистый.

### 5б. Memory Drift Scan

> Страховочная сетка — ловит то, что не обновили в Quick Close сессий за день.

```bash
grep -nE "→ ждёт|ждёт|dep:|блокер|blocked:|остановлен|ждёт согласования" \
  {{HOME_DIR}}/.claude/projects/*/memory/MEMORY.md 2>/dev/null
```

Для каждого найденного паттерна:
1. Определить номер РП (WP-NNN) из контекста строки
2. Найти WP-context: `ls ${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/WP-{N}-*.md` (если заархивирован — `archive/wp-contexts/`)
3. Прочитать секцию «Что узнали» / «Осталось» / финальный статус
4. Если там есть признак закрытия (`DONE`, `РЕШЕНО`, `✅`, `починил`, `закрыт`, `снят`) рядом с тем же именем/системой → обновить MEMORY.md, анонс: *«Memory drift: [факт] устарел → обновлён»*
5. Если WP-context не найден → отметить в итогах: *«Memory drift: WP-N — context не найден, проверить вручную»*

Анонс при 0 изменениях: *«Drift-scan: проверено N паттернов, устаревших фактов не найдено»*

### 5в. Index Health Check

> Ловит раздутие индекс-файлов (MEMORY.md, WP-REGISTRY.md, MAPSTRATEGIC.md, *-registry.md, *-index.md, *-catalog.md). Правило: [feedback_memory_index_discipline.md](../../../memory/feedback_memory_index_discipline.md) — шапки и колонки индексов = hook-строки, не дамп контекста.

```bash
SCRIPT="{{HOME_DIR}}/IWE/.claude/scripts/check-index-health.py"
[ -f "$SCRIPT" ] && python3 "$SCRIPT" || echo "skip: check-index-health.py не найден — запустите update.sh"
```

Для каждого FAIL/WARN в отчёте:
1. Открыть файл, посмотреть конкретные строки/ячейки из отчёта.
2. Диагностика: это дамп контекста (болезнь) или методологическая таблица (жанр)?
   - Дамп → перенести контекст в source-of-truth (inbox/WP-NNN-*.md, WeekPlan, отдельный `*-changelog.md`); в индексе — hook + ссылка.
   - Жанр (таблица-матрица, каталог доменных сущностей) → пометить в начале файла: `<!-- index-health: skip-cells -->` или `<!-- index-health: skip -->` с обоснованием в комментарии.
3. Если FAIL в Pack-файле — не чистить автоматически, это вопрос к владельцу домена (только пометить skip с обоснованием).

Анонс при 0 WARN/FAIL: *«Index-health: N файлов OK, M skip»*. При наличии — перечислить FAIL/WARN с кратким действием.

### 5. Lesson Hygiene

- Просмотреть секцию «Уроки» в MEMORY.md
- Урок применялся сегодня? → оставить
- Урок не применялся >1 нед и есть в тематическом файле (`lessons_*.md`)? → удалить из MEMORY.md
- Новый урок за день? → записать в MEMORY.md (краткая строка) + тематический файл (подробно)
- Цель: ≤8 уроков в MEMORY.md

### 6. Автоматические шаги

```bash
"$IWE_SCRIPTS/day-close.sh"
```

Скрипт выполняет: Linear sync, downstream sync (update.sh), backup (memory/ + CLAUDE.md).

### 6a. Week Draft (рефлексивный черновик)

> **Роль после ОПТ-5:** week-draft — рефлексивный черновик, НЕ дубль метрик WeekReport.
> WeekReport (шаг 3f/10b) = факты (коммиты, РП, мультипликатор).
> Week-draft = мысли, нерешённые вопросы, инсайты для недельного поста.

**Понедельник:** инициализировать черновик недели:
```bash
"$IWE_SCRIPTS/week-draft-init.sh"
```

**Каждый день (включая Пн):** дописать метрики дня в черновик:
```bash
"$IWE_SCRIPTS/week-draft-append.sh"
```

Если `knowledge_repo` не задан в `params.yaml` — оба скрипта выходят с кодом 0 (пропуск), шаг не блокирует закрытие.

> Рефлексия (мир/сообщество/человек/личное): если `knowledge_repo` настроен — агент набрасывает три первых секции из контекста дня; по «Личному» — спросить пилота.

### 7. Мультипликатор IWE

> Условный шаг: если `params.yaml → multiplier_enabled: false` → пропустить.

**Алгоритм:**

1. **WakaTime** — физическое время за день:
   - Сначала CLI: `~/.wakatime/wakatime-cli --today` (CLI не в PATH, бинарник в `~/.wakatime/`)
   - Если CLI недоступен → **fallback Neon**: `SELECT payload->>'human_readable', payload->>'total_seconds' FROM learning.public.domain_event WHERE event_type='coding_time' AND account_id='{DT_USER_ID}' AND external_id='wakatime:{DT_USER_ID}:{YYYY-MM-DD}'`
   - Если Neon тоже пуст (данные синхронизируются ночью) → пометить «pending Neon» и пересчитать при следующей сессии
   - Поле: `payload->>'human_readable'` (напр. «9 hrs»); `total_seconds` для мультипликатора
2. **Бюджет закрыт — считать ПО ФАКТУ, не по букве плана** (БЛОКИРУЮЩЕЕ, урок 27 мая):
   - **Шаг 2.0 (обязательный prerequisite):** открыть `<governance-repo>/sessions/00-index.md`, отфильтровать строки за сегодня (`grep "$(date +%Y-%m-%d)"`), составить полный список peer-сессий с числом ходов. Без этого расчёт занижен ×2.
   - done → полный бюджет (или пропорционально фазам для зонтичных)
   - partial → % выполнения × бюджет; **если сверхплановая работа в плановом РП** (например, план Ф1, реализовано Ф1+Ф7) — засчитывать ФАКТ, не плановый бюджет
   - not started → 0h
   - **ad-hoc peer-сессии (без РП-метки в DayPlan): оценка по числу ходов**, НЕ заглушка 0.25h:
     - 2-4 хода → 0.25-0.5h
     - 5-7 ходов → 0.75-1h
     - 8+ ходов → 1-1.5h
   - **Мелкие правки/чистки без peer-сессии** (бюджет «—» / merged) → 0.25h
3. **Мультипликатор дня** = Бюджет закрыт / WakaTime. Формат: `N.Nx`
4. **Sanity check (БЛОКИРУЮЩЕЕ):** если получившийся мультипликатор <1.5x при дне с ≥10 peer-сессий — пересчитать (вероятен недосчёт ad-hoc или сверхпланового). Показать пилоту 3 метода (буква SKILL / по факту / компромисс) и спросить какой записывать. Урок: `lessons_multiplier_peer_sessions_uncounted.md`.

### 8. Черновик итогов (показать пользователю)

**а) Обзор:** таблица «что сделано» (РП × статус)

**б) Что нового узнал:** captures в Pack, различения, инсайты.

**в) Похвала:** что получилось, что было непросто но сделано.

**г) Не забыто?**
- Незакоммиченные изменения: `${IWE_SCRIPTS}/check-dirty-repos.sh` (сканирует ВСЕ репо в `{{WORKSPACE_DIR}}`, включая вложенные). Если есть грязные → закоммитить и запушить ДО продолжения.

- **Часы саморазвития (WP-310 Ф13c):** записан ли `/slot` за сегодня? Если у пользователя есть бот-аккаунт — спросить «Сколько часов саморазвития сегодня?», предложить кнопки 0/0.5/1/2/3/4 или свой ввод. После ответа: подсказать команду `/slot N` в бот пилота (handler пишет slot_logged event с source='self_report_daily'). bh.inv обновится при следующем прогоне Аттестатора (04:35 МСК).
- Незаписанные мысли? (спросить пользователя)
- Обещания кому-то? (спросить пользователя)

**д) Видео за день:** если `video.enabled: true` → проверить новые видео.

**е) Draft-list:** Pack обогащён → предложить черновик?

**ж) Задел на завтра:**
- С чего начать утром
- Незавершённые РП: что именно осталось (конкретный next action по каждому)

### 9. Согласование

Пользователь читает черновик → корректирует → одобряет.

### 10. Запись итогов

**10a.** Дописать секцию «Итоги дня» в DayPlan (шаблон — см. `memory/templates-dayplan.md § Шаблон итогов дня`).

**Валидация «Завтра начать с» (ADR-207):** поле не пустое + каждый pending РП упомянут + каждый содержит конкретный next action (не «продолжить работу»).

**Postcondition 9a (машинная проверка — НЕ пропускать):**
```bash
TODAY=$(date +%Y-%m-%d)
GOV="$HOME/IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}"
DAYPLAN="$GOV/archive/day-plans/DayPlan ${TODAY}.md"
# Без xargs: имя файла содержит пробел («DayPlan 2026-06-13.md»), xargs резал его по whitespace → ложный FAIL (#173).
[ -f "$DAYPLAN" ] && grep -q "Итоги дня" "$DAYPLAN" && grep -q "${TODAY}" "$DAYPLAN" \
  && echo "9a OK" || echo "9a FAIL: итоги за ${TODAY} не найдены в archive/day-plans/DayPlan ${TODAY}.md"
```
Результат `9a FAIL` → шаг НЕ помечать completed, вернуться к записи.

**10b.** Дописать сводку итогов в WeekReport (split, ОПТ-5 WP-297):
- Файл: `${IWE_GOVERNANCE_REPO:-DS-strategy}/current/WeekReport W{N} YYYY-MM-DD.md` (дата = первый день недели)
- Если файла нет (старый цикл) — fallback в WeekPlan, пометить «требует split в session-prep следующей недели»
- Формат: `<details><summary><b>Итоги {день} {дата}</b></summary>...</details>`
- Порядок: свежие итоги СВЕРХУ (обратная хронология). Проверять: вставлять сразу ниже `</details>` последнего W18-summary, а не в конец файла.
- Содержание: таблица коммитов по репо, закрытые РП, продвинутые РП, мультипликатор

**Postcondition 9b (машинная проверка — НЕ пропускать):**
```bash
TODAY=$(date +%Y-%m-%d)
DAY_NUM=$(date +%-d)
GOV="$HOME/IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}"
# 9b намеренно через glob (WeekReport W*.md), НЕ xargs: glob раскрывается шеллом по-аргументно и сохраняет
# границы имён с пробелами (в отличие от word-splitting в xargs, #173). Не «чинить» на xargs.
# Токен дня ограничен ([^0-9]+ слева, [^0-9]|$ справа): «1» не матчит «31»/«12». Не упрощать до .*${DAY_NUM}.
# Сначала WeekReport (split ОПТ-5), fallback на WeekPlan.
( grep -rlE "Итоги[^0-9]+${DAY_NUM}([^0-9]|$)" "$GOV"/current/WeekReport\ W*.md 2>/dev/null \
  || grep -rlE "Итоги[^0-9]+${DAY_NUM}([^0-9]|$)" "$GOV"/current/WeekPlan\ W*.md 2>/dev/null ) \
  | grep -q . && echo "9b OK" || echo "9b FAIL: итоги за день ${DAY_NUM} не найдены ни в WeekReport, ни в WeekPlan"
```
Результат `9b FAIL` → шаг НЕ помечать completed, вернуться к записи.

### 11. Закоммитить ${IWE_GOVERNANCE_REPO:-DS-strategy}

### 11b. Rule Classifier (WP-272 Ф5.2)

```bash
SCRIPT="$HOME/IWE/.claude/scripts/rule-classifier.py"
[ -f "$SCRIPT" ] && python3 "$SCRIPT" || echo "skip: rule-classifier.py требует ручной установки (claude CLI + PACK-agent-rules)"
```

Запускается после коммита. Обогащает журнал `~/logs/rule-engine/YYYY-MM-DD.jsonl` → `YYYY-MM-DD-classified.jsonl`. Exit код игнорировать (launchd тоже запускает раз в час — идемпотентно). Не ждать завершения если >60 сек (kill).

### 12. Верификация (Haiku R23)

**12a. Собрать факты (основной агент — ДО вызова Haiku):**
```bash
TODAY=$(date +%Y-%m-%d)
GOV="$HOME/IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}"
DAYPLAN="$GOV/archive/day-plans/DayPlan ${TODAY}.md"   # тот же путь, что 9a (archive/, не current/)
# postcondition 9a: итоги дня записаны (grep -c при 0 совпадений сам печатает 0 и выходит !=0 → отдельный if, без двойного «0»)
if [ -f "$DAYPLAN" ]; then grep -c "Итоги дня" "$DAYPLAN"; else echo 0; fi
# postcondition 9b: сегодняшняя сводка в WeekReport, fallback WeekPlan (зеркалит 9b — тот же двухуровневый путь)
DAY_NUM=$(date +%-d)
( grep -rlE "Итоги[^0-9]+${DAY_NUM}([^0-9]|$)" "$GOV"/current/WeekReport\ W*.md 2>/dev/null \
  || grep -rlE "Итоги[^0-9]+${DAY_NUM}([^0-9]|$)" "$GOV"/current/WeekPlan\ W*.md 2>/dev/null ) | grep -q . && echo 1 || echo 0
# коммит за сегодня есть (governance-репо)
git -C "$GOV" log --oneline --since="${TODAY} 00:00" | wc -l | tr -d ' '
# DayPlan заархивирован
[ -f "$DAYPLAN" ] && echo "archived" || echo "NOT archived"
```

**12b. Вызвать sub-agent Haiku (context isolation) с фактами:**
Передать Haiku: (1) чеклист Day Close, (2) факты из шага 12a, (3) список обновлённых файлов.
Haiku оценивает по **фактам**, не догадывается о состоянии файлов.
По ❌ — исправить до показа пользователю.

---

## Чеклист Day Close

- [ ] Все изменения закоммичены и запушены (по всем репо)
- [ ] Extensions before выполнены (если файлы есть)
- [ ] Extensions checks выполнены (если файлы есть)
- [ ] Extensions after выполнены (если файлы есть)
- [ ] Постусловия extensions: `## Итоги дня` обновлён в Obsidian-заметке текущего дня
- [ ] Маркер `.krisp-done` за сегодня поставлен (если есть Krisp-расширение)
- [ ] MEMORY.md: done-РП удалены, активные актуальны, drift-scan выполнен (шаг 5б)
- [ ] Index Health Check (шаг 5в): `check-index-health.py` — все FAIL/WARN разобраны или помечены skip
- [ ] WP-REGISTRY.md обновлён: статусы + done-форматирование (done-строки зачёркнуты, ✅ не зачёркнут)
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
- [ ] Week Draft (6a): `week-draft-init.sh` (Пн) + `week-draft-append.sh` выполнены (или пропуск если `knowledge_repo` не задан)
- [ ] **Rule-engine FP-stats** (WP-272 Ф2.5): `[ -f ~/IWE/.claude/scripts/fp-stats.py ] && python3 ~/IWE/.claude/scripts/fp-stats.py --date $(date +%Y-%m-%d) || echo "skip: fp-stats.py требует rule-classifier.py"` → если есть `⚠️ REVISE` (FP > 20%) — записать в «Завтра начать с» правило + FP%. Флоу ревизии: `~/IWE/PACK-agent-rules/revision-flow.md`.
- [ ] Верификация compliance: /verify запускался сегодня?
- [ ] WakaTime + Мультипликатор: часы / **бюджет ПО ФАКТУ** (sessions/00-index.md перечислен; ad-hoc peer-сессии оценены по числу ходов; сверхплановая работа в плановом РП — по факту); остаток недели. Sanity check: мультипликатор <1.5x при ≥10 peer-сессий = пересчитать
- [ ] Итоги дня записаны в DayPlan **(postcondition 9a: grep подтверждён)**
- [ ] Handoff-валидация: «Завтра начать с» содержит ВСЕ pending РП с конкретным next action
- [ ] Сводка итогов записана в WeekReport (`<details>`, обратная хронология) **(postcondition 9b: grep подтверждён)**
- [ ] Новое репо → MAPSTRATEGIC.md + Strategy.md

Все ✅ → «День закрыт.» Иначе — указать что осталось.
