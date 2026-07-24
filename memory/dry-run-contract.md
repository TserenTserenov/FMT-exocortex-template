---
valid_from: 2026-04-26
related: [VR.SC.005, DP.ARCH.001]

type: protocol
horizon: warm
domains: [reference]
status: active
owner: user
schema_version: 1

name: "dry-run-contract"
description: "Операционный файл памяти IWE"
---
# Dry-run контракт для скиллов с побочными эффектами

> **Назначение.** Гарантировать read-only режим для ритуальных скиллов (`/day-open`, `/day-close`, `/week-close`, `/month-close`), чтобы `/audit-installation` мог реально smoke-тестить их без создания drift.
>
> **Принцип реализации (вариант F3).** Скиллы НЕ знают про dry-run. Защита через **PreToolUse-хук + sentinel-файл** — внешний механизм, независимый от логики скилла. Это покрывает и автора (inline-скиллы), и пилотов (FMT-делегирование), и кастомные скиллы пилотов.

## Sentinel-механика

### Файл

```
/tmp/iwe-dry-run.flag
```

- **Имя:** единый файл, не session-bound (v2, WP-7/BUGTRIAGE2, issue #237). `CLAUDE_SESSION_ID` не пробрасывается в окружение субагентов — session-bound имя создавало рассинхрон: главный агент создавал `iwe-dry-run-${SID}.flag` по своему SID, а Stop-hook субагента чистил по своему (пустому/другому) SID, промахиваясь мимо реального файла. Единое имя убирает рассинхрон создания/очистки.
- **Содержимое:** одна строка JSON: `{"created_at": "<ISO8601>", "session_id": "<id-инициатора>", "initiator": "<skill-name>"}` — session_id хранится только для диагностики, не участвует в поиске/очистке файла.
- **TTL:** 10 минут от mtime. Хук игнорирует файл с mtime > 10 мин назад (защита от sticky-state при kill -9 / краше CLI).
- **Очистка:** (а) явная — финал шага в `/audit-installation`; (б) Stop-hook (`protocol-stop-gate.sh` — безусловный `rm -f /tmp/iwe-dry-run.flag`, без привязки к `CLAUDE_SESSION_ID`); (в) TTL — mtime > 10 мин.
- **Известное ограничение единого файла:** Stop любой параллельной сессии снимет активный dry-run другой сессии. Модель угроз контракта — добросовестный агент/случайный обход, не конкурентная многосессийность вокруг одного smoke-теста (см. §«Не входит в контракт»); TTL и синхронность прогона внутри одного хода инициатора страхуют остаточный риск.

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

При наличии валидного sentinel-файла (единое имя, mtime ≤ 10 мин) хук блокирует **любой tool-call с побочными эффектами** и возвращает exit 2 с диагностикой:

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

**v3 (2026-07-23, /audit-installation follow-up):** два фикса поверх v2 (issue #237):

- **Квотинг сохраняет содержимое.** v2 стирал каждый кавычный спан в фиксированный
  `QSTR` ДО классификации — защищало сегментацию от метасимволов внутри строк, но
  заодно стирало путь у legit-вызовов вида `bash "$IWE_SCRIPTS/script.sh"`, из-за
  чего whitelist read-only хелперов (issue #264) не матчился для цитированных
  путей, только для голых. v3 заменяет каждый спан на ИНДЕКСИРОВАННЫЙ плейсхолдер
  (`__Q0__`, `__Q1__`, ...), исходный текст сохраняется в массиве `QVALS[]` и
  разворачивается обратно точечно, только внутри проверки whitelist —
  сегментация по-прежнему видит безопасный плейсхолдер, а не сырые метасимволы.
- **Классификация по basename.** git/rm/mv/tee/sed/curl/psql/bash/sh/zsh
  матчились только как bareword — вызов по полному пути (напр. `/usr/bin/git`)
  не матчил ничего и утекал необнаруженным. v3 классифицирует по `${W0##*/}`
  (basename первого слова фрагмента), путь не имеет значения для распознавания
  команды.

Три прохода (структура v2 сохранена, детали см. выше):
(1) вырезать кавычные спаны в индексированные плейсхолдеры, (2) разбить
нормализованную строку на простые команды по `; & | && || ( ) { } $( ``,
(3) классифицировать каждый фрагмент по basename первого слова (после пропуска
`VAR=val`/`command`/`env`/`nohup`/`time`/`sudo`). Закрывает subshell-обход
(`(git commit)`), ложные срабатывания на текст внутри кавычек (`echo "git commit"`)
и full-path обход (`/usr/bin/git commit`).
Реализация — `.claude/hooks/dry-run-gate.sh`, функции `normalize_cmd`/`check_indirect`,
секция «Bash matchers».

Классифицируемые команды (по basename первого слова фрагмента):

```
git (add|commit|push|pull|reset|merge|rebase|mv|rm), git checkout -*
rm | mv                     # кроме cleanup собственного sentinel
tee (не /dev/null)
sed -i*
curl -X (POST|PUT|DELETE|PATCH) | curl --data | curl -d
psql ... (INSERT|UPDATE|DELETE|TRUNCATE|DROP|ALTER)   # матчится по оригиналу (SQL в кавычках)
bash|sh|zsh <script>              # indirect execution — block, КРОМЕ whitelist ниже (issue #264)
<путь>/<script>                   # прямой запуск executable без bash/sh/zsh впереди —
                                   # тот же whitelist, что и bash|sh|zsh
eval|source|.|xargs               # indirect execution — payload неинспектируем после quote-strip
> файл / >> файл                  # редирект в реальный файл (не /dev/null)
```

Whitelist read-only helpers (issue #264) — разрешены под dry-run, т.к. write-путей
в коде скрипта нет (проверяется при добавлении, см. правило ниже):

```
.claude/scripts/load-extensions.sh                              # относительный, от workspace-root
$HOME/IWE/.claude/scripts/load-extensions.sh                     # абсолютный, захардкожен
FMT-exocortex-template/scripts/day-close-prepare.sh              # относительный (то же самое, что резолвит $IWE_SCRIPTS)
$HOME/IWE/FMT-exocortex-template/scripts/day-close-prepare.sh    # абсолютный, захардкожен ($HOME/IWE + путь $IWE_SCRIPTS)
$IWE_SCRIPTS/day-close-prepare.sh                                 # литерал как в SKILL.md, НЕ развёрнутая переменная —
                                                                   # сверяется по точному тексту, хук её не разворачивает
```

Абсолютные паттерны захардкожены в `$HOME/IWE`, не glob `*/.claude/...` и не
`$IWE_ROOT` — иначе подложный `/tmp/.claude/scripts/load-extensions.sh` или
env-инъекция `IWE_ROOT=/tmp/evil` прошли бы gate (review-01 High, review-02 H1).
Литеральная форма `$IWE_SCRIPTS/day-close-prepare.sh` сверяется как текст, а не
раскрывается — хук никогда не вызывает `eval`/expansion над входной командой,
поэтому переменные окружения самого хука не влияют на результат сравнения.
Пользователи с нестандартным расположением workspace вызывают helper
относительным путём из корня workspace.

Правило whitelist: добавление только через (1) строку здесь + (2) паттерн в
`check_indirect()` в dry-run-gate.sh + (3) code review на отсутствие write-путей
(redirect/tee/sed -i/mv/rm в коде скрипта).

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

## Ограничения matcher'а, закрытые в v3 (2026-07-23)

Обе находки из первого прохода audit-installation исправлены (см. «Bash matchers»
выше за деталями реализации):

- ~~Полный путь к известной команде обходит её специфичную проверку~~ — классификация
  теперь по basename (`${W0##*/}`), `/usr/bin/git commit` матчит ту же ветку `git)`,
  что и bareword `git commit`.
- ~~Quoted-аргументы всегда блокируются, даже для whitelisted-скриптов~~ — кавычные
  спаны теперь индексированные плейсхолдеры с сохранением исходного текста
  (`QVALS[]`), whitelist сверяется с реальным содержимым, а не с потерянным `QSTR`.

Регресс проверен: 25 тестов (сценарии из issue #237 п.1/п.4, git read/write bareword
и full-path, whitelist bareword/quoted/direct-exec, sentinel cleanup, redirect,
psql/curl/sed, отсутствие sentinel) — все зелёные, до и после фикса поведение
идентично там, где не должно было меняться.

## История

- **v1 (отвергнут):** dry-run флаг в каждом скилле (вариант A на ArchGate v1). Декларативный контракт, LLM могла пропустить флаг.
- **v2 (отвергнут):** dry-run флаг в `/run-protocol` (F2 на ArchGate v2). Не покрывает авторские inline-скиллы.
- **v3 (отвергнут):** sentinel + хук, session-bound имя файла (F3 на ArchGate v3). Покрывал все скиллы независимо от их структуры, но session-bound sentinel не переживал субагентов — issue #237.
- **v4 (текущий, WP-7/BUGTRIAGE2):** единый sentinel-файл (не session-bound) + разбор Bash-команды на простые сегменты вместо построчного regex. Закрывает 4 дыры, найденные и подтверждённые живым запуском хука: залипание блокировки у субагентов, самоблокирующийся cleanup, subshell-обход, ложные срабатывания на текст в кавычках.
