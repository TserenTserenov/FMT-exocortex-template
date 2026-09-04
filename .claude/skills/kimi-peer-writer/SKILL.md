---
name: kimi-peer-writer
description: Peer-сессия DP.SC.154 где Kimi = писатель, Claude = напарник. Запускается простой фразой. Включает ОРЗ Opening и Closing, turn-loop, эскалации, Decision Gate (зафиксировать vs реализовать → ревью → проверить → задеплоить), отложенную финализацию и верификацию.
argument-hint: "<описание задачи> | --list | --interrupt <session_id> | --finalize <session_id>"
version: 1.3.0
layer: L1
status: active
browser_safe: false
triggers:
  slash: [/peer-writer]
  phrases: ["начни peer-сессию", "запусти диалог с Клодом", "peer-сессия", "вместе с Клодом", "с Клодом", "привлеки Клода"]
routing:
  executor: sonnet
  deterministic: false
agents: single
interaction: multi-step
gates_required: []
gates_enforced: []
gates_rationale: "операционный скилл; WP Gate применим только при создании нового РП, не для операционных вызовов"
---

# Kimi Peer Writer (DP.SC.154)

Задача: $ARGUMENTS

> **Архитектура:** я (Kimi) = писатель, Claude = напарник.
> Claude вызывается через `claude-peer-adapter.sh` напрямую — Bash tool, stdin pipe.
> `list_peer_statuses` (Local Gateway) — координация файлов, **не** проверка доступности Claude CLI.
> Gateway offline ≠ Claude недоступен.

---

## When to use

Peer-сессия DP.SC.154 где Kimi = писатель, Claude = напарник. Запускается простой фразой. Включает ОРЗ Opening и Closing, turn-loop, эскалации, Decision Gate (зафиксировать vs реализовать → ревью → проверить → задеплоить), отложенную финализацию и верификацию.

## Scope boundary — не подменяет решения, зарезервированные за пилотом (найдено 2026-07-07)

> Peer-сессия пригодна для: технических решений, дизайна, code review, поиска компромисса между подходами, подготовки кандидатов к решению.
> **НЕ пригодна** для решений, которые процесс явно закрепляет за человеком (например, R15 Валидатор в `/apply-captures` — accept/reject/defer кандидатов знания; R1 Стратег — приоритеты месяца). Согласие двух агентов между собой — не решение пилота, даже единогласное и хорошо обоснованное.
>
> Если задача внутри пир-сессии требует такого решения — писатель обязан остановиться и спросить пилота напрямую в текущем чате (не через turn-файл), прежде чем фиксировать результат. См. `.claude/skills/apply-captures/SKILL.md` раздел «R15 = живой пилот, не агент» и `${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/bugs/bug-2026-07-07-r15-decisions-bypassed-pilot.md` — прецедент, из-за которого добавлено это ограничение.

## Шаг 0. Режим

Определить режим из `$ARGUMENTS`:

- `--list` → прочитать `${IWE_GOVERNANCE_REPO:-DS-strategy}/sessions/00-index.md`, вывести таблицу. Стоп.
- `--interrupt <id>` → перейти к **Шагу 5 (interrupt-режим)**. Стоп после.
- `--finalize <id>` → перейти к **Шагу 6 (finalize-режим)**. Стоп после.
- Иначе → новая сессия, продолжать к Шагу 0б.

---

## Шаг 0а. Preflight Gate (WP-484 Ф33 item Г, обязательно ДО любых других действий)

