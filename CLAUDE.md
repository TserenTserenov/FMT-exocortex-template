# Инструкции для всех репозиториев

> Kimi → `AGENTS.md`, Hermes → Aisystant MCP `get_instructions`; доставка ядра в шаблон — `template-sync.sh` (защищённый конвейер, `--dry-run`/`--check`). Slim-ядро: триггеры + правила hot; детали → `memory/`, `.claude/rules-lazy/`, `.claude/skills/`.

## 1. Архитектура репозиториев

**Base** (ZP, FPF, SPF, FMT-*) = принципы + форматы, первоисточник платформы · **Pack** = паспорт предметной области, первоисточник пользователя · **DS** (instrument/governance/surface) = код, планы, курсы — производное от Pack.

**Fallback Chain (где SoT):** DS → Pack → Base (SPF → FPF → ZP). **Pack = source-of-truth для доменного знания; DS меняется вслед за Pack.**
**Лестница принципов:** ZPF → FPF → SPF → TPF → LPF — полная таблица уровней → `memory/repo-type-rules.md`; словарь ailev ↔ IWE → `memory/fpf-reference.md`.

**Pack Creation Gate:** хочешь создать Pack → `/pack-new` (структура `SPF/pack-template/`, процесс `SPF/process/01-11`, FPF/SPF клонируются автоматически). Имя = существительное-домен (не тема, не инструмент).

## 2. ОРЗ-фрактал (Открытие → Работа → Закрытие)

> Пропуск Открытия = незапланированная работа. Пропуск Закрытия = незафиксированный результат.
> **Сессия:** `protocol-open.md § Сессия` → `protocol-work.md` → `/run-protocol close` · **День:** `/day-open` («открывай») → `/run-protocol day-close` · **Неделя:** `/run-protocol week-close` · **Месяц:** `/month-close` (первый Пн, до Strategy Session).

### Блокирующие правила

> **SoT (WP-272 Ф1):** `PACK-agent-rules/rules/AR.NNN.md` (реестр `.claude/rules-registry.yaml`); полные тексты выжимки → `.claude/rules-lazy/blocking-rules-full.md`. **Приоритет = нумерация:** структурное (1-5) перевешивает поведенческое (6-10).

1. **WP Gate:** ЛЮБОЕ задание → `memory/protocol-open.md` ДО начала работы. Новый РП → Ритуал согласования → явное «да»/«делаем»/«открывай»; без этого не регистрировать.
2. **Push:** «заливай»/«запуши»/«закрывай» → commit + push без вопросов, ДО отчёта Закрытия. Любой Close: `git status --short` по всем репо → незафиксированное commit + push ДО следующего шага.
3. **Close:** Триггер Закрытия → протокол Закрытия → выполнить.
4. **Pull-on-Touch:** `git pull --rebase` при первом обращении к репо за сессию (все `{{WORKSPACE_DIR}}/*`). Dirty → stash; конфликт → `memory/reference/agent-core.md`.
5. **Чеклист-верификация:** Quick/Day Close — sub-agent Haiku R23 сверяет с чеклистом. Исключения: ≤15 мин или без изменений файлов.
6. **Hooks/Scripts Bypass Gate (S-33):** без явного разрешения не менять `.claude/hooks|scripts/`, `.iwe-runtime/`, `FMT-exocortex-template/`, не обходить хуки; блок хука → bug-файл + пилоту + ждать. → `.claude/rules-lazy/hooks-bypass-gate.md`.
7. **Автономность:** не спрашивать подтверждения — выполни → отчитайся. Исключения: необратимо-разрушительное; WP Gate Ритуал; choice-question. → `memory/feedback_behaviour.md` П.1.
8. **Напоминания (S-44):** «напомни через X» → `send_telegram_message(schedule_at)` + ScheduleWakeup резерв; резерв сработал → сначала Telegram, потом чат.
9. **Финиш > отлог (S-46):** доп. задача → дефолт «делаю сейчас»; «сейчас или потом?» = анти-паттерн. Исключения и приоритет WP Gate → `memory/feedback_finish_now_no_defer.md`.

### Протокол Работы (полный → `memory/protocol-work.md`)

