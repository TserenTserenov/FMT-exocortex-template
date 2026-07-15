# Инструкции для всех репозиториев

> **Агент-специфичные инструкции:** Kimi → `AGENTS.md`, Hermes → Aisystant MCP `get_instructions`.
> **Синхронизация:** `scripts/template-sync.sh` проверяет согласованность ядра правил.

> Slim-ядро: триггеры + правила. Детали → memory/protocol-*.md, .claude/rules/, .claude/skills/.

## 1. Архитектура репозиториев

| Тип | Что содержит | Первоисточник |
|-----|-------------|---------------|
| **Base** (Принципы + Форматы) | ZP, FPF, SPF, FMT-* | Да (платформа) |
| **Pack** | Паспорт предметной области | Да (пользователь) |
| **DS** (instrument/governance/surface) | Код, планы, курсы | Нет (производное от Pack) |

**Fallback Chain:** DS → Pack → Base (SPF → FPF → ZP)
**Pack = source-of-truth для доменного знания. DS меняется вслед за Pack.**
Детали типов, именование, измерения: → `memory/repo-type-rules.md`

**Pack Creation Gate:** хочешь создать Pack → `/pack-new`. Структура Pack = `SPF/pack-template/`. Процесс = `SPF/process/01-11`. Имя = существительное-домен (не тема, не инструмент). Если `FPF/` или `SPF/` отсутствуют в рабочей директории — `/pack-new` клонирует их автоматически.

## 2. ОРЗ-фрактал (Открытие → Работа → Закрытие)

> Три стадии, три масштаба. Пропуск Открытия = незапланированная работа. Пропуск Закрытия = незафиксированный результат.

| Масштаб | Открытие | Работа | Закрытие |
|---------|----------|--------|----------|
| **Сессия** | `protocol-open.md § Сессия` (любое задание) | `protocol-work.md` | `/run-protocol close` |
| **День** | `/day-open` («открывай») | Между Day Open и Day Close | `/run-protocol day-close` |
| **Неделя** | — | — | `/run-protocol week-close` |
| **Месяц** | — | Между Month Close предыдущего и текущего | `/month-close` (первый Пн месяца, до Strategy Session) |

### Блокирующие правила

> **Source-of-truth (WP-272 Ф1, 26 апр):** правила формализованы в `PACK-agent-rules/rules/AR.NNN.md` с frontmatter (id, type, priority, triggers, tests, hook). Реестр генерируется в `.claude/rules-registry.yaml` через `python3 .claude/scripts/generate-rules-registry.py`. Диспатчер: `.claude/hooks/rule-engine.sh`. Ниже — горячая выжимка top правил для агента; полный текст — в Pack.
>
> **Иерархия при конфликте:** правила нумерованы по приоритету (= AR-priority в Pack).
> Структурное (1-5) ВСЕГДА перевешивает поведенческое (6-10). Структурное = «без них работы нет». Поведенческое = «как себя вести внутри уже согласованной работы».
> Пример (C-001 в conflicts.md): WP Gate priority=1, Автономность priority=6. При конфликте AR.001 выигрывает.

1. **WP Gate:** ЛЮБОЕ задание → протокол Открытия → ДО начала работы.
   **Ритуал согласования (горячий, не lazy):** при создании нового РП (нет в плане недели) Claude обязан:
   - Шаг 1. Объявить: Роль пользователя · Роль Claude · Работа · РП (артефакт) · Режим ТВС (текущее/важное/срочное — конвейерная модель; «срочное» только при угрозе остановки конвейера, не по дедлайну/«горит») · Класс верификации (trivial/closed-loop/open-loop/problem-framing) · Метод · Оценка ~Xh · Модель.
   - Шаг 2. **Дождаться согласования.** Без явного «да»/«делаем»/«открывай» от пользователя — НЕ регистрировать РП в 4 местах (REGISTRY/WeekPlan/context/Linear). Это исключение из Правила 7 (Автономность).
   - Шаг 3-4. См. `memory/protocol-open.md` (детали).
