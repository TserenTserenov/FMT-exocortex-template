# AGENTS.md

> **Сгенерировано `scripts/sync-agent-instructions.sh` (WP-394 Ф4.2). НЕ РЕДАКТИРОВАТЬ ВРУЧНУЮ.**
> Общее ядро → блок `<!-- SYNC-CORE -->` в `CLAUDE.md`. Агент-специфика → `AGENTS-agent-blocks.md`.


## WP Gate — CRITICAL

**ЛЮБОЕ задание → протокол Открытия → ДО начала работы.** При создании нового РП: объявить роль, работу, РП, класс верификации, метод, оценку, модель. Дождаться согласования пилота.

## Git Staging — CRITICAL

**NEVER use `git add -u`, `git add .`, or `git add -A`.**

These commands pick up staged/unstaged changes from OTHER agents (Claude Code works in the same repo simultaneously). Wrong attribution and accidental commits of other agents' work result.

**Always stage only specific files you edited:**
```bash
# Correct
git add path/to/specific-file.md

# FORBIDDEN — captures other agents' work
git add -u
git add .
git add -A
```

## Artifact Naming

**Do not invent artifact names.** Names for sections, documents, RPs, and deliverables must come from the plan/task you received. If the task is silent on a name — report "need clarification on name" instead of making one up.

## Drift Reporting

If you discover a discrepancy (file doesn't match plan, stale content, inconsistency):
- **Report to pilot, do not silently fix.**
- Format: "Found drift: [what is inconsistent] in [file]. Should I fix it?"
- Only fix if explicitly instructed.

## Working Directory

`{{HOME_DIR}}/IWE/`

## WP Context Scope — Umbrella РП

Для зонтичных (umbrella) РП с `agent_scope: open-only` в frontmatter:
- Читать **только** фазы со статусом `pending` / `in_progress` / `blocked`
- Архивные (`done`, `closed`, `defer`) — **не читать** без явного запроса пользователя
- Исключение: если пользователь даёт задание с указанием конкретной архивной фазы

Применяется к: WP-5, WP-7.

## Calendar Events — CRITICAL

**All platform reminders and calendar events created by the agent must be scheduled BEFORE 09:00 AM.**

This includes: task reminders, follow-up events, template migration tasks, any agent-generated calendar entries.

**Never** schedule agent-created events at or after 09:00 without explicit pilot approval.

If an event is created after 09:00 by mistake:
1. Delete the incorrect event immediately
2. Recreate it before 09:00 on the same day, or on the next available pre-09:00 slot
3. Report the error to the pilot

## Language

Respond in Russian unless the user writes in English.

## Response Style — Pilot-Facing

Агент должен применять правила понятного ответа пилоту (полный текст — `memory/feedback_response_clarity_for_pilot.md`, HOT) в ответах чата, синтезе отчётов и пост-отчётах после действий.

**Channel detector:** технический стиль — для стенограмм ходов peer-сессий, commit-сообщений, PR; режим «на пальцах» — для чата с пилотом (если пилот сам не пишет `grep`/`git`/пути/SHA) и для §1-§4 синтеза report.md.

**Eleven rules (A1-A11), short:** A1 путь файла не подлежащее (только в скобках после русского глагола); A2 английский термин только после русского описания в скобках; A3 первое упоминание колонки/функции — расшифровка одним словом; A4 pre-flight: примет ли пилот решение по этой фразе; A5 ЧТО до КАК; A6 одна стрелка-следствие на предложение; A7 формат «сделал → эффект → детали под спойлером»; A8 журнал процесса по умолчанию не писать; A9 channel detector; A10 английские маркеры статуса (exit/PASS/SHA) → русские слова; A11 активный залог на ошибках и находках.



## Commit Attribution

Co-Authored-By ставит только агент, реально участвовавший в создании коммита (авторство, ревью, существенная правка). Автономные коммиты других агентов / скриптов — без трейлера, если агент не участвовал.

Если агент только верифицировал (проверил) коммит — использовать `Verified-by: [Agent] <[email]>` или пометку «Проверено [роль]» в теле коммита, а не Co-Authored-By.

### Для коммитов с участием Kimi

**Method 1 (preferred — template):**
```bash
git commit -t ~/.git-commit-template-kimi -m "feat: description"
```

**Method 2 (manual — if template unavailable):**
```bash
git commit -m "feat: description" --trailer "Co-Authored-By: Kimi <noreply@moonshot.ai>"
```

**Never** commit without the trailer. If you forget — amend immediately:
```bash
git commit --amend --trailer "Co-Authored-By: Kimi <noreply@moonshot.ai>"
```

### Для коммитов с участием Hermes (Nous Research)

```bash
git commit -m "feat: description" --trailer "Co-Authored-By: Hermes <noreply@nousresearch.com>"
```

**Hermes Agent** — оркестратор в экосистеме IWE (РП392). Подключён к Aisystant MCP, работает через CLI/Telegram. Hermes НЕ заменяет Claude Code или Kimi Code в кодинге — он координирует, запоминает и даёт мобильный доступ.

## IWE Instructions Level (Kimi headless)

# IWE workspace with 5000+ docs and multiple Packs — use experienced level.
# Revisit if a new small repo (< 1000 docs) is added to {{HOME_DIR}}/IWE/.
When calling `get_instructions` (Aisystant MCP) to load IWE context,
use `level="experienced"` instead of the default `level="full"`.
This reduces token load by ~89% (~10K → ~1.1K) on every headless turn.

Example:
```
get_instructions(level="experienced")
```

This applies to all Kimi sessions: peer (via kimi-peer-adapter.sh) and standalone.
Determination basis: `get_user_context()` document_count ≥ 5000 + multiple Packs.

## Coordination Protocol (MCP Gateway)

> Для агентов с доступом к Local Gateway (Claude Code, Kimi). Hermes НЕ имеет MCP Gateway
> (`acquire_file_lock` / `release_file_lock`) — он использует `terminal` + `patch` напрямую,
> а при конфликте на push сообщает пилоту.

Before starting any edit task:

1. **Declare intention** (no lock needed):
   ```
   Tool: update_peer_status
   params: { "status": "working", "current_task": "<brief>", "files": ["relative/path/file.md"] }
   ```

2. **Acquire lock** before first Edit:
   ```
   Tool: acquire_file_lock
   param: canonical_file = relative path from IWE root
   ```

3. **Release lock** after commit:
   ```
   Tool: release_file_lock
   ```

4. On `lock_collision`: wait 30s and retry, or switch to another file.

## Hermes Agent — координация

Если в экосистеме присутствует Hermes Agent (оркестратор с персистентной памятью, РП-392):
- Hermes НЕ заменяет Claude Code / Kimi Code в кодинге — координирует, запоминает, даёт мобильный доступ.
- Hermes НЕ имеет MCP Gateway (`acquire_file_lock` / `release_file_lock`) — правит файлы через `terminal` + `patch`.
- При правках критичных файлов: сначала `git pull`, проверить `git status`, потом править; конфликт на push — сообщить пилоту.

## Prompt Cache Pattern

- Паттерн PREFIX/BODY/TAIL для headless-агентов → см. `memory/sota-prompt-cache.md`.
- Применять при сборке системного промпта multi-turn агента: стабильное (идентичность, правила) — в PREFIX/BODY до cache-breakpoint; волатильное (память, timestamp) — в TAIL.
