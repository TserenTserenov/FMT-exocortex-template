---
name: peer-conversation
description: Multi-turn dialog between writer (Claude) and partner (Kimi) on the pilot's task (DP.SC.154). Manages turn-loop, detects CONSENSUS/ESCALATE, after consensus — Decision Gate (record vs implement → review → verify → deploy), synthesizes report.md via Agent tool.
argument-hint: "<описание задачи> | --list | --interrupt <session_id> | --finalize <session_id>"
version: 1.2.0
layer: L3
status: active
triggers:
  slash: [/peer-conversation]
  phrases: ["начни peer-сессию", "запусти диалог с Кими", "peer-сессия"]
routing:
  executor: sonnet
  deterministic: false
---

# Peer Conversation (DP.SC.154)

Задача: $ARGUMENTS

> **Архитектура:** я (Claude) = писатель, Kimi = напарник.
> Kimi вызывается через `kimi-peer-adapter.sh` напрямую — Bash tool, stdin pipe.
> `list_peer_statuses` (Local Gateway) — координация файлов, **не** проверка доступности Kimi CLI.
> Gateway offline ≠ Kimi недоступен.

---

## Шаг 0. Режим

Определить режим из `$ARGUMENTS`:

- `--list` → прочитать `{{GOVERNANCE_REPO}}/sessions/00-index.md`, вывести таблицу. Стоп.
- `--interrupt <id>` → Read `.claude/skills/peer-conversation/modes.md`. Перейти к **Шагу 5 (interrupt-режим)**. Стоп после.
- `--finalize <id>` → Read `.claude/skills/peer-conversation/modes.md`. Перейти к **Шагу 6 (finalize-режим)**. Стоп после.
- Иначе → новая сессия, продолжать к Шагу 0б.

---

## Шаг 0б. Открытие (WP Gate — только для новой сессии)

Найти WP по задаче: прочитать `{{GOVERNANCE_REPO}}/WP-REGISTRY.md` (grep по ключевым словам) и `{{GOVERNANCE_REPO}}/current/WeekPlan W{N}.md`.

Анонс пилоту:
```
Открываю peer-сессию (DP.SC.154)
Роль: Писатель (Claude) | Напарник: Kimi
Задача: <задача>
РП: WP-NNN «<название>» | или: не найден в плане
Метод: turn-loop ≤10 ходов | Модель напарника: kimi-headless
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

> Statefulness-пробел Kimi закрыт автопередачей git-diff в `kimi-peer-adapter.sh` (§8).

---

## Шаг 1. Инициализация

```bash
SESSIONS_DIR="$HOME/IWE/{{GOVERNANCE_REPO}}/sessions"
TODAY=$(date +%Y-%m-%d)
MONTH=$(date +%Y-%m)
MONTH_DIR="$SESSIONS_DIR/$MONTH"
mkdir -p "$MONTH_DIR"
NUM=$(printf "%02d" $(( $(find "$MONTH_DIR" -maxdepth 1 -type d -name "${TODAY}-[0-9][0-9]-*" 2>/dev/null | wc -l | tr -d ' ') + 1 )))
```

Slug = первые 4 латинских слова из задачи строчными буквами через дефис (не-латиница и дата убираются). Никакой даты в slug — она уже в SESSION_ID. Если латиницы нет → `session`.

`SESSION_ID="${TODAY}-${NUM}-${SLUG}"`
`SESSION_DIR="${MONTH_DIR}/${SESSION_ID}"`

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
peer_agent: "kimi-headless"
peer_cmd: "kimi-peer-adapter"
peer_model: ""
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

**Если пилот не назначил роли** при запуске сессии — initiator в ход 0 предлагает свою роль и роль напарника (см. DP.SC.154 раздел «Opening сессии: Sequential role-discovery»). Discovery-ходes (0-2) **не входят** в `turns_limit: 10`.

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

**1.3 Добавить строку в `sessions/00-index.md`** сверху таблицы (первая строка таблицы после `|---|`):
```
| <TODAY> | <SESSION_ID> | <задача ≤50 симв> | claude-code / kimi | 0 | 0 | started | — |
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

<Моя начальная позиция — анализ задачи, тезисы, конкретные вопросы к напарнику.
НЕ пересказ задачи. Позиция с аргументами.>
```

Показать пилоту краткое резюме: что написал в 00-writer.md.

---

## Шаг 3. Turn loop

Переменные: `TURN=1`, `ESCALATIONS=0`, `DONE=false`.

### 3.1 Вызов Кими

Прочитать все предыдущие реплики из `SESSION_DIR` в порядке нумерации.
Составить промпт:

```
Ты — напарник (peer agent) в диалоговой сессии (DP.SC.154).
Сессия: <SESSION_ID>
Ход: <TURN> из 10
Задача: <задача>

Прочитай все файлы журнала в <SESSION_DIR> по порядку (00-writer.md, 01-peer.md, ...).

Напиши реплику в stdout с frontmatter:
---
turn: <TURN>
role: peer
agent_id: kimi-headless
timestamp: <ISO-8601 UTC>
consensus: none | proposed | reached | escalate
---

