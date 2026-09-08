---
valid_from: 2026-04-26
related: [VR.SC.005, DP.ARCH.001]

type: protocol
horizon: warm
domains: [reference]
status: active
owner: platform
schema_version: 1

name: "dry-run-contract"
description: "Операционный файл памяти IWE"
---
# Dry-run контракт для скиллов с побочными эффектами

> **Назначение.** Гарантировать read-only режим для ритуальных скиллов (`/day-open`, `/day-close`, `/week-close`, `/month-close`), чтобы `/audit-installation` мог реально smoke-тестить их без создания drift.
>
> **Принцип реализации (вариант F3).** Скиллы НЕ знают про dry-run. Защита через **PreToolUse-хук + sentinel-файл** — внешний механизм, независимый от логики скилла. Это покрывает и автора (inline-скиллы), и пилотов (FMT-делегирование), и кастомные скиллы пилотов.

## State-машина (issue #549 stage 2, 2026-08-31 — надмножество над sentinel)

> **Проблема stage 1 не закрывала:** ветка «sentinel снят, owner-файл остался» была вечным fail-closed без штатного пути разблокировки изнутри (сессия умерла между `rm sentinel` и Stop-хуком, или id не совпал).

**Инварианты (дизайн подтверждён пир-ревью Codex, 2 раунда):**

1. **Единая каноническая запись** — `/tmp/iwe-dry-run-<uid>/gate-<gate_id>.state` (JSON v2: `gate_id`, `owner_session_id`, `owner_pid`/`owner_pgid`/`owner_pid_start`, `state: active|completed`, `created_at`, `completed_at`, `completion_reason`, `owner_token_sha256`). Capability-token хранится только как sha256 — репетиция, читающая state разрешённой read-only командой, получает лишь хэш и не может завершить gate сама (завершение требует preimage; Stop-хук рантайма завершает сам inline — никакого trusted-флага не существует, Codex r2: флаг обходился shell-квотированием аргумента). Sentinel `/tmp/iwe-dry-run.flag` — только маркер активного режима со ссылкой `gate_id` на эту запись; решение гейта принимается по таблице состояний (sentinel×state), не по одному sentinel.
2. **Эксклюзивность:** одна активная репетиция на установку; вторая попытка — отказ с текущим `gate_id`. Несколько active-state = corruption → fail-closed.
3. **Атомарные переходы и создание:** только `active→completed`, монотонно, tmp+mv внутри короткого транзакционного замка (`transaction.lock/` через `mkdir`, владелец замка pid+nonce — доказуемо осиротевший замок уносится уникальным именем; освобождение только по своему nonce). Создание — тоже под замком и тоже только через helper (`scripts/dry-run-begin.sh`: скан заново, отказ при активной репетиции, эксклюзивное создание sentinel после state). Завершение делает **команда завершения** (`scripts/dry-run-complete.sh`, capability token), Stop-хук — идемпотентный fallback inline по `gate_id`+`owner_session_id` (весь скан под одним замком, переход только при ровно одном валидном v2 active своей сессии, sentinel только после успешного перехода). Повторное завершение не перетирает metadata.
4. **Доказуемое сиротство** (вместо вечной блокировки): `owner_pid` мёртв ИЛИ его `lstart` не совпал (pid reuse) **И** ни одного живого процесса с `owner_pgid` → `completed(reason=orphan-sweep)` → allow. Любая неоднозначность (ошибка ps, битый state, неизвестный gate_id, живой pgid) → прежний вечный fail-closed с командой восстановления `dry-run-complete.sh <gate_id> manual-recovery`.
5. **Известные остатки (приняты осознанно):** (а) если рантайм помещает сам гейт в process group владельца, pgid-скан всегда видит «живых» → вечный fail-closed (безопасное направление); (б) `lstart` — текстовый платформенный формат: живой pid с ДРУГИМ стартом = pid reuse (исходный владелец доказуемо мёртв), а НЕЧИТАЕМЫЙ ps/пустой вывод = «не доказано» → fail-closed; (c) атаки от того же uid вне threat model (защита — 0700 каталог + lstat-проверки от symlink/чужого владельца); (d) PGID reuse даёт только ложный fail-closed; (e) env-оверрайды путей (`IWE_DRY_RUN_DIR`/`IWE_DRY_RUN_SENTINEL`) действуют только при наличии маркера `.iwe-dry-run-test-mode` в override-каталоге — ambient-переменные из конфигурации запуска защиту не отключают.
6. **Legacy:** owner-*.token старого формата (без state-файла) — прежняя вечная ветка с `rm -f`-восстановлением. `sentinel+completed` — самолечение: stale sentinel снимается после сверки gate_id.

