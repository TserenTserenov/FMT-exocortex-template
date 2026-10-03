---
name: strategy-session
description: Стратегическая сессия — диспетчер. День-0 (нет Strategy.md/WeekPlan) → initial flow (цели, неудовлетворённости, первый WeekPlan). Первая сессия календарного месяца → полный monthly flow (стратегическая сверка + линза калибра). Остальные дни → короткий weekly flow (требует черновик от session-prep). Триггеры — «проведём стратегическую сессию», «первая стратегическая сессия», «strategy session», «давай стратегировать».
version: 1.0.0
layer: L1
status: active
browser_safe: false
triggers:
  slash: [/strategy-session]
  phrases: []
routing:
  executor: opus
  deterministic: false
agents: single
interaction: multi-step
gates_required: []
gates_enforced: []
gates_rationale: "операционный скилл; WP Gate применим только при создании нового РП, не для операционных вызовов"
---

# Strategy Session — диспетчер

> Один skill, три режима. Выбор по факту наличия артефактов в `{{GOVERNANCE_REPO}}/` + календарной позиции сессии.

## When to use

Стратегическая сессия — диспетчер. День-0 (нет Strategy.md/WeekPlan) → initial flow (цели, неудовлетворённости, первый WeekPlan). Первая сессия календарного месяца → полный monthly flow (стратегическая сверка + линза калибра, ~45-60 мин). Остальные сессии → короткий weekly flow (требует черновик от session-prep, ~15-20 мин). Триггеры — «проведём стратегическую сессию», «первая стратегическая сессия», «strategy session», «давай стратегировать».

## Algorithm

### Шаг 0. Рабочая копия governance-репозитория (БЛОКИРУЮЩЕЕ, ДО расширений и любой записи)

> Если в установке есть `session-guard.sh` (канон под freeze), правка идёт только из изолированной копии и публикуется через `ds-publish.sh` (правило «Канон под freeze» в `{{GOVERNANCE_REPO}}/CLAUDE.md`). Если session-guard в установке нет, заморозка выключена (пустой `IWE_FROZEN_CANONICAL_PATH`) или у репозитория управления нет `origin` (установка без GitHub: `open --isolate` без `--base-sha` берёт основу командой `git fetch origin main`, а публиковать некуда), работай как раньше в найденной рабочей копии и сохраняй штатным способом. Это две явные ветки ниже, не молчаливый пропуск. ВСЕ пути записи строятся от `GOV_WT`, не от канона.