Та же проверка, что `~/.kimi-code/skills/session-open/SKILL.md` уже делает для standalone-сессий Kimi (Ф33, 31.07) — до этой правки у пир-сессий Kimi-писателя не было НИКАКОЙ проверки, что сессия открыта честно (тот же класс дыры, что Ф28). Скрипт поставляется шаблоном; звать по конвенции путей (#566 — фантомным был только хардкод `$HOME/IWE/scripts/...`, сам скрипт существует и входит в манифест):

```bash
bash "${IWE_SCRIPTS:-$HOME/IWE/scripts}/kimi-standalone-preflight.sh"
```

- Exit ≠ 0 (`ERROR: Kimi standalone session is NOT OPEN`) → **СТОП.** Не переходить к Шагу 0б, не открывать WP Gate, не создавать `meta.yaml`/`00-writer.md`, не трогать файлы. Показать пилоту команду открытия из stderr скрипта (`bash "${IWE_SCRIPTS:-$HOME/IWE/scripts}/session-guard.sh" open --wp WP-N --task "..." --agent kimi`) и ждать, пока сессия не будет открыта явно.
- Exit 0 (в т.ч. с предупреждением про устаревшую/stale-сессию) → продолжать к Шагу 0б.

## Шаг 0б. Открытие (WP Gate — только для новой сессии)

Найти WP по задаче: прочитать `${IWE_GOVERNANCE_REPO:-DS-strategy}/WP-REGISTRY.md` (grep по ключевым словам) и `${IWE_GOVERNANCE_REPO:-DS-strategy}/current/WeekPlan W{N}.md`.

Анонс пилоту:
```
Открываю peer-сессию (DP.SC.154)
Роль: Писатель (Kimi) | Напарник: Claude
Задача: <задача>
РП: WP-NNN «<название>» | или: не найден в плане
Метод: turn-loop ≤10 ходов | Модель напарника: Sonnet
```

Если РП **не найден** в плане недели → полный WP Gate Ритуал (`memory/protocol-open.md §Сессия`):
объявить артефакт + дождаться подтверждения пилота → **только после «да» переходить к Шагу 1**.

Если РП найден → продолжать без ожидания.

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
writer_agent: "kimi-headless"
peer_agent: "claude-code"
peer_cmd: "claude-peer-adapter"
peer_model: "sonnet"
status: "started"
turns_count: 0
turns_limit: 10
escalations_count: 0
extensions: []
result_path: ""
task_description: "<задача>"
implementation_pipeline: false
review_iterations: 0
verify_status: ""
deploy_shas: {}
# Двухосная модель (WP-367 Ф5, DP.SC.154 v4):
roles: {}            # {agent_id: [DP.ROLE.NNN, ...]} после consensus в Opening
discovery_turns: 0   # сколько ходов ушло на role-discovery (не считается в turns_limit)
ad_hoc_roles: {}     # {role_name: {agent_id, rationale, first_used_turn}} — для каскада audit
swap_history: []     # [{turn, from, to, reason}] — журнал SWAP_WRITER переходов
```

**Если пилот не назначил роли** при запуске сессии — initiator (writer/Kimi) в ход 0 предлагает свою content-role и роль напарника (см. DP.SC.154 раздел «Opening сессии: Sequential role-discovery»). Discovery-ходы (0-2) **не входят** в `turns_limit: 10`.

**In-session ad-hoc role signal** (DP.SC.154 v4, каскад Pack-расширения уровень 1). При использовании ad-hoc роли (нет в Pack `DP.ROLE.NNN`/`MIM.R.NNN`/`VR.R.NNN`) Kimi-писатель **обязан сразу** объявить пилоту:

```
Беру ad-hoc роль «<имя>». В каталоге Pack такой нет.
Обязанности: <одной строкой>. Метод: <одной строкой>.
Предлагаю создать РП на формализацию (~30 мин).
Выбери:
  А. Создать сейчас → отдельный РП «pack-gap-<имя>».
  Б. Отложить → продолжу как ad-hoc, сторож напомнит при Week Close.
```

Запись в `meta.yaml.ad_hoc_roles` идёт независимо от выбора (для back-up уровня 2). При выборе А — после сессии писатель открывает отдельный РП.

**1.3 Добавить строку в `sessions/00-index.md`** сверху таблицы (первая строка таблицы после `|---|`):
```
| <TODAY> | <SESSION_ID> | <задача ≤50 симв> | kimi / claude-code | 0 | 0 | started | — |
```

---

## Шаг 2. Реплика писателя 00-writer.md

Записать `${SESSION_DIR}/00-writer.md` (Write):

```markdown
---
turn: 0
role: writer
agent_id: kimi-headless
timestamp: <ISO-8601 UTC>
consensus: none
---

<Моя начальная позиция — анализ задачи, тезисы, конкретные вопросы к напарнику.
НЕ пересказ задачи. Позиция с аргументами.>
```

Показать пилоту краткое резюме: что написал в 00-writer.md.

---

## Шаг 3. Turn loop

Переменные: `TURN=1`, `ESCALATIONS=0`, `DONE=false`.

### 3.1 Вызов Claude

Прочитать все предыдущие реплики из `SESSION_DIR` в порядке нумерации.
Составить промпт:

```
КРИТИЧНО: Твоя задача — ТОЛЬКО написать одну peer-реплику в stdout с frontmatter.
Запрещено: редактировать файлы, делать commit, git push, создавать файлы в SESSION_DIR.
Весь твой ответ = одна реплика в stdout. Ничего больше.

Ты — напарник (peer agent) в диалоговой сессии (DP.SC.154).
Сессия: <SESSION_ID>
Ход: <TURN> из 10
Задача: <задача>

Прочитай все файлы журнала в <SESSION_DIR> по порядку (00-writer.md, 01-peer.md, ...).

Напиши реплику в stdout с frontmatter:
---
turn: <TURN>
role: peer
agent_id: claude-code
timestamp: <ISO-8601 UTC>
consensus: none | proposed | reached | escalate
---

<Твой ответ>

Правило критика: найди ХОТЯ БЫ ОДИН тезис или допущение писателя, с которым не согласен. Не сдавайся после первого возражения — держись аргументированно. Если всё действительно ОК — объясни почему конкретно, не просто «согласен».

Маркеры (строго в начале строки):
CONSENSUS: <резюме> — если считаешь что договорились
ESCALATE_TO_USER: <причина> — если писатель игнорирует существенное возражение
```

Перед вызовом Claude писатель добавляет в промпт минимальную текстовую проекцию предыдущих реплик и фактов. Claude не читает `SESSION_DIR` и не использует инструменты.

Вызов Claude через Bash:
```bash
PEER_FILE="${SESSION_DIR}/$(printf '%02d' $TURN)-peer.md"
echo "<промпт>" | bash "$HOME/IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/claude-peer-adapter.sh" \
  > "$PEER_FILE" 2> "${PEER_FILE%.md}.err"
```

Если файл пустой или exit ≠ 0 → сообщить пилоту: «Claude не ответил. Повторить или прервать?»

### 3.2 Показать пилоту

Прочитать `$PEER_FILE`. Вывести ключевые тезисы Claude (не всю реплику дословно — краткое резюме + цитаты ключевых позиций).

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
**Реплика Claude:** <PEER_FILE>
**Ответ пилота:** (ввести ниже)
```

- Сообщить пилоту: «Claude эскалирует: <причина>. Нужно твоё решение.»
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
agent_id: kimi-headless
timestamp: <now>
consensus: none
---

<Моя реплика: ответ на аргументы Claude + учёт направления пилота>
```

`TURN += 1` → вернуться к 3.1.

---

## Шаг 3.5. Decision Gate (после консенсуса)

> **Когда срабатывает:** `DONE=true` через CONSENSUS-маркер в Шаге 3.3 (не через `TURN >= 10` — там сразу Шаг 4).
> **Зачем:** консенсус ≠ реализация. Это **легитимный choice-question** для пилота (выбор объёма работы, не yes/no на готовое решение). Исключение из P5 — пилот сам подтвердил: «здесь от меня нужно согласование» (триггер 2026-05-30, WP-367 Ф5).
> **Обязательно:** перед запросом — **краткое резюме консенсуса на пальцах**, чтобы пилот мог осознанно выбрать. Запрос без резюме = механический «выберите А/Б» без понимания.

Извлечь резюме консенсуса (`grep "^CONSENSUS:" "$PEER_FILE" | sed 's/^CONSENSUS: //'`).

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

**Default при молчании пилота:** Б (реализация сейчас), per правило 11 «финиш > отлог». Применять только если пилот явно не ответил в течение разумного времени.

**Triggers automatic-defer** (без запроса пилоту — сразу А):
1. Реализация требует нового РП (новый scope, не покрытый текущим РП).
2. Требуется ArchGate (новое архитектурное решение системного уровня).
3. Контекст полностью переключился (другая часть системы; нужен новый framing).

При срабатывании trigger — анонс пилоту с резюме (НЕ запрос), потом Шаг 4.

---

## Шаг 3.6. Implementation Pipeline (опциональный)

> **Активируется:** только при `IMPLEMENTATION=true` в Шаге 3.5.
> **Принцип:** Kimi-writer применяет решение → cold-context Claude через bash pipe делает code review → writer фиксит → Claude через bash pipe запускает smoke (writer не имеет Skill tool) → deploy → секция «Реализация и проверка» в report-draft.md.
> **Архитектурное ограничение:** Kimi-headless не имеет Agent/Skill tools. Все вызовы внешних агентов идут через `claude-peer-adapter.sh` (stdin pipe) — это осознанная асимметрия с `/peer-conversation`.

### 3.6.1 Implementation

Анонс пилоту:
```
Реализация консенсуса <SESSION_ID>
Файлы: <list of files with absolute paths>
Репо: <repo names, separated by " · ">
Метод: Edit/Write tools напрямую
```

Writer (Kimi) применяет изменения через Edit/Write. Запрещено:
- Менять файлы вне анонсированного списка без нового анонса.
- Делать commit на этом этапе (commit — только Шаг 3.6.5).

Зафиксировать список изменённых файлов в `CHANGED_FILES` (один путь на строку).

### 3.6.2 Code Review (cold-context через bash pipe)

Переменные итерации ревью: `REVIEW_ITER=1` при первом входе, инкрементируется в 3.6.3.

Вызов Claude как code reviewer через тот же адаптер что для turn-loop:

```bash
: "${REVIEW_ITER:=1}"
REVIEW_FILE="${SESSION_DIR}/review-$(printf '%02d' "$REVIEW_ITER").md"
REVIEW_PROMPT=$(cat <<EOF
КРИТИЧНО: НЕ используй Write/Edit. Выводи markdown в stdout.
Весь твой ответ = один отчёт в stdout. Ничего больше.

Cold-context code review результатов peer-сессии <SESSION_ID>.
Ты — независимый ревьюер, не видевший диалога. Контекст ниже.

Резюме консенсуса: <CONSENSUS_SUMMARY>

Изменённые файлы:
<CHANGED_FILES>

У тебя нет файловых инструментов и доступа к каталогу сессии — весь нужный код уже вставлен выше, в `<CHANGED_FILES>` (диф и фрагменты файлов, добавляет писатель перед вызовом).
Проверь по чек-листу:
1. asyncio runtime: ищи 'wait_for(coro)' без 'shield' → coroutine reuse. Fire-and-forget tasks читающие/пишущие одну строку БД из разных мест.
2. Shell ordering: function call ДО function definition. 'set -u' соблюдён?
3. SQL race: cross-file writers в одну строку без атомарности (UPDATE ... RETURNING / SELECT FOR UPDATE).
4. Lock enforcing: при collision — 'exit N' или 'log WARN && continue'? Если advisory — это intentional или баг?
5. Контекст-специфика консенсуса: <дополни из резюме если есть инварианты>.

Верни отчёт в формате:
## Critical (must fix before deploy)
- <file:line-range>: <issue> | fix: <conkr>
## High / ## Medium / ## OK

Не предлагай рефакторинг или стиль — только runtime баги и нарушения чек-листа.
EOF
)

echo "$REVIEW_PROMPT" | bash "$HOME/IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/claude-peer-adapter.sh" \
  > "$REVIEW_FILE" 2> "${REVIEW_FILE%.md}.err"
```

Добавь в `REVIEW_PROMPT` точечный diff и нужные фрагменты файлов. Нельзя передавать каталоги: Claude получает только текстовую проекцию.

### 3.6.3 Review Outcome

Прочитать `$REVIEW_FILE`. Показать пилоту краткое резюме (Critical + High count + один пример).

**Если есть Critical:**
- Применить фиксы (Edit) → `REVIEW_ITER += 1` → вернуться к 3.6.2 (новый review-NN.md).
- Лимит итераций: 3. На 3-й — `ESCALATE_TO_USER:` + escalation-NN.md.

**Если только High/Medium:**
- Спросить пилота: «Есть N High и M Medium замечаний. Фиксить сейчас или после deploy?»
- Записать в meta.yaml (`review_iterations: <N>`, `unresolved: <count>`).

**Если только OK:**
- Продолжить к 3.6.4.

### 3.6.4 Smoke Verification (через bash pipe к Claude)

Kimi-writer не имеет Skill tool — `/verify` вызывается через Claude как proxy:

```bash
VERIFY_FILE="${SESSION_DIR}/verify-01.md"
VERIFY_PROMPT=$(cat <<EOF
КРИТИЧНО: НЕ используй Write/Edit для файлов вне временного smoke-скрипта. Выводи результат в stdout.
Весь твой ответ = один отчёт в stdout. Ничего больше.

Запусти smoke test для изменений peer-сессии <SESSION_ID>.

Изменённые файлы:
<CHANGED_FILES>

Инварианты консенсуса (что должно работать):
<list from 3.5>

Используй встроенный /verify skill (Skill tool: skill=verify, args=...).
Если /verify не подходит (например, CLI-only без UI) — напиши и запусти точечный smoke (pytest fixture / curl call / минимальный python script).
Верни:
- PASS / FAIL
- При FAIL: traceback + первая строка-причина
- Команда которую запустил
EOF
)

echo "$VERIFY_PROMPT" | bash "$HOME/IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/claude-peer-adapter.sh" \
  > "$VERIFY_FILE" 2> "${VERIFY_FILE%.md}.err"
```

Claude в этом вызове не запускает smoke-тесты: он может только оценить переданный текст. Исполняемую проверку запускает писатель локально по отдельному протоколу.

**Результат:**
- PASS → перейти к 3.6.5.
- FAIL → показать traceback пилоту, спросить «фиксить и повторить или escalate?»
  - «фиксить» → Edit → вернуться к 3.6.2 (review после фиксов) или 3.6.4 (если фикс точечный, по согласию пилота).
  - «escalate» → ESCALATE_TO_USER + escalation-NN.md.

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

Записать commit SHA для каждого репо в `DEPLOY_SHAS` (map: repo → sha).

**Если push fail:**
- НЕ обходить хуки (`--no-verify` запрещён правилом 6 CLAUDE.md).
- Зафиксировать в logs, показать пилоту, ESCALATE_TO_USER.

### 3.6.6 Outcome дополнение к report-draft.md

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

> **Почему здесь:** пир-сессия — тоже сессия работы, вопрос рефлексии обязателен так же, как и в обычной Quick Close (Ф18) — этот же разрыв найден и закрыт 30.07 в `peer-conversation/SKILL.md` (Claude-писатель); здесь тот же фикс для симметричного случая (Kimi-писатель, Claude-напарник). Порог и формулировка идентичны — Claude (напарник) остаётся тем, у кого есть живой канал с пилотом и доступ к Skill/Bash, поэтому шаг ниже исполняет напарник, не писатель.

**Порог:** та же формула, что в `peer-conversation/SKILL.md` §3.7 (переиспользует починенный в `gather-session-facts.sh`, WP-484 Ф26, разбор даты — не изобретать заново):
```bash
START_TIME=$(grep '^start_time:' "$SESSION_DIR/meta.yaml" | sed -E 's/^start_time: *"?([^"]*)"?$/\1/')
NOW_EPOCH=$(date -u +%s)
START_EPOCH=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$START_TIME" +%s 2>/dev/null \
    || date -u -d "$START_TIME" +%s 2>/dev/null \
    || echo "$NOW_EPOCH")
DURATION_MIN=$(( (NOW_EPOCH - START_EPOCH) / 60 ))
```
Если `DURATION_MIN ≤ 15` — пропустить, перейти к Шагу 4 молча.

Если `duration_min > 15`:

1. Показать пилоту краткий итог (2-3 строки, суть сессии, не пересказ turn-файлов).
2. Спросить: «Что в этой сессии стоит запомнить на будущее — не про саму задачу, а про то, как шла работа?» (дословно Ф18, `CONCEPT-night-cycle.md §18`).
3. Записать ответ (issue #409: скрипт есть не на каждой установке — не блокировать при отсутствии):
   ```bash
   LEDGER_SCRIPT="$HOME/IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/ledger-append.sh"
   if [ -f "$LEDGER_SCRIPT" ]; then
     bash "$LEDGER_SCRIPT" day "$(date +%F)" session_reflection "{\"wp\": \"<WP-NNN>\", \"answer\": <экранированный ответ>}" kimi-peer-writer
   else
     echo "ledger-append.sh недоступен на этой установке — рефлексия не записана в дневной ledger"
   fi
   ```
4. Сказать пилоту: «Ты свободен, дальше закрываю сессию сам» — продолжить Шаг 4 без дальнейшего участия пилота.

Пропуск ответа — не блокировать: `"answer": "нет ответа"`, продолжить Шаг 4.

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

### 4.2 Синтез report-draft.md

> **Архитектурное ограничение:** Kimi-писатель использует bash pipe через `claude-peer-adapter.sh`, т.к. Kimi не имеет доступа к Claude Agent tool. Claude-писатель (скилл `/peer-conversation`) использует Agent tool — это осознанное различие, а не дрейф.

Запустить Claude как синтезатора через bash pipe (context isolation через stdin):
```bash

python3 - "$SESSION_DIR" "$SESSION_ID" <<'PYEOF'
import sys, os, glob, subprocess, datetime

session_dir, session_id = sys.argv[1:3]

# Read meta
meta_path = os.path.join(session_dir, 'meta.yaml')
meta = {}
with open(meta_path, encoding='utf-8') as f:
    for line in f:
        if ':' in line and not line.strip().startswith('#'):
            k, v = line.split(':', 1)
            meta[k.strip()] = v.strip().strip('"').strip("'")

writer_agent = meta.get('writer_agent', '')
peer_agent = meta.get('peer_agent', '')
start_time = meta.get('start_time', '')
escalations_count = meta.get('escalations_count', '0')
task_desc = meta.get('task_description', '')

# Gather turns
turn_files = sorted(glob.glob(os.path.join(session_dir, '[0-9][0-9]-*.md')))
turns_text = ''
for tf in turn_files:
    fname = os.path.basename(tf)
    with open(tf, encoding='utf-8') as f:
        body = f.read()
    turns_text += f'\n\n=== {fname} ===\n{body}'

outcome_path = os.path.join(session_dir, '_outcome.md')
outcome_text = ''
if os.path.exists(outcome_path):
    with open(outcome_path, encoding='utf-8') as f:
        outcome_text = f.read()

# Consistency guard: _outcome.md отсутствует, но meta говорит implementation_pipeline: true
if not outcome_text and meta.get('implementation_pipeline', 'false').lower() == 'true':
    import re as _re
    with open(meta_path, encoding='utf-8') as _f:
        _mc = _f.read()
    _mc = _re.sub(r'^implementation_pipeline:.*$', 'implementation_pipeline: false', _mc, flags=_re.MULTILINE)
    with open(meta_path, 'w', encoding='utf-8') as _f:
        _f.write(_mc)
    meta['implementation_pipeline'] = 'false'

synth_prompt = f"""Ты — синтезатор итогов диалога двух агентов (DP.SC.154).
Задача сессии: {task_desc}

Ниже — полная стенограмма диалога (реплики в порядке нумерации):
{turns_text}

Прочитай `meta.yaml` в той же папке — извлеки `roles`, `ad_hoc_roles`, `discovery_turns` для §1.5.

{('Дополнительно — outcome реализации (источник для §6):' + chr(10) + outcome_text) if outcome_text else 'Implementation pipeline не запускался — §6 omit.'}

КРИТИЧНО: НЕ используй Write/Edit. Выводи markdown в stdout — он будет записан в report-draft.md.
Не оборачивай в ```markdown``` — пиши markdown напрямую.
Инвариант: result_class=agreed → §4 непустой; not-agreed → §4 = «Консенсус не достигнут».
§6 обязательна если есть _outcome.md; omit если нет.
Verify-якоря обязательны для код-ссылок (file:line-range). Теги [synthesized] в §4.

СТИЛЬ: разговорный для пилота (DP.SC.050 A1-A11). Перепиши, не копируй turn-файлы. Замени технические термины на бытовые, убери машинные маркеры (PASS, SHA, exit), активный залог.

---
schema_version: 1
session_id: {session_id}
generated_at: {datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', '')}Z
writer: {writer_agent}
peer: {peer_agent}
duration_min: <(end_time − start_time) в минутах, целое>
escalations_count: {escalations_count}
result_class: agreed | partial | escalated | not-agreed
confidence: low | med | high
confidence_basis: <обязателен если confidence <= med; иначе omit>
ttl_event: <«до merge PR-NNN» | «до WP-NNN» | «до отмены пилотом» | omit>
cost_usd: <если известно; иначе omit>
cost_source: api | estimated | missing
roles: <из meta.yaml: roles — {{agent_id: [DP.ROLE.NNN, ...]}} или omit если пусто>
ad_hoc_roles: <из meta.yaml: ad_hoc_roles — {{role_name: {{agent_id, rationale, first_used_turn}}}} или omit если пусто>
discovery_turns: <из meta.yaml: discovery_turns, целое; omit если 0>
---

# Итоговый отчёт

## Algorithm

## 1. Исходная постановка
- **Задача:** <цитата из задания пилота, дословно>
- **Первоначальная позиция писателя:** <если зафиксирована в 00-writer.md; omit если нет>

## 1.5 Роли участников
Omit если `roles` пусто и `ad_hoc_roles` пусто.

**Форменные роли:**
- Писатель: <writer_agent>
- Напарник (критик): <peer_agent>

**Содержательные роли (content-roles):**
- <agent_id>: <роль> (источник: Pack `DP.ROLE.NNN` | ad-hoc | не назначена)
- ...

**Ad-hoc роли (если есть):**
- «<имя>» — <agent_id>, <рационал>, впервые использована в ходе <first_used_turn>

**Discovery:** <discovery_turns> ходов ушло на согласование ролей (не считались в лимит).

## 2. Позиции по темам
Под каждой темой (затронута обеими сторонами и повлияла на итог):

**Тема N: <формулировка>**
- Инициатор: писатель | напарник
- **Писатель:** тезис → обоснование → якорь (file:line-range / Pack-ID)
- **Напарник:** тезис → обоснование → якорь
- Эволюция (опц.): если позиция менялась — ход и причина
- Разрешение: что приняли + чей аргумент перевесил

## 3. Отвергнутые альтернативы
Omit если пусто. Только аргументированные обеими сторонами ИЛИ отвергнутые с контраргументом.
- Альтернатива → причина отказа → ссылка на ход

## 4. Зафиксированное решение
- <Исполняемая формулировка> [synthesized]
- **Главный аргумент:** <одной строкой>
- **Confidence:** low | med | high (если ≤ med — обоснование обязательно)
- **TTL-event:** <привязка к событию или omit>

Инвариант: agreed → непустой; not-agreed — «Консенсус не достигнут».

## 5. Открытые вопросы и эскалации
Omit если пусто.
- <Вопрос или эскалация>
- Статус: needs-decision | needs-verification | deferred
- Ссылка: escalation-NN.md или NN-peer.md (если есть)

## 6. Реализация и проверка
Omit если `implementation_pipeline: false` в meta.yaml.
Если true — обязательная секция, источник = `_outcome.md` в этой же папке.
- **Изменённые файлы:** список с one-line описанием каждого
- **Code review итераций:** <N>
- **Unresolved:** <count High/Medium или «нет»>
- **Smoke verification:** PASS | FAIL
- **Deploy:** repo → commit SHA (по каждому затронутому репо)
- **Открытые задачи после deploy:** список или «нет»
- **Ссылки:** review-NN.md, verify-NN.md

## 7. Метаданные и навигация
- **Журнал:** ссылки на все NN-writer.md / NN-peer.md по порядку
- **Связанные артефакты:** Pack-IDs, файлы (PR, спецификации) — если упоминались
- **Стоимость:** $X (источник: api / estimated / missing) — omit если missing
"""

import tempfile
with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False, encoding='utf-8') as tmp:
    tmp.write(synth_prompt)
    tmp_path = tmp.name

