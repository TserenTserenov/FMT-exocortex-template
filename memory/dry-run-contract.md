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
/tmp/iwe-dry-run-${SESSION_ID}.flag
```

- **Имя:** `iwe-dry-run-${SESSION_ID}.flag`. `SESSION_ID` = идентификатор Claude Code сессии (получается из env `CLAUDE_SESSION_ID` или генерируется через `uuidgen`/`date +%s%N` если env пуст).
- **Содержимое:** одна строка JSON: `{"created_at": "<ISO8601>", "session_id": "<id>", "initiator": "<skill-name>"}`.
- **TTL:** 10 минут от mtime. Хук игнорирует файл с mtime > 10 мин назад (защита от sticky-state при kill -9 / краше CLI).
- **Очистка:** (а) явная — финал шага в `/audit-installation`; (б) Stop-hook (`protocol-stop-gate.sh` — добавить очистку для текущего session-id); (в) TTL — mtime > 10 мин.

### Жизненный цикл

```
[start]  /audit-installation шаг smoke-test
         → echo "$payload" > /tmp/iwe-dry-run-${SESSION_ID}.flag
         → запуск subagent: /run-protocol close day (через Agent tool)
         → ...
[end]    rm -f /tmp/iwe-dry-run-${SESSION_ID}.flag
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

Регулярные выражения для блокировки в `command`:

```
^git\s+(commit|push|pull|reset|merge|rebase|checkout\s+-)
\s>\s(?!/dev/null)         # перенаправление в файл
\s>>                        # append в файл
\bpsql\s+.*-c\s+["'].*INSERT|UPDATE|DELETE|TRUNCATE|DROP|ALTER
\bcurl\s+.*-X\s+(POST|PUT|DELETE|PATCH)
\bcurl\s+.*--data
\b(rm|mv|cp)\s+-r?\s
\bcat\s+>>?\s
\btee\s+(?!/dev/null)
\bsed\s+-i
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
- **v3 (текущий):** sentinel + хук (F3 на ArchGate v3). Покрывает все скиллы независимо от их структуры.