```bash
CANON="{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}"
GUARD="${IWE_SCRIPTS:-}/session-guard.sh"
[ -f "$GUARD" ] || GUARD="{{WORKSPACE_DIR}}/scripts/session-guard.sh"
[ -f "$GUARD" ] || GUARD="$CANON/scripts/session-guard.sh"
[ -f "$GUARD" ] && GUARD_MODE=required || GUARD_MODE=absent
CANON_C=$(cd -- "$CANON" 2>/dev/null && pwd -P) || { echo "ERROR: канон $CANON недоступен" >&2; exit 1; }
CANON_COMMON=$(git -C "$CANON_C" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
  || { echo "ERROR: $CANON_C не git-репозиторий" >&2; exit 1; }
if [ -f "$CANON_C/scripts/lib/governance-repo-path.sh" ]; then
  CAND=$(. "$CANON_C/scripts/lib/governance-repo-path.sh" && resolve_active_worktree) \
    || { echo "ERROR: resolve_active_worktree завершился с ошибкой" >&2; exit 1; }
else
  CAND=$(git rev-parse --show-toplevel 2>/dev/null) || CAND=""
fi
CAND_C=""; CAND_COMMON=""
if [ -n "$CAND" ]; then
  CAND_C=$(cd -- "$CAND" 2>/dev/null && pwd -P) || { echo "ERROR: не удалось нормализовать путь $CAND" >&2; exit 1; }
  CAND_COMMON=$(git -C "$CAND_C" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || CAND_COMMON=""
fi
# кандидат годится, только если его общий git-каталог совпадает с каноном (тот же governance-репозиторий)
if [ -n "$CAND_C" ] && [ "$CAND_COMMON" = "$CANON_COMMON" ]; then GOV_WT="$CAND_C"; else GOV_WT=""; fi
# изоляция нужна, только когда есть origin (обычно open --isolate берёт основу через git fetch origin main;
# офлайн можно указать проверенный локальный коммит через --base-sha) и заморозка не выключена
# (пустой IWE_FROZEN_CANONICAL_PATH выключает её и в самом session-guard.sh): иначе работа как раньше
GUARD_OFF=""
if [ "$GUARD_MODE" = required ]; then
  if [ "${IWE_FROZEN_CANONICAL_PATH+x}" = x ] && [ -z "$IWE_FROZEN_CANONICAL_PATH" ]; then
    GUARD_OFF="заморозка выключена: IWE_FROZEN_CANONICAL_PATH пуст"
  elif ! git -C "$CANON_C" remote get-url origin >/dev/null 2>&1; then
    GUARD_OFF="у репозитория управления нет origin: изоляции нечего получать (git fetch origin main) и публиковать некуда"
  fi
  [ -z "$GUARD_OFF" ] || GUARD_MODE=absent
fi
if [ "$GUARD_MODE" = required ]; then
  if [ -z "$GOV_WT" ] || [ "$GOV_WT" = "$CANON_C" ]; then
    echo "NOT ISOLATED: канон под freeze, запись запрещена. Открой копию: (cd -- \"$CANON_C\" && bash \"$GUARD\" open --isolate --wp <WP-N>), затем повтори этот шаг внутри копии: (cd -- \"<worktree_path>\" || exit 1; <блок шага 0>)" >&2
    LOCAL_BASE_SHA=$(git -C "$CANON_C" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)
    if [ -n "$LOCAL_BASE_SHA" ]; then
      echo "Если origin недоступен: проверь локальный коммит: git -C \"$CANON_C\" show -s --format='%H %s' \"$LOCAL_BASE_SHA\"" >&2
      echo "Затем добавь к команде открытия --base-sha $LOCAL_BASE_SHA; с этим флагом сеть не нужна. Локальная ревизия может отставать от origin." >&2
    fi
    exit 2
  fi
  echo "GOV_WT=$GOV_WT mode=isolated"
else
  [ -n "$GOV_WT" ] || GOV_WT="$CANON_C"
  echo "GOV_WT=$GOV_WT mode=legacy (${GUARD_OFF:-session-guard не найден: заморозки нет}, работа как раньше)"
fi
```

- Код выхода 0 -> **запиши абсолютный путь `GOV_WT` в свой ответ пользователю** (контекст сессии): независимые вызовы Bash не разделяют переменные, а `cd` в подоболочке каталог не меняет.
- Код выхода 2 (`NOT ISOLATED`) -> ничего не записывай. Открой копию из канона, возьми `worktree_path` из вывода `open --isolate` и повтори блок шага 0 внутри копии; `<CANON_C>` и `<GUARD>` — пути из сообщения `NOT ISOLATED`. Переход в каталог — только в подоболочке `( … )`: верхнеуровневый `cd` хук `destructive-guard.sh` блокирует.
  ```bash
  (cd -- "<CANON_C>" && bash "<GUARD>" open --isolate --wp <WP-N>)
  ```
  ```bash
  (cd -- "<worktree_path>" || exit 1
  <блок шага 0 без изменений>
  )
  ```
  Офлайн (нет сети, `git fetch origin main` не удаётся): проверь локальный коммит командой из шага 0 и используй готовую команду с `--base-sha`, которую напечатает `session-guard.sh`. Она создаёт копию от указанного коммита без обращения к `origin`. Пилот может отдельно решить выключить заморозку пустым `IWE_FROZEN_CANONICAL_PATH` и перейти в режим `legacy`.
  Не получилось -> сообщи пилоту и остановись (fail-closed), в канон не пиши. Код 1 -> ошибка резолвера или путей: покажи сообщение и остановись.
- КАЖДЫЙ последующий блок записи начинается с явного задания и проверки `GOV_WT` и выполняется в подоболочке внутри копии (git — `git -C "$GOV_WT" …`, файлы — абсолютные пути от `$GOV_WT`):
  ```bash
  GOV_WT="<записанный абсолютный путь>"; : "${GOV_WT:?}"
  (cd -- "$GOV_WT" || exit 1
  <команды записи>
  )
  ```