2. **Push:** «заливай» / «запуши» / «закрывай» → commit + push без доп. вопросов. Push ДО отчёта Закрытия. **При любом Close-протоколе (Quick/Day/Week):** `git status --short` по ВСЕМ репо сессии — незафиксированные изменения → commit + push ДО перехода к следующему шагу протокола.
3. **Close:** Триггер Закрытия → протокол Закрытия → выполнить.
4. **Pull-on-Touch:** `git pull --rebase` при первом **обращении** к репо за сессию (любое — `ls`/`Read`/`find`/`grep`/Edit/commit), один раз на репо, lazy. Применяется ко ВСЕМ git-репо в `{{WORKSPACE_DIR}}/*`, не только governance. Перед pull — `git status`: dirty → stash или пропустить с пометкой «вывод potentially stale»; rebase conflict → два варианта: (А) stash незафиксированных изменений + пометить вывод как potentially stale → продолжить; (Б) прервать сессию + отчёт пилоту. Default: вариант А. Без автоматического разрешения конфликта. Сетевой fail → работать с локальной копией, помечать выводы как potentially stale. Причина расширения с «изменения» на «обращения»: 5 мая 2026 ложный диагноз «Day Open пропущен» из-за чтения устаревшей локальной копии DS-strategy (origin был на 3 коммита впереди). Без Obsidian: см. §9.
5. **Чеклист-верификация (Haiku R23):** Quick Close и Day Close — sub-agent Haiku R23 (context isolation). Проверяет формальное соответствие чеклисту (все ли пункты закрыты, есть ли коммит, обновлён ли MEMORY.md), но не оценивает качество результата. Исключения: сессия ≤15 мин или без изменений файлов.
6. **Hooks/Scripts Bypass Gate (БЛОКИРУЮЩЕЕ, S-33):** Без явного разрешения пользователя НЕ менять скрипты шаблона (`.claude/hooks/`, `.claude/scripts/`, `.iwe-runtime/`, `FMT-exocortex-template/`) и НЕ обходить хуки никаким способом (`--no-verify`, изменение флагов запуска, `git config core.fileMode false` без причины, переопределение `AI_CLI_EXTRA_FLAGS`). Если хук или скрипт IWE блокирует действие: (1) НЕ обходить — выполнять как задумано; (2) записать ошибку в `<governance-repo>/inbox/bugs/bug-YYYY-MM-DD-<тема>.md`; (3) сообщить пользователю что заблокировано и где bug-файл; (4) ждать инструкций. Исключение — пользователь явно говорит «обойди» / «игнорируй хук» / «измени скрипт». **Источник:** Дмитрий (пилот), 2026-04-28; ортогонально Extensions Gate (тот про «куда писать кастомизацию», этот — «что делать когда хук блокирует»).
7. **Автономность (поведенческое):** НЕ спрашивать подтверждения — ни «добавить?», ни «продолжить?», ни «записать?», ни «хотите...?». Задание → выполни → отчитайся. Не заканчивать сообщение вопросом. Очевидные следствия (синхронизация, обновление связанных файлов) — делать сразу. Факт, проверяемый самостоятельно (grep, БД, конфиг), — проверять, а не спрашивать. **Исключения** (когда вопрос/согласование легитимны):
    - **Необратимое разрушительное действие** (force push в прод, удаление данных без бэкапа).
    - **WP Gate Ритуал** (создание/закрытие/изменение РП): согласование артефакта/формулировки/репо/бюджета через Ритуал §2 Open. Это другая ось — НЕ нарушение Правила 1. Без согласия пользователя новый РП НЕ создавать (даже если задача очевидно «перерастает в РП» — формальное предложение, не автономная регистрация в 4 местах).
    - **Choice-question** (выбор между альтернативами): «делаем X или Y?», «сегодня или завтра?» — заказчик решает, это нормальный режим collaboration. Запрещены только yes/no запросы согласия на готовое решение.

    Отклонение инструмента ≠ запрет навсегда — попробовать другой путь. Детали и журнал нарушений → `memory/feedback_behaviour.md` Правило 1. Подтверждено P5-детектором: апрель 2026 — 853 срабатывания в 104 сессиях. 26 апр WP-271: P5-block на одну фразу интерпретирован как «не задавать никаких вопросов» → пропущен WP Gate, создан РП без согласия → нужны исключения выше.
8. **Напоминания (S-44):** «напомни через X», «поставь таймер» → использовать IWE-инструмент Telegram-доставки (стандартно: `send_telegram_message`) с `schedule_at` + одновременно ScheduleWakeup как резервный канал. При срабатывании ScheduleWakeup → сначала отправить через Telegram-инструмент (немедленно, без `schedule_at`), потом написать в чате. Если Telegram-инструмент недоступен → только ScheduleWakeup + сообщить причину. Зачем: уведомление в чате IDE видно только при открытом окне; Telegram доставляет на любое устройство.
9. **Финиш > отлог (S-46):** обнаружена дополнительная задача в текущей сессии (косяк, недоделка, следующий шаг от субагента) → **дефолт = делаю сейчас**, НЕ «отдельный РП / технический долг» первым вариантом. Choice question «сейчас или потом?» = анти-паттерн (скрытое предложение отложить → inventory, не throughput). Исключения для отложения: бюджет ×2-×3, требуется доменное решение/данные, требуется ArchGate, контекст полностью переключился (другая часть системы). **WP Gate приоритет:** если дополнительная задача >15 мин и создаёт новый артефакт — п.1 WP Gate действует (см. AR.001 порог «creates_artifact + >15 мин»); п.9 не отменяет п.1 для таких задач. Детали → [feedback_finish_now_no_defer.md](memory/feedback_finish_now_no_defer.md). Source: 17 мая 2026, WP-311 cleanup эпизод.

