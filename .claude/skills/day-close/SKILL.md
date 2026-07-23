---
name: day-close
description: "Протокол закрытия дня (Day Close). Алиас для /run-protocol close day — симметрия с /day-open."
argument-hint: ""
version: 1.1.0
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
`bash .claude/scripts/load-extensions.sh day-close before` → exit 0: `Read` каждый файл из вывода (alphabetic) → выполнить как первые шаги. Поддерживает `extensions/day-close.before.md` И `extensions/day-close.before.<suffix>.md`.

### 0б. Дайджест — token discipline (issue #234)
`bash "$IWE_SCRIPTS/day-close-prepare.sh"` — один вызов вместо ~10 скан-запросов. Пронумерованные секции дайджеста ЗАМЕНЯЮТ скан-команды внутри шагов ниже (сами шаги исполняются — но берут данные из дайджеста, не перезапускают сканы): §1→шаг 1, §2→10b, §3→2d, §4→4б, §5→4в, §6→4, §7→6, §8→6 (prerequisite), §9-10→3, §11→2f. Реагировать только на flagged-пункты; drift-хит, который реально «ждёт X», — не drift. Скрипт отсутствует → legacy: inline-команды шагов.
**Субагентное исполнение (рекомендуется при большой сессии дня):** родитель выполняет только дайджест → диспетчеризацию → согласование (шаг 8) → верификацию; шаги 1-7 исполняет ОДИН general-purpose субагент (sonnet, context isolation) с дайджестом в промпте, шаги 9-10b — субагент-финализатор с `day-close-prepare.sh --verify` вместо inline-grep 9a/9b; шаг 11 (R23) диспетчеризует родитель — субагент не может звать субагентов. Fallback: Agent tool недоступен / субагент упал дважды → исполнять inline, всё равно с дайджестом.
<!-- Детали фаз: day-close-details.md § Шаг 0б -->

> **Best practice:** запускать `/day-close` в свежей сессии, не хвостом рабочей — протоколу нужны файлы на диске, а не разговор за день.

### 0в. Strategy_day guard (issue #286)
Проверить `day_open.strategy_day` в `day-rhythm-config.yaml` (тот же ключ, что читает `/day-open`, по умолчанию `monday`) против дня недели сегодня. Симметрично `/day-open` (SKILL.md шаг 4: «Если `strategy_day` → DayPlan НЕ создавать»): в стратегический день `current/DayPlan <дата>.md` не создавался — шаги 1, 2b, 3, 9a **неприменимы** (не FAIL), см. пометки внутри них. Итоги дня идут только в WeekReport (шаг 9b), как и предписывает § ниже.
<!-- Детали: day-close-details.md § Шаг 0в -->

### 1. Сбор данных
**Strategy_day (шаг 0в) → неприменимо, пропустить** (нет DayPlan, сверять таблицу «На сегодня» не с чем). Иначе: запустить bash-скрипт сбора коммитов за день по всем git-репо в `{{HOME_DIR}}/IWE/`. Сопоставить с таблицей «На сегодня» из DayPlan → определить статусы.
<!-- Детали: day-close-details.md § Шаг 1 -->

### 2. Governance batch
**2a.** WeekPlan (`current/Plan W{N}...`): обновить статусы РП — grep по номеру РП, обновить ВСЕ упоминания.
**2b.** **Strategy_day (шаг 0в) → неприменимо, пропустить** (DayPlan не создавался). Иначе: DayPlan `current/DayPlan YYYY-MM-DD.md`: статусы ВСЕХ строк (РП + ad-hoc). Done → зачеркнуть.
**2c.** `docs/WP-REGISTRY.md`: статусы + даты.
**2d.** `inbox/open-sessions.log`: удалить строки закрытых сессий.
**2e.** Новые репо/сервисы за день? → REPOSITORY-REGISTRY, navigation.md, MAP.002.
**2f.** WeekReport — если есть `WeekReport W{N}.md`: добавить `<details><summary><b>Итоги {День} {Дата}</b></summary>` **перед** предыдущими итогами (обратная хронология).
<!-- Детали 2f: day-close-details.md § Шаг 2f -->

**EXTENSION POINT (checks):** `bash .claude/scripts/load-extensions.sh day-close checks` → exit 0: `Read` каждый файл → выполнить.

