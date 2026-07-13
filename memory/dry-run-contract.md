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

При наличии валидного sentinel-файла (для текущего `SESSION_ID`, mtime ≤ 10 мин) хук блокирует **любой tool-call с побочными эффектами** и возвращает exit 2 с диагностикой:

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
bash|sh|zsh|eval|source|.|xargs   # indirect execution — payload неинспектируем после quote-strip
> файл / >> файл             # редирект в реальный файл (не /dev/null)
```

### MCP-write matcher

**IWE Gateway (`iwe-knowledge`, `mcp.aisystant.com/mcp`) — сверка по ДЕЙСТВИЮ, не по префиксу.**

Префикс MCP-инструмента дрейфует между способами подключения к одному и тому же Gateway,
поэтому exact-list по полному имени устаревает при каждой миграции namespace:

| Namespace | Откуда | Пример |
|---|---|---|
| `mcp__claude_ai_IWE__<action>` | legacy connector с именем «IWE» | `mcp__claude_ai_IWE__personal_write` |
| `mcp__iwe_knowledge_<action>` | OMP runtime (одинарный разделитель `_`) | `mcp__iwe_knowledge_personal_write` |
| `mcp__iwe-knowledge__<action>` | project `.mcp.json` (server id `iwe-knowledge`) | `mcp__iwe-knowledge__personal_write` |
| `mcp__claude_ai_https_..._mcp__<action>` | connector с именем, производным от URL | `mcp__claude_ai_https_mcp_aisystant_com_mcp__personal_write` |

Хук блокирует по **действию** — суффиксу после последнего разделителя (`*_<action>` ловит и
`__<action>`, и OMP-вариант `_<action>`). Список действий (все write / side-effect):

```
personal_write  personal_delete  personal_create_pack  personal_propose_capture
personal_reindex_source  personal_scaffold_notes  personal_connect_source
personal_disconnect_source  personal_purge_source  personal_generate_fault_remind
dt_write_digital_twin  create_repository  github_connect  github_disconnect
knowledge_feedback  knowledge_reindex_source  send_telegram_message
run_strategist  run_extractor  capture_trace  grant_consent
agent_status_update  request_equipment_upgrade
```

**Vendor MCP — exact tool_name** (префиксы вендоров стабильны):

```
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
if [ -f "/tmp/iwe-dry-run-${CLAUDE_SESSION_ID:-noid}.flag" ]; then
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
- **v4 (текущий, WP-7/BUGTRIAGE2):** единый sentinel-файл (не session-bound) + разбор Bash-команды на простые сегменты вместо построчного regex. Закрывает 4 дыры, найденные и подтверждённые живым запуском хука: залипание блокировки у субагентов, самоблокирующийся cleanup, subshell-обход, ложные срабатывания на текст в кавычках.