<Твой ответ>

Правило критика: найди ХОТЯ БЫ ОДИН тезис или допущение писателя, с которым не согласен. Не сдавайся после первого возражения — держись аргументированно. Если всё действительно ОК — объясни почему конкретно, не просто «согласен».

Маркеры (строго в начале строки):
CONSENSUS: <резюме> — если считаешь что договорились
ESCALATE_TO_USER: <причина> — если писатель игнорирует существенное возражение
```

Вызов Кими через Bash:
```bash
PEER_FILE="${SESSION_DIR}/$(printf '%02d' $TURN)-peer.md"
echo "<промпт>" | bash "$HOME/IWE/{{GOVERNANCE_REPO}}/scripts/kimi-peer-adapter.sh" \
  --add-dir "$SESSION_DIR" \
  2>/dev/null > "$PEER_FILE"
```

Если файл пустой или exit ≠ 0 → сообщить пилоту: «Kimi не ответил. Повторить или прервать?»

### 3.2 Показать пилоту

Прочитать `$PEER_FILE`. Вывести ключевые тезисы Кими (не всю реплику дословно — краткое резюме + цитаты ключевых позиций).

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
**Реплика Кими:** <PEER_FILE>
**Ответ пилота:** (ввести ниже)
```

- Сообщить пилоту: «Кими эскалирует: <причина>. Нужно твоё решение.»
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

<Моя реплика: ответ на аргументы Кими + учёт направления пилота>
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
git add <specific files — НЕ git add . и НЕ git add -u>
git commit -m "<type>(<scope>): <короткое описание>

Refs: peer-session <SESSION_ID>
Review iters: <REVIEW_ITER>
Verify: PASS"
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
- Создавать supplement-директории — `sessions/YYYY-MM/<id>/` = единое пространство.
- Продолжать писать `-writer.md`/`-peer.md` при `status: completed` — статус меняется только после Close-сигнала.

### 4.2b Стиль report.md (DP.SC.050)

> **Канал определяет стиль.** Turn-файлы (00-writer.md, 01-peer.md, ...) — технические, для агентов. report.md — разговорный, для пилота.
>
> При синтезе report.md из turn-файлов: **перепиши**, не копируй. Замени технические термины на бытовые (A1-A11), убери машинные маркеры (PASS, SHA, exit), переведи пассивный залог в активный.

Промпт субагенту:

```
Ты — синтезатор итогов диалога двух агентов (DP.SC.154).
Задача сессии: <задача>

Стиль: разговорный для пилота (A1-A11). Перепиши, не копируй turn-файлы.

Прочитай все файлы реплик в <SESSION_DIR> (00-writer.md, 01-peer.md, ...) в порядке нумерации.
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
peer: <из meta.yaml: peer_agent>
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

## 1. Исходная постановка
- **Задача:** <цитата из задания пилота, дословно>
- **Первоначальная позиция писателя:** <если зафиксирована в 00-writer.md; omit если нет>

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
- **Журнал:** ссылки на все NN-writer.md / NN-peer.md по порядку
- **Связанные артефакты:** Pack-IDs, файлы (PR, спецификации) — если упоминались
- **Стоимость:** $X (источник: api / estimated / missing) — omit если missing
```

### 4.3 Обновить sessions/00-index.md

Найти строку с `<SESSION_ID>` и заменить целиком:
```
| <TODAY> | <SESSION_ID> | <задача ≤50> | claude-code / kimi | <TURNS> | <ESCALATIONS> | completed | [report.md](<MONTH>/<SESSION_ID>/report.md) |
```
(Bash awk — безопасен для строк с `|`.)

### 4.4 Закрытие (ОРЗ — сессионный файл рядом с папкой сессии)

Slug-часть (без даты и номера): `SESSION_SLUG=$(echo "$SESSION_ID" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{2}-//')`

Записать `{{GOVERNANCE_REPO}}/sessions/<MONTH>/<TODAY>-<SESSION_SLUG>.md` (Write):
```markdown
---
date: <TODAY>
type: peer-session
writer: claude-code
peer: kimi-headless
duration_h: <(end_time - start_time) в часах, 1 знак>
artifacts: sessions/<MONTH>/<SESSION_ID>/report.md
session_id: <SESSION_ID>
wp: <WP-NNN или unknown>
---

# Главный инсайт

<1-2 строки из §4 report.md — зафиксированное решение>
```

### 4.5 Commit + push

```bash
cd "$HOME/IWE/{{GOVERNANCE_REPO}}"
git add "sessions/$MONTH/$SESSION_ID/"
git add "sessions/00-index.md"
git add "sessions/$MONTH/${TODAY}-${SESSION_SLUG}.md"
git commit -m "feat(peer): $SESSION_ID — <задача кратко>"
git push
```

Показать пилоту: «Сессия завершена. Отчёт: `sessions/$MONTH/$SESSION_ID/report.md`»

---

> Режимы `--interrupt`, `--finalize` и верификация → `.claude/skills/peer-conversation/modes.md`