### 3. Архивация
- **Strategy_day (шаг 0в) → архивацию DayPlan сегодня пропустить** (не создавался — нечего архивировать). DayPlan'ы прошлых дней в `current/` (мусор) — заархивировать в любом случае.
- Иначе: DayPlan сегодня → `git mv current/DayPlan $(date +%Y-%m-%d).md archive/day-plans/`.
- Done WP context files → `mv inbox/WP-{N}-*.md → archive/wp-contexts/`
- Done РП → удалить строку из MEMORY.md. MEMORY.md хранит ТОЛЬКО активные РП.

### 4б. Memory Drift Scan
Grep MEMORY.md на паттерны «ждёт/блокер/blocked/остановлен». Для каждого: найти WP-context, проверить статус, обновить устаревшее. Анонс при 0 изменениях: *«Drift-scan: N паттернов, устаревших нет»*.
<!-- Детали: day-close-details.md § Шаг 4б -->

### 4в. Index Health Check
`python3 ${IWE_TEMPLATE:-{{HOME_DIR}}/IWE/FMT-exocortex-template}/.claude/scripts/check-index-health.py` — для каждого FAIL/WARN: диагностика (дамп vs жанр) → перенести или пометить skip.
<!-- Детали: day-close-details.md § Шаг 4в -->

### 4. Lesson Hygiene
Просмотреть «Уроки» в MEMORY.md. Не применялся >1 нед и есть в `lessons_*.md` → удалить. Новый урок → строка в MEMORY.md + `lessons_*.md`. Цель: ≤8 уроков.

### 5. Автоматические шаги
`"$IWE_SCRIPTS/day-close.sh"` — Linear sync, downstream sync (update.sh), backup (memory/ + CLAUDE.md).

### 6. Мультипликатор IWE
> Условный шаг: если `params.yaml → multiplier_enabled: false` → пропустить.

WakaTime CLI (`~/.wakatime/wakatime-cli --today`) или Neon-fallback → Бюджет ПО ФАКТУ / WakaTime = мультипликатор `N.Nx`. Prerequisite: прочитать `sessions/00-index.md` (grep сегодня) → список peer-сессий с числом ходов. Sanity check: <1.5x при ≥10 peer-сессий → пересчитать.
<!-- Детали: day-close-details.md § Шаг 6 -->

### 7. Черновик итогов (показать пользователю)
Обзор (РП × статус) + Что нового узнал + Похвала + Не забыто (dirty repos, /slot часы, мысли, обещания) + Видео + Draft-list + Задел на завтра + **Утренние приоритеты (priorities.yaml)**.
<!-- Детали: day-close-details.md § Шаг 7 -->

### 8. Согласование
Пользователь читает черновик → корректирует → одобряет.

