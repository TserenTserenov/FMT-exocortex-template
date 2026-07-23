# Каталог скиллов IWE

> Автогенерировано `scripts/generate-catalogs.py` · 2026-07-23 · НЕ редактировать вручную.
> Источник: `.claude/skills/*/SKILL.md`. Скилл вызывается командой `/<id>`.

| Скилл | Что делает |
|-------|------------|
| `/agent-fault` | Регистрация косяка агента в системе учёта WP-316 L1. Без LLM — детерминированный скрипт без WP Gate. |
| `/apply-captures` | Разбор extraction-reports со status pending-review — решение R15 (accept/reject/defer) ЖИВЫМ ПИЛОТОМ, запись… |
| `/archgate` | Оценка архитектурного решения по 7 характеристикам ЭМОГССБ (v3 — профиль без агрегатного балла, conjunctive s… |
| `/artifactor` | Classifies raw pilot request → structured JSON {task_type, class, artifact, budget_estimate, confidence, rout… |
| `/audit-docs` | Audit repository documentation: detect drift between code and docs, report coverage by category. Run manually… |
| `/audit-installation` | Аудит пользовательской инсталляции IWE. Запускает scripts/iwe-audit.sh + MCP healthcheck + smoke-test ритуала… |
| `/author-mode` | Инструкции для автора шаблона IWE: staging-канал (обкатка → FMT), авторские правила L3, Extensions Gate. Загр… |
| `/bottleneck-pick` | Аналитик ограничений (DP.ROLE.054): находит главное ограничение (bottleneck) конкретного конвейера через TOC… |
| `/check-secret` | Check a text fragment for potential secrets (API keys, tokens, passwords) BEFORE sending to chat / committing… |
| `/consent` | Управление consent в learning.tracking_consent — opt-in / opt-out / status / revoke. Обязательное условие для… |
| `/day-close` | Протокол закрытия дня (Day Close). Алиас для /run-protocol close day — симметрия с /day-open. |
| `/day-open` | Day Open protocol. Collects yesterday's commits, issues, notes, calendar, bot QA, Scout, world events — build… |
| `/decompose` | Decompose work into stages with physical artifacts and acceptance checklists. Gap detector. Use when opening… |
| `/diagnose` | Диагностика ступени мастерства (Диагност R28, FORM.089 §6.1 v5.0) прямо в VS Code / claude.ai. До 6 вопросов,… |
| `/discovery-session` | Разговор-распаковка неудовлетворённостей (discovery-стратегирование). Сократический разбор сырой рефлексии и… |
| `/extend` | IWE extensibility catalog: what can be customized, which extension points exist, which parameters are availab… |
| `/fpf` | Загрузка применимых принципов для задачи из иерархии Pack → SPF → FPF. Используй когда нужно найти релевантны… |
| `/integration-gate` | IntegrationGate — обязательный чеклист (4 шага) при проектировании нового инструмента, агента, детектора или… |
| `/iwe-bug-report` | Сообщить об ошибке или проблеме платформы IWE. Создаёт GitHub issue в FMT-exocortex-template. |
| `/iwe-restore` | Восстановление памяти агента из exocortex-бэкапа при переезде на новое устройство. Находит DS-strategy/exocor… |
| `/iwe-rules-review` | Weekly review of IWE work culture (element 14 — System Evolution). Runs during Week Close. |
| `/iwe-update` | Update IWE with change explanations. Agent calls update.sh, parses CHANGELOG, explains what changed, helps ad… |
| `/ke` | Knowledge Extraction — captures and routes knowledge at work boundaries. Use when you discover a pattern, mak… |
| `/kimi-peer-writer` | Peer-сессия DP.SC.154 где Kimi = писатель, Claude = напарник. Запускается простой фразой. Включает ОРЗ Openin… |
| `/lesson-close` | Закрыть занятие, открытое скиллом /lesson. Финализирует lesson/YYYY-MM-DD.md (frontmatter status, метаданные… |
| `/local-llm` | Локальный LLM-стек на Mac (Apple Silicon, MLX) под приватность и запасной режим. NL-вход к установке/запуску/… |
| `/month-close` | Протокол закрытия месяца (Month Close). Стадия 7 каскада ВДВ v9 (PD.METHOD.008). Запускается в первый Пн меся… |
| `/org-dev` | Organizational Development Manager (R31): guides the subject from an organizational change request (self/team… |
| `/pack-creator` | Guide a PACK-X author through the SPF fill cycle 01-11. Calls R28 Diagnostician to select mode (assembly/hybr… |
| `/pack-new` | Create a new Pack — guided flow through SPF: choose domain, name Pack, scaffold structure, fill roadmap. |
| `/peer-conversation` | Многотуровый диалог писателя (Claude) с напарником (Kimi) по задаче пилота (DP.SC.154). Ведёт turn-loop, обна… |
| `/personal-guide-render` | Тонкий клиент — собирает персональное руководство пилота через локальный шлюз (mcp__iwe-local-gateway__render… |
| `/personal-guide-start` | Bootstrap wrapper — creates an empty personal-guide repo under the pilot's account (flat name, no login in th… |
| `/platform-bottleneck` | Скилл IWE — см. тело файла |
| `/restore-exocortex` | Restore IWE memory from an exocortex backup on a new device or after data loss — NL wrapper around restore-fr… |
| `/run-protocol` | Step-by-step execution of the OWC protocol with mandatory checkpoint at each step. Prevents skipping steps (i… |
| `/setup-wakatime` | Set up WakaTime time-tracking for Claude Code and VS Code. |
| `/skill-creator` | | |
| `/strategy-session` | Стратегическая сессия — диспетчер. День-0 (нет Strategy.md/WeekPlan) → initial flow (цели, неудовлетворённост… |
| `/think` | ADI-cycle structured reasoning (Abduction-Deduction-Induction-Audit-Decide). Use for complex decisions when m… |
| `/transcribe` | Transcribe audio/video files via MLX Whisper (Apple Silicon). Usage: /transcribe path/to/file.mp3 |
| `/vdv` | ВДВ-скилл — генератор и аудитор описания стадийного процесса по 6 принципам Вход·Действие·Выход. Используй дл… |
| `/verify` | Верификация артефакта по эталону из Pack. Загружает роль VR.R.001 (Верификатор) с context isolation — проверя… |
| `/verify-hypotheses` | Сверка журнала гипотез (hypotheses-log.md) по запросу вне ритма week-close. Фильтрует записи со статусом «на… |
| `/w-reflection` | Записать W-рефлексию (мировоззренческий слот RCS) в learning.w_reflections. Используется Диагностом R28 (MIM.… |
| `/week-close` | Протокол закрытия недели (Week Close). Ретро 7 дней + carry-over в новую неделю + платформенные шаги (бэкап,… |
| `/week-close-pilot` | Run the pilot-facing Week Close protocol with progress review and carry-over. |
| `/wp-new` | Создание нового рабочего продукта (РП) с записью в 5 мест атомарно. Используй когда появляется новая задача,… |

_Всего скиллов: 48_