report_file = os.path.join(session_dir, 'report-draft.md')
gov_repo = os.environ.get('IWE_GOVERNANCE_REPO', 'DS-strategy')
adapter = os.path.expanduser(f'~/IWE/{gov_repo}/scripts/claude-peer-adapter.sh')

# synth_prompt above already inlines the full transcript, meta.yaml fields and
# _outcome.md into stdin — claude-peer-adapter.sh is a text-only reviewer by
# contract (WP-458) and unconditionally rejects --add-dir (exit 64). Passing
# it here made every synthesis call fail deterministically, not just under
# some failure condition; found via code review, confirmed by Codex reading
# the same two files independently, peer-session
# 2026-08-04-08-wp7-f44-sandbox-review. stderr is now captured (not
# discarded) so a future regression leaves an actual diagnostic in the
# fallback stub below instead of the same generic guess every time.
stderr_path = tmp_path + '.err'
try:
    with open(tmp_path, 'r', encoding='utf-8') as stdin_f, \
         open(report_file, 'w', encoding='utf-8') as stdout_f, \
         open(stderr_path, 'w', encoding='utf-8') as stderr_f:
        try:
            result = subprocess.run(
                ['bash', adapter],
                stdin=stdin_f,
                stdout=stdout_f,
                stderr=stderr_f,
                timeout=180
            )
        except (subprocess.TimeoutExpired, OSError):
            # Any launch failure, not just a timeout, folds into the same
            # returncode=1 path below — that branch already reads and cleans
            # up stderr_path; a narrower except here left it leaking on the
            # rarer OSError case (found in cold review, same peer-session).
            result = subprocess.CompletedProcess(args=[], returncode=1)
