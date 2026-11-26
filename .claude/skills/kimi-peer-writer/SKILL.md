---
name: kimi-peer-writer
description: Peer-сессия DP.SC.154 где Kimi = писатель, напарник — параметр `--peer` (default Claude). Запускается простой фразой. Включает ОРЗ Opening и Closing, turn-loop, эскалации, Decision Gate (зафиксировать vs реализовать → ревью → проверить → задеплоить), отложенную финализацию и верификацию.
argument-hint: "<описание задачи> | --list | --interrupt <session_id> | --finalize <session_id>"
version: 1.4.2
layer: L1
status: active
browser_safe: false
triggers:
  slash: [/peer-writer]
  phrases:
    - "запусти диалог с Клодом"
    - "вместе с Клодом"
    - "с Клодом"
    - "привлеки Клода"
    - "скилл пир-сессия с Кими-писателем"
routing:
  executor: sonnet
  deterministic: false
agents: single
interaction: multi-step
gates_required: []
gates_enforced: []
gates_rationale: "операционный скилл; WP Gate применим только при создании нового РП, не для операционных вызовов"
audience: user
runs_on: [kimi]
---

# Kimi Peer Writer (DP.SC.154)

Задача: $ARGUMENTS

> **Архитектура:** я (Kimi) = писатель, напарник — параметр `--peer` (Шаг 0а.2, default `claude`).
> Напарник вызывается через свой `<vendor>-peer-adapter.sh` напрямую — Bash tool, stdin pipe.
> `list_peer_statuses` (Local Gateway) — координация файлов, **не** проверка доступности CLI напарника.
> Gateway offline ≠ напарник недоступен.

## Identity gate (БЛОКИРУЮЩЕЕ) — прочитать ДО Шага 0

> **WP-484 Ф93 (12.08).** Этот скилл написан для реального headless-процесса
> Kimi CLI (`~/.kimi-code/bin/kimi`) — не для Claude Code, читающего этот файл
> через `Skill` tool. Найдено живым инцидентом: Claude Code трижды исполнил
> этот скилл, играя роль «писателя-Kimi» текстом от первого лица, подписывая
> файлы `agent_id: kimi-headless`, ни разу не вызвав реальный `kimi` CLI —
> preflight-гейт ниже (`kimi-standalone-preflight.sh`) проверяет только
> «существует ли где-то живой семафор Kimi», не «является ли исполнитель этих
> инструкций сейчас тем же процессом». Технической проверки идентичности не
> существует (переменные окружения/PID подделываемы или ненадёжны — peer-session
> 2026-08-12-13-wp484-integration-collision-audit, живой Kimi это подтвердил).
>
> **Если ты — Claude Code, читающий этот файл через `Skill` tool: ОСТАНОВИСЬ.**
> Этот скилл не для тебя. У тебя есть симметричный `peer-conversation/SKILL.md`
> (Claude = писатель, Kimi/Codex/Hermes = напарник через реальный adapter-вызов)
> — используй его вместо этого.
>
> **Если ты — реальный процесс `kimi` CLI:** у тебя физически нет доступа к
> `Skill` tool Claude Code (это подтверждено в `peer-conversation/SKILL.md`:
> «Skill tool доступен только Claude в этой сессии») — сам факт того, что ты
> дочитал этот файл через `Skill` tool, а не через прямой вызов `kimi`
> бинарника, уже противоречит контракту. Продолжай только если ты запущен как
> `kimi` CLI напрямую (терминал, launchd, headless-вызов), не как Skill tool
> внутри Claude Code сессии.
>
> **Это не техническая защита** (текстовый gate обходим тем же способом, что
> уже был проигнорирован implicitly трижды) **— это explicit acknowledgement**,
> принуждающий момент остановки вместо молчаливого продолжения по инерции.
> Настоящее решение требует правки харнесса (Claude Code CLI / Kimi CLI),
> которым авторы этого репо не владеют — см. `inbox/WP-484/WP-484.md` Ф93 для
> нерешённых upstream-пунктов.

---

## When to use

Peer-сессия DP.SC.154 где Kimi = писатель, напарник — параметр `--peer` (default Claude). Запускается простой фразой. Включает ОРЗ Opening и Closing, turn-loop, эскалации, Decision Gate (зафиксировать vs реализовать → ревью → проверить → задеплоить), отложенную финализацию и верификацию.

## Scope boundary — не подменяет решения, зарезервированные за пилотом (найдено 2026-07-07)

> Peer-сессия пригодна для: технических решений, дизайна, code review, поиска компромисса между подходами, подготовки кандидатов к решению.
> **НЕ пригодна** для решений, которые процесс явно закрепляет за человеком (например, R15 Валидатор в `/apply-captures` — accept/reject/defer кандидатов знания; R1 Стратег — приоритеты месяца). Согласие двух агентов между собой — не решение пилота, даже единогласное и хорошо обоснованное.
>
> Если задача внутри пир-сессии требует такого решения — писатель обязан остановиться и спросить пилота напрямую в текущем чате (не через turn-файл), прежде чем фиксировать результат. См. `.claude/skills/apply-captures/SKILL.md` раздел «R15 = живой пилот, не агент» и `DS-strategy/inbox/bugs/bug-2026-07-07-r15-decisions-bypassed-pilot.md` — прецедент, из-за которого добавлено это ограничение.

## Шаг 0. Режим

Определить режим из `$ARGUMENTS`:

- `--list` → прочитать `$SESSIONS_DIR/00-index.md` (WP-526 Ф2), вывести таблицу. Стоп. `SESSIONS_DIR` — тем же общим выбором папки журнала, что в Шаге 1.
- `--interrupt <id>` → перейти к **Шагу 5 (interrupt-режим)**. Стоп после.
- `--finalize <id>` → перейти к **Шагу 6 (finalize-режим)**. Стоп после.
- Иначе → новая сессия, продолжать к Шагу 0б.

---

## Шаг 0а. Preflight Gate (WP-484 Ф33 item Г, обязательно ДО любых других действий)