### 9. Запись итогов
**9a.** **Strategy_day (шаг 0в) → неприменимо, пропустить целиком** (DayPlan не создавался — писать «Итоги дня» некуда, postcondition-grep недостижим по конструкции дня, не FAIL). Итоги стратегического дня идут только в 9b/WeekReport, как обычный день — только факты, плановые строки не копировать (day-close-details.md § strategy_day). Иначе: дописать «Итоги дня» в DayPlan (шаблон: `memory/templates-dayplan.md`). Валидация: «Завтра начать с» непустое + каждый pending РП с конкретным next action. Postcondition: bash-grep по паттерну `Итоги дня|Day summary` (оба языка — issue #234: при `language: english` заголовок DayPlan «Day summary», русский grep всегда FAIL) → `9a OK/FAIL`.

При архивации DayPlan (шаг 3) — frontmatter `status: active` → `status: closed`:
```bash
TODAY_DAYPLAN="${IWE_GOVERNANCE_REPO:-DS-strategy}/archive/day-plans/DayPlan $(date +%Y-%m-%d).md"
[ -f "$TODAY_DAYPLAN" ] && sed -i.bak 's/^status: active$/status: closed/' "$TODAY_DAYPLAN" && rm -f "$TODAY_DAYPLAN.bak"
```
Не путать с шагом 10c ниже (P1, WP-5 Ubuntu-audit): гард day-open-pipeline.sh проверяет присутствие архивного DayPlan в git, не это поле — `status: closed` служит только людям/сторонним инструментам, не текущей реализации гарда.
**9b.** Дописать сводку в WeekReport (`<details>`, обратная хронология). Fallback на WeekPlan если нет WeekReport. Postcondition: bash-grep по паттерну `Сводка|Results` (оба языка — issue #234) → `9b OK/FAIL`.
`*a/*b FAIL` → НЕ помечать completed, вернуться к записи.
<!-- Детали postconditions: day-close-details.md § Шаг 9 -->

### 10. Rule Classifier
`python3 $HOME/IWE/.claude/scripts/rule-classifier.py` (идемпотентно, kill если >60 сек). **ДО коммита** — иначе его правки уходят в незакоммиченный хвост (issue #249).

### 10b. Финальный коммит (все затронутые репозитории, не только governance)
`git status --short` по КАЖДОМУ репо, который сессия трогала за день — как минимум workspace root (`{{HOME_DIR}}/IWE/`, там физически лежат `MEMORY.md` и `memory/*.md`, их правят шаги 4б/4) и `${IWE_GOVERNANCE_REPO:-DS-strategy}` (WeekPlan/DayPlan/WP-REGISTRY). Незафиксированное → `git add <specific paths>` → commit → push. Переходить к шагу 11 только когда `git status` чист во всех репо.

### 10c. Heartbeat для Day Open guard
Пишется ПОСЛЕ push шага 10b — DayPlan уже реально закоммичен. day-open-pipeline.sh на следующий день читает этот файл как сигнал «Day Close сделан» (fallback — присутствие архивного DayPlan в git, симметрично day-open):
```bash
mkdir -p ~/.claude/state
jq -n \
  --arg date "$(date +%Y-%m-%d)" \
  --arg commit "$(git -C "${IWE_GOVERNANCE_REPO:-DS-strategy}" rev-parse HEAD)" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{date: $date, commit_hash: $commit, timestamp: $ts, status: "success"}' \
  > ~/.claude/state/day-close-last-success.json
```

### 11. Верификация (Haiku R23)
Sub-agent Haiku R23 (context isolation): передать чеклист + черновик итогов + список обновлённых файлов. По ❌ — исправить до показа пользователю.

**EXTENSION POINT (checks):** `bash .claude/scripts/load-extensions.sh day-close checks` → exit 0: `Read` каждый файл → выполнить.

---

## Чеклист Day Close

- [ ] Все изменения закоммичены и запушены (по всем репо)
- [ ] MEMORY.md: done-РП удалены, активные актуальны, drift-scan выполнен (шаг 4б)
- [ ] Index Health Check (шаг 4в): все FAIL/WARN разобраны или помечены skip
- [ ] WP-REGISTRY.md обновлён
- [ ] WeekPlan обновлён (grep по номерам РП — ВСЕ упоминания)
- [ ] DayPlan обновлён (статусы ВСЕХ строк: РП + ad-hoc) — **N/A на strategy_day** (шаг 0в)
- [ ] open-sessions.log: строки закрытых сессий удалены
- [ ] Captures за день применены (все Quick Close → KE пройден)
- [ ] Синхронизация downstream: `update.sh` выполнен
- [ ] Linear sync: статусы соответствуют git. Кол-во active РП в REGISTRY = active issues в Linear
- [ ] Repo CLAUDE.md: feat-коммиты → новые правила?
- [ ] DayPlan сегодня → `archive/day-plans/` (старые DayPlan'ы в `current/` тоже) — **DayPlan сегодня N/A на strategy_day** (шаг 0в), старые — архивировать в любом случае
- [ ] WP context: done → `mv inbox/ → archive/wp-contexts/`
- [ ] Lesson Hygiene: уроки MEMORY.md ≤8
- [ ] Draft-list: Pack обогащён → черновик предложен?
- [ ] Видео: обработанные помечены (если video.enabled)
- [ ] Governance: REPOSITORY-REGISTRY, navigation.md, MAP.002
- [ ] Backup: `day-close.sh` выполнен
- [ ] **Rule-engine FP-stats** (WP-272 Ф2.5): `python3 ~/IWE/.claude/scripts/fp-stats.py --date $(date +%Y-%m-%d)` → `⚠️ REVISE` → записать в «Завтра начать с»
- [ ] Верификация compliance: /verify запускался сегодня?
- [ ] WakaTime + Мультипликатор: часы / бюджет ПО ФАКТУ (sessions/00-index.md перечислен; ad-hoc оценены по ходам; сверхплановое — по факту); sanity check ≥10 peer-сессий
- [ ] Итоги дня записаны в DayPlan **(postcondition 9a: grep подтверждён)** — **N/A на strategy_day** (шаг 0в)
- [ ] Handoff-валидация: «Завтра начать с» содержит ВСЕ pending РП с конкретным next action — **N/A на strategy_day** (шаг 0в; на strategy_day это поле живёт в WeekPlan, не DayPlan)
- [ ] Сводка итогов записана в WeekReport (`<details>`, обратная хронология) **(postcondition 9b: grep подтверждён)**
- [ ] Новое репо → MAPSTRATEGIC.md + Strategy.md

Все ✅ → «День закрыт.» Иначе — указать что осталось.

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