### Протокол Работы (полный → `memory/protocol-work.md`)

**Capture-to-Pack** — на каждом рубеже: есть ли знание для записи? Анонсировать: *«Capture: [что] → [куда]»*. Маршрутизация: правило (1-3 строки) → CLAUDE.md, доменное → Pack, реализационное → DS docs/, урок → memory/. Capture-to-Pack — shortcut внутри маршрутизации знаний, не замена Routing Gate. При создании нового артефакта Routing Gate (DP.KR.001 §5) проверяется первым.
**Self-correction:** расхождение → немедленно предложить фикс (файл, строка, что изменить). Применяется только внутри scope текущего хода: файлы/директории из agenda хода (проверяется `git diff HEAD`). За пределами scope — Drift Reporting (Agent Core SYNC-CORE): отчитаться пилоту, не фиксить.

### Pre-action Gates

| Момент | Проверка |
|--------|---------|
| Начало работы | Какие сервисы (MAP.002) затронуты? |
| Пользовательский сценарий | **SC Gate:** какое обещание (08-service-clauses/) затронуто? |
| Первое содержательное действие в репо (Read файла, Edit, ответ о структуре, commit) | **Repo-Touch Gate:** прочитать `<repo>/CLAUDE.md`. Если содержит блок «обязательно загружай» — загрузить указанные файлы ДО ответа. |
| Архитектурное решение | **АрхГейт** → `/archgate` |
| РП затрагивает PII (email, telegram_id, ЦД, tokens, user_events) | **Security Gate (B7.3):** ответить на §Б чеклист ArchGate ДО реализации. Логирование PII = блокер. |
| РП ≥3h | **Priority Gate:** к какому R{N} ведёт? |
| Новый инструмент/агент/система | **IntegrationGate (БЛОКИРУЮЩЕЕ):** проектирование ТОЛЬКО в последовательности — (1) обещание → (2) сценарии → (3) роль → (4) реализация. См. ниже явный чеклист. Прыжок сразу в реализацию = P10 (DP.FM.010). |
| Замена legacy-компонента (миграция из LMS/внешней системы) | **LegacyPortGate (БЛОКИРУЮЩЕЕ):** сначала 15-мин субагент: «как это работает сейчас?» (cron/API/merchant/токены). Решение портирование vs новый дизайн — ТОЛЬКО после ответа. Прыжок в «новый дизайн» без проверки = DP.FM.014 (Legacy Port Jump). См. `memory/feedback_behaviour.md` Правило 10. |

### IntegrationGate — явный чеклист (БЛОКИРУЮЩЕЕ)


2. **Сценарии использования.** Кто запускает? Когда? Зачем? В каком контексте? Что делает с результатом? Минимум 3 сценария с разными потребителями. Приложить к Service Clause.
4. **Реализация.** Только после (1)-(3). Код, тесты, регистрация в hooks/config, smoke-test. Заголовок реализации должен содержать ссылку на Service Clause и Role (`# see DP.SC.NNN, DP.ROLE.NNN`).

**Исключения (IntegrationGate НЕ нужен):**
- Правка существующего инструмента без изменения его обещания.
- Bugfix без изменения поведения снаружи.
- Рефакторинг (переименование, реорганизация) без функциональных изменений.
- Экспериментальный скрипт на один запуск (но если запускается повторно — уже инструмент).

## 3. Описания методов (PROCESSES.md)

≤15 мин — не нужен. Внутри системы — `<repo>/PROCESSES.md`. Новая система — сценарий + процессы + данные.

## 4. Memory (Слой 3)

| Ситуация | Читай |
|----------|-------|
| Файлы/репо | `memory/navigation.md` |
| Pack-репо | `memory/repo-type-rules.md` |
| Терминология | `memory/hard-distinctions.md` |
| FPF/SOTA/Роли | `memory/fpf-reference.md`, `memory/sota-reference.md`, `memory/roles.md` |
| Документ/чеклист | `memory/checklists.md` |