Та же проверка, что `~/.kimi-code/skills/session-open/SKILL.md` уже делает для standalone-сессий Kimi (Ф33, 31.07) — до этой правки у пир-сессий Kimi-писателя не было НИКАКОЙ проверки, что сессия открыта честно (тот же класс дыры, что Ф28: закрытие пир-сессии сочло «у пир-сессии свой протокол» достаточным основанием и обошло вопрос-рефлексию). Скрипт поставляется шаблоном; звать по конвенции путей (#566 — фантомным был только хардкод `$HOME/IWE/scripts/...`, сам скрипт существует и входит в манифест):

`PEER_WP` — номер РП ЭТОЙ пир-сессии (из задания пилота; если неизвестен — сначала Шаг 0б, потом этот шаг). Preflight без `--wp` берёт «самый свежий» семафор Kimi, и пир-сессия по другому РП молча пишет в рабочую копию чужой сессии (инцидент WP-561, 26.10: пир-сессия по РП-568/538 писала в изолят РП-561). С `--wp` семафор должен быть открыт именно под этот РП и быть единственным; иначе СТОП — открыть собственную сессию (`session-guard.sh open --wp "$PEER_WP" --agent kimi --isolate`) и работать из её каталога. Если отказ — «несколько семафоров на один РП» (рядом живёт другая сессия того же РП), добавь к вызову `--slug` или `--session-id` СВОЕЙ сессии, не снимай `--wp`.

```bash
PREFLIGHT_OUT=$(bash "${IWE_SCRIPTS:-$HOME/IWE/scripts}/kimi-standalone-preflight.sh" --wp "$PEER_WP")
PREFLIGHT_STATUS=$?
printf '%s\n' "$PREFLIGHT_OUT"
```

`PREFLIGHT_OUT` захвачен (не просто выведен в терминал) — Шагу 0а.0б ниже нужна его `MARKER:`-строка, чтобы восстановить точный семафор без независимого `ls -t`.

- `PREFLIGHT_STATUS ≠ 0` (`ERROR: Kimi standalone session is NOT OPEN`) → **СТОП.** Не переходить к Шагу 0а.1 или 0б, не открывать WP Gate, не создавать `meta.yaml`/`00-writer.md`, не трогать файлы. Показать пилоту команду из stderr скрипта (`session-guard.sh open --wp WP-N --task "..." --agent kimi`) и ждать, пока сессия не будет открыта явно.
- `PREFLIGHT_STATUS = 0` (в т.ч. с предупреждением про устаревшую/stale-сессию) → продолжать к Шагу 0а.0б.

## Шаг 0а.0б. Постфактум-исправление `close_path` (WP-561 Ф9, пир-сессия 2026-09-12-06 с Claude)

`~/.kimi-code/skills/session-open/SKILL.md` (вне IWE-репозитория, не git) открывает семафор ДО того, как известно, что задание перерастёт в пир-сессию — пишет `close_path: unknown`, а не `close_path: peer-session`. `session-guard.sh close` и проверки перед коммитом читают `close_path` заново с диска в момент своего вызова, не из снимка при `open` — значит значение можно безопасно исправить здесь, сразу после того, как стало понятно, что это пир-сессия писателя Kimi, и до первого коммита.

Точный семафор восстанавливаем из `MARKER:`-строки, которую preflight уже вывел на предыдущем шаге (без независимого `ls -t` — тот выбрал бы «самый свежий» файл, а не обязательно тот же, что признал валидным preflight):

```bash
MARKER_LINES=$(grep -c '^MARKER: ' <<< "$PREFLIGHT_OUT")
SEM_FILE=""
if [ "$MARKER_LINES" -eq 1 ]; then
  MARKER_LINE=$(grep '^MARKER: ' <<< "$PREFLIGHT_OUT")
  SESSION_ID_FROM_MARKER=$(sed -E 's#.*kimi-standalone-(.*)\.marker$#\1#' <<< "$MARKER_LINE")
  CANDIDATE="${IWE_ROOT:-$HOME/IWE}/.iwe-runtime/sessions/kimi-${SESSION_ID_FROM_MARKER}.open"
  [ -n "$SESSION_ID_FROM_MARKER" ] && [ -f "$CANDIDATE" ] && SEM_FILE="$CANDIDATE"
fi
if [ -z "$SEM_FILE" ]; then
  echo "WARN: close_path-патч пропущен — не удалось однозначно восстановить семафор из вывода preflight (0 или >1 строк MARKER:, либо файл не найден)" >&2
elif grep -q '^close_path: unknown$' "$SEM_FILE" 2>/dev/null; then
  # flock — defensive: снижает, но не доказанно устраняет окно между этой
  # проверкой и записью (validation-to-use race), т.к. писатели вне IWE-репо
  # (~/.kimi-code/) не обязаны использовать тот же .lock-файл.
  (
    flock -x 9
    grep -q '^close_path: unknown$' "$SEM_FILE" 2>/dev/null || exit 0
    # `sed -i` без развилки BSD/GNU ломается на macOS (тот же класс,
    # что уже ловили в Ф136-B этого РП) — temp-file+mv портируем, как
    # уже сделано в peer-conversation/SKILL.md Шаг 4.1 для meta.yaml.
    tmpf=$(mktemp "${SEM_FILE}.XXXXXX") && sed 's/^close_path: unknown$/close_path: peer-session/' "$SEM_FILE" > "$tmpf" && mv "$tmpf" "$SEM_FILE"
    grep -q '^close_path: peer-session$' "$SEM_FILE" || echo "WARN: close_path-патч не подтвердился после записи" >&2
  ) 9>"$SEM_FILE.lock"
fi
```

Не трогаем: явные значения `close_path` кроме `unknown` (`pipeline`, `machine-publish-only` и т.п. — от планировщика/автоматики, перезаписывать нельзя); сам `~/.kimi-code/skills/session-open/SKILL.md` (не git, вне зоны деплоя этой сессии — открытый пункт «Осталось» РП-561: научить `session-open` принимать явный сигнал пир-режима, например `IWE_SESSION_CLOSE_PATH`, отдельная межрепозиторная сессия).

## Шаг 0а.1. Доставка личности (Кир, WP-510 Ф22)

Та же доставка, что `~/.kimi-code/skills/session-open/SKILL.md` шаг 1 делает для standalone-сессий Kimi — здесь нужна отдельно, т.к. `session-open` на пир-сессии не распространяется (см. его собственное «Scope: не peer-сессии»):

```bash
[ ! -f "${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/resolve-personality-by-host.py" ] || \
"$(bash "${IWE_SCRIPTS:-$HOME/IWE/scripts}/lib/find-python3.sh" --stdlib-only)" "${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/resolve-personality-by-host.py" \
  --registry "${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/current/AI Personalities Registry.md" \
  --hostname "$(hostname)" --runtime-id kimi-code-local
```

- `status: matched` → показать пилоту ПЕРВЫМ, отдельным блоком до 00-writer.md (источник текста — вывод резолвера, не суждение агента о себе; значения `<personality_id>`/`<relation>` — буквально то, что вернул резолвер, без подстановки своего имени, если резолвер вернул другое или ошибся):

  ```text
  [Runtime context / personality_id delivery]
  Рантайм: personality_id = <personality_id> (relation: <relation>)
  — Личность назначена внешним резолвером (resolve-personality-by-host.py), не выбрана агентом.
  — Это только маршрутизирующая метка: не паспорт, не грант полномочий, не разрешение атрибутировать коммиты (никаких Co-Authored-By и подобного) от имени этой личности, и не решение о повторной активации.
  — Полный паспорт — только по явному запросу через штатный сборщик.
  [Конец контекста]
  ```
- Любой другой статус (`no_match`, `ambiguous`, ошибка резолвера) → пропустить блок молча, не блокировать сессию (best-effort, как у Элара и Кориса).
- Продолжать к Шагу 0а.2.

## Шаг 0а.2. Напарник: параметр `--peer` (WP-516 Ф5)

Извлечь `--peer <vendor>` из `$ARGUMENTS`. Нет флага → `PEER_VENDOR=claude` (обратная совместимость с версиями до параметризации).

**Маппинг вендоров** (явный, локальный для этого скилла; обязан быть согласован с реестром §0в `peer-conversation/SKILL.md` — норма OwnerIntegrity из §0в.1, расхождение = дефект; runtime-чтение чужого SKILL.md НЕ допускается):

| `PEER_VENDOR` | Адаптер (`ADAPTER`) | `PEER_AGENT_ID` (meta.yaml) | `PEER_CMD` | Модель по умолчанию |
|---|---|---|---|---|
| `claude` | `scripts/claude-peer-adapter.sh` | `claude-code` | `claude-peer-adapter` | sonnet |
| `codex` | `scripts/codex-peer-adapter.sh` | `codex` | `codex-peer-adapter` | — (дефолт CLI) |
| `hermes` | `scripts/hermes-peer-adapter.sh` | `hermes` | `hermes-peer-adapter` | — |
| `grok` | `scripts/grok-peer-adapter.sh` | `grok` | `grok-peer-adapter` | — (дефолт CLI) |

Неизвестный vendor → СТОП до создания сессии: «Напарник `<vendor>` не зарегистрирован. Известные: claude, codex, hermes, grok.» Добавление вендора = правка реестра §0в peer-conversation + этой таблицы одним коммитом (OwnerIntegrity, §0в.1).

Особенности по вендору (учитывать в turn-loop и промптах):
- `claude`: усиленный text-only контракт WP-458 — `--add-dir` запрещён адаптером; контекст только текстовой проекцией в stdin.
- `codex`: read-only sandbox всегда (§0в.1); `--add-dir` даёт чтение отфильтрованной копии, не запись.
- `hermes`: не поддерживает `--model`/`--add-dir`; лимит промпта 4000 символов — адаптер откажет с диагностикой (§0в.1, сохранность промпта): сокращай текстовую проекцию заранее. Поддерживает `--session-id`.
- `grok`: только read-only участник (АрхГейт WP-530 Ф51): `--sandbox read-only`+`--tools ""` зашиты адаптером; `--add-dir` — отфильтрованная копия (PII/.agentigore). Реплики помечать пилоту как «непроверенный критик» на первых сессиях.

Дальше по скиллу `$PEER_VENDOR` / `$PEER_AGENT_ID` / `$ADAPTER` / модель напарника подставляются из этой таблицы вместо прежних упоминаний Claude.

**Где искать адаптер (`<ADAPTER_PATH>` ниже).** Адаптеры поставляются в папке программ шаблона (issues #830, #1513); у автора шаблона их рабочие копии живут в репозитории управления. Цепочка: копия в репозитории управления, если она есть, иначе папка шаблона. Вычислить один раз и подставлять готовый путь:

```bash
ADAPTER_PATH="${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/$ADAPTER"
[ -x "$ADAPTER_PATH" ] || ADAPTER_PATH="${IWE_TEMPLATE:-${IWE_WORKSPACE:-$HOME/IWE}/FMT-exocortex-template}/$ADAPTER"
echo "адаптер: ${ADAPTER_PATH}" >&2
```

## Шаг 0б. Открытие (WP Gate — только для новой сессии)

Найти WP по задаче: прочитать `${IWE_GOVERNANCE_REPO:-DS-strategy}/WP-REGISTRY.md` (grep по ключевым словам) и `${IWE_GOVERNANCE_REPO:-DS-strategy}/current/WeekPlan W{N}.md`.

После нахождения РП, до выбора фазы выполнить Sync Gate — тот же вызов и разбор exit-кодов, что в `memory/protocol-open.md` Шаг 3a и в `peer-conversation/SKILL.md` §0б (РП-484 Ф224, 22.10 — эта секция до правки не вызывала Sync Gate вообще, не только словесно, а никак):

```bash
bash "${IWE_WORKSPACE:-$HOME/IWE}/.claude/scripts/wp-sync-bundle.sh" WP-N > /tmp/wp-sync-bundle-$$.md; BUNDLE_RC=$?; head -3 /tmp/wp-sync-bundle-$$.md; echo "bundle_rc=$BUNDLE_RC"
```

Разбор `BUNDLE_RC` и `CARD_SOURCE` — та же таблица, что в `memory/protocol-open.md` Шаг 3a. Прочитать секцию «## Последний отчёт сессии этого РП» из вывода — первоисточник report.md последней сессии, не пересказ из карточки; отдельно проверить отчёты текущего дня по этому РП в `MC-sessions`. `rm -f /tmp/wp-sync-bundle-$$.md` после использования. Exit 3 (свежесть не подтверждена) — переход в изолированную копию, по отстающей локальной карточке фазу не выбирать.

Анонс пилоту:
```
Открываю peer-сессию (DP.SC.154)
Роль: Писатель (Kimi) | Напарник: <PEER_VENDOR>
Задача: <задача>
РП: WP-NNN «<название>» | или: не найден в плане
Метод: turn-loop ≤10 ходов | Модель напарника: <из таблицы Шага 0а.2 или «дефолт CLI»>
```

Если РП **не найден** в плане недели → полный WP Gate Ритуал (`memory/protocol-open.md §Сессия`):
объявить артефакт + дождаться подтверждения пилота → **только после «да» переходить к Шагу 1**.

Если РП найден → продолжать без ожидания.

---

## Шаг 1. Инициализация

```bash
# Journal folder: the shared resolver used by session-guard.sh (explicit IWE_SESSIONS_ROOT,
# then $IWE_WORKSPACE/MC-sessions, then the legacy sessions/ folder of the governance repo).
IWE_COMMON="${IWE_SCRIPTS:-$HOME/IWE/scripts}/lib/common.sh"
[ -f "$IWE_COMMON" ] || IWE_COMMON="${IWE_TEMPLATE:-${IWE_WORKSPACE:-$HOME/IWE}/FMT-exocortex-template}/scripts/lib/common.sh"
. "$IWE_COMMON"
SESSIONS_DIR=$(IWE_ROOT="${IWE_ROOT:-${IWE_WORKSPACE:-$HOME/IWE}}" iwe_sessions_dir) \
  || { echo "папка журнала сессий не найдена (задан недоступный IWE_SESSIONS_ROOT?)" >&2; exit 1; }
TODAY=$(date +%Y-%m-%d)
MONTH=$(date +%Y-%m)
DAY=$(date +%d)
DAY_DIR="$SESSIONS_DIR/$MONTH/$DAY"
mkdir -p "$DAY_DIR"
# Порядок резолва: настроенный каталог скриптов, затем корневой чекаут. На
# хостах, где IWE_SCRIPTS указывает на копию шаблона, она может отставать.
RESERVE="${IWE_SCRIPTS:-$HOME/IWE/scripts}/session-dir-reserve.sh"
[ -x "$RESERVE" ] || RESERVE="${IWE_TEMPLATE:-${IWE_WORKSPACE:-$HOME/IWE}/FMT-exocortex-template}/scripts/session-dir-reserve.sh"
SESSION_ID=$(bash "$RESERVE" "$DAY_DIR" "$TODAY" "$SLUG") || { echo "резервация номера сессии не удалась (см. stderr выше)" >&2; exit 1; }
SESSION_DIR="${DAY_DIR}/${SESSION_ID}"
```

Slug = первые 4 латинских слова из задачи строчными буквами через дефис (не-латиница и дата убираются). Никакой даты в slug — она уже в SESSION_ID. Если латиницы нет → `session`.

Номер выдаёт **скрипт, а не инлайновый bash** (WP-530, пир-сессия `2026-09-05-24` с Kimi). Прежняя формула `find | wc -l + 1` с последующим `mkdir -p` давала две ошибки: гонку (две сессии в узком окне получали один номер, `mkdir -p` не отказывает на существующем каталоге — и обе молча писали журнал в один каталог) и перевыдачу номера после любой уборки (`count+1` ≠ `max+1`). Живой прогон 12 одновременных писателей на старой формуле: 12 сессий, 6 уникальных номеров. Скрипт отказал (exit ≠ 0) → СТОП, сообщить пилоту причину из stderr; ручная подстановка номера возвращает ровно ту гонку, ради которой скрипт написан.

**1.1 Каталог сессии уже создан** — его создаёт `session-dir-reserve.sh` в тот же момент, когда выигрывает номер. Отдельный `mkdir -p` здесь был бы не просто лишним: он маскирует отказ резервации (создаёт каталог под номером, который скрипт не выдавал).

**1.2 Записать `meta.yaml`** (Write):
```yaml
task_id: ""
date: "<TODAY>"
session_id: "<SESSION_ID>"
start_time: "<ISO-8601 UTC>"
end_time: ""
writer_agent: "kimi-headless"
peer_agent: "<PEER_AGENT_ID из Шага 0а.2>"
peer_cmd: "<PEER_CMD из Шага 0а.2>"
peer_model: "<модель из Шага 0а.2 или \"\" = дефолт CLI>"
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

**1.3 Записать открывающую запись в индекс-черновик** (WP-537 Ф4: `00-index.md` в MC-sessions (WP-526 Ф2) больше не пишется напрямую — session-index-snapshot.sh единственный писатель git-tracked файла, все остальные пишут в свой runtime-черновик, см. `scripts/lib/session-index-draft.sh`):
```bash
IDX_LIB="${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/lib/session-index-draft.sh"
[ -f "$IDX_LIB" ] || IDX_LIB="${IWE_TEMPLATE:-${IWE_WORKSPACE:-$HOME/IWE}/FMT-exocortex-template}/scripts/lib/session-index-draft.sh"
. "$IDX_LIB"
session_index_draft_write "$SESSION_ID" "$TODAY" "<задача ≤50 симв>" \
  "kimi / <PEER_AGENT_ID>" "0" "0" "started" "—"
```

Установка без переносчика черновиков в индекс (программы session-index-snapshot.sh в папке программ репозитория управления; так у пользователей шаблона) — черновик никто не перенесёт, поэтому ещё и вести `00-index.md` напрямую, как до WP-537 (файла нет → создать, issue #568; строку сессии заменить по `SESSION_ID` или вставить первой в таблицу):
```bash
if [ ! -f "${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/session-index-snapshot.sh" ]; then
  IDX="$SESSIONS_DIR/00-index.md"
  [ -f "$IDX" ] || printf '%s\n' '# Индекс пир-сессий' '' \
    '| Дата | Сессия | Задача | Агенты | Ходы | Эскалации | Статус | Отчёт |' \
    '|------|--------|--------|--------|------|-----------|--------|-------|' > "$IDX"
  ROW="| $TODAY | $SESSION_ID | <задача ≤50 симв> | kimi / <PEER_AGENT_ID> | 0 | 0 | started | — |"
  if grep -qF "| $SESSION_ID |" "$IDX"; then
    ID="| $SESSION_ID |" ROW="$ROW" awk 'index($0, ENVIRON["ID"]) { print ENVIRON["ROW"]; next } { print }' "$IDX" > "$IDX.tmp"
  else
    ROW="$ROW" awk '{ print } /^\|------/ && !done { print ENVIRON["ROW"]; done = 1 }
      END { if (!done) print ENVIRON["ROW"] }' "$IDX" > "$IDX.tmp"
  fi
  mv "$IDX.tmp" "$IDX"
fi
```
В этом режиме `00-index.md` идёт в коммит сессии (Шаг 4.5) вместе с её файлами.

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

После записи содержимого обоих файлов связать журнал с уже открытым семафором
Kimi. Пока `meta.yaml` или `00-writer.md` пуст, связь не заявлять: проверка
закрытия принимает только заполненную пару из одной папки. Использовать
`$SEM_FILE`, выбранный в Шаге 0а, а не угадывать самый свежий семафор.

```bash
[ -n "$SEM_FILE" ] && [ -f "$SEM_FILE" ] || { echo "семафор Kimi не определён" >&2; exit 1; }
GUARD_SESSION_ID=$(sed -n 's/^session_id: //p' "$SEM_FILE")
[ -n "$GUARD_SESSION_ID" ] || { echo "в семафоре нет session_id" >&2; exit 1; }
for PEER_CORE_FILE in "$SESSION_DIR/meta.yaml" "$SESSION_DIR/00-writer.md"; do
  [ -s "$PEER_CORE_FILE" ] || { echo "пир-журнал ещё не заполнен: $PEER_CORE_FILE" >&2; exit 1; }
  IWE_AGENT=kimi bash "${IWE_SCRIPTS:-$HOME/IWE/scripts}/session-guard.sh" \
    note-file "$PEER_CORE_FILE" --agent kimi --wp "$PEER_WP" \
    --session-id "$GUARD_SESSION_ID" || exit 1
done
```

Показать пилоту краткое резюме: что написал в 00-writer.md.

---

## Шаг 3. Turn loop

Переменные: `TURN=1`, `ESCALATIONS=0`, `DONE=false`.

### 3.1 Вызов напарника

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

Перед вызовом напарника писатель добавляет в промпт минимальную текстовую проекцию предыдущих реплик и фактов. Напарник не читает `SESSION_DIR` и не использует инструменты.

Вызов напарника через Bash (адаптер — из таблицы Шага 0а.2):
```bash
PEER_FILE="${SESSION_DIR}/$(printf '%02d' $TURN)-peer.md"
echo "<промпт>" | IWE_PEER_PLAIN=0 bash "<ADAPTER_PATH>" \
  > "$PEER_FILE" 2> "${PEER_FILE%.md}.err"
PEER_RC=$?   # captured before the .err block below, which resets $?
```

**Файл ошибок напарника (`NN-peer.err`, РП-524 Ф7, 20.11).** Журнал сессий игнорирует `**/*.err` (`.gitignore` журнала, решение 10.09), поэтому stderr адаптера в историю не попадает. Сразу после вызова:
1. Строку `INTEGRITY-WARNING:` (адаптер подозревает потерю целого сообщения в ответе) показать пилоту, реплику не считать полной (перезапросить ход или сверить с журналом сессии напарника) и перенести факт и текст предупреждения в свою следующую реплику или §5 отчёта: ссылка на `.err` потеряется.
2. Пустой `.err` можно удалить, это необязательная уборка.
3. `.err` никогда не передавать в `git add`/`git commit` явным путём; список файлов для коммита — по Шагу 4.5.

```bash
ERR_FILE="${PEER_FILE%.md}.err"
if grep -q '^INTEGRITY-WARNING:' "$ERR_FILE" 2>/dev/null; then
  echo "ЦЕЛОСТНОСТЬ: адаптер сообщил о возможной потере целого сообщения в ответе напарника." >&2
  grep '^INTEGRITY-WARNING:' "$ERR_FILE" >&2
fi
[ -s "$ERR_FILE" ] || rm -f "$ERR_FILE"
```

Те же три правила — для файлов ошибок ревью (`review-NN.err`, Шаг 3.6.2) и проверки (`verify-01.err`, Шаг 3.6.4).

Если файл пустой или `PEER_RC` ≠ 0 → сообщить пилоту: «<PEER_VENDOR> не ответил. Повторить или прервать?»

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
agent_id: kimi-headless
timestamp: <now>
consensus: none
---

<Моя реплика: ответ на аргументы напарника + учёт направления пилота>
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
  А. Только зафиксировать → report-draft.md и остановка. Закрытие сессии — отдельное решение, только по слову пилота «закрывай»; выбор этого варианта слова о закрытии не заменяет.
     Реализация — отдельный РП/фаза при следующей сессии.
  Б. Реализовать сейчас → ревью → проверить → задеплоить → остановка; закрытие — только по слову пилота «закрывай».
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
> **Принцип:** Kimi-writer применяет решение → cold-context напарник через bash pipe делает code review → writer фиксит → напарник через bash pipe запускает smoke (writer не имеет Skill tool) → deploy → секция «Реализация и проверка» в report-draft.md.
> **Архитектурное ограничение:** Kimi-headless не имеет Agent/Skill tools. Все вызовы внешних агентов идут через `<ADAPTER>` из Шага 0а.2 (stdin pipe) — это осознанная асимметрия с `/peer-conversation`.

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

Вызов напарника как code reviewer через тот же адаптер что для turn-loop:

Каталог для промптов создать один раз: `mkdir -p "${IWE_WORKSPACE:-$HOME/IWE}/.iwe-runtime/peer-prompts"`. Промпт собирается **в файл инструментом записи файлов (WriteFile/Write), не через оболочку**: в диф и фрагменты кода попадают обратные кавычки, `$(...)` и строки `EOF`, которые в heredoc или в двойных кавычках выполнятся или оборвут текст. Путь файла: `${IWE_WORKSPACE:-$HOME/IWE}/.iwe-runtime/peer-prompts/<SESSION_ID>-review-NN.txt`. Содержимое — шаблон ниже с подставленными значениями:

```text
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
```

Вместо `<CHANGED_FILES>` писатель вставляет точечный diff и нужные фрагменты файлов. Нельзя передавать каталоги: напарник получает только текстовую проекцию. Затем — в оболочку только пути:

```bash
: "${REVIEW_ITER:=1}"
REVIEW_FILE="${SESSION_DIR}/review-$(printf '%02d' "$REVIEW_ITER").md"
REVIEW_PROMPT_FILE="${IWE_WORKSPACE:-$HOME/IWE}/.iwe-runtime/peer-prompts/<SESSION_ID>-review-$(printf '%02d' "$REVIEW_ITER").txt"
IWE_PEER_PLAIN=1 bash "<ADAPTER_PATH>" \
  < "$REVIEW_PROMPT_FILE" > "$REVIEW_FILE" 2> "${REVIEW_FILE%.md}.err"
REVIEW_RC=$?
# .err rules of step 3.1 (WP-524 F7): surface INTEGRITY-WARNING, optional empty-file cleanup.
grep '^INTEGRITY-WARNING:' "${REVIEW_FILE%.md}.err" >&2 2>/dev/null || :
[ -s "${REVIEW_FILE%.md}.err" ] || rm -f "${REVIEW_FILE%.md}.err"
# A failed adapter leaves an empty review; it must not read as "no findings".
[ "$REVIEW_RC" -eq 0 ] && [ -s "$REVIEW_FILE" ] \
  || { echo "ревью не получено (код адаптера $REVIEW_RC)" >&2; exit 1; }
```

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

### 3.6.4 Smoke Verification (через bash pipe к напарнику)

Kimi-writer не имеет Skill tool, а напарник в этом вызове не имеет файловых инструментов и ничего не запускает: он оценивает переданный текст по правилам `/verify` (формат вердикта, условие опровержения). Исполняемые проверки (тесты, smoke) писатель запускает сам локально и вставляет их вывод в промпт как свидетельство.

1. Условие опровержения — инструментом записи файлов в `${IWE_WORKSPACE:-$HOME/IWE}/.iwe-runtime/peer-prompts/<SESSION_ID>-verify.condition.txt`, по одному условию на строку (для каждого инварианта — какое наблюдаемое его нарушило бы, с якорем: код в обратных кавычках, путь, строка, файл:N). Проверить:

```bash
[ -f "${IWE_WORKSPACE:-$HOME/IWE}/.claude/skills/verify/falsification_lint.py" ] || echo "программы проверки условий на этой установке нет — условие сверить по правилам /verify самому" >&2
[ ! -f "${IWE_WORKSPACE:-$HOME/IWE}/.claude/skills/verify/falsification_lint.py" ] || "$(bash "${IWE_SCRIPTS:-$HOME/IWE/scripts}/lib/find-python3.sh" --stdlib-only)" "${IWE_WORKSPACE:-$HOME/IWE}/.claude/skills/verify/falsification_lint.py" condition \
  < "${IWE_WORKSPACE:-$HOME/IWE}/.iwe-runtime/peer-prompts/<SESSION_ID>-verify.condition.txt"
```

Код 1 → исход NOT_VERIFIABLE (условие не сформулировано), напарника не вызывать. Код 2 → NOT_VERIFIABLE «проверочная программа недоступна». Программы нет на установке (шаблон) → писатель сам сверяет условие с правилами `/verify` (у каждой строки свой якорь) и продолжает.

2. Промпт — инструментом записи файлов в `${IWE_WORKSPACE:-$HOME/IWE}/.iwe-runtime/peer-prompts/<SESSION_ID>-verify.txt`, не через оболочку:

```text
КРИТИЧНО: НЕ используй Write/Edit. Весь твой ответ = один отчёт в stdout.

Проверка результатов peer-сессии <SESSION_ID> по правилам /verify (режим code). Ты оцениваешь только переданный ниже текст, ничего не запускаешь.

Изменённые файлы (диф и фрагменты):
<CHANGED_FILES>

Вывод проверок, запущенных писателем (тесты, smoke):
<вывод команд>

Инварианты консенсуса:
<list from 3.5>

Условие опровержения (дословно, не меняй):
<содержимое файла условия>

Верни ровно в формате:
## Verdict: PASS | CONDITIONAL | FAIL | UNKNOWN
### Условие опровержения
<дословно>
### Что проверено
<какие свидетельства из текста выше ты прочитал — без выводов>
### Несоответствия
| # | Severity | Файл | Строка | Что |
### Сводка
- **Критических:** N
- **Высоких:** N
[для UNKNOWN] **Недостающее свидетельство:** … / **Как получить:** …
Правила: FAIL — сработало условие опровержения или есть критическое; UNKNOWN — критических нет, но по переданному тексту нельзя решить условие; CONDITIONAL — есть высокие, исправимые без новых свидетельств; PASS — ничего из этого. Старшинство: FAIL > UNKNOWN > CONDITIONAL > PASS (высокие при нерешённом условии → UNKNOWN). Severity в таблице — словами: критический / высокий / средний / низкий.
```

3. Вызов и проверка ответа — в оболочку только пути:

```bash
VERIFY_FILE="${SESSION_DIR}/verify-01.md"
IWE_PEER_PLAIN=1 bash "<ADAPTER_PATH>" \
  < "${IWE_WORKSPACE:-$HOME/IWE}/.iwe-runtime/peer-prompts/<SESSION_ID>-verify.txt" \
  > "$VERIFY_FILE" 2> "${VERIFY_FILE%.md}.err"
VERIFY_RC=$?
# .err rules of step 3.1 (WP-524 F7): surface INTEGRITY-WARNING, optional empty-file cleanup.
grep '^INTEGRITY-WARNING:' "${VERIFY_FILE%.md}.err" >&2 2>/dev/null || :
[ -s "${VERIFY_FILE%.md}.err" ] || rm -f "${VERIFY_FILE%.md}.err"
# A failed adapter leaves no verdict: outcome NOT_VERIFIABLE, the verdict program is not run.
[ "$VERIFY_RC" -eq 0 ] && [ -s "$VERIFY_FILE" ] \
  || { echo "NOT_VERIFIABLE: проверка не получена (код адаптера $VERIFY_RC)" >&2; exit 1; }
[ -f "${IWE_WORKSPACE:-$HOME/IWE}/.claude/skills/verify/falsification_lint.py" ] || echo "программы проверки вердикта на этой установке нет — исход прочитать из $VERIFY_FILE по правилам выше" >&2
[ ! -f "${IWE_WORKSPACE:-$HOME/IWE}/.claude/skills/verify/falsification_lint.py" ] || "$(bash "${IWE_SCRIPTS:-$HOME/IWE/scripts}/lib/find-python3.sh" --stdlib-only)" "${IWE_WORKSPACE:-$HOME/IWE}/.claude/skills/verify/falsification_lint.py" verdict \
  --condition-file "${IWE_WORKSPACE:-$HOME/IWE}/.iwe-runtime/peer-prompts/<SESSION_ID>-verify.condition.txt" \
  < "$VERIFY_FILE"
```

`VERIFY_RC` ≠ 0 или пустой `$VERIFY_FILE` → блок останавливается до программы вердикта, исход NOT_VERIFIABLE «проверка не получена». Код 1: напарник вернул FAIL → исход FAIL (провал не понижается), нарушения оформления перечислить; иначе → исход NOT_VERIFIABLE «вердикт невалиден: <вывод программы>». Код 2 → NOT_VERIFIABLE «проверочная программа недоступна».

**Результат (все пять исходов `/verify`, ни один не трактуется молча как другой):**
- PASS → перейти к 3.6.5.
- CONDITIONAL → показать пилоту высокие замечания, спросить «фиксить сейчас или деплоить с ними?»; без ответа к 3.6.5 не переходить.
- FAIL → показать traceback пилоту, спросить «фиксить и повторить или escalate?»
  - «фиксить» → Edit → вернуться к 3.6.2 (review после фиксов) или 3.6.4 (если фикс точечный, по согласию пилота).
  - «escalate» → ESCALATE_TO_USER + escalation-NN.md.
- UNKNOWN → не подтверждено, но и не провал: показать пилоту «Недостающее свидетельство» и «Как получить»; добыть свидетельство и повторить 3.6.4, либо пилот явно принимает деплой без него.
- NOT_VERIFIABLE → проверка не поставлена: показать «Причину» (обычно — условие опровержения не сформулировано); переформулировать условие и повторить 3.6.4. Не FAIL артефакта, не PASS.

### 3.6.5 Deploy

Для каждого репо в списке изменённых файлов. Сообщение коммита сначала записать инструментом записи файлов (не через оболочку) в `${IWE_WORKSPACE:-$HOME/IWE}/.iwe-runtime/peer-prompts/<SESSION_ID>-commit-msg.txt`:

```text
<type>(<scope>): <короткое описание>

Refs: peer-session <SESSION_ID>
Review iters: <REVIEW_ITER>
Verify: <вердикт /verify из 3.6.4: PASS | CONDITIONAL (принято пилотом) | UNKNOWN (деплой без свидетельства принят пилотом)>
```

```bash
cd <repo path>
git status --short
# pathspec после `--`: commit ТОЛЬКО свои файлы. Bare `git commit` сметает
# чужое pre-staged из общего индекса (mis-attribution, см. 2026-06-20-39).
git add <specific files — НЕ git add . и НЕ git add -u>
# Message text is written to a file with a file-writing tool, never inlined in
# double quotes: backticks and $(...) in a description would be executed.
git commit -F "${IWE_WORKSPACE:-$HOME/IWE}/.iwe-runtime/peer-prompts/<SESSION_ID>-commit-msg.txt" -- <те же specific files>

# WP-537: заявить свой коммит в семафоре сессии. Без этой строки закрытие
# проверяет «моя работа опубликована» по состоянию ВСЕЙ ветки, и один
# непушенный коммит соседней сессии отклоняет честную заявку. Только здесь —
# Шаг 4.5 (PR-flow на отдельной ветке) сознательно не трогаем по той же
# причине, по которой его не тронул WP-530 Ф9: коммит там уходит в ветку под
# PR, и заявлять его как «доставленный в main» было бы ложным свидетельством
# до слияния.
# `-C "$NC_ROOT"` явно, не полагаясь на `cd` выше: верхнеуровневый `cd` в этом
# репозитории блокирует собственный PreToolUse-хук (destructive-guard.sh), и
# без явного корня агент, переписывающий блок под `git -C`, получил бы HEAD
# текущего каталога вызова, а не репозитория деплоя (найдено холодным ревью
# этой же сессии). `--agent kimi`: сессия открыта под этим агентом (Шаг 0),
# без флага `note-commit` не находит свой семафор и no-op'ится молча.
NC_ROOT=$(git -C <repo path> rev-parse --show-toplevel)
NOTE_COMMIT="${IWE_SCRIPTS:-$HOME/IWE/scripts}/session-guard.sh"
[ -x "$NOTE_COMMIT" ] || NOTE_COMMIT="${IWE_WORKSPACE:-$HOME/IWE}/scripts/session-guard.sh"
if ! bash "$NOTE_COMMIT" note-commit "$(git -C "$NC_ROOT" rev-parse HEAD)" \
       --repo "$(basename "$NC_ROOT")" --agent kimi --slug "$SESSION_ID"; then
  echo "WARN: коммит не заявлен в семафоре — закрытие сессии проверится по всей ветке" >&2
fi
```

**Публикация — через общий шлюз координации, не голым `git push`** (WP-530 Ф9, 19.08, пир-сессия Клода с Codex: голый push здесь обходил тот же `ds-publish.sh`, которым уже пользуются quick-close/day-close/week-close/month-close/day-open — живой тест 18.08 дал 7 из 8 конфликтов при параллельной интерактивной записи без него). Шаг 4.5 этого же скилла (закрытие сессии) прежде шёл отдельным путём (feature-branch + `gh pr create --auto-merge`, WP-436 Ф2); с 21.09 (WP-484) он публикует свои коммиты через тот же шлюз с `--exact-commit`, потому что ветка `peer/<id>` оставляла общий checkout MC-sessions не на `main`. `REPO_ROOT` — обязательно через `git rev-parse --show-toplevel`, не сырой путь:

```bash
REPO_ROOT=$(git -C "<repo path>" rev-parse --show-toplevel)
. "${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/lib/publish-gate.sh"
SHA=$(git -C "$REPO_ROOT" rev-parse HEAD)
# normal по умолчанию; high — ТОЛЬКО если пилот на Decision Gate (Шаг 3.5)
# явно пометил реализацию как срочную.
PRIORITY="normal"
if is_ds_repo_by_origin "$REPO_ROOT"; then
    publish_commit "$REPO_ROOT" "$SHA" "$PRIORITY" "peer-session <SESSION_ID> (kimi-writer) deploy" \
        || { echo "publish_commit не удался — см. stderr/Telegram-алерт ds-publish.sh" >&2; exit 1; }
else
    push_branch "$REPO_ROOT"
fi
```

> **Код возврата обязателен, не только текст в stderr** (найдено холодным ревью Ф9): `exit 1` в конце `||`-блока — обязательная часть паттерна, иначе последней командой ветки оказывается всегда-успешный `echo`, и упавшая публикация выглядит завершившейся успешно.

Записать commit SHA для каждого репо в `DEPLOY_SHAS` (map: repo → sha).

**Если commit/publish fail:**
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

> **Почему здесь:** пир-сессия — тоже сессия работы, вопрос рефлексии обязателен так же, как и в обычной Quick Close (Ф18) — этот же разрыв найден и закрыт 30.07 в `peer-conversation/SKILL.md` (Claude-писатель); здесь тот же фикс для симметричного случая (Kimi-писатель). Порог и формулировка идентичны — напарник остаётся тем, у кого есть живой канал с пилотом и доступ к Skill/Bash, поэтому шаг ниже исполняет напарник, не писатель.

**Порог:** та же формула, что в `peer-conversation/SKILL.md` §3.7 (переиспользует починенный в `gather-session-facts.sh`, WP-484 Ф26, разбор даты — не изобретать заново):
```bash
START_TIME=$(grep '^start_time:' "$SESSION_DIR/meta.yaml" | sed -E 's/^start_time: *"?([^"]*)"?$/\1/')
NOW_EPOCH=$(date -u +%s)
START_EPOCH=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$START_TIME" +%s 2>/dev/null \
    || date -u -d "$START_TIME" +%s 2>/dev/null \
    || echo "$NOW_EPOCH")
DURATION_MIN=$(( (NOW_EPOCH - START_EPOCH) / 60 ))
```
Если `DURATION_MIN ≤ 45` — пропустить, перейти к Шагу 4 молча.

Если `duration_min > 45` (порог поднят с 30 решением пилота 18.10, `CONCEPT-night-cycle.md §23`):

1. Показать пилоту краткий итог (2-3 строки, суть сессии, не пересказ turn-файлов).
2. Спросить: «Что в этой сессии стоит запомнить на будущее — не про саму задачу, а про то, как шла работа?» (дословно Ф18, `CONCEPT-night-cycle.md §18`).
3. Записать ответ (issue #409: скрипт есть не на каждой установке — не блокировать при отсутствии):
   ```bash
   LEDGER_SCRIPT="${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/ledger-append.sh"
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

> **Архитектурное ограничение:** Kimi-писатель использует bash pipe через `<ADAPTER>` из Шага 0а.2, т.к. Kimi не имеет доступа к Agent tool. Claude-писатель (скилл `/peer-conversation`) использует Agent tool — это осознанное различие, а не дрейф.

Запустить напарника как синтезатора через bash pipe (context isolation через stdin):
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
# Session adapter from meta.yaml peer_cmd (WP-516 F5): governance repo copy first,
# else the template's scripts/ (issue #1513).
workspace = os.environ.get('IWE_WORKSPACE') or os.path.join(os.path.expanduser('~'), 'IWE')
adapter_name = meta.get('peer_cmd', 'claude-peer-adapter') + '.sh'
adapter = os.path.join(workspace, gov_repo, 'scripts', adapter_name)
if not os.access(adapter, os.X_OK):
    template_dir = os.environ.get('IWE_TEMPLATE') or os.path.join(workspace, 'FMT-exocortex-template')
    adapter = os.path.join(template_dir, 'scripts', adapter_name)

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
                env={**os.environ, 'IWE_PEER_PLAIN': '1'},  # synth output — не peer-реплика (§0в.1)
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
note: синтез не выполнен (напарник недоступен, вернул пустой результат, или таймаут >180с)
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
- Создавать supplement-директории — `$SESSIONS_DIR/YYYY-MM/DD/<id>/` (MC-sessions) = единое пространство.
- Продолжать писать `-writer.md`/`-peer.md` при `status: completed` — статус меняется только после Close-сигнала.

### 4.3 Обновить индекс-черновик

Тот же черновик, что Шаг 1.3 открыл — `opened_at` сохраняется, остальные поля заменяются целиком:
```bash
IDX_LIB="${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/lib/session-index-draft.sh"
[ -f "$IDX_LIB" ] || IDX_LIB="${IWE_TEMPLATE:-${IWE_WORKSPACE:-$HOME/IWE}/FMT-exocortex-template}/scripts/lib/session-index-draft.sh"
. "$IDX_LIB"
session_index_draft_write "$SESSION_ID" "$TODAY" "<задача ≤50>" \
  "kimi / <PEER_AGENT_ID>" "<TURNS>" "<ESCALATIONS>" \
  "completed" "[report.md](<MONTH>/<DAY>/<SESSION_ID>/report.md)"
```

Установка без переносчика черновиков в индекс (программы session-index-snapshot.sh в папке программ репозитория управления; так у пользователей шаблона) — черновик никто не перенесёт, поэтому ещё и вести `00-index.md` напрямую, как до WP-537 (файла нет → создать, issue #568; строку сессии заменить по `SESSION_ID` или вставить первой в таблицу):
```bash
if [ ! -f "${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/session-index-snapshot.sh" ]; then
  IDX="$SESSIONS_DIR/00-index.md"
  [ -f "$IDX" ] || printf '%s\n' '# Индекс пир-сессий' '' \
    '| Дата | Сессия | Задача | Агенты | Ходы | Эскалации | Статус | Отчёт |' \
    '|------|--------|--------|--------|------|-----------|--------|-------|' > "$IDX"
  ROW="| $TODAY | $SESSION_ID | <задача ≤50> | kimi / <PEER_AGENT_ID> | <TURNS> | <ESCALATIONS> | completed | [report.md](<MONTH>/<DAY>/<SESSION_ID>/report.md) |"
  if grep -qF "| $SESSION_ID |" "$IDX"; then
    ID="| $SESSION_ID |" ROW="$ROW" awk 'index($0, ENVIRON["ID"]) { print ENVIRON["ROW"]; next } { print }' "$IDX" > "$IDX.tmp"
  else
    ROW="$ROW" awk '{ print } /^\|------/ && !done { print ENVIRON["ROW"]; done = 1 }
      END { if (!done) print ENVIRON["ROW"] }' "$IDX" > "$IDX.tmp"
  fi
  mv "$IDX.tmp" "$IDX"
fi
```
В этом режиме `00-index.md` идёт в коммит сессии (Шаг 4.5) вместе с её файлами.

### 4.4 Закрытие (ОРЗ — сессионный файл рядом с папкой сессии)

**Выключатель пути закрытия (РП-561 Ф61 этап 2, решения пилота 15.11).** Включён, если `IWE_CLOSE_ROUTE_ENFORCE=1` или есть файл `${IWE_WORKSPACE:-$HOME/IWE}/.iwe-runtime/close-route-enforce` (переменная файл не выключает). Выключен — закрытие ниже как раньше. Включён — короткого закрытия пир-сессии нет, и патч `close_path: peer-session` из шага 0а.0б от раннера не освобождает: сессия с изменениями закрывается обычным закрытием (раннер quick-close с итоговой проверкой, архивацией фаз и РП), ОРЗ-файл и файлы журнала передаются раннеру в коммитах репозитория сессий поштучно, списком из Шага 4.5 (только строки построения `PATHS` до цикла `git add`, без `git add`/`git commit`; не папкой: раннер делает `git add` переданных путей, и папка унесла бы изменённый отслеживаемый `.err`, РП-524 Ф7), прямой коммит и `session-guard.sh close` после слов о закрытии не делать. Порядок тот же, что в навыке peer-conversation, Шаг 4.5, абзац «Сначала: включён ли выключатель». Сессия без изменений (без журнала) закрывается одним `session-guard.sh close`.

Slug-часть (без даты и номера): `SESSION_SLUG=$(echo "$SESSION_ID" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{2}-//')`

Записать `$SESSIONS_DIR/<MONTH>/<TODAY>-<SESSION_SLUG>.md` (Write, WP-526 Ф2 — MC-sessions, не governance-репо) — Quick Close файл плоский под месячной папкой, без DD/ (симметрично session-guard.sh; DD/ — только для peer-session-папок):
```markdown
---
date: <TODAY>
type: peer-session
agent: kimi-headless
writer: kimi-headless
peer: <PEER_AGENT_ID>
duration_h: <(end_time - start_time) в часах, 1 знак>
artifacts: [<MONTH>/<DAY>/<SESSION_ID>/report.md]
session_id: <SESSION_ID>
wp: <WP-NNN или unknown>
---

## Главный инсайт

<1-2 строки из §4 report.md — зафиксированное решение>

## Контекст

<одной строкой: задача сессии и кто участвовал>

## Достигнуто

<что изменилось: файлы, коммиты, решения; «ничего» тоже ответ>

## Ключевые решения

См. report.md §4.
```

> **Схема обязательна (WP-484, 26.10, peer-session 2026-10-26-19).** До этой правки шаблон давал `# Главный инсайт` (заголовок первого уровня), не имел ключа `agent:` и трёх остальных разделов: 4 из 4 дефектных закрывающих файлов за 26.10 писал этот шаблон. `session-guard.sh` проверяет ключи `date: type: wp: duration_h: artifacts: agent:` и разделы `## Главный инсайт`, `## Контекст`, `## Достигнуто`, `## Ключевые решения` (`validate_orz`); Kimi-писатель `close` не вызывает, поэтому дефект всплывал только позже, в аудите. Ту же проверку делает защитный блок Шага 4.5 ниже.

### 4.5 Commit + push

**Поле «Следующий шаг» карточки РП (WP-484 Ф257, M2/M6) — до коммита.** Этот скилл не вызывает `session-guard.sh close`, поэтому проверку поля, которую у Claude-писателя запускает `close`, здесь запускаешь сам. Сначала переписать на месте поле «Следующий шаг» в `## Осталось` карточки РП: метка ровно `**Следующий шаг:**` (без даты), одна строка на фазу, `ФN — первое действие`; фаза другого РП — только с номером РП (`РП-561 Ф46`); значение — по последнему решению пилота в этом чате; параллельные сессии того же РП — своя строка фазы заменяется, чужие остаются; не «продолжай по плану», не прежнее значение (формат — `protocol-close.md` § «Формат «Осталось»»). Затем закоммитить и опубликовать карточку (проверка смотрит опубликованную версию) и записать ровно тот же текст поля (свой следующий шаг для следующей сессии, как в отчёте; строку «Дальше» пилоту пишешь отдельно простыми словами по правилу 6 пака, РП-605 — с полем она не совпадает) — в `${IWE_ROOT:-$HOME/IWE}/.iwe-runtime/peer-prompts/$SESSION_ID-next-step.txt` (WP-484 Ф285, М1: без файла проверка даёт отказ `HANDOFF_AGENT_NEXT_MISSING`) и прогнать проверку (решение пилота 10.11, Ф285: проверяется опубликованная карточка; код 10 = блокирующий отказ — `HANDOFF_AGENT_NEXT_MISSING`, `HANDOFF_AGENT_PHASE_MISSING` или `HANDOFF_UNKNOWN_PHASE` вне белого списка `machine/handoff-phase-allowlist.yaml`; остальные коды предупреждают):

```bash
HANDOFF_CHECK="${IWE_SCRIPTS:-$HOME/IWE/scripts}/wp-handoff-peer-check.sh"
[ -f "$HANDOFF_CHECK" ] || echo "проверки поля «Следующий шаг» на этой установке нет — пропущена" >&2
[ ! -f "$HANDOFF_CHECK" ] || bash "$HANDOFF_CHECK" --agent kimi --wp "$PEER_WP" \
  --next-file "${IWE_ROOT:-$HOME/IWE}/.iwe-runtime/peer-prompts/$SESSION_ID-next-step.txt"
HANDOFF_RC=$?
# Only code 10 is a block; any other non-zero is a failure of the check itself, not a verdict.
[ "$HANDOFF_RC" -ne 10 ] || { echo "СТОП: поле «Следующий шаг» не прошло блокирующую проверку — исправить, опубликовать карточку, повторить" >&2; exit 1; }
```

Любой `HANDOFF_*` — отказ для самого писателя: поправить поле и файл, опубликовать карточку и повторить проверку до коммита; при коде 10 коммит сессии не делать, пока проверка не пройдёт (этот скилл не вызывает `session-guard.sh close`, поэтому стоп здесь — единственное место блока); не прошло — сказать пилоту одной строкой. Семафор Kimi ищется по номеру РП; два открытых семафора пир-сессии на один РП скрипт не угадывает, а пишет `SEMAPHORE_AMBIGUOUS` в журнал наблюдения.

**Снимок открытых фаз карточки (WP-484 Ф299, вход И-6 из РП-561) — до коммита.** Если сессия меняла статусы или разделы фаз карточки РП — обновить self-entry `handoff_snapshot` тем же скриптом, что `memory/protocol-close.md` §5; иначе гейт Ф42 на следующем открытии даёт ложное MISMATCH. `--governance-repo` — каталог, где карточка реально правилась (изолированная копия под заморозкой, иначе `${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}`):

```bash
SNAPSHOT_WRITER="${IWE_WORKSPACE:-$HOME/IWE}/scripts/wp-phase-snapshot-write.py"
if [ -f "$SNAPSHOT_WRITER" ]; then
  "$(bash "${IWE_SCRIPTS:-$HOME/IWE/scripts}/lib/find-python3.sh" --stdlib-only)" "$SNAPSHOT_WRITER" "$PEER_WP" --governance-repo "<каталог карточки>"
else
  echo "записи снимка фаз на этой установке нет — пропущена" >&2
fi
```

Код 0 — записано или уже актуально; код 3 — проверка списка фаз не сошлась, скрипт отказался писать: руками не чинить, одна строка пилоту.

```bash
# WP-526 Ф2: коммит и push сессии идут в MC-sessions ($SESSIONS_DIR), не
# в governance-репо. session-manifest-write.sh живёт в DS-strategy
# (обычный скрипт), но работает НАД MC-sessions ($WORKTREE = первый аргумент).
# The whole block runs in a subshell with the journal folder as cwd (no top-level cd, #1006).
(cd "$SESSIONS_DIR" || exit 1

# Pre-commit guard
test ! -f "$SESSION_DIR/report-draft.md" \
  || { echo "FAIL: report-draft.md существует — mv к report.md не выполнен"; exit 1; }
test -f "$SESSION_DIR/report.md" \
  || { echo "FAIL: report.md отсутствует"; exit 1; }
CLOSE_FILE="$SESSIONS_DIR/$MONTH/${TODAY}-${SESSION_SLUG}.md"
test -f "$CLOSE_FILE" \
  || { echo "FAIL: close-файл $CLOSE_FILE отсутствует"; exit 1; }
# Same schema session-guard.sh validate_orz enforces (this skill never calls `close`,
# so without this check a malformed close file is found only by a later audit).
FRONTMATTER=$(awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } NR > 1 { print }' "$CLOSE_FILE")
for key in date type wp duration_h artifacts agent; do
  printf '%s\n' "$FRONTMATTER" | grep -q "^${key}:" \
    || { echo "FAIL: в $CLOSE_FILE нет ключа ${key}: во frontmatter"; exit 1; }
done
for section in "## Главный инсайт" "## Контекст" "## Достигнуто" "## Ключевые решения"; do
  grep -q "^${section}\$" "$CLOSE_FILE" \
    || { echo "FAIL: в $CLOSE_FILE нет раздела '$section'"; exit 1; }
done
# WP-537 Ф4: индекс-черновик, не 00-index.md — эта сессия больше не
# пишет git-tracked файл напрямую (session-index-snapshot.sh единственный писатель).
DRAFT_FILE="${IWE_WORKSPACE:-$HOME/IWE}/.iwe-runtime/session-index-drafts/${SESSION_ID}.yaml"
test -f "$DRAFT_FILE" \
  || { echo "FAIL: индекс-черновик $DRAFT_FILE отсутствует — Шаг 4.3 не выполнен"; exit 1; }
grep -qF "status: completed" "$DRAFT_FILE" \
  || { echo "FAIL: $DRAFT_FILE: status != completed"; exit 1; }

# pathspec после `--`: commit ТОЛЬКО файлы сессии (mis-attribution, 2026-06-20-39)
# 00-index.md больше НЕ входит сюда (WP-537 Ф4) — см. комментарий выше.
# WP-484 (21.09, пир-сессия 2026-09-21-08): здесь НЕ создаём ветку `peer/<id>` и не
# открываем PR. Прежний шаг (`git checkout -b`, `git push origin "$BRANCH"`,
# `gh pr create`) переключал ОБЩИЙ checkout MC-sessions на ветку сессии и оставлял
# его там: пока ветка не слита, все следующие сессии, которые пишут в этот checkout,
# коммитят в неё, а не в `main`, и `session-guard.sh close` не находит HEAD среди
# предков origin/main (ветка `peer/2026-09-19-11-...` простояла с 19.09).
# Коммитим в текущую ветку и публикуем ровно свои коммиты через шлюз (ниже).
# WP-524 F7 (20.11): explicit session files, never the folder and never .err.
# The journal ignores `**/*.err`; `git commit -- <folder>` would still take a
# modified tracked .err along (2000+ such files predate the 10.09 rule).
# Listing: untracked-but-not-ignored + changed tracked (deletions included,
# --no-renames turns a rename into delete + add; --relative keeps paths
# relative to $SESSIONS_DIR, which in a legacy install is the sessions/
# subfolder of the governance repo, not a repo root). NUL read loop works on
# macOS bash 3.2 (no mapfile).
REL="$MONTH/$DAY/$SESSION_ID"
PATHS=("$MONTH/${TODAY}-${SESSION_SLUG}.md")
# Install without the index snapshotter: the index is kept directly and goes in the commit.
[ -f "${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/session-index-snapshot.sh" ] || PATHS+=("00-index.md")
SKIPPED_ERR=()
SESSION_FILES=0
while IFS= read -r -d '' p; do
  case "$p" in
    *.err) SKIPPED_ERR+=("$p") ;;
    *) PATHS+=("$p"); SESSION_FILES=$((SESSION_FILES + 1)) ;;
  esac
done < <(
  {
    git ls-files -z --others --exclude-standard -- "$REL"
    git diff -z --name-only --relative --no-renames HEAD -- "$REL"
  } | sort -zu
)
[ "$SESSION_FILES" -gt 0 ] || { echo "FAIL: в папке сессии $REL нет файлов для сохранения" >&2; exit 1; }
# A modified tracked .err (re-closing an old session) keeps the journal copy
# dirty: save it outside the IWE workspace for analysis, then
# `git restore --source=HEAD --staged --worktree -- <path>`.
[ "${#SKIPPED_ERR[@]}" -eq 0 ] || printf 'WARN: .err в сохранение не идёт: %s\n' "${SKIPPED_ERR[@]}" >&2
for P in "${PATHS[@]}"; do
  if [ -e "$P" ]; then
    git add -- "$P" || { echo "FAIL: не удалось добавить $P" >&2; exit 1; }
  elif git ls-files --error-unmatch -- "$P" >/dev/null 2>&1; then
    # Tracked file deleted on disk, deletion not staged yet.
    git rm --cached --quiet -- "$P" || { echo "FAIL: не удалось снять $P с индекса" >&2; exit 1; }
  fi   # deletion already staged: `git commit -- <path>` takes it
done
# Task text: written beforehand with a file-writing tool (not the shell) to
# ${IWE_WORKSPACE:-$HOME/IWE}/.iwe-runtime/peer-prompts/<SESSION_ID>-task.txt — never inline it in quotes.
TASK_FILE="${IWE_WORKSPACE:-$HOME/IWE}/.iwe-runtime/peer-prompts/$SESSION_ID-task.txt"
test -s "$TASK_FILE" || { echo "нет файла задачи $TASK_FILE — записать его инструментом записи файлов" >&2; exit 1; }
{ printf 'feat(peer): %s (kimi-writer) — ' "$SESSION_ID"; cat "$TASK_FILE"; } | git commit -F - -- "${PATHS[@]}"
OUR_SHAS=("$(git rev-parse HEAD)")   # публикуем ровно свои коммиты по одному

# F1 (пир-сессия 2026-08-21-02-day-close-anomaly-classes): attest-манифест
# сессии — ПОСЛЕ payload-коммита с отчётом, ДО публикации. Без манифеста
# догоняющий quick-close уже запушенной сессии не может доказать «всё на
# remote» и падает в ручной обход. Отказ манифеста (грязное дерево канона и
# т.п.) не блокирует закрытие — WARN и дальше без него (legacy-путь
# confirmed_clean_repos остаётся).
MANIFEST_WRITER="${IWE_SCRIPTS:-$HOME/IWE/scripts}/session-manifest-write.sh"
[ -f "$MANIFEST_WRITER" ] || MANIFEST_WRITER="${IWE_TEMPLATE:-${IWE_WORKSPACE:-$HOME/IWE}/FMT-exocortex-template}/scripts/session-manifest-write.sh"
bash "$MANIFEST_WRITER" "$(git rev-parse --show-toplevel)" "$SESSION_ID" \
  || echo "WARN: attest-манифест не создан — догоняющее закрытие этой сессии пойдёт legacy-путём"
# attest-манифест — второй наш коммит (если создан): порядок публикации «payload, затем манифест»
[ "$(git rev-parse HEAD)" = "${OUR_SHAS[0]}" ] || OUR_SHAS+=("$(git rev-parse HEAD)")

# Публикация: только свои коммиты, по одному, через шлюз с `--exact-commit`.
# НИКОГДА `git push` текущей ветки: если общий checkout стоит не на `main`, коммит
# уйдёт в чужую ветку; а `--from-commit` без `--exact-commit` переносит весь диапазон
# `origin/main..<sha>` (чужие коммиты, конфликт в `00-index.md`). Повтор идемпотентен:
# уже опубликованный patch-эквивалент пропускается. Зависимые коммиты доставляются
# не атомарно — при сбое между ними повторить цикл, он безопасен.
REPO_ROOT=$(git rev-parse --show-toplevel)
git -C "$REPO_ROOT" fetch -q origin main
# Служебный id охранника = имя файла семафора `kimi-<id>.open`; дата-слаг пир-сессии им не является
# (WP-539 Ф21 Б5: с слагом квитанция отказывала «нет открытой сессии»). Ищем семафор по полю slug;
# ровно один. Семафор Kimi открывается снаружи, и его slug бывает номером РП, а не слагом сессии:
# не нашли однозначно — публикуем без квитанции (как раньше), но громко предупреждаем, не стоп.
# Без IWE_AGENT квитанция тоже не пишется — задаём его явно.
if [ -f "${IWE_WORKSPACE:-$HOME/IWE}/.iwe-runtime/sessions/kimi-${SESSION_ID}.open" ]; then
  GUARD_SESSION_ID="$SESSION_ID"
else
  GUARD_SEM_MATCHES=$(grep -lxF "slug: ${SESSION_ID}" "${IWE_WORKSPACE:-$HOME/IWE}"/.iwe-runtime/sessions/kimi-*.open 2>/dev/null)
  if [ "$(printf '%s\n' "$GUARD_SEM_MATCHES" | grep -c .)" -eq 1 ]; then
    GUARD_SESSION_ID=$(basename "$GUARD_SEM_MATCHES" .open)
    GUARD_SESSION_ID="${GUARD_SESSION_ID#kimi-}"
  else
    GUARD_SESSION_ID=""
    echo "WARN: семафор Kimi для $SESSION_ID не найден однозначно — публикую без квитанции v2" >&2
  fi
fi
for SHA in "${OUR_SHAS[@]}"; do
  # IWE_PUBLICATION_SESSION_ID обязателен: без него квитанция публикации (v2) не записывается
  IWE_AGENT=kimi IWE_PUBLICATION_SESSION_ID="$GUARD_SESSION_ID" bash "${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/ds-publish.sh" "$REPO_ROOT" high \
    --from-commit "$SHA" --exact-commit "$SHA" --reason "peer-session $SESSION_ID close" \
    || { echo "ds-publish --exact-commit не удался для $SHA — см. вывод шлюза" >&2; exit 1; }
done
)
```

> **Семафор Kimi-standalone (`.iwe-runtime/sessions/kimi-*.open`) этот скилл НЕ закрывает** (найдено 2026-09-04, пир-сессия 2026-09-04-23-wp561-peer-session-closed-ledger-gap с Claude). Он открывается снаружи, `~/.kimi-code/skills/session-open/SKILL.md`, без `--close-path peer-session` — этот флаг задаётся только при `open` и не может быть передан отдельно при `close`, а слепое добавление `--close-path peer-session` в общий `session-open` неверно для НЕ-пир сессий Kimi (обошло бы типизированный раннер и там). Семафор сейчас закрывается только через `session-guard.sh`-хаусхолдинг (auto-orphan, TTL 30 мин) — событие `session_closed_direct` в дневном журнале для Kimi-writer сессий не пишется. Полноценный фикс требует координации между `~/.kimi-code/skills/session-open/SKILL.md` (вне IWE-репозитория) и этим файлом — вынесен в отдельную сессию (РП-561, follow-up фаза).

Показать пилоту: «Сессия завершена. Отчёт: `MC-sessions:$MONTH/$DAY/$SESSION_ID/report.md`»

---

## Шаг 5. Interrupt-режим

При `--interrupt <session_id>`:

1. Извлечь месяц и день из id: `MONTH=$(echo "$session_id" | cut -c1-7)`, `DAY=$(echo "$session_id" | cut -c9-10)` → найти `$SESSIONS_DIR/$MONTH/$DAY/$session_id/meta.yaml` (MC-sessions, WP-526 Ф2).
2. Обновить (Bash sed): `status: interrupted`, `end_time: <now>`, `turns_count: <число файлов>`.
3. Обновить индекс-черновик (WP-537 Ф4, `session_index_draft_write`, см. Шаг 4.3): статус → `interrupted`, report → `—`.
4. Commit + push внутри `$SESSIONS_DIR` (без `00-index.md`, без папки и без `.err`, РП-524 Ф7):
   ```bash
   # SESSIONS_DIR: the same journal-folder lines as step 1; subshell, no top-level cd (#1006).
   (cd "$SESSIONS_DIR" || exit 1
   SESSION_ID="$session_id"
   REL="$MONTH/$DAY/$SESSION_ID"
   PATHS=()
   while IFS= read -r -d '' p; do
     case "$p" in *.err) ;; *) PATHS+=("$p") ;; esac
   done < <(
     { git ls-files -z --others --exclude-standard -- "$REL"
       git diff -z --name-only --relative --no-renames HEAD -- "$REL"; } | sort -zu
   )
   CLOSE_FILE="$MONTH/$(echo "$SESSION_ID" | cut -c1-10)-$(echo "$SESSION_ID" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{2}-//').md"
   [ ! -e "$CLOSE_FILE" ] || PATHS+=("$CLOSE_FILE")
   # Install without the index snapshotter: update 00-index.md with the step 4.3 block first.
   [ -f "${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/session-index-snapshot.sh" ] || PATHS+=("00-index.md")
   [ "${#PATHS[@]}" -gt 0 ] || { echo "в папке сессии $REL нет файлов для сохранения" >&2; exit 1; }
   for P in "${PATHS[@]}"; do
     if [ -e "$P" ]; then git add -- "$P" || exit 1
     elif git ls-files --error-unmatch -- "$P" >/dev/null 2>&1; then git rm --cached --quiet -- "$P" || exit 1
     fi
   done
   git commit -m "feat(peer): $SESSION_ID (kimi-writer) — <режим>" -- "${PATHS[@]}" || exit 1
   git rev-parse HEAD
   )   # prints the commit to publish (OUR_SHAS for the step 4.5 publication loop)
   ```
   Публикация — тем же циклом `ds-publish.sh --exact-commit`, что в Шаге 4.5 (`REPO_ROOT`, `GUARD_SESSION_ID` — так же, как там). Проверки над блоком 4.5 (`report.md`, закрывающий файл, `status: completed`) в этом режиме не применяются.

---

## Шаг 6. Finalize-режим

При `--finalize <session_id>`:

1. Извлечь месяц и день: `MONTH=$(echo "$session_id" | cut -c1-7)`, `DAY=$(echo "$session_id" | cut -c9-10)`. Проверить что папка `$SESSIONS_DIR/$MONTH/$DAY/$session_id` (MC-sessions, WP-526 Ф2) существует и содержит хотя бы `00-writer.md`.
2. Прочитать `meta.yaml` — взять `task_description`, `start_time`, `escalations_count`.
3. Выполнить **Шаг 4.2** (синтез report-draft.md через адаптер сессии: `scripts/<peer_cmd>.sh`, где `peer_cmd` читается из `meta.yaml` этой сессии — аргумента `--peer` при `--finalize` нет, Шаг 0а.2 не выполняется заново) с теми же инвариантами и fallback.
4. Обновить `meta.yaml` (Bash sed): `status: completed`, `end_time: <now>`, `turns_count: <число файлов>`.
5. Обновить индекс-черновик (WP-537 Ф4, `session_index_draft_write`, см. Шаг 4.3): статус → `completed`, report → ссылка.
6. Commit + push внутри `$SESSIONS_DIR` (без `00-index.md`, без папки и без `.err`, РП-524 Ф7):
   ```bash
   # SESSIONS_DIR: the same journal-folder lines as step 1; subshell, no top-level cd (#1006).
   (cd "$SESSIONS_DIR" || exit 1
   SESSION_ID="$session_id"
   REL="$MONTH/$DAY/$SESSION_ID"
   PATHS=()
   while IFS= read -r -d '' p; do
     case "$p" in *.err) ;; *) PATHS+=("$p") ;; esac
   done < <(
     { git ls-files -z --others --exclude-standard -- "$REL"
       git diff -z --name-only --relative --no-renames HEAD -- "$REL"; } | sort -zu
   )
   CLOSE_FILE="$MONTH/$(echo "$SESSION_ID" | cut -c1-10)-$(echo "$SESSION_ID" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{2}-//').md"
   [ ! -e "$CLOSE_FILE" ] || PATHS+=("$CLOSE_FILE")
   # Install without the index snapshotter: update 00-index.md with the step 4.3 block first.
   [ -f "${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/session-index-snapshot.sh" ] || PATHS+=("00-index.md")
   [ "${#PATHS[@]}" -gt 0 ] || { echo "в папке сессии $REL нет файлов для сохранения" >&2; exit 1; }
   for P in "${PATHS[@]}"; do
     if [ -e "$P" ]; then git add -- "$P" || exit 1
     elif git ls-files --error-unmatch -- "$P" >/dev/null 2>&1; then git rm --cached --quiet -- "$P" || exit 1
     fi
   done
   git commit -m "feat(peer): $SESSION_ID (kimi-writer) — <режим>" -- "${PATHS[@]}" || exit 1
   git rev-parse HEAD
   )   # prints the commit to publish (OUR_SHAS for the step 4.5 publication loop)
   ```
   Публикация — тем же циклом `ds-publish.sh --exact-commit`, что в Шаге 4.5 (`REPO_ROOT`, `GUARD_SESSION_ID` — так же, как там). Проверки над блоком 4.5 (`report.md`, закрывающий файл, `status: completed`) в этом режиме не применяются.

Используется для восстановления прерванных сессий без перезапуска turn-loop.

---

## Верификация отчёта

Для проверки любого существующего report.md написать в чат:
«проверь отчёт сессии `<session_id>`»

Запустить субагент (Sonnet, context isolation): прочитать все файлы сессии + report.md, сверить с инвариантами schema_version=1 (frontmatter, §4 непустой при agreed, verify-якоря).

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
