---
name: day-close
description: "Протокол закрытия дня (Day Close). Алиас для /run-protocol close day — симметрия с /day-open."
argument-hint: ""
version: 1.1.0
layer: L1
status: active
browser_safe: false
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

Day Close = протокол. Блокирующее требование — наблюдаемое свойство: **ни один шаг не пропущен молча**; каждый шаг отмечается ДО перехода к следующему.
**Шаг 0 — ПЕРВОЕ действие:** зафиксировать список шагов прямо сейчас (до любых других действий) — в TodoWrite, а при его недоступности явной нумерацией в ответе.
Инструмент по умолчанию — TodoWrite: каждый шаг алгоритма → отдельная задача (pending → in_progress → completed). **TodoWrite недоступен** (штатная ситуация, зависит от сборки клиента) → сообщить пилоту одной строкой, вести шаги явной нумерацией («Шаг X из Y: <название> — выполнен»), факт замены зафиксировать в отчёте закрытия (issues #561, #563).
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
Две независимые проверки (issue #326 — лексическая одна пропускала расхождения статуса без триггерных слов):
1. **Структурная:** `T="${IWE_TEMPLATE:-{{HOME_DIR}}/IWE/FMT-exocortex-template}"; PY3="$(bash "$T/.claude/lib/find-python3.sh")" && "$PY3" "$T/.claude/scripts/memory-drift-scan.py"` — сверяет колонку «Статус» MEMORY.md с полем `status` WP-context по номеру РП. Exit 1 → для каждой найденной строки обновить устаревшее.
2. **Лексическая:** Grep MEMORY.md на паттерны «ждёт/блокер/blocked/остановлен» (ловит текстовые блокеры без изменения статуса — отдельный класс, скрипт п.1 их не видит). Для каждого: найти WP-context, проверить статус, обновить устаревшее.
Анонс при 0 расхождений по обеим проверкам: *«Drift-scan: N паттернов + M структурных, устаревших нет»*.
<!-- Детали: day-close-details.md § Шаг 4б -->

### 4в. Index Health Check
`T="${IWE_TEMPLATE:-{{HOME_DIR}}/IWE/FMT-exocortex-template}"; PY3="$(bash "$T/.claude/lib/find-python3.sh")" && "$PY3" "$T/.claude/scripts/check-index-health.py"` — для каждого FAIL/WARN: диагностика (дамп vs жанр) → перенести или пометить skip.
<!-- Детали: day-close-details.md § Шаг 4в -->

### 4. Lesson Hygiene
Просмотреть «Уроки» в MEMORY.md. Не применялся >1 нед и есть в `lessons_*.md` → удалить. Новый урок → строка в MEMORY.md + `lessons_*.md`. Цель: ≤8 уроков.

### 5. Автоматические шаги
`"$IWE_SCRIPTS/day-close.sh"` — Linear sync, downstream sync (update.sh), backup (memory/ + CLAUDE.md).

### 6. Мультипликатор IWE
> Условный шаг: если `params.yaml → multiplier_enabled: false` → пропустить и
> при записи итогов выбрать только ветку `multiplier:off` из шаблона. Не добавлять
> WakaTime, физическое время, формулу или заглушку «мультипликатор не посчитан».

WakaTime CLI (`~/.wakatime/wakatime-cli --today`) или Neon-fallback → Бюджет ПО ФАКТУ / WakaTime = мультипликатор `N.Nx`. Prerequisite: прочитать `sessions/00-index.md` (grep сегодня) → список peer-сессий с числом ходов. Sanity check: <1.5x при ≥10 peer-сессий → пересчитать.
<!-- Детали: day-close-details.md § Шаг 6 -->

### 7. Черновик итогов (показать пользователю)
Обзор (РП × статус) + Что нового узнал + Похвала + Не забыто (dirty repos, /slot часы, мысли, обещания) + Видео + Draft-list + Задел на завтра + **Утренние приоритеты (priorities.yaml)**.
<!-- Детали: day-close-details.md § Шаг 7 -->

### 8. Согласование
Пользователь читает черновик → корректирует → одобряет.

### 9. Запись итогов
**9a.** **Strategy_day (шаг 0в) → неприменимо, пропустить целиком** (DayPlan не создавался — писать «Итоги дня» некуда, postcondition-grep недостижим по конструкции дня, не FAIL). Итоги стратегического дня идут только в 9b/WeekReport, как обычный день — только факты, плановые строки не копировать (day-close-details.md § strategy_day). Иначе: дописать «Итоги дня» в DayPlan (шаблон: `memory/templates-dayplan.md`, ветка по `multiplier_enabled`). Валидация: «Завтра начать с» непустое + каждый pending РП с конкретным next action. Postcondition: bash-grep по паттерну `Итоги дня|Day summary` (оба языка — issue #234: при `language: english` заголовок DayPlan «Day summary», русский grep всегда FAIL) → `9a OK/FAIL`.

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
`SCRIPT="$HOME/IWE/.claude/scripts/rule-classifier.py"; [ -f "$SCRIPT" ] && python3 "$SCRIPT" || echo "skip: rule-classifier.py требует ручной установки (claude CLI + PACK-agent-rules)"` (идемпотентно, kill если >60 сек). **ДО коммита** — иначе его правки уходят в незакоммиченный хвост (issue #249).

### 10a. Extensions (after)
`bash .claude/scripts/load-extensions.sh day-close after` → exit 0: `Read` каждый файл из вывода (alphabetic) → выполнить. Exit 1 → пропустить. Поддерживает `extensions/day-close.after.md` И `extensions/day-close.after.<suffix>.md`. Симметрично week-close (шаг 9): вызывается ДО финального коммита (10b), чтобы правки расширений попадали в тот же коммит, не оставались незакоммиченным хвостом (issue #320/#322).

### 10b. Финальный коммит (все затронутые репозитории, не только governance)
`git status --short` по КАЖДОМУ репо, который сессия трогала за день — как минимум workspace root (`{{HOME_DIR}}/IWE/`, там физически лежат `MEMORY.md` и `memory/*.md`, их правят шаги 4б/4) и `${IWE_GOVERNANCE_REPO:-DS-strategy}` (WeekPlan/DayPlan/WP-REGISTRY). Незафиксированное (включая правки шага 10a) стадировать и коммитить только одной fail-closed командой ниже: ненулевой код = СТОП, отдельный `git commit` после него запрещён. Переходить к шагу 11 только когда `git status` чист во всех репо.

<!-- issue-511-guard:start -->
```bash
assert_staged_scope_or_stop() {
  if [ "$#" -lt 2 ]; then
    echo "STOP: assert_staged_scope_or_stop requires <repo> <path>..." >&2
    return 74
  fi
  local repo="$1"
  shift
  # Variable names deliberately avoid zsh special parameters: `path` shadows
  # PATH (git stops resolving) and `status` is read-only in zsh (#557); the
  # agent sources these functions in the pilot's login shell, not bash.
  local staged_status staged_path staged_path_after allowed_path commit_path normalized_path display_path
  while IFS= read -r -d '' staged_status; do
    IFS= read -r -d '' staged_path || {
      echo "STOP: staged index status could not be parsed" >&2
      return 76
    }
    staged_path_after=""
    case "$staged_status" in
      R*|C*)
        IFS= read -r -d '' staged_path_after || {
          echo "STOP: staged rename/copy status could not be parsed" >&2
          return 76
        }
        ;;
    esac
    allowed_path=false
    for commit_path in "$@"; do
      normalized_path="${commit_path#./}"
      if [ "$staged_path" = "$normalized_path" ] || \
         [ "$staged_path_after" = "$normalized_path" ]; then
        allowed_path=true
        break
      fi
    done
    if ! $allowed_path; then
      display_path="$staged_path"
      [ -n "$staged_path_after" ] && display_path="$staged_path -> $staged_path_after"
      echo "STOP: staged path is outside the explicit commit scope: $display_path" >&2
      return 75
    fi
  done < <(git -C "$repo" diff --cached --name-status -z -M)
}

stage_and_commit_or_stop() {
  if [ "$#" -lt 3 ]; then
    echo "STOP: usage: stage_and_commit_or_stop <repo> <message> <path>..." >&2
    return 63
  fi
  local repo="$1" message="$2"
  shift 2
  if [ "$#" -eq 0 ]; then
    echo "STOP: no explicit paths supplied for commit" >&2
    return 64
  fi

  local commit_path normalized_path tracked_descendant
  for commit_path in "$@"; do
    case "$commit_path" in
      .|./|-A|--all|-u|--update)
        echo "STOP: broad git-add path/options are forbidden: $commit_path" >&2
        return 65
        ;;
    esac
    if [ -d "$repo/$commit_path" ]; then
      echo "STOP: explicit commit scope requires files, not a directory: $commit_path" >&2
      return 65
    fi
    normalized_path="${commit_path#./}"
    normalized_path="${normalized_path%/}"
    tracked_descendant=""
    while IFS= read -r -d '' tracked_descendant; do
      break
    done < <(git -C "$repo" ls-files -z -- "$normalized_path/")
    if [ -n "$tracked_descendant" ]; then
      echo "STOP: explicit commit scope resolves to tracked descendants, not one file: $commit_path" >&2
      return 65
    fi
    local path_status=""
    if ! path_status=$(git -C "$repo" status --porcelain=v1 --untracked-files=all -- "$commit_path"); then
      echo "STOP: path status could not be inspected: $commit_path" >&2
      return 66
    fi
    if [ -z "$path_status" ]; then
      echo "STOP: explicit path has no pending or staged change: $commit_path" >&2
      return 67
    fi
  done

  # A shared repository can already contain another agent's staged work.
  # Refuse it before mutating the index; `git commit -m` commits the whole
  # index, not only the pathspec later passed to `git add`.
  assert_staged_scope_or_stop "$repo" "$@" || return $?

  if ! git -C "$repo" add -- "$@"; then
    echo "STOP: git add failed; commit was not attempted" >&2
    return 68
  fi
  for commit_path in "$@"; do
    if git -C "$repo" diff --cached --quiet --exit-code -- "$commit_path"; then
      echo "STOP: explicit path has no staged content: $commit_path" >&2
      return 69
    else
      local path_diff_rc=$?
      if [ "$path_diff_rc" -ne 1 ]; then
        echo "STOP: staged content could not be inspected for: $commit_path" >&2
        return 70
      fi
    fi
  done
  if git -C "$repo" diff --cached --quiet --exit-code; then
    echo "STOP: staged diff is empty" >&2
    return 71
  else
    local diff_rc=$?
    if [ "$diff_rc" -ne 1 ]; then
      echo "STOP: staged diff could not be inspected" >&2
      return 72
    fi
  fi
  if ! git -C "$repo" commit -m "$message"; then
    echo "STOP: git commit failed" >&2
    return 73
  fi
}
```
<!-- issue-511-guard:end -->

> **Двойной сторож коммита (#511, дважды воспроизведённый класс «git mv + правка → пустой/устаревший дифф»):** механизм 21.08 доказан — `git mv` уже положил rename в индекс, правка нового пути осталась только в worktree, `git add` старого пути упал, но отдельный commit проигнорировал ошибку и зафиксировал прежний staged rename. Функция выше устраняет именно этот путь: commit недостижим после failed add. Механизм 18.08 по имеющейся фактуре всё ещё не установлен, поэтому issue остаётся открытым.
> 1. ПЕРЕД commit: функция сначала запрещает staged-пути вне явного списка, затем сама проверяет код `git add`, непустой общий staged diff и непустой staged-контент каждого явно переданного пути (`git diff --cached -- <path>`). `git add -- <явные пути>` после этой проверки не может добавить чужой путь; повторная проверка по именам после add дала бы ложный отказ для rename, который Git переклассифицировал в delete+add после изменения содержимого. Не повторять commit вручную после отказа функции.
> 1a. **После `git mv` в этом же ходе передавать ТОЛЬКО новый (текущий) путь файла** — старый путь больше не существует на диске, `git add` по нему падает (код 68) и коммит корректно останавливается. Для staged-rename проверка области видимости сверяет обе стороны переименования и принимает новый путь (issue #557, замечание к архивации DayPlan).
> 2. ПОСЛЕ commit: сверить, что правки реально в HEAD — `git show HEAD --stat` содержит перемещённый файл, и `git diff HEAD -- <файл>` пуст (на диске нет незакоммиченных остатков правок).
> 3. Любое срабатывание → СТОП + собрать диагностику в отчёт дня: `git status`, `git diff`, `git log -1 --stat`, точная последовательность выполненных команд — и сообщить пилоту. Индекс намеренно не сбрасывать автоматически: там может быть доказательство инцидента или ранее сделанный `git mv`. После диагностики исправить список путей и повторить единую функцию. Это материал для установления корня #511.

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
- [ ] **Синхронизация рабочих копий (поручение пилота 21.08):** все машины/копии установки ↔ GitHub синхронизированы, за исключением работающих сейчас сессий. Проверка: `git status -sb` в governance-репо (без ahead/behind) + статус sync-скрипта вторичных копий (если настроен, напр. `tsekh1-git-sync.sh --status`). «Deferred из-за живого семафора» — норма для реально работающей сессии; протухший семафор при запушенном отчёте — аномалия: закрыть семафор до завершения Day Close.
- [ ] Linear sync: статусы соответствуют git. Кол-во active РП в REGISTRY = active issues в Linear
- [ ] Repo CLAUDE.md: feat-коммиты → новые правила?
- [ ] DayPlan сегодня → `archive/day-plans/` (старые DayPlan'ы в `current/` тоже) — **DayPlan сегодня N/A на strategy_day** (шаг 0в), старые — архивировать в любом случае
- [ ] WP context: done → `mv inbox/ → archive/wp-contexts/`
- [ ] Lesson Hygiene: уроки MEMORY.md ≤8
- [ ] Draft-list: Pack обогащён → черновик предложен?
- [ ] Видео: обработанные помечены (если video.enabled)
- [ ] Governance: REPOSITORY-REGISTRY, navigation.md, MAP.002
- [ ] Backup: `day-close.sh` выполнен
- [ ] **Rule-engine FP-stats** (WP-272 Ф2.5): `[ -f ~/IWE/.claude/scripts/fp-stats.py ] && python3 ~/IWE/.claude/scripts/fp-stats.py --date $(date +%Y-%m-%d) || echo "skip: fp-stats.py требует rule-classifier.py"` → если есть `⚠️ REVISE` → **спросить пилота по факту флага** (WP-545 Ф5, 21.08 — заменяет прежний еженедельный R8-вопрос, который спрашивал вслепую по расписанию, не по конкретному сигналу): «правило `<X>` — это ложные срабатывания детектора, или реальный, но неудобный сигнал?» Ответ → в «Завтра начать с» вместе с решением (переформулировать правило / оставить как есть)
- [ ] Верификация compliance: /verify запускался сегодня?
- [ ] WakaTime + Мультипликатор: часы / бюджет ПО ФАКТУ (sessions/00-index.md перечислен; ad-hoc оценены по ходам; сверхплановое — по факту); sanity check ≥10 peer-сессий
- [ ] Итоги дня записаны в DayPlan **(postcondition 9a: grep подтверждён)** — **N/A на strategy_day** (шаг 0в)
- [ ] Handoff-валидация: «Завтра начать с» содержит ВСЕ pending РП с конкретным next action — **N/A на strategy_day** (шаг 0в; на strategy_day это поле живёт в WeekPlan, не DayPlan)
- [ ] Сводка итогов записана в WeekReport (`<details>`, обратная хронология) **(postcondition 9b: grep подтверждён)**
- [ ] Новое репо → MAPSTRATEGIC.md + Strategy.md

Все ✅ → «День закрыт.» Иначе — указать что осталось.

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