Политика: ≤11 файлов. **Горячие** (читаются каждую сессию: CLAUDE.md, MEMORY.md, distinctions.md, formatting.md): лимит строк — см. `distinctions.md` (WP-7 NR1.2: 150 строк/файл, source-of-truth). Протоколы (lazy, по триггеру): ≤150. **Lazy-reference** (по ссылке из MEMORY.md, не каждую сессию — feedback_*, templates-*, reference_*): без жёсткого лимита, > 300 строк → пересмотреть.
Temporal metadata: `valid_from: YYYY-MM-DD` (обязательно при создании), `superseded_by: <файл>` (при устаревании). Подробности → `protocol-work.md § 2`.
Рабочая директория: `{{HOME_DIR}}/IWE/` (не из sub-директорий). `{{HOME_DIR}}/IWE/memory/` = симлинк на auto-memory.

## 5. АрхГейт — ОБЯЗАТЕЛЬНАЯ оценка

> **БЛОКИРУЮЩЕЕ.** Архитектурное решение → `/archgate` → принципы (DP.ARCH.001 §7) → профиль ЭМОГССБ (✅/⚠️/❌) → conjunctive screening (см. `.claude/skills/archgate/SKILL.md`). Без агрегатного балла — `feedback_decision_gates.md`.
> Чеклист современности: (1) Context Engineering SOTA.002, (2) DDD Strategic SOTA.001, (3) Coupling Model SOTA.011.

## 6. Форматирование → `.claude/rules/formatting.md`

## Различения → `.claude/rules/distinctions.md`

## 7. Обновление этого файла

> **3 слоя:** L1 (§1-§7) = платформа (`update.sh`). L2 (§8) = staging. L3 (§9) = авторское.

- Протоколы → `memory/protocol-*.md`
- Различение (1-3 строки) → `.claude/rules/distinctions.md`
- Форматирование → `.claude/rules/formatting.md`
- Стабильные знания → `memory/*.md`
- Свои правила → §8 (staging) или §9 (авторское)

<!-- PLATFORM-END -->

---

## Agent Core (SYNC-CORE → AGENTS.md)

> **WP-394 Ф4.2.** Ниже — единое ядро инструкций для всех агентов (Claude, Kimi, Hermes).
> `AGENTS.md` генерируется из этого блока + `AGENTS-agent-blocks.md` скриптом
> `scripts/sync-agent-instructions.sh`. **Не редактировать `AGENTS.md` вручную** — правки сюда.

<!-- SYNC-CORE-START -->

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

**Before every commit: verify staged scope.**
Run `git diff --cached --name-only` and confirm that all staged files belong to the current session's WP/context.
If unexpected files appear — `git restore --staged <file>` before committing.

## Artifact Naming

**Do not invent artifact names.** Names for sections, documents, RPs, and deliverables must come from the plan/task you received. If the task is silent on a name — report "need clarification on name" instead of making one up.

## Drift Reporting