**Capture-to-Pack** — на каждом рубеже: есть ли знание для записи? Анонс: *«Capture: [что] → [куда]»*. Маршрутизация: правило → CLAUDE.md, доменное → Pack, реализационное → DS docs/, урок → memory/; при новом артефакте Routing Gate (DP.KR.001 §5) первым.
**Self-correction:** расхождение внутри scope текущего хода (файлы из agenda, `git diff HEAD`) → немедленно предложить фикс; за пределами scope — Drift Reporting (SYNC-CORE), не фиксить.

### Pre-action Gates

> Полные формулировки → `.claude/rules-lazy/blocking-rules-full.md`.

- Начало работы → какие сервисы (MAP.002) затронуты?
- Нетривиальное действие/РП → **State-Transition Gate (WP-457):** `{тип состояния, из→в}`, только `gate_ready: true` → Agent Core ниже.
- Пользовательский сценарий → **SC Gate:** какое обещание (08-service-clauses/) затронуто?
- Создание/размещение артефакта → **Routing Gate:** карта DP.KR.001 §5; «по аналогии с соседним» запрещено.
- Первое содержательное действие в репо → **Repo-Touch Gate:** прочитать `<repo>/CLAUDE.md`; блок «обязательно загружай» → загрузить ДО ответа.
- Архитектурное решение → **АрхГейт** `/archgate`.
- РП затрагивает PII → **Security Gate (B7.3):** §Б чеклист ArchGate ДО реализации; логирование PII = блокер.
- РП ≥3h → **Priority Gate:** к какому R{N} ведёт?
- Новый инструмент/агент/система → **IntegrationGate (БЛОКИРУЮЩЕЕ):** только (1) обещание → (2) сценарии → (3) роль → (4) реализация → `.claude/rules-lazy/integration-gate.md`.
- Замена legacy-компонента → **LegacyPortGate (БЛОКИРУЮЩЕЕ):** сначала 15-мин субагент «как это работает сейчас?» → `memory/feedback_behaviour.md` П.10.

## 3. Описания методов (PROCESSES.md)

≤15 мин — не нужен. Внутри системы — `<repo>/PROCESSES.md`. Новая система — сценарий + процессы + данные.

## 4. Memory (Слой 3)

Файлы/репо → `memory/navigation.md` · Pack-репо → `memory/repo-type-rules.md` · терминология → `memory/hard-distinctions.md` · FPF/SOTA/Роли → `memory/fpf-reference.md`, `memory/sota-reference.md`, `memory/roles.md` · документ/чеклист → `memory/checklists.md`.

Политика: ≤11 файлов; построчно проверяется только distinctions.md (≤150), остальное — суммарным M1/M2-бюджетом (WP-7 NR1.2); lazy-reference без лимита. Горизонты/frontmatter → `memory/memory-lifecycle-spec.md`; temporal metadata → `protocol-work.md §2`.
Рабочая директория: `{{HOME_DIR}}/IWE/`; `memory/` = симлинк на auto-memory.

## 5. АрхГейт — ОБЯЗАТЕЛЬНАЯ оценка

> **БЛОКИРУЮЩЕЕ.** Архитектурное решение → `/archgate`: принципы DP.ARCH.001 §7 → профиль ЭМОГССБ (✅/⚠️/❌) → conjunctive screening; чеклист современности (SOTA.002/001/011 + CGUS/PUA) — внутри `.claude/skills/archgate/SKILL.md`. Без агрегатного балла — `feedback_decision_gates.md`.

## 6. Форматирование → `.claude/rules/formatting.md` · Различения → `.claude/rules/distinctions.md`

## Контекстный бюджет IWE (WP-445)

