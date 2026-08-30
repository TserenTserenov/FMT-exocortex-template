---
name: peer-conversation
description: Многотуровый диалог писателя (Claude) с одним или несколькими напарниками (любой набор из kimi/codex/hermes/claude-headless) по задаче пилота (DP.SC.154). Ведёт turn-loop (2 участника) или round-loop (3+, WP-509), обнаруживает CONSENSUS/ESCALATE, после консенсуса — Decision Gate (зафиксировать vs реализовать → ревью → проверить → задеплоить), синтезирует report.md через Agent tool.
argument-hint: "<описание задачи> [--peer kimi|codex|hermes|claude[,vendor2,...]] | --list | --interrupt <session_id> | --finalize <session_id>"
version: 1.5.5
layer: L1
status: active
triggers:
  slash: [/peer-conversation]
  phrases: ["начни peer-сессию", "запусти диалог с Кими", "запусти диалог с Codex", "peer-сессия"]
routing:
  executor: sonnet
  deterministic: false
agents: single
interaction: multi-step
gates_required: []
gates_enforced: []
gates_rationale: "операционный скилл; WP Gate применим только при создании нового РП, не для операционных вызовов"
---

# Peer Conversation (DP.SC.154)

Задача: $ARGUMENTS

> **Архитектура:** я (Claude) = писатель всегда (Skill tool доступен только мне в этой сессии). Напарник(и) — параметр `--peer` (default `kimi`), список из одного или нескольких зарегистрированных вендоров (§0в). При 2+ напарниках (N>2 участников целиком) — расширение WP-509, см. §0в и §3р.
> Каждый напарник вызывается через свой `<vendor>-peer-adapter.sh` напрямую — Bash tool, stdin pipe. Контракт одинаковый у всех: stdin = промпт, stdout = реплика, exit 0-5 (см. §0в). **Напарнику запрещено писать файлы своими инструментами внутри `SESSION_DIR`** — только stdout (гонка file-write vs stdout-capture портит журнал, найдено WP-509 2026-07-30).
> `list_peer_statuses` (Local Gateway) — координация файлов, **не** проверка доступности напарника CLI.
> Gateway offline ≠ напарник недоступен.

---

## When to use

Многотуровый диалог писателя (Claude) с одним или несколькими напарниками (любой набор зарегистрированных вендоров — Kimi, Codex, Hermes, второй Claude-инстанс headless) по задаче пилота (DP.SC.154). При одном напарнике — turn-loop (пара реплик). При двух и более напарниках — round-loop (WP-509): каждый раунд высказывается каждый участник, с явной role-discovery фазой (раунды 0–2), валидацией реплик по 4 критериям, лимитом повторных вызовов и классификацией результата `agreed|partial|escalated|not-agreed`. Обнаруживает CONSENSUS/ESCALATE, после консенсуса — Decision Gate (зафиксировать vs реализовать → ревью → проверить → задеплоить), синтезирует report.md через Agent tool.

## Scope boundary — не подменяет решения, зарезервированные за пилотом (найдено 2026-07-07)

> Peer-сессия пригодна для: технических решений, дизайна, code review, поиска компромисса между подходами, подготовки кандидатов к решению.
> **НЕ пригодна** для решений, которые процесс явно закрепляет за человеком (например, R15 Валидатор в `/apply-captures` — accept/reject/defer кандидатов знания; R1 Стратег — приоритеты месяца). Согласие двух агентов между собой — не решение пилота, даже единогласное и хорошо обоснованное.
>
> Если задача внутри пир-сессии требует такого решения — писатель обязан остановиться и спросить пилота напрямую в текущем чате (не через turn-файл), прежде чем фиксировать результат. См. `.claude/skills/apply-captures/SKILL.md` раздел «R15 = живой пилот, не агент» и `${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/bugs/bug-2026-07-07-r15-decisions-bypassed-pilot.md` — прецедент, из-за которого добавлено это ограничение.

## Шаг 0. Режим

Определить режим из `$ARGUMENTS`:

- `--list` → прочитать `${IWE_GOVERNANCE_REPO:-DS-strategy}/sessions/00-index.md`, вывести таблицу. Файла нет → явно сообщить «индекс сессий ещё не создан (его создаст первая пир-сессия, шаг 1.3); прошлые сессии смотри в дереве sessions/YYYY-MM/DD/» — не молчать (issue #568). Стоп.
- `--interrupt <id>` → перейти к **Шагу 5 (interrupt-режим)**. Стоп после.
- `--finalize <id>` → перейти к **Шагу 6 (finalize-режим)**. Стоп после.
- Иначе → новая сессия, продолжать к Шагу 0в.

---

## Шаг 0в. Выбор напарника(ов) (`--peer`)

> **Добавлено 2026-07-29** (АрхГейт: вариант «параметризовать» против «отдельный скилл на вендора» — эволюционируемость заблокировала копипаст, см. `sessions/2026-07/2026-07-29-*-wp401-peer-vendor.md`). **Расширено 2026-07-30 (WP-509):** список из N>1 напарников вместо одного.

Извлечь `--peer <vendor1,vendor2,...>` из `$ARGUMENTS` (через запятую, без пробелов). Нет флага → `PEER_VENDORS=(kimi)` (обратная совместимость с версией до 1.4.0). Один vendor без запятой → `PEER_VENDORS=(<vendor>)`, поведение идентично версии 1.4.0 — отдельного code path для одного напарника не заводить, `PEER_COUNT=${#PEER_VENDORS[@]}` управляет веткой (turn loop §3 при `PEER_COUNT==1`, round loop §3р при `PEER_COUNT>=2`).

**Реестр вендоров** (единственное место маппинга — OwnerIntegrity; новый вендор добавляется только здесь):

| `PEER_VENDOR` | Адаптер | `peer_agent` (meta.yaml) | Поддерживает `--add-dir` | Поддерживает `--model` | Особый флаг |
|---|---|---|---|---|---|
| `kimi` | `scripts/kimi-peer-adapter.sh` | `kimi-headless` | да | да | — |
| `codex` | `scripts/codex-peer-adapter.sh` | `codex` | да | да | — |
| `hermes` | `scripts/hermes-peer-adapter.sh` | `hermes` | **нет** | **нет** | `--session-id <id>` вместо |
| `claude` | `scripts/claude-peer-adapter.sh` | `claude-code-headless` | **нет** | да | text-only; контекст в stdin |

Каждый элемент `PEER_VENDORS` валидировать отдельно. Неизвестный `PEER_VENDOR` в списке → СТОП **на этом элементе, не на всём списке**: сообщить пилоту, какой конкретно vendor не распознан («Напарник `<vendor>` не зарегистрирован. Известные: kimi, codex, hermes, claude.»), предложить продолжить с оставшимися распознанными или прервать целиком. Добавление нового вендора — правка таблицы выше + написание `<vendor>-peer-adapter.sh` по контракту §0в.1.

**§0в.1 Общий контракт адаптера** (для добавления нового вендора): stdin = полный промпт хода (Bash pipe, не inline `echo` — inline попадает в командную строку и хук B7.7c может ложно заблокировать повторные вызовы); stdout = одна реплика с frontmatter; exit `0` = OK, `1` = general error, `2` = content-filter/PII violation, `3` = PII hard block, `5` = уже идёт сессия (pidfile lock). Для `claude` действует усиленный контракт WP-458: `--add-dir` запрещён, peer получает только минимальную текстовую проекцию в stdin и не имеет файловых или shell-инструментов. Коды 2-5 — не обязательны для нового адаптера, но `0`/`1` обязательны (Шаг 3.1/3р.1 проверяет `exit ≠ 0` как «напарник не ответил»).

Построить для каждого `vendor` в `PEER_VENDORS`: `ADAPTER_PATH[$vendor]="$HOME/IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/<адаптер из таблицы>"` и `PEER_AGENT_ID[$vendor]="<peer_agent из таблицы>"` (bash associative arrays; порядок вызова = порядок `PEER_VENDORS`). Используются везде ниже вместо хардкода `kimi-peer-adapter.sh`/`kimi-headless`.

**§0в.2 Проверка доступности vendor'ов (capability-check, WP-509 Ф5).** После построения `ADAPTER_PATH`, до анонса напарников:

1. **Дубликаты** в списке (`--peer codex,codex`) → отклонить: N участников не подменяется повторными вызовами одного напарника; сообщить пилоту, стоп до исправления списка.
2. **Проверка каждого `vendor`** (накопить доступных в `remaining`):
   ```bash
   remaining=()
   for vendor in "${PEER_VENDORS[@]}"; do
     ok=true
     if [[ ! -x "${ADAPTER_PATH[$vendor]}" ]]; then ok=false; fi  # адаптер отсутствует/не исполняем
     if [[ "$vendor" == hermes ]] && ! command -v hermes >/dev/null 2>&1; then ok=false; fi  # CLI hermes недоступен
     $ok && remaining+=("$vendor") || :  # недоступный — кандидат на исключение (п. 3)
   done
   ```
   Живой probe-вызов CLI НЕ делать: ошибки всплывут при вызове по контракту адаптера (exit ≠ 0, Шаг 3.1/3р.1); vendor-specific знания сверх `hermes` в скилл не добавлять (иначе Шаг 0в расходится с адаптерами).
3. **Недоступный vendor** → сообщить пилоту какой именно и почему (нет адаптера / нет CLI), предложить продолжить с оставшимися или прервать — тот же UX, что для незарегистрированного vendor (стоп на элементе, не на списке).
4. **Нормализация после исключений (атомарно):**
   ```bash
   PEER_VENDORS=("${remaining[@]}")
   PEER_COUNT=${#PEER_VENDORS[@]}
   round_order=("${PEER_VENDORS[@]}")
   ```
   Режим выбирается заново: `PEER_COUNT>=2` → round-loop (§3р), `==1` → turn-loop (§3 — сценарий «запрошены codex,hermes, остался codex» идёт классическим диалогом вдвоём, не усечённым кругом), `==0` → безусловный стоп с сообщением пилоту.

Анонсировать пилоту:
```
Напарник: <PEER_VENDOR> (<peer_agent>)                    # PEER_COUNT == 1, как раньше
```
или при `PEER_COUNT >= 2`:
```
Напарники (<PEER_COUNT>):
  1. kimi (kimi-headless)
  2. codex (codex)
```

---

## Шаг 0б. Открытие (WP Gate — только для новой сессии)

Найти WP по задаче: прочитать `${IWE_GOVERNANCE_REPO:-DS-strategy}/WP-REGISTRY.md` (grep по ключевым словам) и `${IWE_GOVERNANCE_REPO:-DS-strategy}/current/WeekPlan W{N}.md`.

Анонс пилоту:
```
Открываю peer-сессию (DP.SC.154)
Роль: Писатель (Claude) | Напарник(и): <PEER_VENDOR (PEER_AGENT_ID)>[, ...]
Задача: <задача>
РП: WP-NNN «<название>» | или: не найден в плане
Метод: turn-loop ≤10 ходов (PEER_COUNT==1) | round-loop ≤rounds_limit раундов (PEER_COUNT>=2, WP-509)
```

Если РП **не найден** в плане недели → полный WP Gate Ритуал (`memory/protocol-open.md §Сессия`):
объявить артефакт + дождаться подтверждения пилота → **только после «да» переходить к Шагу 1**.

Если РП найден → продолжать без ожидания.

**Определение рекомендуемой модели писателя (WP-394 Ф4.6):**
```
# informational — pilot selects model at Claude Code startup, not auto-applied here
verification_class = из WP контекста или из описания задачи
WRITER_MODEL_RECOMMENDED = "sonnet"   # default: закрытые задачи с тестами/чёткой проверкой
if verification_class in ("open-loop", "problem-framing"):
    WRITER_MODEL_RECOMMENDED = "opus"
```
Анонсировать пилоту:
```
Модель писателя (рекомендуется): <WRITER_MODEL_RECOMMENDED>
(Класс задачи: <verification_class>. Выбери модель при запуске Claude Code.)
```

**Подсказка маршрутизации агента (WP-383, информационная — не enforcement).**
По классу работы есть рекомендуемый инициатор/агент. Это подсказка пилоту, не блокировка:

| Класс работы | Рекомендуемый агент |
|--------------|---------------------|
| Уборка / форматирование / триаж | Kimi (дёшево, быстро) |
| Верификация shallow (формат/чеклист/drift) | Kimi |
| Верификация deep (cross-file invariant) | Claude (statefulness) |
| Реализация multi-file / tight-loop | Claude (держит состояние сессии) |
| Дизайн / scope / планирование | сильная модель (Claude/Opus или Kimi) |

**Trigger эскалации (лог, не блок):** если пилот 2 раза подряд выбирает агента вопреки подсказке — записать сигнал «routing-таблица устарела или классификация неверна» в `inbox/WP-383/routing-drift.log` (создать при первом срабатывании). Не блокировать выбор пилота.

> Источник таблицы: `${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/WP-383/routing-design-v1.md §3`. Statefulness-пробел Kimi закрыт автопередачей git-diff в `kimi-peer-adapter.sh` (§8).

---

## Шаг 1. Инициализация

```bash
SESSIONS_DIR="$HOME/IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/sessions"
TODAY=$(date +%Y-%m-%d)
MONTH=$(date +%Y-%m)
DAY=$(date +%d)
DAY_DIR="$SESSIONS_DIR/$MONTH/$DAY"
mkdir -p "$DAY_DIR"
NUM=$(printf "%02d" $(( $(find "$DAY_DIR" -maxdepth 1 -type d -name "${TODAY}-[0-9][0-9]-*" 2>/dev/null | wc -l | tr -d ' ') + 1 )))
```

Slug = первые 4 латинских слова из задачи строчными буквами через дефис (не-латиница и дата убираются). Никакой даты в slug — она уже в SESSION_ID. Если латиницы нет → `session`.

`SESSION_ID="${TODAY}-${NUM}-${SLUG}"`
`SESSION_DIR="${DAY_DIR}/${SESSION_ID}"`

**1.0 Session-guard open (WP-398, обязательно, ДО любых Write/Edit в сессии).** Синхронизирует пир-сессию с `session-guard.sh` Scope gate — без этого коммит на Шаге 4.5 будет заблокирован pre-commit хуком (mtime файлов сессии старше семафора). WP берётся из Шага 0б (найденный или «day-close»/«unknown», если РП не назначен):

```bash
IWE_AGENT=claude-code bash "${IWE_SCRIPTS:-$HOME/IWE/scripts}/session-guard.sh" open \
  --wp "<WP-NNN из Шага 0б>" --agent claude-code --close-path peer-session \
  --task "<задача одной строкой>" --slug "$SESSION_ID"
```

> **Не хардкодить `~/IWE/scripts/session-guard.sh`.** Пир-сессия 2026-07-31-16-wp484-new-order-cutover сначала внесла такой хардкод по образцу `day-close/SKILL.md`, но холодный ревью нашёл: у обычного пользователя шаблона `setup.sh` НЕ копирует корневую `scripts/` — существует только каталог скриптов внутри шаблона, и `${IWE_SCRIPTS:-...}` резолвится именно туда намеренно (issue #266, commit `835d5ea` — тот же хардкод уже один раз чинили этим фоллбэком). Хардкод в `day-close/SKILL.md` — недокументированный долг, ждущий той же поломки при промоции, не образец для копирования. Для author-mode расхождение реальное (FMT-копия `session-guard.sh` отстаёт от корневой на фиксы WP-484 Нить1) — но лечится синком `template-sync.sh` (с отдельного разрешения пилота, S-33) или личной правкой `~/.iwe-paths`, не хардкодом в файле, который промотируется всем пользователям шаблона.

Если команда упала (exit ≠ 0) — не блокировать сессию: сообщить пилоту одной строкой «session-guard open не сработал (<причина>), продолжаю без семафора — на Шаге 4.5 возможна ручная разблокировка через touch/note-file» и идти дальше. Semaphore-файл session-guard создаёт СВОЙ ORZ-скаффолд-заготовку по пути `sessions/<MONTH>/<TODAY>-<CLEAN_SLUG>.md` — тот же путь, что закрывающий файл пир-сессии из Шага 4.4/4.5.0 (до 2026-08-03 эти два места ошибочно считали разные пути, см. пометку на Шаге 4.4); Шаг 4.5.0 дописывает в этот же файл финальное содержимое, а не создаёт новый.

**1.1 Создать папку:**
```bash
mkdir -p "$SESSION_DIR"
```

**1.2 Записать `meta.yaml`** (Write):
```yaml
task_id: ""
date: "<TODAY>"
session_id: "<SESSION_ID>"
start_time: "<ISO-8601 UTC>"
end_time: ""
writer_agent: "claude-code"
personality: "<unassigned|UUID>"   # WP-510 Патч 4, слой 3: writer_agent = конструктивная реализация; personality = какая ИИ-личность (если есть авторитетная запись в `current/AI Personalities Registry.md` для текущего хоста/раннера) вела сессию. Ищи по хосту/раннеру в реестре — не выдумывай; нет однозначного совпадения → "unassigned". Маршрутизирующая метка, не допуск к памяти.
peer_agent: "<первый PEER_AGENT_ID из §0в>"      # backward-compat (PEER_COUNT==1: единственный); полный список — peer_agents
peer_cmd: "<первый PEER_VENDOR>-peer-adapter"     # backward-compat; полный список — peer_cmds
peer_agents: ["<PEER_AGENT_ID>", "..."]   # WP-509: в порядке PEER_VENDORS, длина 1 при PEER_COUNT==1 (дублирует peer_agent); §4.2 читает ТОЛЬКО это поле для report.md peer: при PEER_COUNT>=2
peer_cmds: ["<vendor>-peer-adapter", "..."]   # WP-509: та же длина/порядок, что peer_agents
round_order: ["<vendor>", "..."]   # WP-509: фиксированный порядок раунда (= PEER_VENDORS), только при PEER_COUNT>=2
write_token_holder: "writer_agent"   # WP-509: держатель write token сейчас; default = writer_agent, меняется только через подтверждённый ACCEPT_HANDOFF (см. §3р.3)
peer_model: ""
status: "started"
turns_count: 0
turns_limit: 10        # PEER_COUNT==1: лимит реплик, без изменений с v4
rounds_limit: 6         # WP-509: лимит раундов, применяется только при PEER_COUNT>=2, НЕ переопределяет turns_limit
round_skips: {}        # WP-509: {round_NN: [vendor, ...]} — кто не ответил/пропустил раунд; исключаются из требования "консенсус у каждого" в §3р.3
participant_status: {}  # WP-509: {vendor: active|failed} — финальный статус участника после исчерпания попыток
max_peer_attempts: 2    # WP-509: лимит повторных вызовов одного peer подряд
peer_attempts: {}     # WP-509: {vendor: N} — счётчик вызовов в текущем раунде
peer_failures: []      # WP-509: [{round, vendor, reason}] — зафиксированные отказы участников
handoff_history: []    # WP-509: [{round, from, to, reason}] — журнал OFFER_HANDOFF/ACCEPT_HANDOFF (write token, DP.SC.154 «Write token ≠ process_position»)
escalations_count: 0
extensions: []
result_path: ""
task_description: "<задача>"
implementation_pipeline: false
review_iterations: 0
verify_status: ""
deploy_shas: {}
writer_model_recommended: "sonnet"  # informational — pilot selects model at startup, not auto-applied; opus only for open-loop|problem-framing
# Sequential role-discovery (WP-367) — заполняется во время Opening:
# Если пилот задал явно — сразу заполни `roles`.
# Если не задал — initiator в ход 0 заполняет `proposed_roles` в frontmatter 00-writer.md;
#                  после согласования (ход 2) переноси в `roles`.
roles: {}            # финальное: {agent_id: [DP.ROLE.NNN, ...]} после consensus
discovery_turns: 0   # сколько ходов ушло на role-discovery (не считается в turns_limit)
# Двухосная модель (WP-367 Ф5, DP.SC.154 v4):
ad_hoc_roles: {}     # {role_name: {agent_id, rationale, first_used_turn}} — для каскада audit
swap_history: []     # [{turn, from, to, reason}] — журнал SWAP_WRITER переходов
```

**Если пилот не назначил роли** при запуске сессии — initiator в ход/раунд 0 предлагает свою роль и роль **каждого** напарника (см. DP.SC.154 раздел «Opening сессии: Sequential role-discovery», при `PEER_COUNT>=2` — раздел «Role-discovery для N>2»). Discovery-ходы/раунды (0-2) **не входят** в `turns_limit`/`rounds_limit`.

**In-session ad-hoc role signal** (DP.SC.154 v4, каскад Pack-расширения уровень 1). При использовании ad-hoc роли (нет в Pack `DP.ROLE.NNN`/`MIM.R.NNN`/`VR.R.NNN`) агент **обязан сразу** объявить пилоту — формат:

```
Беру ad-hoc роль «<имя>». В каталоге Pack такой нет.
Обязанности: <одной строкой>. Метод: <одной строкой>.
Предлагаю создать РП на формализацию (~30 мин: passport + scenarios + templates).
Выбери:
  А. Создать сейчас → отдельный РП «pack-gap-<имя>» через create-wp.sh.
  Б. Отложить → продолжу как ad-hoc, сторож напомнит при Week Close.
```

Запись в `meta.yaml.ad_hoc_roles` идёт независимо от выбора (для back-up на уровне 2 — Week Close audit). Если пилот выбрал А — после сессии писатель открывает отдельный РП и делает формализацию.

**1.3 Добавить строку в `sessions/00-index.md`** сверху таблицы (первая строка таблицы после `|---|`). Колонка «Агенты» — при `PEER_COUNT>=2` напарники соединяются через `+`:

> **Файла нет — создать его сейчас** (issue #568: установка индекс не создаёт, и до этой правки шаг молча не исполнялся — восемь сессий подряд без единой записи). Временная мера до РП-526 (семейство MC переведёт индекс на snapshot-механику — при миграции этот блок удалить). Создаваемый файл обязан честно объявлять свою неполноту прямо в себе (не в stdout — вывод теряется, а файл читают через недели):
> ```bash
> IDX="${IWE_GOVERNANCE_REPO:-DS-strategy}/sessions/00-index.md"
> if [ ! -f "$IDX" ]; then
>   mkdir -p "$(dirname "$IDX")"
>   {
>     echo "# Индекс пир-сессий"
>     echo ""
>     echo "<!-- index regenerated on $(date +%Y-%m-%d): created empty by peer-conversation step 1.3 (issue #568) — sessions before this date exist on disk but are NOT backfilled here; the folder tree sessions/YYYY-MM/DD/ is the authoritative record -->"
>     echo ""
>     echo "| Дата | Сессия | Задача | Агенты | Ходы | Эскалации | Статус | Отчёт |"
>     echo "|------|--------|--------|--------|------|-----------|--------|-------|"
>   } > "$IDX"
> fi
> ```

```
| <TODAY> | <SESSION_ID> | <задача ≤50 симв> | claude-code / <PEER_VENDOR1>[+<PEER_VENDOR2>...] | 0 | 0 | started | — |
```

---

## Шаг 2. Реплика писателя 00-writer.md

Записать `${SESSION_DIR}/00-writer.md` (Write):

```markdown
---
turn: 0
role: writer
agent_id: claude-code
timestamp: <ISO-8601 UTC>
consensus: none
---

<Моя начальная позиция — анализ задачи, тезисы, конкретные вопросы к напарнику(ам).
При `PEER_COUNT>=2` — предложить содержательную роль каждому напарнику отдельно (не только «роль для группы»), с обоснованием на каждого (DP.SC.154 «Role-discovery для N>2»).
НЕ пересказ задачи. Позиция с аргументами.>
```

Показать пилоту краткое резюме: что написал в 00-writer.md.

---

## Шаг 2.5. Role-discovery для N>2 (PEER_COUNT >= 2, WP-509)

> **Пропустить, если PEER_COUNT == 1.** Для двух участников discovery сводится к предложению ролей в 00-writer.md и согласованию в turn-loop.

После 00-writer.md запустить **раунды 0–2**, которые **не входят** в `rounds_limit`.

### 2.5.1 Раунд 0 — писатель предлагает роли

В 00-writer.md (Шаг 2) писатель уже предлагает содержательную роль каждому напарнику. Дополнительно записать в frontmatter `00-writer.md`:
```yaml
proposed_roles: { "<PEER_AGENT_ID>": "<role_name>", ... }
suggested_initiator_role: "<role_name>"
```

### 2.5.2 Раунд 1 — каждый peer подтверждает или спорит роль

Вызвать каждого напарника по порядку `round_order` с промптом, аналогичным §3р.1, но с единственной задачей:
- прочитать 00-writer.md;
- согласиться с предложенной ролью, предложить правку или запросить уточнение у пилота;
- явно подтвердить, что понимает ограничение «ответ только в stdout, никаких файловых операций в SESSION_DIR».

Формат реплики:
```yaml
---
turn: 0
role: peer
agent_id: <PEER_AGENT_ID>
content_role: <согласованная/предложенная роль>
process_position: peer
timestamp: <ISO-8601 UTC>
consensus: none
role_accepted: true | false | clarify
---

<Обоснование принятия роли или запрос уточнения>
```

Если `role_accepted: clarify` — писатель уточняет у пилота и повторяет раунд 1 только для этого участника (не считается отдельным раундом discovery).

### 2.5.3 Раунд 2 — фиксация agreed_roles

Писатель записывает `01-writer.md` (turn: 0, role: writer) с итоговой таблицей ролей:
```yaml
---
turn: 0
role: writer
agent_id: claude-code
consensus: none
agreed_roles: { "<PEER_AGENT_ID>": "<role_name>", ... }
writer_role: "<role_name>"
discovery_turns: 1   # сколько дополнительных проходов раунда 1 потребовалось
---
```

Обновить `meta.yaml`:
```yaml
roles: { "claude-code": ["<writer_role>"], "<PEER_AGENT_ID>": ["<role_name>"], ... }
discovery_turns: <N>
```

Только после этого переходить к **Шагу 3р (ROUND=1)** с содержательными раундами.

---

## Шаг 3. Turn loop (PEER_COUNT == 1)

> **При `PEER_COUNT >= 2` — пропустить этот шаг целиком, перейти к Шагу 3р (round loop, WP-509).** Этот шаг не менялся с версии 1.4.0 — один напарник, поведение идентично.

Переменные: `TURN=1`, `ESCALATIONS=0`, `DONE=false`.

### 3.1 Вызов напарника

Прочитать все предыдущие реплики из `SESSION_DIR` в порядке нумерации.
Составить промпт:

```
Ты — напарник (peer agent) в диалоговой сессии (DP.SC.154).
Сессия: <SESSION_ID>
Ход: <TURN> из 10
Задача: <задача>

Контекстная проекция ниже — единственный источник о сессии. Не читай файлы и не используй инструменты:
<минимальная текстовая проекция предыдущих реплик и проверяемых фактов>

Напиши реплику в stdout с frontmatter:
---
turn: <TURN>
role: peer
agent_id: <PEER_AGENT_ID>
timestamp: <ISO-8601 UTC>
consensus: none | proposed | reached | escalate
---

<Твой ответ>

Правило критика: найди ХОТЯ БЫ ОДИН тезис или допущение писателя, с которым не согласен. Не сдавайся после первого возражения — держись аргументированно. Если всё действительно ОК — объясни почему конкретно, не просто «согласен».

Маркеры (строго в начале строки):
CONSENSUS: <резюме> — если считаешь что договорились
ESCALATE_TO_USER: <причина> — если писатель игнорирует существенное возражение
```

Вызов напарника через Bash — флаги зависят от вендора (таблица §0в):

```bash
PEER_FILE="${SESSION_DIR}/$(printf '%02d' $TURN)-peer.md"
if [ "$PEER_VENDOR" = "hermes" ]; then
  # hermes-peer-adapter.sh не принимает --add-dir/--model — свой --session-id.
  # НЕ путать с $SESSION_ID пир-сессии: адаптер всегда шлёт переданный --session-id
  # как `--resume <id>` в hermes CLI — на самом первом вызове этой пир-сессии
  # у Hermes ещё не существует диалога с ID пир-сессии (это два разных
  # пространства идентификаторов), `hermes chat --resume <несуществующий>`
  # падает молча (set -euo pipefail в адаптере гасит его же диагностику до того,
  # как она успевает напечататься) — найдено живьём 2026-07-31/08-01, WP-484/WP-509.
  # Родной session_id Hermes читаем С ДИСКА (последний уже записанный NN-peer.md),
  # не из shell-переменной — агент делает каждый вызов отдельным Bash-тулом, и
  # переменные не переживают границу между вызовами (найдено code review 01.08).
  HERMES_LAST_ID=$(grep -h "^session_id: " "${SESSION_DIR}"/[0-9][0-9]-peer.md 2>/dev/null | tail -1 | sed 's/^session_id: //')
  if [ -z "$HERMES_LAST_ID" ]; then
    echo "<промпт>" | bash "$ADAPTER_PATH" > "$PEER_FILE" 2>/dev/null
  else
    echo "<промпт>" | bash "$ADAPTER_PATH" --session-id "$HERMES_LAST_ID" > "$PEER_FILE" 2>/dev/null
  fi
else
  printf '%s\n' "<промпт с минимальной текстовой проекцией>" | bash "$ADAPTER_PATH" \
    > "$PEER_FILE" 2> "${PEER_FILE%.md}.err"
fi
```

Если файл пустой или exit ≠ 0 → сообщить пилоту: «<PEER_VENDOR> не ответил. Повторить или прервать?»

### 3.2 Показать пилоту

Прочитать `$PEER_FILE`. Вывести ключевые тезисы напарника (не всю реплику дословно — краткое резюме + цитаты ключевых позиций).

### 3.3 Проверить маркеры

**ESCALATE_TO_USER:**
Если `grep -q "^ESCALATE_TO_USER:" "$PEER_FILE"`:
- Извлечь причину: `grep "^ESCALATE_TO_USER:" "$PEER_FILE" | sed 's/^ESCALATE_TO_USER: //'`
- `ESCALATIONS += 1`
- Записать `${SESSION_DIR}/escalation-$(printf '%02d' $((ESCALATIONS-1))).md`:

```markdown
---
escalation_number: <N>
turn: <TURN>
timestamp: <now>
reason: "<причина>"
pilot_response: ""
---

# Эскалация <N> (ход <TURN>)

**Причина:** <причина>
**Реплика напарника:** <PEER_FILE>
**Ответ пилота:** (ввести ниже)
```

- Сообщить пилоту: «<PEER_VENDOR> эскалирует: <причина>. Нужно твоё решение.»
- Дождаться ответа пилота, записать в `pilot_response` в escalation-файл.
- Обновить `meta.yaml`: `escalations_count: <ESCALATIONS>` (Bash sed).

**CONSENSUS:**
Если `grep -q "^CONSENSUS:" "$PEER_FILE"`:
- Извлечь резюме.
- `DONE=true`, перейти к **Шагу 3.5 (Decision Gate)** — НЕ к Шагу 4 напрямую.

### 3.4 Реплика писателя

Если `TURN >= 10` → `DONE=true`, перейти к Шагу 4.

Написать `$(printf '%02d' $((TURN+1)))-writer.md` (Write):
```markdown
---
turn: <TURN+1>
role: writer
agent_id: claude-code
timestamp: <now>
consensus: none
---

<Моя реплика: ответ на аргументы напарника + учёт направления пилота>
```

`TURN += 1` → вернуться к 3.1.

---

## Шаг 3р. Round loop (PEER_COUNT >= 2, WP-509)

> **Пропустить, если `PEER_COUNT == 1`** — там действует классический Шаг 3.

Переменные: `ROUND=1`, `ESCALATIONS=0`, `DONE=false`. Порядок раунда = `PEER_VENDORS` в порядке `--peer` (записан в `meta.yaml.round_order` на Шаге 1.2).

### 3р.1 Вызов каждого напарника по порядку раунда

`WRITE_TOKEN_HOLDER` — читать из `meta.yaml.write_token_holder` (default, записанный на Шаге 1.2, = `writer_agent`: писатель держит write token, пока не было ни одного `ACCEPT_HANDOFF`). Значение передаётся в промпт явно — напарники не обязаны сами читать `meta.yaml` в поисках держателя.

Для `vendor` в `round_order` (по очереди, не параллельно — каждый следующий видит реплики предыдущих этого же раунда) составить промпт:

```
Ты — напарник (peer agent) в диалоговой сессии (DP.SC.154, N>2 участников).
Сессия: <SESSION_ID>
Раунд: <ROUND> из <rounds_limit>
Задача: <задача>
Текущий держатель write token: <WRITE_TOKEN_HOLDER>

Для Claude: передай в его stdin минимальную текстовую проекцию всех нужных реплик и фактов этого раунда. Он не читает журнал сессии и не использует инструменты. Для остальных напарников применяй их собственный контракт.

ВАЖНО: ответ только в stdout. Не используй свои файловые инструменты ни для одного
файла в этой папке — это создаёт гонку с перехватом stdout и портит журнал сессии.

Напиши реплику в stdout с frontmatter:
---
turn: <ROUND>
role: peer
agent_id: <PEER_AGENT_ID>
content_role: <согласованная роль или предложение, если ещё не согласована>
process_position: peer
timestamp: <ISO-8601 UTC>
consensus: none | proposed | reached | escalate
---

<Твой ответ>

Правило критика: найди ХОТЯ БЫ ОДИН тезис, с которым не согласен — свой или другого напарника.

Маркеры (строго в начале строки):
PASS — если нечего добавить в этом раунде (не ошибка, явное право промолчать)
CONSENSUS: <резюме> — если согласен с итогом
ESCALATE_TO_USER: <причина> — если есть проигнорированное существенное возражение
OFFER_HANDOFF: <agent_id> — <причина> — если хочешь предложить свой write token другому (только если ты сейчас держатель)
ACCEPT_HANDOFF — если принимаешь предложенный тебе OFFER_HANDOFF
REQUEST_HANDOFF: <причина> — необязывающая просьба к держателю
```

Вызов напарника через Bash (промпт — во временный файл, не inline `echo` — тот же B7.7c-риск, что в §0в.1):

```bash
PEER_FILE="${SESSION_DIR}/$(printf '%02d' $ROUND)-peer-${vendor}.md"
PROMPT_FILE=$(mktemp)
# записать промпт (см. шаблон выше) в $PROMPT_FILE
if [ "$vendor" = "hermes" ]; then
  # Тот же контракт и та же ловушка, что в Шаге 3.1 (turn-loop) — hermes не берёт
  # --add-dir, и переданный --session-id всегда трактуется как --resume. Родной
  # hermes session_id читаем С ДИСКА (последний уже записанный NN-peer-hermes.md),
  # не из shell-переменной — агент делает каждый вызов отдельным Bash-тулом, и
  # переменные не переживают границу между вызовами (найдено code review 01.08).
  HERMES_LAST_ID=$(grep -h "^session_id: " "${SESSION_DIR}"/[0-9][0-9]-peer-hermes.md 2>/dev/null | tail -1 | sed 's/^session_id: //')
  if [ -z "$HERMES_LAST_ID" ]; then
    cat "$PROMPT_FILE" | bash "${ADAPTER_PATH[$vendor]}" > "$PEER_FILE" 2>/dev/null
    STATUS=$?
  else
    cat "$PROMPT_FILE" | bash "${ADAPTER_PATH[$vendor]}" --session-id "$HERMES_LAST_ID" > "$PEER_FILE" 2>/dev/null
    STATUS=$?
  fi
else
  if [ "$vendor" = "claude" ]; then
    cat "$PROMPT_FILE" | bash "${ADAPTER_PATH[$vendor]}" > "$PEER_FILE" 2> "${PEER_FILE%.md}.err"
  else
    cat "$PROMPT_FILE" | bash "${ADAPTER_PATH[$vendor]}" --add-dir "$SESSION_DIR" > "$PEER_FILE" 2>/dev/null
  fi
  STATUS=$?
fi
rm -f "$PROMPT_FILE"
```

**3р.1а Валидация реплики (WP-509)**

Применить **перед** записью в `round_skips` или консенсус. Реплика считается `valid`, если все 4 проверки прошли (с исключением для discovery-раундов, см. ниже):

1. **По предмету:** файл не пуст, frontmatter распарсен, тело содержит ответ на задачу раунда (не только формальные фразы / повтор условия).
2. **Роль исполнена:**
   - В **discovery-раундах 0–2** (`PEER_COUNT >= 2`): `content_role` совпадает с ролью, предложенной в `00-writer.md.proposed_roles` для этого `agent_id`, либо peer явно предлагает другую ad-hoc роль с обоснованием.
   - В **содержательных раундах** (`ROUND >= 1` после §2.5.3): `content_role` совпадает с ролью, согласованной в `meta.yaml.roles` для этого `agent_id`; если в реплике предлагается ad-hoc роль — см. §1.2 «In-session ad-hoc role signal».
3. **Нет побочных действий:** в stdout-ответе нет маркеров вида `FILE_WRITTEN`, `MEMORY_UPDATED`, `TOOL_CALLED` и т.п.; кроме того, **не проверять файловую систему напрямую** — адаптер гарантирует изоляцию, но агент-участник может декларировать действия в тексте.
4. **Непротиворечивость фактам:** если реплика ссылается на конкретный факт (SHA, имя файла, статус РП, commit), проверить его по доступным источникам; при несовпадении — `failed` с причиной `fact_mismatch`.

Если реплика `invalid`:
- Инкремент `meta.yaml.peer_attempts[vendor]`.
- Если `peer_attempts[vendor] < max_peer_attempts` — повторить вызов этого же peer в том же раунде с уточняющим промптом (причина invalid + контекст раунда).
- Если `peer_attempts[vendor] >= max_peer_attempts` — зафиксировать `meta.yaml.peer_failures += [{round: ROUND, vendor: vendor, reason: <проверка>}]`, установить `meta.yaml.participant_status[vendor] = "failed"`, исключить vendor из требования консенсуса в §3р.3 (как `round_skips`, но с явным статусом `failed`).

Пустой файл или `STATUS != 0` → этот напарник пропущен в этом раунде (не блокирует раунд, DP.SC.154 «Раунды вместо бесконечного круга»): записать `meta.yaml.round_skips.round_<NN>: [..., vendor]`, инкремент `peer_attempts[vendor]`; при исчерпании попыток — `participant_status[vendor] = "failed"` и `peer_failures += [...]`.

### 3р.2 Показать пилоту

Резюме по КАЖДОМУ напарнику раунда (не только последнему) — кто что сказал, кратко.

### 3р.3 Проверить маркеры у всех реплик раунда

Применяется к репликам напарников этого раунда (3р.1) **и**, при возврате из 3р.4, к реплике писателя того же раунда — обработка маркеров одинаковая для обеих ролей, разница только в том, что писатель пишет последним в раунде.

- `ESCALATE_TO_USER` у любого участника (включая писателя) → тот же процесс, что в §3.3 (запись `escalation-NN.md`, пауза на ответ пилота).
- `OFFER_HANDOFF`/`ACCEPT_HANDOFF`/`REQUEST_HANDOFF` у любого участника → при подтверждённом `ACCEPT_HANDOFF` (реплика-адресат отвечает на `OFFER_HANDOFF` предыдущей реплики) — append `{round, from, to, reason}` в `meta.yaml.handoff_history` И обновить `meta.yaml.write_token_holder` на нового держателя. `REQUEST_HANDOFF` без ответного `OFFER_HANDOFF` держателя — не меняет ничего, просьба зафиксирована в реплике и всё.
- `CONSENSUS` — «консенсус раунда»: учитываются только участники со статусом `active` (не `round_skips` этого раунда и не `participant_status == failed`). `DONE=true`, если у каждого активного участника есть либо `CONSENSUS`, либо `PASS` без встречных возражений в теле реплики. Хотя бы один содержательный контраргумент без `CONSENSUS` у активного участника → раунд не закрыт.
  - Если все активные участники поставили `CONSENSUS`/`PASS` → `result_class` для report.md = `agreed`.
  - Если консенсус достигнут среди активных, но один или несколько участников имеют `participant_status == failed` (исчерпаны попытки в этом или предыдущих раундах) → `DONE=true`, но `result_class` = `partial`; отказавшиеся участники и причины фиксируются в `report.md §5`.
  - Если ни один участник не имеет `CONSENSUS`/`PASS`, но все технически ответили — раунд не закрыт, продолжаем (или `ROUND >= rounds_limit` → §3р.5).

### 3р.4 Реплика писателя

Если 3р.3 уже установил `DONE=true` по репликам напарников этого раунда → писатель реплику в этом раунде не пишет, сразу к Шагу 3.5 (Decision Gate).

Иначе — писатель отвечает (`$(printf '%02d' $ROUND)-writer.md`, тот же формат frontmatter, что в Шаге 2, плюс те же маркеры `CONSENSUS`/`ESCALATE_TO_USER`/`OFFER_HANDOFF`/`ACCEPT_HANDOFF`/`REQUEST_HANDOFF`, что и у напарников — писатель тоже может держать или передавать write token). Применить к этой реплике проверку маркеров из 3р.3.

Если после этого `DONE=true` (писатель сам поставил `CONSENSUS`, приняв позицию раунда) → Шаг 3.5.

Иначе, если `ROUND >= rounds_limit` (default 6) → к 3р.5 (спор без консенсуса).

Иначе — `ROUND += 1` → 3р.1.

### 3р.5 Спор между 3+ позициями (после исчерпания rounds_limit без консенсуса)

> Учитывать `participant_status`: участники со статусом `failed` не голосуют и не блокируют принятие решения оставшимися.

Применить критерий обратимости (DP.SC.154 «Разрешение спора между 3+ позициями») **до** эскалации:
- Решение обратимо и в пределах полномочий **активных** участников → писатель фиксирует позицию большинства среди `active` (2 из 3 или большинство при N>3), несогласие меньшинства — в `report.md` §3 «Отвергнутые альтернативы`, `DONE=true`, `result_class` = `partial` если есть `failed`-участники, иначе `agreed` → Шаг 3.5.
- Решение необратимо, вне полномочий, ИЛИ сам вопрос обратимости спорен → `ESCALATE_TO_USER: rounds_limit exhausted, no consensus, irreversible or scope-disputed` → пауза на пилота.

---

## Шаг 3.5. Decision Gate (после консенсуса)

> **Когда срабатывает:** `DONE=true` через CONSENSUS-маркер в Шаге 3.3 (турн-loop) или 3р.3 (round-loop) — не через `TURN >= 10`/`ROUND >= rounds_limit` без консенсуса, там сразу Шаг 3р.5 или Шаг 4.
> **Зачем:** консенсус ≠ реализация. Это **легитимный choice-question** для пилота (выбор объёма работы, не yes/no на готовое решение). Исключение из P5 — пилот сам подтвердил: «здесь от меня нужно согласование» (триггер 2026-05-30, WP-367 Ф5).
> **Обязательно:** перед запросом — **краткое резюме консенсуса на пальцах**, чтобы пилот мог осознанно выбрать. Запрос без резюме = механический «выберите А/Б» без понимания.

Извлечь резюме консенсуса: `PEER_COUNT==1` → `grep "^CONSENSUS:" "$PEER_FILE" | sed 's/^CONSENSUS: //'`. `PEER_COUNT>=2` → пройти все `${SESSION_DIR}/$(printf '%02d' $ROUND)-peer-*.md` последнего раунда, взять резюме первого файла с маркером `CONSENSUS:` (если формулировки разошлись — писатель сводит их одним предложением сам, не берёт произвольно один голос).

**Резюме на пальцах** — обязательная часть. Формат (без технических терминов, кодов, путей):

```
Консенсус достигнут.

Что обсуждалось: <одной фразой>
К чему пришли: <2-3 строки человеческим языком — суть решения>
Что предлагается реализовать: <список изменений, по 1 строке каждое; без файлов, путей>
Сколько займёт реализация: ~<N>h (включая ревью + smoke + deploy)
Изменения у других пользователей: <если есть — что и как доставляется; если нет — «только локально»>
```

После резюме — choice question:

```
Что дальше?
  А. Только зафиксировать → Шаг 4 (report.md + commit + close).
     Реализация — отдельный РП/фаза при следующей сессии.
  Б. Реализовать сейчас → ревью → проверить → задеплоить → Шаг 4.
```

Дождаться ответа пилота. Записать выбор в `meta.yaml` (Bash sed):
```yaml
implementation_pipeline: false | true
```

- **А** → `IMPLEMENTATION=false`, перейти к Шагу 4.
- **Б** → `IMPLEMENTATION=true`, перейти к Шагу 3.6.

**Default при молчании пилота:** Б (реализация сейчас), per правило 11 «финиш > отлог». Применять только если пилот явно не ответил в течение разумного времени (например, пропустил Decision Gate в скрипте).

**Triggers automatic-defer** (без запроса пилоту — сразу А):
1. Реализация требует нового РП (новый scope, не покрытый текущим РП).
2. Требуется ArchGate (новое архитектурное решение системного уровня).
3. Контекст полностью переключился (другая часть системы; нужен новый framing).

При срабатывании trigger — анонс пилоту с резюме (НЕ запрос), потом Шаг 4.

---

## Шаг 3.6. Implementation Pipeline (опциональный)

> **Активируется:** только при `IMPLEMENTATION=true` в Шаге 3.5.
> **Принцип:** writer применяет решение → cold-context Agent делает code review → writer фиксит → built-in `/verify` запускает smoke → deploy → секция «Реализация и проверка» в report-draft.md.
> **Завершение:** в любой подшаг можно эскалировать к пилоту через `ESCALATE_TO_USER:` маркер (как в Шаге 3.3) — записать `escalation-NN.md`, дождаться ответа.

### 3.6.1 Implementation

Анонс пилоту:
```
Реализация консенсуса <SESSION_ID>
Файлы: <list of files with absolute paths>
Репо: <repo names, separated by " · ">
Метод: Edit/Write tools напрямую
```

Writer применяет изменения через Edit/Write. Запрещено:
- Менять файлы вне анонсированного списка без нового анонса.
- Делать commit на этом этапе (commit — только Шаг 3.6.5).

Зафиксировать список изменённых файлов в переменной `CHANGED_FILES` (один путь на строку).

### 3.6.2 Code Review (cold-context)

Переменные итерации: `REVIEW_ITER=1` при первом входе в 3.6.2, инкрементируется в 3.6.3 при Critical.

Сохранять отчёт в `${SESSION_DIR}/review-$(printf '%02d' $REVIEW_ITER).md` (Write).

Вызвать `Agent` (subagent_type: general-purpose) с явным чек-листом:

```
Agent(
  description: "Code review post-consensus",
  subagent_type: "general-purpose",
  prompt: """
    Cold-context code review результатов peer-сессии <SESSION_ID>.

    Контекст консенсуса: <резюме из 3.5>
    Изменённые файлы:
    <CHANGED_FILES>

    Прочитай каждый файл (только указанные строки/функции, не весь файл если он большой).
    Проверь по чек-листу:
    1. asyncio runtime: ищи `wait_for(coro)` без `shield` → coroutine reuse. Ищи fire-and-forget tasks которые читают/пишут одну строку БД из разных мест.
    2. Shell ordering: function call ДО function definition. `set -u` соблюдён?
    3. SQL race: cross-file writers в одну строку без атомарности (UPDATE ... RETURNING или SELECT FOR UPDATE).
    4. Lock enforcing: при collision — `exit N` или `log WARN && continue`? Если advisory — это intentional или баг?
    5. Контекст-специфика консенсуса: <дополни из резюме, если есть инварианты>.

    Верни отчёт в формате:
    ## Critical (must fix before deploy)
    - <file:line-range>: <issue> | fix: <conkr>
    ## High
    - ...
    ## Medium
    - ...
    ## OK (что проверено и норм)
    - ...

    Не предлагай рефакторинг или стиль — только runtime баги и нарушения чек-листа.
  """
)
```

Сохранить отчёт ревьюера в `${SESSION_DIR}/review-NN.md` где `NN = printf '%02d' $REVIEW_ITER` (Write).

### 3.6.3 Review Outcome

Показать пилоту краткое резюме отчёта (Critical + High count + один пример).

**Если есть Critical:**
- Применить фиксы (Edit) → инкремент `REVIEW_ITER += 1` → вернуться к 3.6.2 (новый review-NN.md).
- Лимит итераций: 3. Если на 3-й итерации остался Critical → ESCALATE_TO_USER с приложением последнего review.

**Если только High/Medium:**
- Спросить пилота: «Есть N High и M Medium замечаний. Фиксить сейчас или после deploy?»
- Записать решение в meta.yaml (`review_iterations: <N>`, `unresolved: <count>`).

**Если только OK:**
- Продолжить к 3.6.4.

### 3.6.4 Smoke Verification

Вызвать built-in `/verify` через Skill tool:

```
Skill(
  skill: "verify",
  args: "Smoke test changes from peer-session <SESSION_ID>. Files: <CHANGED_FILES>. Consensus invariants to check: <list из 3.5 — что должно работать>. Запусти приложение/тесты, проверь поведение, верни PASS/FAIL с traceback при FAIL."
)
```

`/verify` сам решит как проверять (запуск приложения, pytest, manual instructions для UI).

**Результат:**
- PASS → перейти к 3.6.5.
- FAIL → показать traceback пилоту, спросить «фиксить и повторить или escalate?»
  - «фиксить» → Edit → вернуться к 3.6.2 (review после фиксов) или сразу 3.6.4 если фикс точечный (по согласию пилота).
  - «escalate» → ESCALATE_TO_USER + escalation-NN.md.

Сохранить вывод `/verify` в `${SESSION_DIR}/verify-01.md`.

### 3.6.5 Deploy

Для каждого репо в списке изменённых файлов:

```bash
cd <repo path>
git status --short
# pathspec после `--`: commit ТОЛЬКО свои файлы. Bare `git commit` сметает
# чужое pre-staged из общего индекса (mis-attribution, см. 2026-06-20-39).
git add <specific files — НЕ git add . и НЕ git add -u>
git commit -m "<type>(<scope>): <короткое описание>

Refs: peer-session <SESSION_ID>
Review iters: <REVIEW_ITER>
Verify: PASS" -- <те же specific files>
git push
```

Записать commit SHA для каждого репо в переменную `DEPLOY_SHAS` (map: repo → sha).

**Если push fail** (pre-commit hook отказал, конфликт с remote):
- НЕ обходить хуки (`--no-verify` запрещён правилом 6).
- Зафиксировать в logs, показать пилоту, ESCALATE_TO_USER.

### 3.6.6 Outcome дополнение к report-draft.md

Перед Шагом 4 (финализация) writer дописывает в `${SESSION_DIR}/report-draft.md` (если файл уже создан — append; если ещё нет — отметить что будет создан в 4.2 с включением этой секции) пометку для синтезатора:

В `${SESSION_DIR}/_outcome.md` (Write) — служебный файл для синтезатора:
```markdown
## Реализация и проверка

**Изменённые файлы:**
<CHANGED_FILES with one-line description each>

**Code review итераций:** <REVIEW_ITER>
**Unresolved (отложено на потом):** <count High/Medium или «нет»>

**Smoke verification:** PASS | FAIL (с пометкой что fix'нули)

**Deploy:**
- <repo1>: commit <sha1>
- <repo2>: commit <sha2>

**Открытые задачи после deploy:** <список или «нет»>
```

Этот файл будет включён синтезатором (Шаг 4.2) как обязательная секция при `implementation_pipeline: true`.

---

## Шаг 3.7. Рефлексия перед финализацией (WP-484, решение пилота 30.07)

> **Почему здесь:** пир-сессия — тоже сессия работы, вопрос рефлексии обязателен так же, как и в обычной Quick Close (Ф18), а не только там (Ф28 — этот разрыв и был найден 29.07). Порог и формулировка те же, что уже используются везде — не новый механизм, применение существующего.

**Порог:** тот же порог, что в `quick-close.yaml`, и та же формула вычисления, что уже проверена и починена в `gather-session-facts.sh` (WP-484 Ф26, 30.07 — наивный разбор ISO-даты дал баг «duration_min всегда 0» на BSD-date/macOS, эта же формула переиспользуется, не изобретается заново):
```bash
START_TIME=$(grep '^start_time:' "$SESSION_DIR/meta.yaml" | sed -E 's/^start_time: *"?([^"]*)"?$/\1/')
NOW_EPOCH=$(date -u +%s)
START_EPOCH=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$START_TIME" +%s 2>/dev/null \
    || date -u -d "$START_TIME" +%s 2>/dev/null \
    || echo "$NOW_EPOCH")
DURATION_MIN=$(( (NOW_EPOCH - START_EPOCH) / 60 ))
```
Если `DURATION_MIN ≤ 15` — пропустить, перейти к Шагу 4 молча (короткая сессия, не задерживать пилота).

Если `duration_min > 15`:

1. Показать пилоту краткий итог (2-3 строки, что сделали в этой пир-сессии — не пересказ turn-файлов, суть).
2. Спросить: «Что в этой сессии стоит запомнить на будущее — не про саму задачу, а про то, как шла работа?» (дословно вопрос Ф18, `CONCEPT-night-cycle.md §18`).
3. Записать ответ в дневной ledger (issue #409: скрипт есть не на каждой установке — не блокировать при отсутствии):
   ```bash
   LEDGER_SCRIPT="$HOME/IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/ledger-append.sh"
   if [ -f "$LEDGER_SCRIPT" ]; then
     bash "$LEDGER_SCRIPT" day "$(date +%F)" session_reflection "{\"wp\": \"<WP-NNN>\", \"answer\": <экранированный ответ>}" peer-conversation
   else
     echo "ledger-append.sh недоступен на этой установке — рефлексия не записана в дневной ledger"
   fi
   ```
4. Сказать пилоту: «Ты свободен, дальше закрываю сессию сам» — и продолжить Шаг 4 (финализация: report.md, commit, session-guard close) без дальнейшего участия пилота.

Пропуск ответа пилотом (ушёл, не ответил) — не блокировать: записать `"answer": "нет ответа"`, продолжить Шаг 4 как обычно.

---

## Шаг 4. Финализация

### 4.1 Обновить meta.yaml

```bash
TURNS_DONE=$(find "$SESSION_DIR" -maxdepth 1 -name "[0-9][0-9]-*.md" | wc -l | tr -d ' ')
END_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
tmpf=$(mktemp)
sed "s/^status:.*/status: \"completed\"/" "$SESSION_DIR/meta.yaml" |
  sed "s/^end_time:.*/end_time: \"$END_TIME\"/" |
  sed "s/^turns_count:.*/turns_count: $TURNS_DONE/" |
  sed "s/^escalations_count:.*/escalations_count: $ESCALATIONS/" > "$tmpf"
mv "$tmpf" "$SESSION_DIR/meta.yaml"
```

### 4.2 Синтез report-draft.md (не report.md — см. 4.2a)

> **Архитектурное ограничение:** Claude-писатель использует Agent tool для синтеза, т.к. Claude может запустить субагента Sonnet внутри сессии. Kimi-писатель (скилл `/peer-writer`) вынужден использовать bash pipe через `claude-peer-adapter.sh`, т.к. Kimi не имеет доступа к Claude Agent tool. Это осознанное различие, а не дрейф.

Запустить субагент через Agent tool (Sonnet, context isolation).
**Fallback:** если `report-draft.md` не создан или пустой после завершения субагента — записать заглушку (Write):

```markdown
---
session_id: <SESSION_ID>
generated_at: <now>
note: синтез не выполнен (субагент недоступен или вернул пустой результат)
---

# Итоговый отчёт

Стенограмма: см. файлы реплик в папке сессии.
Повтори синтез: `/peer-conversation --finalize <SESSION_ID>`
```

### 4.2a Правило отложенной финализации (post-2026-05-22)

> **Инвариант:** `report.md` — только финальная версия. До явного Close-сигнала от пилота файл называется `report-draft.md`.

**При консенсусе (turn ≤ 10):**
- Не переименовывать в `report.md`.
- Спросить пилота: «Консенсус достигнут. Закрываем сессию или нужно дозакрытие?»
- Если пилот говорит «закрываем» → переименовать `report-draft.md → report.md` (шаг 4.3).
- Если пилот запрашивает дозакрытие → продолжить turn-loop, а при финальном Close дописать `## Дополнение (turns N–M, <timestamp>)` в тот же `report-draft.md`, затем переименовать.

**При дозакрытии:**
```markdown
## Дополнение (turns N–M, <timestamp>)

### Turn N — <тема>
...
```

**В `meta.yaml`:**
```yaml
extensions:
  - turns: [4, 5, 6]
    reason: "verification R23 + multiplier recalculation"
    appended_at: "2026-05-23T04:25"
```

**Запрещено:**
- Создавать `report-v1.md`, `report-v2.md` — одна сессия = один отчёт.
- Создавать supplement-директории — `sessions/YYYY-MM/DD/<id>/` = единое пространство.
- Продолжать писать `-writer.md`/`-peer.md` при `status: completed` — статус меняется только после Close-сигнала.

### 4.2b Стиль report.md (DP.SC.050)

> **Канал определяет стиль.** Turn-файлы (00-writer.md, 01-peer.md, ...) — технические, для агентов. report.md — разговорный, для пилота.
>
> При синтезе report.md из turn-файлов: **перепиши**, не копируй. Замени технические термины на бытовые (A1-A11), убери машинные маркеры (PASS, SHA, exit), переведи пассивный залог в активный.

Промпт субагенту:

```
Ты — синтезатор итогов диалога нескольких агентов (DP.SC.154, писатель + <PEER_COUNT> напарник(а/ов)).
Задача сессии: <задача>

Стиль: разговорный для пилота (A1-A11). Перепиши, не копируй turn-файлы.

Прочитай все файлы реплик в <SESSION_DIR> (00-writer.md, затем 01-peer.md.../01-peer-<vendor>.md... — в порядке нумерации, при PEER_COUNT>=2 несколько файлов на один номер раунда, читать все) в порядке нумерации.
Если в папке есть `_outcome.md` — прочитай его, он обязателен для §6.
Если есть review-NN.md / verify-NN.md — включи как якоря в §5/§6.
Напиши <SESSION_DIR>/report.md строго по схеме ниже.
Не оборачивай в ```markdown``` — пиши markdown напрямую.
Инвариант: result_class=agreed → §4 непустой; not-agreed → §4 = «Консенсус не достигнут».
Verify-якоря обязательны для код-ссылок (file:line-range). Теги [synthesized] в §4.

---
schema_version: 1
session_id: <SESSION_ID>
generated_at: <ISO-8601 UTC>
writer: <из meta.yaml: writer_agent>
peer: <из meta.yaml: peer_agent, при PEER_COUNT>=2 — все peer_agents через ", ">
duration_min: <(end_time − start_time) в минутах, целое>
escalations_count: <из meta.yaml>
result_class: agreed | partial | escalated | not-agreed
confidence: low | med | high
confidence_basis: <обязателен если confidence <= med; иначе omit>
ttl_event: <«до merge PR-NNN» | «до WP-NNN» | «до отмены пилотом» | omit>
cost_usd: <если известно; иначе omit>
cost_source: api | estimated | missing
---

# Итоговый отчёт

## Algorithm

## 1. Исходная постановка
- **Задача:** <цитата из задания пилота, дословно>
- **Первоначальная позиция писателя:** <если зафиксирована в 00-writer.md; omit если нет>

## 2. Позиции по темам
Под каждой темой (затронута 2+ сторонами и повлияла на итог). При PEER_COUNT==1 — секция «Писатель/Напарник» как раньше. При PEER_COUNT>=2 — по каждому участнику, приславшему позицию, отдельной строкой (не сводить всех напарников в одну общую «Напарник»):

**Тема N: <формулировка>**
- Инициатор: <agent_id, кто поднял тему>
- **<agent_id 1>:** тезис → обоснование → якорь (file:line-range / Pack-ID)
- **<agent_id 2>:** тезис → обоснование → якорь
- **<agent_id N>:** ... (по одной строке на каждого участника, высказавшегося по теме)
- Эволюция (опц.): если позиция менялась — раунд/ход и причина
- Разрешение: что приняли + чей аргумент перевесил

## 3. Отвергнутые альтернативы
Omit если пусто. Только аргументированные обеими сторонами ИЛИ отвергнутые с контраргументом.
- Альтернатива → причина отказа → ссылка на ход

## 4. Зафиксированное решение
- <Исполняемая формулировка> [synthesized]
- **Главный аргумент:** <одной строкой>
- **Confidence:** low | med | high (если ≤ med — обоснование обязательно)
- **TTL-event:** <привязка к событию или omit>

Инвариант: agreed → непустой; not-agreed → «Консенсус не достигнут».

## 5. Открытые вопросы и эскалации
Omit если пусто.
- <Вопрос или эскалация>
- Статус: needs-decision | needs-verification | deferred
- Ссылка: escalation-NN.md или NN-peer.md (если есть)

## 6. Реализация и проверка
Omit если `implementation_pipeline: false` в meta.yaml.
Если true — обязательная секция, источник = `${SESSION_DIR}/_outcome.md`.
- **Изменённые файлы:** список с one-line описанием каждого
- **Code review итераций:** <N>
- **Unresolved:** <count High/Medium или «нет»>
- **Smoke verification:** PASS | FAIL
- **Deploy:** repo → commit SHA (по каждому затронутому репо)
- **Открытые задачи после deploy:** список или «нет»
- **Ссылки:** review-NN.md, verify-NN.md

## 7. Метаданные и навигация
- **Журнал:** ссылки на все NN-writer.md / NN-peer.md (или NN-peer-<vendor>.md при PEER_COUNT>=2) по порядку
- **Связанные артефакты:** Pack-IDs, файлы (PR, спецификации) — если упоминались
- **Пропуски раундов** (только при PEER_COUNT>=2 и непустом `meta.yaml.round_skips`): кто и в каком раунде не ответил — omit если пусто
- **Передача write token** (только при PEER_COUNT>=2 и непустом `meta.yaml.handoff_history`): раунд → от кого → к кому → причина, по каждой записи — omit если пусто
- **Стоимость:** $X (источник: api / estimated / missing) — omit если missing
```

### 4.3 Обновить sessions/00-index.md

Файла нет (сессия шла в обход Шага 1.3 или индекс удалён) → сначала создать его тем же блоком, что в Шаге 1.3 (идемпотентно, issue #568), затем добавить строку как новую. Иначе — найти строку с `<SESSION_ID>` и заменить целиком (колонка «Агенты» — та же `+`-склейка при PEER_COUNT>=2, что в Шаге 1.3):
```
| <TODAY> | <SESSION_ID> | <задача ≤50> | claude-code / <PEER_VENDOR1>[+<PEER_VENDOR2>...] | <TURNS/ROUNDS> | <ESCALATIONS> | completed | [report.md](<MONTH>/<DAY>/<SESSION_ID>/report.md) |
```
(Bash awk — безопасен для строк с `|`.)

### 4.4 Закрытие (ОРЗ — сессионный файл рядом с папкой сессии)

> **До 2026-08-03 этот шаг и Шаг 4.5.0 писали в файл независимо, разными шаблонами и разными путями** (`SESSION_SLUG` здесь отбрасывал дату И номер сессии, `CLEAN_SESSION_ID` в 4.5.0 отбрасывал только дату) — на диске оставались два сиротских файла вместо одного (пример: `sessions/2026-08/2026-08-03-codex-wp510-strategy-questions.md` рядом с `sessions/2026-08/2026-08-03-04-codex-wp510-strategy-questions.md`). Найдено и исправлено в peer-session `2026-08-03-09-launchd-focustodo-weekly-export`. Теперь запись в файл — единственная, на Шаге 4.5.0; этот шаг только определяет общую переменную пути.

Slug-часть (без даты, с номером — та же формула, что `session-guard.sh` использует для своего ORZ-скаффолда, `session-guard.sh:241-243`): `SESSION_SLUG="${SESSION_ID#"$TODAY"-}"`

Целевой путь (используется здесь и на Шаге 4.5.0): `${IWE_GOVERNANCE_REPO:-DS-strategy}/sessions/<MONTH>/<TODAY>-<SESSION_SLUG>.md` — плоский Quick Close файл под месячной папкой, без DD/ (DD/ — только для peer-session-папок). Тот же путь, что `session-guard.sh` уже создал (или создаст) как свой ORZ-скаффолд на Шаге 1.0 — содержимое пишется один раз, на Шаге 4.5.0.

### 4.5 Commit + push

**4.5.0 Записать закрывающий ОРЗ-файл сессии** (единственная точка записи — формула пути и обоснование см. Шаг 4.4; заодно закрывает служебный семафор session-guard, если Шаг 1.0 его создал):

```bash
# Путь строится ТОЙ ЖЕ формулой, что session-guard.sh использует для своего
# ORZ-скаффолда (session-guard.sh:241-243, WP-484 31.07 — защита от задвоения
# даты) — $SESSION_SLUG уже определён на Шаге 4.4. SESSION_ID здесь ВСЕГДА
# начинается с "$TODAY-" (Шаг 1: "${TODAY}-${NUM}-${SLUG}"), поэтому склейка
# "${TODAY}-${SESSION_ID}" без предварительного вычитания задваивала бы дату.
GUARD_ORZ="$HOME/IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/sessions/$MONTH/${TODAY}-${SESSION_SLUG}.md"
cat > "$GUARD_ORZ" <<EOF
---
date: $TODAY
type: peer-session
wp: <WP-NNN>
writer: claude-code
peer: [<PEER_AGENT_ID>, ...]      # список; при PEER_COUNT==1 — один элемент
duration_h: <(end_time - start_time) в часах, 1 знак>
artifacts: [sessions/$MONTH/$DAY/$SESSION_ID/report.md]
session_id: $SESSION_ID
---

## Главный инсайт

<1-2 строки из §4 report.md — зафиксированное решение>

## Контекст

Пир-сессия $SESSION_ID — полная стенограмма и синтез в sessions/$MONTH/$DAY/$SESSION_ID/.

## Достигнуто

| Артефакт | Описание |
|----------|----------|
| sessions/$MONTH/$DAY/$SESSION_ID/report.md | Итоговый отчёт пир-сессии |

## Ключевые решения

См. report.md §4.
EOF
```

Если запись упала (директория недоступна, диск полон) — не блокировать финализацию: сообщить пилоту одной строкой и продолжить, Шаг 4.5.1 подхватит `$GUARD_ORZ` в PATHS независимо от результата.

**4.5.1 Commit + push:**

```bash
cd "$HOME/IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}"
# pathspec после `--`: commit ТОЛЬКО файлы сессии, не подметаем чужое
# pre-staged из общего индекса (mis-attribution, см. 2026-06-20-39).
# $GUARD_ORZ (Шаг 4.5.0) — тот же путь, что "$TODAY-$SESSION_SLUG.md" (Шаг 4.4),
# одна запись вместо двух хардкодов одного и того же файла.
PATHS=("sessions/$MONTH/$DAY/$SESSION_ID/" "sessions/00-index.md" "$GUARD_ORZ")
git add "${PATHS[@]}"
git commit -m "feat(peer): $SESSION_ID — <задача кратко>" -- "${PATHS[@]}"
git push
```

**4.5.2 Session-guard close** (best-effort, ПОСЛЕ успешного push — закрывать семафор раньше нельзя, иначе Scope gate на 4.5.1 не найдёт активного семафора):

```bash
IWE_AGENT=claude-code bash "${IWE_SCRIPTS:-$HOME/IWE/scripts}/session-guard.sh" close --agent claude-code 2>&1 || \
  echo "session-guard close не прошёл — семафор останется активным до auto-orphan (TTL 30 мин на следующем open), не блокирует пилота"
```

**Показать пилоту in-chat summary** (прочитать `report.md`, извлечь и вывести):

```
Сессия завершена.

Ходов/раундов: <turns_count|rounds> | Роли: <writer_agent> (писатель) · <peer_agent(s)> (напарник(и)) | Эскалаций: <escalations_count>

Решение: <первый пункт §4 из report.md — одна строка на пальцах, без технических кодов>

Подробный отчёт: sessions/<MONTH>/<DAY>/<SESSION_ID>/report.md
```

Если report.md пустой или субагент-синтезатор не создал его — показать только ссылку без §4.

---

## Шаг 5. Interrupt-режим

При `--interrupt <session_id>`:

1. Извлечь месяц и день из id: `MONTH=$(echo "$session_id" | cut -c1-7)`, `DAY=$(echo "$session_id" | cut -c9-10)` → найти `sessions/$MONTH/$DAY/$session_id/meta.yaml`.
2. Обновить (Bash sed): `status: interrupted`, `end_time: <now>`, `turns_count: <число файлов>`.
3. Найти строку с `<session_id>` в `sessions/00-index.md` и заменить: статус → `interrupted`, report → `—`.
4. Commit + push.

---

## Шаг 6. Finalize-режим

При `--finalize <session_id>`:

1. Извлечь месяц и день: `MONTH=$(echo "$session_id" | cut -c1-7)`, `DAY=$(echo "$session_id" | cut -c9-10)`. Проверить что папка `sessions/$MONTH/$DAY/$session_id` существует и содержит хотя бы `00-writer.md`.
2. Прочитать `meta.yaml` — взять `task_description`, `start_time`, `escalations_count`.
3. Выполнить **Шаг 4.2** (синтез report.md через Agent tool) с теми же инвариантами и fallback.
4. Обновить `meta.yaml` (Bash sed): `status: completed`, `end_time: <now>`, `turns_count: <число файлов>`.
5. Обновить строку в `sessions/00-index.md`: статус → `completed`, report → ссылка.
6. Commit + push.

Используется для восстановления прерванных сессий без перезапуска turn-loop.

---

## Верификация отчёта

Для проверки любого существующего report.md написать в чат:
«проверь отчёт сессии `<session_id>`»

Запустить субагент (Sonnet, context isolation): прочитать все файлы сессии + report.md, сверить с инвариантами schema_version=1 (frontmatter, §4 непустой при agreed, verify-якоря).

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