## Sentinel-механика

### Файл

```
/tmp/iwe-dry-run.flag
```

- **Имя:** единый файл, не session-bound (v2, WP-7/BUGTRIAGE2, issue #237). `CLAUDE_SESSION_ID` не пробрасывается в окружение субагентов — session-bound имя создавало рассинхрон: главный агент создавал `iwe-dry-run-${SID}.flag` по своему SID, а Stop-hook субагента чистил по своему (пустому/другому) SID, промахиваясь мимо реального файла. Единое имя убирает рассинхрон создания/очистки.
- **Содержимое:** одна строка JSON: `{"created_at": "<ISO8601>", "session_id": "<id-инициатора>", "initiator": "<skill-name>"}` — session_id хранится только для диагностики, не участвует в поиске/очистке файла.
- **TTL:** 40 минут (2400с) от mtime (issue #460 путь 3, было 10 мин — измеренный `close day` занимает ~26 мин, старый TTL истекал посреди легитимной репетиции). Файл с mtime старше TTL — **fail-CLOSED**: хук блокирует и оставляет sentinel на месте для ручного разбора, больше не удаляет его сам (раньше `rm -f` + allow — тот же класс fail-open, что путь 1/2).
- **Очистка:** (а) явная — финал шага в `/audit-installation`; (б) TTL-expiry требует ручного `rm -f`, автоматической очистки больше нет. Stop владельца (даже при совпадении `session_id` и capability-token) **больше не удаляет sentinel** (issue #460 путь 6 — тот же `session_id` у родителя и его фонового субагента, поэтому Stop родительского хода мог снести защиту, пока субагент ещё пишет); Stop только подчищает residue-owner-файл текущей сессии, и только когда sentinel уже отсутствует. Чужой Stop по-прежнему не снимает защиту (issue #460 путь 7, регрессия покрыта тестом).

### Жизненный цикл

```
[start]  /audit-installation шаг smoke-test
         → echo "$payload" > /tmp/iwe-dry-run.flag
         → запуск subagent: /run-protocol close day (через Agent tool)
         → ...
[end]    rm -f /tmp/iwe-dry-run.flag
         → анализ результата subagent'а
```

## PreToolUse-хук `dry-run-gate.sh`

### Контракт

При наличии валидного sentinel-файла (единое имя, mtime ≤ 40 мин) хук блокирует **любой tool-call с побочными эффектами** и возвращает exit 2 с диагностикой:

```
[dry-run-gate] BLOCKED: <tool> on <path/cmd>
Reason: dry-run mode active (sentinel created at <iso>, by <initiator>)
Expected: tool blocked by contract, this is rehearsal failure point
```

### Заблокированные tool-matchers

| Tool | Matcher | Что | Почему |
|---|---|---|---|
| `Write` | любой | Запись файла | Очевидное side-effect |
| `Edit` | любой | Редактирование | Очевидное side-effect |
| `MultiEdit` | любой | Множественное редактирование | Очевидное side-effect |
| `NotebookEdit` | любой | Jupyter | Side-effect |
| `Bash` | `command` regex | См. ниже | Опосредованные side-effects |
| MCP-write | tool name whitelist | См. ниже | Запись через MCP |

### Bash matchers

v2 (WP-7/BUGTRIAGE2, issue #237): не regex по всей строке команды, а три прохода —
(1) вырезать кавычные спаны (`'...'`/`"..."` → `QSTR`, кроме psql — SQL матчится по
оригиналу), (2) разбить нормализованную строку на простые команды по `; & | && || ( ) { } $( ``,
(3) классифицировать каждый фрагмент по первому слову (после пропуска `VAR=val`/
`command`/`env`/`nohup`/`time`/`sudo`). Закрывает одновременно subshell-обход
(`(git commit)`) и ложные срабатывания на текст внутри кавычек (`echo "git commit"`).
Реализация — `.claude/hooks/dry-run-gate.sh`, секция «Bash matchers».

Классифицируемые команды (по первому слову фрагмента):

```
git (add|commit|push|pull|reset|merge|rebase|mv|rm), git checkout -*
rm | mv                     # кроме cleanup собственного sentinel
tee (не /dev/null)
sed -i*
curl -X (POST|PUT|DELETE|PATCH) | curl --data | curl -d
psql ... (INSERT|UPDATE|DELETE|TRUNCATE|DROP|ALTER)   # матчится по оригиналу (SQL в кавычках)
bash|sh|zsh <script>              # indirect execution — block, КРОМЕ whitelist ниже (issue #264)
python|python3 <script>           # indirect execution — block, КРОМЕ whitelist ниже (issue #460 путь 5)
python|python3 -c "..."           # inline snippet — вне контракта по threat model (см. ниже), allow
eval|source|.|xargs               # indirect execution — payload неинспектируем после quote-strip

Whitelist read-only helpers (issue #264) — разрешены под dry-run, т.к. write-путей
в коде скрипта нет (проверяется при добавлении, см. правило ниже):

```
.claude/scripts/load-extensions.sh                    # относительный, от workspace-root
$HOME/IWE/.claude/scripts/load-extensions.sh          # абсолютный, захардкожен
scripts/day-close-prepare.sh                          # относительный (issue #315) — рабочий,
                                                        # только если CWD внутри FMT-exocortex-template
${IWE_SCRIPTS:-$HOME/IWE/scripts}/day-close-prepare.sh # абсолютный (нестатический — реальный вложенный
                                                        # путь резолвится через $IWE_SCRIPTS, issue #315)
"$IWE_SCRIPTS/day-close-prepare.sh"                    # реальная документированная форма (день. вызов
                                                        # из day-close/SKILL.md) — маркер __WL_DAY_CLOSE_PREPARE__
```

Python-whitelist (issue #460 путь 5, добавлен после того как code review поймал, что
безусловный block ломает `close day` на первом же шаге):

```
${IWE_TEMPLATE:-<HOME_DIR>/IWE/FMT-exocortex-template}/.claude/scripts/memory-drift-scan.py
${IWE_TEMPLATE:-<HOME_DIR>/IWE/FMT-exocortex-template}/.claude/scripts/check-index-health.py
```

Обе — read-only диагностика (day-close/SKILL.md шаги 1-2), без write-путей в коде
(проверено). Маркеры `__WL_PY_MDS__`/`__WL_PY_CIH__`, та же техника точечной
sed-замены до split, что у `day-close-prepare.sh` выше — `${IWE_TEMPLATE:-...}`
содержит `{`/`}`, которые иначе рвут путь на сегменты (см. комментарий в коде).
Паттерн matches **точный** `$HOME`-путь, не wildcard-default — round-2 review
живьём воспроизвёл, что `[^}]*` пропускал `${IWE_TEMPLATE:-$(cmd)}/...` как
allow, глотая command substitution маркером раньше, чем шаг 2 успевал его
сегментировать. `rule-classifier.py` (day-close/SKILL.md шаг «Rule-engine»)
сознательно НЕ в whitelist — сам SKILL.md документирует, что скрипт вносит правки.
`{{HOME_DIR}}` в исходнике SKILL.md — шаблонный плейсхолдер репозитория-шаблона
(setup.sh рендерит только CLAUDE.md, не `.claude/skills/`); ожидается, что
исполняющий агент подставляет реальный путь при формировании Bash-вызова — тот
же принцип, что у уже существующего `WL_ABS`/`WL_ABS2` (bash-whitelist).

Абсолютный паттерн захардкожен в `$HOME/IWE`, не glob `*/.claude/...` и не
`$IWE_ROOT` — иначе подложный `/tmp/.claude/scripts/load-extensions.sh` или
env-инъекция `IWE_ROOT=/tmp/evil` прошли бы gate (review-01 High, review-02 H1).
Пользователи с нестандартным расположением workspace вызывают helper
относительным путём из корня workspace.

Реальный (и единственный документированный) вызов `day-close-prepare.sh` —
`bash "$IWE_SCRIPTS/day-close-prepare.sh"` (day-close/SKILL.md, day-close-details.md).
`$IWE_SCRIPTS` по умолчанию = `$WORKSPACE_DIR/FMT-exocortex-template/scripts`
(`scripts/` не копируется в workspace-root, в отличие от `.claude/` — см.
`.claude/lib/iwe-env-bootstrap.sh:86`), поэтому ни один из двух путей выше сам
по себе не совпадает с реальным вызовом: переменная в кавычках `"$IWE_SCRIPTS/..."`
попадает под общее схлопывание кавычек (шаг 1 Bash matchers) раньше, чем до неё
доходит whitelist-case, и превращается в неотличимый токен `QSTR`. Точечная
sed-подмена литерального (нераскрытого на момент PreToolUse) паттерна
`"$IWE_SCRIPTS/day-close-prepare.sh"` → маркер `__WL_DAY_CLOSE_PREPARE__`
идёт ДО общего схлопывания кавычек и восстанавливает совпадение именно для
этого прошитого вызова, не открывая обход кавычек ни для чего другого
(независимая проверка — review нашёл и это, и неверный абсолютный путь выше
в первой версии фикса; исправлено во второй итерации, живое воспроизведение
точной документированной команды подтвердило allow).

`day-close-prepare.sh` (issue #315) — read-only дайджест-оркестратор шага 0б
Day Close (см. код: только `git log`/`grep`/`ls`/`wc`/`python3 <script>`/
`wakatime-cli --today`, ни одного write-пути — redirect в файл, `tee`, `sed -i`,
`git add|commit|push`, `rm`/`mv` в коде отсутствуют). До фикса узкий whitelist
(только `load-extensions.sh`) блокировал его как «indirect execution», хотя
сам гейт срабатывает по факту записи — smoke-тест ритуала терял точность,
падая на безобидном чтении раньше первого реального write.

Правило whitelist: добавление только через (1) строку здесь + (2) ветку в case
`bash|sh|zsh` в dry-run-gate.sh + (3) code review на отсутствие write-путей
(redirect/tee/sed -i/mv/rm в коде скрипта).
> файл / >> файл             # редирект в реальный файл (не /dev/null)
```

### MCP-write whitelist

Точное имя tool (полный список — все, что НЕ read-only):

```
mcp__claude_ai_IWE__personal_write
mcp__claude_ai_IWE__personal_delete
mcp__claude_ai_IWE__personal_create_pack
mcp__claude_ai_IWE__personal_propose_capture
mcp__claude_ai_IWE__personal_reindex_source
mcp__claude_ai_IWE__personal_scaffold_notes
mcp__claude_ai_IWE__dt_write_digital_twin
mcp__claude_ai_IWE__create_repository
mcp__claude_ai_IWE__github_connect
mcp__claude_ai_IWE__github_disconnect
mcp__claude_ai_IWE__knowledge_feedback
mcp__claude_ai_Gmail__create_draft
mcp__claude_ai_Gmail__create_label
mcp__claude_ai_Gmail__label_message
mcp__claude_ai_Gmail__label_thread
mcp__claude_ai_Gmail__unlabel_message
mcp__claude_ai_Gmail__unlabel_thread
mcp__claude_ai_Google_Calendar__create_event
mcp__claude_ai_Google_Calendar__delete_event
mcp__claude_ai_Google_Calendar__update_event
mcp__claude_ai_Google_Calendar__respond_to_event
mcp__claude_ai_Google_Drive__create_file
mcp__ext-google-calendar__create-event
mcp__ext-google-calendar__create-events
mcp__ext-google-calendar__delete-event
mcp__ext-google-calendar__update-event
mcp__ext-google-calendar__respond-to-event
mcp__ext-google-drive__copy_file
mcp__ext-google-drive__create_file
mcp__ext-google-drive__create_folder
mcp__ext-google-drive__delete_file
mcp__ext-google-drive__move_file
mcp__ext-google-drive__update_file
mcp__ext-google-drive__share_file
mcp__ext-linear__create_issue
mcp__ext-linear__update_issue
mcp__ext-railway__create-environment
mcp__ext-railway__create-project-and-link
mcp__ext-railway__deploy
mcp__ext-railway__deploy-template
mcp__ext-railway__generate-domain
mcp__ext-railway__link-environment
mcp__ext-railway__link-service
mcp__ext-railway__set-variables
```

Read-only tools (`*_search`, `*_get_*`, `*_list_*`, `*_status`, `dt_read_*`, etc.) — **разрешены**.

### Fail-safe (отказ хука)

Если хук **сам падает** (синтаксис, отсутствие jq) → **fail-CLOSED** (exit 2 с пометкой `hook-error`). Принцип: лучше ложно заблокировать, чем пропустить нарушение контракта.

```bash
if ! command -v jq >/dev/null 2>&1; then
    echo "[dry-run-gate] FAIL-CLOSED: jq missing, blocking by default" >&2
    exit 2
fi
```

## Обязательства extensions

Пилотские расширения (`extensions/*.md`) могут запускать собственный bash. Чтобы не нарушить dry-run:

```bash
# В начале extension-скрипта, ДО любого write-действия:
if [ -f "/tmp/iwe-dry-run.flag" ]; then
    echo "[extension] dry-run active, skipping write steps"
    exit 0
fi
```

**Альтернативный путь:** extension просто делает write через стандартные tools (Write/Edit/Bash) — хук перехватит автоматически. Явная проверка sentinel в extension нужна только если extension хочет дать «осмысленный rehearsal» (вместо просто block'а), либо использует exotic tools (бинарные API), которых хук не покрывает.

## Анализ smoke-теста в `/audit-installation`

Subagent после прогона ритуала анализирует transcript:

| Сигнал | Интерпретация |
|---|---|
| **Все шаги завершились без block'а** | `/run-protocol close day` НЕ имеет write-шагов (подозрительно — должен иметь). Verdict: ⚠️ |
| **Block на шаге 1-2** | Ритуал ломается рано (нет нужного source-файла, MCP отвалился). Verdict: ❌ |
| **Block на write-шаге (commit/Write)** после успешных read-шагов | Read-логика работает. Это **ожидаемое поведение** smoke-теста. Verdict: ✅ |
| **Hook-error** (jq missing и т.п.) | Инфраструктура поломана. Verdict: ❌ |

## Не входит в контракт

- **Гарантия что ритуал работает корректно содержательно** (pas-fail logic). Это open-loop verification, не closed-loop. Smoke-тест проверяет инициируемость, не правильность.
- **Покрытие тонких side-effects** — например, скилл может прочитать `/tmp` файл, в нём `mktemp` (создаёт временный файл, формально write). Хук таких не блокирует. Принцип: блокируем то, что меняет user-data, не temp-state.
- **Защита от malicious extensions.** Контракт работает в условиях добросовестных пилотов. Если extension намеренно обходит хук (например, через `python -c 'open(...,"w")'`) — это вне модели угроз.

## История

- **v1 (отвергнут):** dry-run флаг в каждом скилле (вариант A на ArchGate v1). Декларативный контракт, LLM могла пропустить флаг.
- **v2 (отвергнут):** dry-run флаг в `/run-protocol` (F2 на ArchGate v2). Не покрывает авторские inline-скиллы.
- **v3 (отвергнут):** sentinel + хук, session-bound имя файла (F3 на ArchGate v3). Покрывал все скиллы независимо от их структуры, но session-bound sentinel не переживал субагентов — issue #237.
- **v4 (WP-7/BUGTRIAGE2):** единый sentinel-файл (не session-bound) + разбор Bash-команды на простые сегменты вместо построчного regex. Закрывает 4 дыры, найденные и подтверждённые живым запуском хука: залипание блокировки у субагентов, самоблокирующийся cleanup, subshell-обход, ложные срабатывания на текст в кавычках.
- **v5 (текущий, issue #460):** живая установка поймала 7 fail-open путей разом — `/audit-installation` реально записал в файл во время репетиции. Fail-closed вместо fail-open на jq-missing (путь 1) и sentinel-missing-with-owner (путь 2); TTL 600с→2400с + fail-closed вместо `rm+allow` на истечении (путь 3); `python`/`python3` добавлены в indirect-execution матчер (путь 5); Stop-хук больше не удаляет живой sentinel вообще, даже свой — только residue owner-файл, когда sentinel уже снят явно (путь 6); путь 7 (чужая сессия) подтверждён уже закрытым, покрыт регресс-тестом.