Hot-каркас ≤20K токенов (M1), строгая цель ≤12K (M2). Изменил файл из `hot-files.list` (оба CLAUDE.md, rules/*.md) → перед коммитом `DS-strategy/scripts/verify-context-budget.sh`.

## 7. Обновление этого файла

> **3 слоя:** L1 (§1-§7) = платформа (`update.sh`). L2 (§8) = staging. L3 (§9) = авторское.
> Протоколы → `memory/protocol-*.md` · различения → `.claude/rules/distinctions.md` · форматирование → `.claude/rules/formatting.md` · стабильные знания → `memory/*.md` · свои правила → §8/§9.

<!-- PLATFORM-END -->

---

## Agent Core (SYNC-CORE → AGENTS.md)

> **WP-394 Ф4.2.** Единое ядро для всех агентов (Claude, Kimi, Hermes). `AGENTS.md` генерируется отсюда скриптом `scripts/sync-agent-instructions.sh` — **не редактировать `AGENTS.md` вручную**. Элаборация → `memory/reference/agent-core.md`.

<!-- SYNC-CORE-START -->

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

<!-- SYNC-CORE-END -->

---

## 8. Staging (обкатка → шаблон)

> Правила на обкатке (STAGING.md) → работают → переносятся в шаблон (L1). Новое поведение в §9 → ОДНОВРЕМЕННО строка в STAGING.md (`status: testing`). Промоция на Week Close (`validated`→`promoted`, `rejected` остаётся в §9 — не удалять) → скилл `/author-mode` и `.claude/rules-lazy/blocking-rules-full.md`.

**Активная запись:** S-45 Agent Inbox (WP-324) — `inbox/agent/` + `iwe-agent-dispatcher.py`, промотировано в FMT `extensions/agent-inbox/`. Status: testing.

---

## 9. Авторское (только мой IWE)

> Элаборации всех пунктов → `memory/reference/agent-core.md`.

- **Без Obsidian (DS-strategy):** просмотр через VS Code.
- **Комментарии кода — только EN (решение Андрея, 14.06.2026):** весь `{{WORKSPACE_DIR}}/**`; исключение — user-facing строки по языку интерфейса.
- **Различения (авторские):** `.claude/rules/distinctions.md` (секция «Авторские») + `memory/distinctions-warm.md` (в т.ч. «Бот = интерфейс, не место агентов»).
- **Именование:** governance-репо называется `DS-strategy` по умолчанию; рабочая директория `{{HOME_DIR}}/IWE/`.
- **Extensions Gate (БЛОКИРУЮЩЕЕ):** пользователи кастомизируют ТОЛЬКО `extensions/*.md` + `params.yaml` (правка `.claude/skills/` или `memory/protocol-*.md` = ошибка); автор (`author_mode: true`) редактирует L1 напрямую — авторский IWE = SoT, доставка в FMT через `template-sync.sh`.
- **README.md (FMT-exocortex-template):** изменение структуры — по согласованию с владельцем.
- **WP Entry Filter (S-47, БЛОКИРУЮЩЕЕ):** новый РП — только при явной связи с R1-R6 месяца или внешнем заказчике; иначе → `inbox/backlog-with-triggers.md`. Исключения: spin-off закрытого РП; прямое поручение пилота.
- **Именование РП:** существительное-артефакт, только русский (Pack-ID допустим); реестр ≤80 символов → SYNC-CORE; переименование — синхронно REGISTRY+MEMORY.md+WeekPlan+DayPlan+WP-context.
- **Память (S-35):** новые `memory/*.md` — обязательный frontmatter; шаблон и горизонты → `memory/memory-lifecycle-spec.md` (единственный источник).
- **Security Audit Cadence (WP-212, S-36):** per-ArchGate (§Б B7.1 + STRIDE) · Week Close (`security-posture.md §3`) · Daily (tsekh-1) · Month Close (VR.R.002).
- **WeekPlan/WeekReport split (WP-297):** WeekPlan = только интенты, WeekReport = только факты; при создании WeekPlan итоги уезжают в WeekReport.
- **Режим «на пальцах» (S-37):** триггеры «объясни», «на пальцах», «что сделали», «простыми словами» → Response Style + `memory/feedback_response_clarity_for_pilot.md`.
- **Календарный конвейер (WP-357):** SoT — `DS-strategy/calendar/process-catalog.yaml` (+ derived `date-ledger.yaml`, не редактировать); новый процесс = каталог + plist; спецификация → `docs/calendar-pipeline.md`.

---

*Последнее обновление: 2026-07-16 (M2-слим, WP-7 HOTBUDGET-M2)*