- Публикация в конце: `mode=isolated` -> коммит в `GOV_WT`, затем публикация из копии, в канон не коммить. Ветка назначения `main` задаётся явно (`--branch main`): `session-guard.sh open --isolate` создаёт копию от `origin/main` на её собственной ветке `session-isolate/<agent>-<session>`, которой на сервере нет. `--branch` получает только публикатор, который его знает: `update.sh` не заменяет уже лежащий `scripts/ds-publish.sh` (собственный публикатор установки или старая копия шаблона), и такой публикатор вызывается без `--branch`, как раньше. Знает или нет, функция `knows_branch` судит по тексту файла (эвристика): ветка разбора аргумента `--branch)` (также `-b|--branch)`, `--branch=*)`) в начале строки; комментарий, текст usage или `git status --branch` не в счёт. Ложный пропуск (обёртка, передающая `"$@"`) безопасен: публикатор вызывается как раньше; ложное срабатывание — нет, поэтому признак узкий. Публикатор берётся из копии; из канона — если в копии его нет (`update.sh` кладёт `scripts/ds-publish.sh` в канон без коммита, и копия от `origin/main` его не содержит) или если в копии он не знает `--branch`, а в каноне знает. Нет нигде -> ненулевой код и сообщение: запусти `update.sh`. Публикатор без `--branch` отказал -> предложи пилоту заменить `scripts/ds-publish.sh` в репозитории управления версией шаблона `seed/strategy/scripts/ds-publish.sh`. Публикатор переносит один коммит за вызов, поэтому блок публикует по очереди все коммиты копии, которых нет на `origin/main`, от старого к новому, и останавливается на первом отказе; уже опубликованный коммит публикатор пропускает, повтор блока безвреден. Коммит-слияние публикатор не переносит (код 2): блок остановится на первом таком коммите, так что «все коммиты» — это обычные коммиты. Незакоммиченные изменения в копии не публикуются: блок предупредит одной строкой «ВНИМАНИЕ…», код выхода от этого не меняется. Коммитов нет -> одна строка «Публиковать нечего», без сообщения о публикации; список коммитов не получен (ошибка git) -> код 1 и сообщение, не «Публиковать нечего».
  ```bash
  GOV_WT="<записанный абсолютный путь>"; : "${GOV_WT:?}"
  knows_branch() { grep -qE -e '^[[:space:]]*[(]?([^|)#[:space:]]+[[:space:]]*[|][[:space:]]*)*"?--branch(=[^|)[:space:]]*)?"?[[:space:]]*[|)]' "$1" 2>/dev/null; }
  PUB="$GOV_WT/scripts/ds-publish.sh"; CANON_PUB="{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/scripts/ds-publish.sh"
  if ! knows_branch "$PUB" && knows_branch "$CANON_PUB"; then PUB="$CANON_PUB"; fi
  [ -f "$PUB" ] || PUB="$CANON_PUB"
  [ -f "$PUB" ] || { echo "ERROR: публикатор ds-publish.sh не найден ни в копии, ни в каноне. Запусти update.sh (он доставляет публикатор) и повтори публикацию; коммиты остаются в копии $GOV_WT" >&2; exit 1; }
  git -C "$GOV_WT" rev-parse -q --verify origin/main >/dev/null || { echo "ERROR: в копии $GOV_WT нет origin/main, публикацию не с чем сравнить" >&2; exit 1; }
  COMMITS=$(git -C "$GOV_WT" rev-list --reverse origin/main..HEAD) || { echo "ERROR: не удалось получить список коммитов копии $GOV_WT" >&2; exit 1; }
  [ -z "$(git -C "$GOV_WT" status --porcelain)" ] || echo "ВНИМАНИЕ: в копии есть незакоммиченные изменения, они не опубликованы: закоммитьте их" >&2
  [ -n "$COMMITS" ] || { echo "Публиковать нечего: в копии нет коммитов, которых нет на origin/main"; exit 0; }
  for c in $(printf '%s\n' "$COMMITS"); do
    if knows_branch "$PUB"; then bash "$PUB" "$GOV_WT" normal --reason "strategy-session" --from-commit "$c" --branch main || exit $?
    else bash "$PUB" "$GOV_WT" normal --reason "strategy-session" --from-commit "$c" || exit $?; fi
  done
  ```
  `mode=legacy` -> сохраняй штатным способом установки (коммит и push своими средствами; если у репозитория нет `origin`, достаточно коммита); `ds-publish.sh` используй, только если он есть.

### Шаг 0.1. Extensions (before)
`GOV_WT="<записанный путь>" bash .claude/scripts/load-extensions.sh strategy-session before` -> Exit 0: Read каждый файл, выполнить; расширения работают с этим корнем `GOV_WT`. Exit 1: пропустить.

## Шаг 1. Определить режим

Проверь наличие любого из:

- `$GOV_WT/docs/Strategy.md`
- `$GOV_WT/current/WeekPlan W*.md`

Если хотя бы один есть — проверь ВТОРЫМ шагом, первая ли это Strategy Session календарного месяца. Записи двух легальных раскладок (issue #608, тот же корень, что #545 в day-open-scaffold.sh): плоские файлы Strategy/Day-сессий (`sessions/YYYY-MM-DD.md`) и подпапка по месяцу для peer-сессий (`sessions/YYYY-MM/`) — искать нужно по обоим адресам, иначе плоская раскладка (дефолт по `memory/routing-vocab.md`) всегда даёт «не найдено» и месячная сверка не срабатывает ни разу:
```bash
GOV_WT="<записанный путь>"; : "${GOV_WT:?}"
(cd -- "$GOV_WT" || exit 1
SESSIONS_DIR=$(source "{{WORKSPACE_DIR}}/scripts/lib/common.sh" 2>/dev/null && iwe_sessions_dir 2>/dev/null) || SESSIONS_DIR="$GOV_WT/sessions"
grep -rl "strategy-session\|Strategy Session" \
  "$SESSIONS_DIR/$(date +%Y-%m)-"*.md \
  "$SESSIONS_DIR/$(date +%Y-%m)/" 2>/dev/null
)
```
Первая сессия месяца = дата сессии ≤7 числа месяца И поиск выше пуст. Журнал сессий берётся из `iwe_sessions_dir` (общий журнал вне копии), при его отсутствии из `$GOV_WT/sessions`.

> **Найдено платформенным аудитом 17.08.2026:** до этого исправления диспетчер знал только про initial/weekly — monthly-вариант (`strategy-session-monthly.md`) был реализован, но ничем не вызывался, кроме редкой ручной эскалации из weekly-stop-gate. Результат — шаги, привязанные только к monthly (стратегическая сверка, линза калибра/lifework-пакет, разбор inbox), фактически никогда не запускались ни у одного пользователя. Этот шаг — фикс маршрутизации, не новая функциональность.
>
> **Известное ограничение (policy, не баг, peer-review с Codex 17.08.2026):** триггер идемпотентен относительно УСПЕШНОГО запуска (файл сессии записан в `sessions/`), но не относительно прерванного/aborted запуска до записи файла — следующая попытка в том же месяце снова увидит «нет записей» и снова пойдёт в monthly. Осознанный компромисс: at-least-once per month лучше, чем zero-times (баг, который этот фикс и устраняет). Ужесточение до exactly-once — отдельный РП при появлении живого сигнала, что дублирование monthly реально мешает.

| Состояние | Режим | Куда дальше |
|-----------|-------|-------------|
| Нет ни Strategy.md, ни WeekPlan | **initial** (день-0) | §2 этого файла |
| Есть Strategy.md и/или WeekPlan, и это первая сессия календарного месяца | **monthly** (полный вариант) | `roles/strategist/prompts/strategy-session-monthly.md` |
| Есть Strategy.md и/или WeekPlan со `status: draft`, не первая сессия месяца | **weekly** | `roles/strategist/prompts/strategy-session-weekly.md` |
| Есть Strategy.md, но нет draft WeekPlan | weekly без draft | сообщи пользователю: «нет черновика, запустить session-prep?» |

---

## Шаг 2. Initial flow (день-0)

> Цель: запустить пользователя со старта. Никакого session-prep, никакого ревью прошлой недели — их ещё нет.

Скажи пользователю:

> «Это первая стратегическая сессия. Пройдём 4 шага: цели → неудовлетворённости → первый WeekPlan → MEMORY.md.»

### 2.1. Цели (5 мин)

Спроси:
- «Кем хочешь быть через год?»
- «Чему хочешь научиться?»
- «Какие 2-3 крупные цели на ближайшие 3-6 месяцев?»

Запиши ответы в `$GOV_WT/docs/Strategy.md` по структуре:
- Видение (1 год)
- Цели на горизонт (3-6 месяцев)
- Принципы (что для меня важно)

### 2.2. Неудовлетворённости (5 мин)

Спроси:
- «Что сейчас мешает? Где разрыв между текущим и желаемым?»
- «Что регулярно раздражает или забирает энергию?»

Запиши в `$GOV_WT/docs/Dissatisfactions.md` списком: каждая неудовлетворённость = 1-2 строки.

### 2.3. Первый WeekPlan (10 мин)

На основе целей + неудовлетворённостей предложи 3-5 РП на ближайшую неделю. Для каждого:
- Название (существительное-артефакт)
- Бюджет (часы)
- Артефакт-критерий (что появится по завершении)

Запиши в `$GOV_WT/current/WeekPlan W{N}.md` (где N — номер ISO-недели).

### 2.4. Обновление MEMORY.md (2 мин)

В `~/.claude/projects/{{CLAUDE_PROJECT_SLUG}}/memory/MEMORY.md` добавь раздел «РП текущей недели» со списком из 2.3.

### 2.5. Закрытие initial-сессии

Скажи: «Готово. Завтра утром можешь сказать "открывай день" — Стратег соберёт DayPlan на сегодня. По понедельникам в 04:00 автоматически готовится session-prep для следующей сессии.»

**Extensions (after):** `bash .claude/scripts/load-extensions.sh strategy-session after` → Exit 0: Read каждый файл, выполнить. Exit 1: пропустить.

---

## БЛОКИРУЮЩЕЕ: один шаг за раз

> Нарушение этого правила делает сессию бессмысленной — пилот не вносит свои данные, решения принимаются без него.

**После выполнения ЛЮБОГО шага — СТОП.** Не читать следующий шаг, не продолжать. Ждать сообщения пилота. Следующий шаг — только после его ответа. Это правило действует даже после compaction, даже если gate = `auto`, даже если «очевидно что делать дальше».

---

## Шаг 3. Weekly flow

Если режим = weekly:

### 3.1 Обход Backlog (B-005, обязательно)

Прочитай `$GOV_WT/docs/Backlog.md`. Для каждой записи `B-NNN` в разделе `## Активные записи`:

- Проверь триггеры открытия (`Триггер открытия:` блок в записи).
- **Hard-trigger сработал?** (внешнее событие случилось — например, `первый user-deletion request получен`, `legal review запланирован на эту неделю`, `Honcho API timeout ≥48ч`) — поднять для обсуждения в стратегической повестке: «B-NNN активирован, открываем РП?»
- **Soft-trigger подошёл?** (дата/процессная веха, например `при открытии WP-XXX-v2`, `при следующей ревизии DP.D.NNN`) — упомянуть в обзоре повестки как кандидата на следующие 1-2 недели.
- Ни один не сработал → оставить как есть, отметить «B-NNN живой, триггеров нет».

Если есть `??` (неопределённый статус) или `Дата открытия:` старше 90 дней без движения — пометить как кандидата на архивацию (`## Архивные записи`) с явным решением пилота.

**Цель шага:** Backlog не должен превращаться в dead inventory. Каждый Strategy Session — явная сверка триггеров.

### 3.2 Распаковка R1: discovery (Стратег) → планирование (Плановик)

> **Роль R1 распакована (РП378):** Стратег ведёт WHAT/WHY (discovery неудовлетворённостей,
> состояние, приоритеты месяца), Плановик (DP.ROLE.066) — HOW MUCH/WHEN (упаковка в неделю,
> бюджеты, WIP, дни). Граница — по типу решения, не по артефакту.

**Режим discovery (Стратег, этапы 1-4 — НЭП → приоритеты).**
Если приоритеты месяца устарели ИЛИ состояние пилота изменилось ИЛИ это первый месяц —
сначала разговор-распаковка: запусти `/discovery-session` (метод DP.METHOD.053). На выходе —
state-card + 3 топ-неудовлетворённости + ранжированные приоритеты месяца + ТОС-месяца. Это
**контекст приоритетов**, передаётся в планирование.

**Режим планирования (Плановик, этапы 5-6 — упаковка недели/дня).**
Если приоритеты актуальны (discovery не нужен) — Плановик ведёт неделю один (совместный
ритуал DP.SC.051). Загрузи `{{IWE_TEMPLATE}}/roles/strategist/prompts/strategy-session-weekly.md`
(если файл отсутствует → выполни `bash update.sh` или создай вручную; продолжи по базовому
шаблону WeekPlan из этого SKILL.md)
и следуй ему: упакуй контекст приоритетов в WeekPlan с бюджетами, распредели по дням, держи
WIP-лимит (8-15).

**Связка:** discovery даёт контекст приоритетов → планирование его упаковывает. Стратег
подключается к недельному ритуалу только при триггере пересмотра; иначе — Плановик один.

**Extensions (after):** `bash .claude/scripts/load-extensions.sh strategy-session after` → Exit 0: Read каждый файл, выполнить. Exit 1: пропустить.

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