finally:
    os.unlink(tmp_path)

if result.returncode != 0 or os.path.getsize(report_file) == 0:
    stderr_tail = ''
    if os.path.exists(stderr_path):
        with open(stderr_path, encoding='utf-8') as f:
            stderr_tail = f.read()[-2000:]
        os.unlink(stderr_path)
    now = datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', '') + 'Z'
    with open(report_file, 'w', encoding='utf-8') as f:
        f.write(f"""---
session_id: {session_id}
generated_at: {now}
note: синтез не выполнен (Claude недоступен, вернул пустой результат, или таймаут >180с)
---

# Итоговый отчёт

Стенограмма: см. файлы реплик в папке сессии.
Повтори синтез: `/peer-writer --finalize {session_id}`

## Диагностика (stderr адаптера, для отладки — не для пилота)

```
returncode: {result.returncode}
{stderr_tail if stderr_tail else '(stderr пуст)'}
```
""")
    sys.exit(1)
else:
    if os.path.exists(stderr_path):
        os.unlink(stderr_path)
PYEOF
```

> **Fallback:** заглушка `report-draft.md` записывается изнутри python-блока выше (строки `if result.returncode != 0 or os.path.getsize(report_file) == 0`). Внешнего bash-fallback не нужно — `sys.exit(1)` уведомляет shell, но скилл идёт дальше к Шагу 4.3 (заглушка уже на диске). Заглушка теперь несёт код возврата и хвост stderr адаптера — секция «Диагностика» служебная (для отладки), синтезатор её не видит и не переносит в финальный report.md.

### 4.2a Правило отложенной финализации (post-2026-05-22)

> **Инвариант:** `report.md` — только финальная версия. До явного Close-сигнала от пилота файл называется `report-draft.md`.

**При консенсусе (turn ≤ 10):**
- Не переименовывать в `report.md`.
- **Close-signal detector:** если в последнем сообщении пилота встречается одно из: `закрывай`, `закрываем`, `всё`, `close`, `закрой` — считать Close-сигналом и сразу переходить к финализации БЕЗ choice-question.
- Иначе — спросить пилота: «Консенсус достигнут. Закрываем сессию или нужно дозакрытие?»
- Если пилот говорит «закрываем» (или Close-signal) → выполнить:
  ```bash
  mv "$SESSION_DIR/report-draft.md" "$SESSION_DIR/report.md"
  ```
  затем перейти к шагу 4.3.
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

### 4.3 Обновить sessions/00-index.md

Найти строку с `<SESSION_ID>` и заменить целиком:
```
| <TODAY> | <SESSION_ID> | <задача ≤50> | kimi / claude-code | <TURNS> | <ESCALATIONS> | completed | [report.md](<MONTH>/<DAY>/<SESSION_ID>/report.md) |
```
(Bash awk — безопасен для строк с `|`.)

### 4.4 Закрытие (ОРЗ — сессионный файл рядом с папкой сессии)

Slug-часть (без даты и номера): `SESSION_SLUG=$(echo "$SESSION_ID" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{2}-//')`

Записать `${IWE_GOVERNANCE_REPO:-DS-strategy}/sessions/<MONTH>/<TODAY>-<SESSION_SLUG>.md` (Write) — Quick Close файл плоский под месячной папкой, без DD/ (симметрично session-guard.sh; DD/ — только для peer-session-папок):
```markdown
---
date: <TODAY>
type: peer-session
writer: kimi-headless
peer: claude-code
duration_h: <(end_time - start_time) в часах, 1 знак>
artifacts: sessions/<MONTH>/<DAY>/<SESSION_ID>/report.md
session_id: <SESSION_ID>
wp: <WP-NNN или unknown>
---

# Главный инсайт

<1-2 строки из §4 report.md — зафиксированное решение>
```

### 4.5 Commit + push

```bash
cd "$HOME/IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}"

# Pre-commit guard
test ! -f "$SESSION_DIR/report-draft.md" \
  || { echo "FAIL: report-draft.md существует — mv к report.md не выполнен"; exit 1; }
test -f "$SESSION_DIR/report.md" \
  || { echo "FAIL: report.md отсутствует"; exit 1; }
CLOSE_FILE="sessions/$MONTH/${TODAY}-${SESSION_SLUG}.md"
test -f "$CLOSE_FILE" \
  || { echo "FAIL: close-файл $CLOSE_FILE отсутствует"; exit 1; }
INDEX_COUNT=$(grep -cF "| $SESSION_ID |" "sessions/00-index.md" || echo 0)
test "$INDEX_COUNT" -eq 1 \
  || { echo "FAIL: 00-index.md: ожидается 1 запись для $SESSION_ID, найдено $INDEX_COUNT"; exit 1; }

# pathspec после `--`: commit ТОЛЬКО файлы сессии (mis-attribution, 2026-06-20-39)
# PR flow (WP-436 Ф2): push to feature branch + auto-merge PR → branch protection on main.
PATHS=("sessions/$MONTH/$DAY/$SESSION_ID/" "sessions/00-index.md" "sessions/$MONTH/${TODAY}-${SESSION_SLUG}.md")
BRANCH="peer/$SESSION_ID"
git checkout -b "$BRANCH" 2>/dev/null || git checkout "$BRANCH"
git add "${PATHS[@]}"
git commit -m "feat(peer): $SESSION_ID (kimi-writer) — <задача кратко>" -- "${PATHS[@]}"
git push origin "$BRANCH"
gh pr create --title "feat(peer): $SESSION_ID" \
  --body "Peer-сессия DP.SC.154. Kimi (writer) + Claude (peer)." \
  --base main --auto-merge 2>/dev/null \
  || echo "WARN: gh pr create failed — merge manually or check gh auth"
```

Показать пилоту: «Сессия завершена. Отчёт: `sessions/$MONTH/$DAY/$SESSION_ID/report.md`»

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
3. Выполнить **Шаг 4.2** (синтез report-draft.md через `claude-peer-adapter.sh`) с теми же инвариантами и fallback.
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
