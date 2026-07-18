# AGENTS.md

> **Сгенерировано `scripts/sync-agent-instructions.sh` (WP-394 Ф4.2). НЕ РЕДАКТИРОВАТЬ ВРУЧНУЮ.**
> Этот файл предназначен для Codex, Kimi Code и других агентов, поддерживающих `AGENTS.md`.
> Общее ядро → блок `<!-- SYNC-CORE -->` в `CLAUDE.md`. Дополнения → `AGENTS-agent-blocks.md`.


## WP Gate — CRITICAL

**ЛЮБОЕ задание → протокол Открытия → ДО начала работы.** При создании нового РП: объявить роль, работу, РП, класс верификации, метод, оценку, модель. Дождаться согласования пилота.

## State-Transition Gate — CRITICAL

**Перед любым нетривиальным действием или РП назвать целевой переход состояния пользователя** `{тип состояния, из→в}` (WP-457). Типы — только `DS-strategy/docs/state-axes-registry.yaml`, допустимы только `gate_ready: true`; ссылка на declared FSM-owner обязательна, свободный текст не принимается. Нет ссылки или тип не `gate_ready` → действие = inventory → СТОП/отложить. Модель осей → `archive/wp-contexts/WP-457/CONCEPT-user-states.md §5`; cross-axis → `agent-core.md`.

## Git Staging — CRITICAL

**NEVER `git add -u`, `git add .`, `git add -A`** — подхватывают изменения ДРУГИХ агентов (Kimi/Hermes работают параллельно) → неверная атрибуция. Стейджить только конкретные файлы; перед коммитом `git diff --cached --name-only`, лишнее — `git restore --staged`. Примеры → `memory/reference/agent-core.md`.

## Artifact Naming

**Do not invent artifact names.** Names for sections, documents, RPs, and deliverables must come from the plan/task you received. If the task is silent on a name — report "need clarification on name" instead of making one up.

## Drift Reporting

Discrepancy found (file ≠ plan, stale content): **report to pilot, do not silently fix.** Format: "Found drift: [what] in [file]. Should I fix it?" Fix only if explicitly instructed.

## Working Directory

`{{WORKSPACE_DIR}}/`

## Status Reporting — Agent Status Registry (РП-395)

**Primary (обязательно):** в начале задачи `agent_status_update(agent=<claude-code|kimi|hermes>, status=working, task=<кратко>, files=[...])`; по завершении — `status=idle`. Статусы: `idle|working|peer-session|blocked`; пилот видит всех через `agent_status_list`. Командный режим (`repo=`) и fail-safe скрипт → `memory/reference/agent-core.md`.

## Long Operation Protocol — 180 s Silence Threshold

**Не молчи больше 180 секунд.** Операция >180с → ДО запуска сообщить: что запускается, длительность, шаг X из Y, id фоновой задачи. >180с тишины → микро-отчёт «Всё ещё работаю. Текущий шаг: [X из Y]. Следующий: [Z].» Касается всего, где пилот видит пустое «Thinking» (bash, subagent, фоновые задачи, Close-протоколы).

## WP-REGISTRY Naming — CRITICAL

**Колонка «Название» в WP-REGISTRY содержит ТОЛЬКО имя артефакта ≤80 символов** — без дат, ссылок на сессии, метрик, SHA и прочих служебных данных.

**Куда писать остальное:** итог закрытия → `## Закрытие` в `archive/wp-contexts/`; фазы/прогресс → frontmatter `inbox/WP-NNN/WP-NNN.md` (всегда папка — WP-434), при смене статуса фаз обновлять frontmatter, НЕ имя реестра. Полный текст и примеры ✅/❌ → `memory/reference/agent-core.md`.

## WP Context Scope — Umbrella РП

Umbrella-РП с `agent_scope: open-only` (WP-5, WP-7) — читать **только** фазы `pending`/`in_progress`/`blocked`; архивные — не читать без явного запроса пользователя.

## Calendar Events — CRITICAL

**All agent-created reminders and calendar events must be scheduled BEFORE 09:00 AM** (позже — только с явного одобрения пилота). Создано после 09:00 по ошибке → удалить + пересоздать до 09:00 + сообщить пилоту (шаги → `memory/reference/agent-core.md`).

## Language

Respond in Russian unless the user writes in English.

## Response Style — Pilot-Facing

Правила понятного ответа пилоту (полный текст — `memory/feedback_response_clarity_for_pilot.md`) — в чате, синтезе отчётов и пост-отчётах после действий.

**Channel detector:** технический стиль — стенограммы peer-сессий, commit, PR; «на пальцах» — чат с пилотом (если тот сам не пишет `grep`/`git`/пути/SHA) и §1-§4 синтеза report.md.

**Eleven rules (A1-A11), short:** A1 путь файла не подлежащее (только в скобках после русского глагола); A2 английский термин только после русского описания в скобках; A3 первое упоминание колонки/функции — расшифровка одним словом; A4 pre-flight: примет ли пилот решение по этой фразе; A5 ЧТО до КАК; A6 одна стрелка-следствие на предложение; A7 «сделал → эффект», `<details>` — только при наличии нужных пилоту деталей или по его явному запросу; A7.1 журнал (SHA, коммиты, дефекты) — только в файл отчёта, не в чат; A8 журнал процесса по умолчанию не писать; A9 channel detector; A10 английские маркеры статуса (exit/PASS/SHA) → русские слова; A11 активный залог на ошибках и находках.

## Code Style — Engineering (DP.SC.172)


**P-правила, short:** P0 перед коммитом — форматтер+линтер репо (механику закрывает инструмент); P1 тест без проверки наблюдаемого результата запрещён (`assert True` — запах); P2 третье повторение → функция, не `locals()[str]`; P3 мёртвую ветку/enum удалять, не «для совместимости»; P4 `except: pass` без логирования запрещён; P5 длинную функцию со смешанными обязанностями / булевы флаги-режимы — разбить. Граница: жёсткие запреты (`git add -A`, секреты) — в PACK-agent-rules (AR.*), не здесь. (Доставка/детекторы по агенту → `memory/reference/agent-core.md`.)



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

## Codex Runtime

Codex использует этот `AGENTS.md` как постоянные проектные инструкции. При работе в Codex:

- проектные skills искать в `.agents/skills/`; наличие одноимённого Claude skill в `.claude/skills/` не означает, что он доступен в Codex;
- не считать slash-команды и hooks Claude Code доступными автоматически — использовать их Codex-эквиваленты, если они настроены в проекте;
- если MCP Gateway или его инструменты блокировок недоступны, не имитировать вызов: проверить `git status`, ограничить правки файлами текущей задачи и сообщить о пересечении изменений.

## Kimi Runtime — IWE Instructions Level (headless)

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

## Coordination Protocol (MCP Gateway, when available)

> Только для агентов, которым фактически доступны инструменты Local Gateway (обычно Claude Code и Kimi).
> Codex следует этому протоколу лишь при наличии этих инструментов. Hermes НЕ имеет MCP Gateway
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