If you discover a discrepancy (file doesn't match plan, stale content, inconsistency):
- **Report to pilot, do not silently fix.**
- Format: "Found drift: [what is inconsistent] in [file]. Should I fix it?"
- Only fix if explicitly instructed.

## Working Directory

`{{WORKSPACE_DIR}}/`

## Status Reporting — Agent Status Registry (РП-395)

**Primary (обязательно):** в начале задачи вызвать MCP-инструмент `agent_status_update(agent=<твой-id>, status=working, task=<кратко>, files=[...])`; по завершении — `status=idle`. `agent` = `claude-code` | `kimi` | `hermes`. Статусы: `idle|working|peer-session|blocked`. Инструмент в Aisystant MCP; не виден в каталоге → появится после рестарта сессии (Ф1 в проде). Пилот видит всех агентов через `agent_status_list`.

**Командный режим (WP-398 Ф5):** если работаешь с файлами из командного репо (несколько участников в одном репо), передавай `repo="org/repo-name"` в `agent_status_update`. Это позволяет другим агентам команды видеть твои активные файлы и избегать конфликтов. Пример: `agent_status_update(agent="claude-code", status=working, task="WP-X фаза", files=["src/marathon.py"], repo="TserenTserenov/DS-strategy")`.

**Fail-safe:** если не вызвал сам — детерминированно пишет `{{WORKSPACE_DIR}}/scripts/agent-status-report.sh <agent> <status> [task] [files-csv]` (Claude — из Stop-хука, Kimi — из `kimi-peer-adapter.sh`). Не отменяет primary.

## WP-REGISTRY Naming — CRITICAL

**Колонка «Название» в WP-REGISTRY содержит ТОЛЬКО имя артефакта ≤80 символов.**

Запрещено в колонке «Название»: даты закрытия, ссылки на peer-сессии, метрики фаз, SHA коммитов, результаты проверок, количество тестов, и любые другие служебные данные.

- ✅ `~~Алгоритм диагностики~~`
- ❌ `~~Алгоритм диагностики~~ — closed 30 мая (PHASE1=5, MANDATORY=5...)`

**Куда писать:**
- Итог закрытия РП → раздел `## Закрытие` в `archive/wp-contexts/WP-NNN-*.md`
- Текущие фазы и прогресс → frontmatter поля `phases`/`progress` в `inbox/WP-NNN.md`

**При начале работы с РП:** прочитать `inbox/WP-NNN.md`. При изменении статуса фаз → обновить frontmatter карточки, НЕ имя реестра.

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

**Eleven rules (A1-A11), short:** A1 путь файла не подлежащее (только в скобках после русского глагола); A2 английский термин только после русского описания в скобках; A3 первое упоминание колонки/функции — расшифровка одним словом; A4 pre-flight: примет ли пилот решение по этой фразе; A5 ЧТО до КАК; A6 одна стрелка-следствие на предложение; A7 «сделал → эффект», `<details>` — только при наличии нужных пилоту деталей или по его явному запросу; A7.1 журнал (SHA, коммиты, дефекты) — только в файл отчёта, не в чат; A8 журнал процесса по умолчанию не писать; A9 channel detector; A10 английские маркеры статуса (exit/PASS/SHA) → русские слова; A11 активный залог на ошибках и находках.

## Code Style — Engineering (DP.SC.172)


**P-правила, short:** P0 перед коммитом — форматтер+линтер репо (механику закрывает инструмент); P1 тест без проверки наблюдаемого результата запрещён (`assert True` — запах); P2 третье повторение → функция, не `locals()[str]`; P3 мёртвую ветку/enum удалять, не «для совместимости»; P4 `except: pass` без логирования запрещён; P5 длинную функцию со смешанными обязанностями / булевы флаги-режимы — разбить. Граница: жёсткие запреты (`git add -A`, секреты) — в PACK-agent-rules (AR.*), не здесь. У Claude правила приходят хуком (`inject-code-style.sh`); детектор-страховка `code-style-hook.sh` пишет P1/P2/P4 в единый лог стиля.

<!-- SYNC-CORE-END -->

---

## 8. Staging (обкатка → шаблон)

> Правила на обкатке. Работают → переносятся в шаблон (L1).
> **Перенесено в L1 (20 мар):** SC Gate, межсистемные процессы, чеклист-верификация.
> **Промотировано в FMT (20 апр):** S-13 (именование РП = существительное-артефакт), S-14 (синхронизация REGISTRY→производные).

### Staging-канал (my IWE → FMT-exocortex-template)

- **S-45 Agent Inbox** (WP-324, 17 мая, расширено session 6) — `inbox/agent/` структура + 5 templates + SPEC + DP.SC.135 + DP.ROLE.045 + `iwe-agent-dispatcher.py` (headless `claude -p`, обход CCR v1→v2 bug). Промотировано в FMT `extensions/agent-inbox/` + `pack-templates/digital-platform/`. Status: testing (полная end-to-end automation smoke на расписании — defer-ред: требует Nix systemd unit или cron).

**Правило добавления:** новое поведение в §9 (авторское) → ОДНОВРЕМЕННО строка в STAGING.md (`status: testing`).

**Промоция (при Week Close):**
1. Просмотреть STAGING.md → есть `validated`?
2. Убрать авторские константы → заменить на `{{PLACEHOLDER}}`
3. Перенести в `FMT-exocortex-template` + commit `feat: promote S-NN from staging`
4. Обновить STAGING.md: статус → `promoted`

**Отклонение:** специфичное для авторского окружения → статус `rejected` (остаётся навсегда в §9, не промотируется). Не удалять из таблицы — это решение.

---

## 9. Авторское (только мой IWE)

### Блокирующие (авторские)

- **Pull-before-Commit:** перенесён в §2 п.5 (платформенное правило для ВСЕХ репо).
- **Без Obsidian (DS-strategy):** Просмотр через VS Code.
- **S-33 (Hooks/Scripts Bypass Gate):** перенесён в §2 п.6 (платформенное правило). Авторское дополнение: путь `FMT-exocortex-template/` включён в §2 п.6.
- **Комментарии кода — только на английском (решение Андрея, ИТ-встреча 14 июня 2026).** Все inline-комментарии, docstring'и и README внутри кода писать на EN. Мотив: AI-инструменты (Cursor/Claude) лучше работают с EN-комментариями; код публикуется в мировой орг — кириллица в комментариях = барьер для не-русскоязычных читателей. Область применения: весь код в `{{WORKSPACE_DIR}}/**`, включая DS и Pack-скрипты. Исключение: user-facing строки в интерфейсах (UX-тексты, сообщения пользователю) — по языку интерфейса.

### Различения (авторские)

> Хранятся в `.claude/rules/distinctions.md` в зоне AUTHOR-ONLY — не затираются при `update.sh`.


### Именование

- `DS-strategy` (не `DS-strategy`) — личный governance-хаб
- `{{HOME_DIR}}/IWE/` — рабочая директория

### Read-only репо


### Extensions Gate (БЛОКИРУЮЩЕЕ)

**Для пользователей:** кастомизация протоколов/скиллов → ТОЛЬКО в `extensions/*.md`.
Прямое редактирование `.claude/skills/` или `memory/protocol-*.md` = ошибка.
**Архитектурное обоснование:** платформенные файлы (L1) и пользовательские расширения (L3) -- разные слои. Смешение слоёв = хрупкость при обновлении. Разделение: платформенное → `FMT-exocortex-template` → `update.sh`. Пользовательское → `extensions/` + `params.yaml`.

**Для автора шаблона (`params.yaml → author_mode: true`):** прямое редактирование L1 файлов РАЗРЕШЕНО.
- **Flow (единый для всего L1):** авторский IWE (source-of-truth) → доставка в FMT (с отрезанием личного) → GitHub → `update.sh` → пользователи. Авторский IWE = SoT для ВСЕГО: CLAUDE.md, скриптов, хуков, скиллов.
- **CLAUDE.md:** авторский IWE → `bash $IWE_TEMPLATE/scripts/template-sync.sh` → автоматически в FMT (плейсхолдеры + отрезание §9). Режимы: без флагов = sync, `--dry-run` = diff, `--check` = drift (exit 1).
- **Промоция артефактов в шаблон** — единая команда по типу:
  - Скрипт: `bash $IWE_SCRIPTS/script-promote.sh <личный-скрипт>.sh [--dry-run]` → FMT/scripts/
  - Хук: `bash $IWE_SCRIPTS/hook-promote.sh <личный-хук>.sh [--dry-run]` → FMT/.claude/hooks/
  - Скилл: `bash $IWE_SCRIPTS/skill-promote.sh <папка-скилла>/ [--dry-run]` → FMT/.claude/skills/
  - CLAUDE.md: `bash $IWE_SCRIPTS/template-sync.sh` (автозамена §9 + плейсхолдеры)
- **Все promote-скрипты:** применяют одинаковые подстановки (личные пути и repo-имя → env vars) → прогоняют `validate-fmt-scripts.sh` → копируют. Флаг `--dry-run` показывает результат без копирования.
- **Валидатор** запускается автоматически после каждого `template-sync.sh`. Вручную: `bash $IWE_SCRIPTS/validate-fmt-scripts.sh $IWE_SCRIPTS/`.


### README.md (FMT-exocortex-template)

> Изменение структуры — по согласованию с владельцем.

### WP Entry Filter (S-47, БЛОКИРУЮЩЕЕ, авторское)

> **Принято Strategy Session 1 июня 2026 (С.6 proposal-2026-06 v4).** Метод от R31 Менеджера оргразвития: оргхаос потока задач = тип системы «организация» → дисциплина «системный менеджмент» → правило входа.

Новый РП открывается **ТОЛЬКО при выполнении одного из двух условий**:

1. **Связь со стратегической целью R1-R6** месяца (см. Strategy.md §«Результаты месяца R1-R6»). Цель должна быть явной — не «полезно для платформы», а «двигает R{N} к Q результату».
2. **Явный заказчик извне:** Ильшат (Track A), волонтёр когорты, регулятор (юрист/налоговая), Андрей (Track B), партнёр.

**Иначе** — задача попадает в `DS-strategy/inbox/backlog-with-triggers.md` (а не в WP-REGISTRY) с условием возврата:
- **Триггер «N=10 повторений»** — если идея повторяется в captures/peer-сессиях/обсуждениях ≥10 раз → пересмотр на следующем Month Close.
- **Auto-перевод активного РП в backlog: 30 дней без коммита** в context-файл / связанные репо → automatic transition (детектор R31 Ф2.7 уже работает на сигнал «stuck >14 дней» → 30-day trigger автоматизировать в следующей сессии).

**Цель:** удержать WIP в норме 8-15 (вместо текущих 30+). 91 активный РП на 31 мая = inflated WIP в 6 раз, мёртвый капитал → throughput падает.

**Применение Claude:** при предложении нового РП в Strategy Session или сессии — **сначала** проверять filter:
- (Q1) К какой R{N} цели месяца этот РП ведёт? Конкретно одной фразой.
- (Q2) Если нет цели — есть ли явный внешний заказчик с именем?
- Если оба ответа отрицательные → не открывать РП. Записать в `backlog-with-triggers.md` с краткой формулировкой + дата + источник идеи.

**Исключения:**
- spin-off от закрытого РП (Ф-N → отдельный РП) — допустимо без явной R{N} цели, если родитель был привязан к R{N}.
- пилот явно называет задачу как РП («открой РП», «создай WP», «это новый РП для X») — это прямое поручение, не предложение агента. S-47 не применяется.

### Именование РП

**Название РП = существительное-артефакт**, а не глагол-действие.
- ✅ «Дизайн системы стратегирования», «Архитектура MCP», «Концепция подписок»
- ❌ «Разработать систему», «Настроить MCP», «Сделать концепцию»

**Название в WP-REGISTRY.md = ≤80 символов, только русский.** Допустимо вкрапление кодовых идентификаторов и Pack-ID, если они являются собственным именем артефакта (`projection-worker`, `DP.SC.125`, `cut-over`, `IWE`). Реестр — индекс, не карточка РП.

Запрещено в названии:
- статус, даты, commit hash, фазы, метрики («closed 27 апр», «Ф1 done», «PASS», «1.5h факт vs 3h»)
- список под-задач через `+`/`;` или parenthetical-нарратив
- английские пояснения (`spawn`, `closes drift`, `runtime activation`)
- ссылки на другие РП («child WP-268», «parent zonтик», «source: feedback_*»)

Контекст РП (фазы, handoff, ArchGate, бюджеты, решения) живёт в `DS-strategy/inbox/WP-NNN-*.md` для активных и `DS-strategy/archive/wp-contexts/` для закрытых. В реестре — только имя артефакта.

Эталоны: WP-254 «Миграция учебных объектов #6 aist-bot → #11 learning», WP-258 «Plugin API L2 для IWE (регистр MCP-расширений + контракт плагина)», WP-264 «Day Open enforcement — diagnostic logging + deterministic scaffold».

**Синхронизация REGISTRY→производные:** при переименовании РП → обновить одновременно REGISTRY.md + MEMORY.md + WeekPlan + DayPlan (если активен) + WP-context file.

### Память (Memory Lifecycle) — S-35

> Spec: `memory/memory-lifecycle-spec.md` (WP-217 Ф10.1, ArchGate 2026-04-30).

**Обязательный frontmatter** для всех новых файлов `memory/*.md`:

```yaml
---
name: "..."
description: "одна строка для MEMORY.md"
type: user | feedback | project | reference | lesson | protocol
horizon: hot | warm | cold | archive
domains: [тег1, тег2]
status: active | dormant | superseded | archived
valid_from: YYYY-MM-DD
owner: user | platform
schema_version: 1
---
```

**Правила горизонта:**
- `hot` — загружается каждую сессию. Суммарный лимит: ≤150 строк по всем HOT-файлам (без frontmatter).
- `warm` — по триггеру. Default для `project`, `reference`, `lesson`, `protocol`.
- HOT-лимит превышен → предложить понизить один из HOT-файлов в WARM перед добавлением нового.

**Архивация:** предлагает агент при Week/Month Close — не выполняет автономно. HOT→WARM: 14 дней без обращения. WARM→COLD: 30 дней. COLD→archive: 90 дней.

### Security Audit Cadence (WP-212, S-36)

> **Три уровня периодичности:**
> - **Per-ArchGate (каждое архитектурное решение):** §Б чеклист в ArchGate (B7.1 ✅) + STRIDE для нового сервиса → обновить B7.2 scope-таблицу.
> - **Week Close (2 мин):** проверить `security-posture.md §3` — `open_critical_count > 0`? Если да → добавить WP-212 в следующий WeekPlan.
> - **Daily (tsekh-1, 04:45 МСК):** systemd-timer `iwe-overnight-auditor` → VR.R.002 daily-headless по B7.4 A-D (~10-15 мин, $1.5). Critical flags → Day Open «Требует внимания».
> - **Month Close (VR.R.002 Аудитор monthly-deep, ~1h):** sub-agent VR.R.002 (catalog R24, context isolation, Sonnet) → разделы A-F чеклиста B7.4 → обновить `security-posture.md` → коммит `docs(WP-212): security audit YYYY-MM`.

**Файлы:**

### WeekPlan / WeekReport split (ОПТ-5, WP-297)

**WeekPlan** = намерения недели (planning, inbox triage, НЭП, приоритеты, контент-план). **Только интенты.** Нет прошлого.
**WeekReport** = факты недели (итоги дней, что сделано, коммиты). **Только история.** Нет планов.

**Правило:** при создании WeekPlan — предыдущие «Итоги дня» и «Итоги прошлой недели» → новый `WeekReport W{N} YYYY-MM-DD.md`. WeekPlan держит только `week_report: WeekReport W{N}...` в frontmatter как ссылку.
**Мотив:** WeekPlan смешивал факты и намерения → 545 строк → непригоден как planning-документ. Split → WeekPlan ≤200 строк.

### Режим «на пальцах» (S-37)

**Явные триггеры:** «объясни», «на пальцах», «что сделали», «расскажи понятно», «простыми словами» — любая просьба объяснить итоги или суть работы.

**Детектор канала (peer-session 2026-06-01-27, добавлено):**
- **Технический режим** в чате с пилотом — если в сообщении пилота сами встречаются: `grep`, `git`, имена файлов с путями, флаги команд, SHA, английские термины из кода.
- **Режим «на пальцах»** по умолчанию для всего остального: ответы на «что произошло», «почему не работает», «объясни», или задание без технических деталей в формулировке.
- **report.md** при синтезе peer-сессии: §1-§4 (Постановка, Позиции, Альтернативы, Решение) — режим «на пальцах»; прямые цитаты из ходов внутри §2 — плотный технический стиль (доказательство, не синтез).
- **Стенограммы ходов** (NN-writer / NN-peer) — плотный технический стиль, правила режима НЕ применяются.
- **Commit messages, PR descriptions** — плотный технический стиль.

**Правила ответа в режиме «на пальцах» (полная нумерация A1-A11 — в `feedback_response_clarity_for_pilot.md`, единый источник — `communication-style-base.md`):**
- Только русский язык. Английские термины и коды — только после русского описания в скобках. Исключение — термины, которые сам пилот употребляет (бот, чек-ин, deploy, smoke, merge, push, commit, MCP, Pack). Не «WP-330», а «марафон (РП330)». Не «G3 PASS», а «финальная проверка (G3) прошла успешно». **(A2 + A2-ext)**
- Путь к файлу — никогда не подлежащее. Только в скобках после русского глагола («бот пишет ноль в счётчик (`handlers/marathon.py:65`)»). **(A1)**
- Блок `<details>` — только при наличии деталей, нужных пилоту для решения/действия, или явно им запрошенных. SHA, коммиты, дефекты, scope — только в файл отчёта (report.md, handoff.md), никогда в чат. **(A7 + A7.1)**
- При первом упоминании имени колонки/функции/переменной — расшифровка одним словом. **(A3)**
- Никаких английских маркеров успеха/неудачи как факта: «exit 0», «PASS», «SHA: abc» → «получилось», «прошло проверку», «залил правкой». **(A10)**
- Никакого пассивного залога при ошибке или находке: «было обнаружено» → «я нашёл», «я ошибся». **(A11)**
- Объяснять через аналогии из физического мира или инженерии: что делает система, зачем, что было сломано, что починили. **(A5)**
- Допустимо: цифры, проценты, сравнения «было / стало», схемы словами.
- Формат: свободный текст или маркированный список.

**Пример нарушения:** «Исправлен `activity_domain` фильтр в `load_rcs_metrics` — заменён на `SELF_DEV_EVENT_TYPES`.»
**Правильно:** «Раньше система считала рабочие дни вместе с учебными — теперь считает только те дни, человек реально занимался саморазвитием.»

**Полные правила, 12 паттернов и примеры «было / стало»:** [feedback_response_clarity_for_pilot.md](memory/feedback_response_clarity_for_pilot.md).

### Календарный конвейер (WP-357)

> Single source-of-truth для датозависимых процессов IWE. Полная спецификация → `DS-strategy/docs/calendar-pipeline.md`.

**Каталог:** `DS-strategy/exocortex/process-catalog.yaml` (10 процессов: 6 A-класс + 4 B-класс).
**Ledger (generated):** `DS-strategy/current/date-ledger.yaml` (регенерируется при каждом Day Open).
**Watchdog:** in-band (Day Open hook) + out-of-band (launchd, каждый час). Telegram-дайджест при пропусках (cooldown 12h).
**Установка:** `bash DS-strategy/scripts/install-launchd.sh` (12 plist, требует ручного запуска пилота).
**Smoke-test:** `bash DS-strategy/scripts/calendar-pipeline-smoke.sh`.

Добавление нового процесса = добавить запись в process-catalog.yaml + плист в exocortex/launchd/ + entry в install-launchd.sh PLISTS. Не редактировать date-ledger.yaml вручную (derived).

---

*Последнее обновление: 2026-05-26*
