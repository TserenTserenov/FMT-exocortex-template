# Каталог скриптов IWE

> Автогенерировано `scripts/generate-catalogs.py` · 2026-07-23 · НЕ редактировать вручную.
> Источник: `scripts/*.sh`, `.claude/scripts/*.{sh,py}`. Это вспомогательные скрипты (хелперы, утилиты, серверы), не скиллы.

| Скрипт | Путь | Что делает |
|--------|------|------------|
| `active-wp-sweep.sh` | `scripts/active-wp-sweep.sh` | heartbeat sweep активных РП |
| `add-skill-markers.sh` | `scripts/add-skill-markers.sh` | inject empty USER-SPACE block into L1 SKILL.md files that lack it. |
| `agent-heartbeat.sh` | `scripts/agent-heartbeat.sh` | agent-heartbeat.sh |
| `agent-status-report.sh` | `scripts/agent-status-report.sh` | РП-395 Ф3 fail-safe writer. |
| `agent_fault_remind.sh` | `scripts/agent_fault_remind.sh` | WP-316: Agent Fault Profile reminder wrapper |
| `archive-done-wp.sh` | `scripts/archive-done-wp.sh` | атомарная архивация завершённого РП |
| `backup-icloud.sh` | `scripts/backup-icloud.sh` | Бэкап IWE в iCloud Drive (без .git, node_modules, .venv) |
| `changelog-append.sh` | `scripts/changelog-append.sh` | идемпотентное обновление секции [Unreleased] в CHANGELOG.md |
| `changelog-flush.sh` | `scripts/changelog-flush.sh` | переименовывает [Unreleased] → конкретную версию в CHANGELOG.md |
| `check-component-parity.sh` | `scripts/check-component-parity.sh` | asserts setup.sh (fresh install) and update.sh |
| `check-dirty-repos.sh` | `scripts/check-dirty-repos.sh` | Скан всех IWE репо на незакоммиченные изменения |
| `check-index-health.py` | `.claude/scripts/check-index-health.py` | Детектор раздутых индекс-файлов. |
| `check-open-sessions.sh` | `scripts/check-open-sessions.sh` | WP-358 Ф10 — детектор незакрытых external-сессий. |
| `check-script-collisions.sh` | `scripts/check-script-collisions.sh` | проверить коллизии скриптов между авторской зоной и FMT-шаблоном. |
| `check-seed-drift.sh` | `scripts/check-seed-drift.sh` | seed/strategy/scripts/ снапшоты не разъехались с scripts/ |
| `check-setup-update-parity.sh` | `scripts/check-setup-update-parity.sh` | статический анализ парных скриптов |
| `check-wp-transfer-completeness.sh` | `scripts/check-wp-transfer-completeness.sh` | проверка перед архивацией inbox/WP-N/: |
| `claude-peer-adapter.sh` | `scripts/claude-peer-adapter.sh` | адаптер Claude для peer-conversation (роль напарника) |
| `close-wp.sh` | `scripts/close-wp.sh` | Закрытие РП: зачёркивает строку в REGISTRY, дописывает ## Закрытие в archive/wp-contexts/ |
| `coverage-skills.sh` | `scripts/coverage-skills.sh` | детектор B12a/B12b/B12c/B12d (promotion coverage) |
| `create-skill.sh` | `scripts/create-skill.sh` | создать scaffold нового скилла IWE (SKILL.md v2) |
| `create-wp.sh` | `scripts/create-wp.sh` | атомарное создание РП в 4 местах (inbox, REGISTRY, WeekPlan, Linear) |
| `day-close-lock.sh` | `scripts/day-close-lock.sh` | git-native cross-machine lock against duplicate Day Close runs (WP-484 Ф2). |
| `day-close-prepare.sh` | `scripts/day-close-prepare.sh` | one-call data digest for the Day Close protocol (issue #234). |
| `day-close.sh` | `scripts/day-close.sh` | Автоматические шаги Day Close (backup + reindex + linear sync + sessions) |
| `day-open-checks-runner.sh` | `scripts/day-open-checks-runner.sh` | парсер и исполнитель bash-блоков из extensions/day-open.checks.md |
| `day-open-pipeline.sh` | `scripts/day-open-pipeline.sh` | оркестратор полного конвейера Day Open (WP-356 DOE3) |
| `day-open-preflight.sh` | `scripts/day-open-preflight.sh` | pre-flight healthcheck для Day Open |
| `day-open-scaffold.sh` | `scripts/day-open-scaffold.sh` | детерминированная генерация скелета DayPlan |
| `day-open-smoke-extended.sh` | `scripts/day-open-smoke-extended.sh` | extended smoke для Day Open (запускается hourly cron, кэш) |
| `day-open-smoke.sh` | `scripts/day-open-smoke.sh` | core smoke для Day Open (≤10с) |
| `fmt-critical-alert.sh` | `scripts/fmt-critical-alert.sh` | MVP-механизм обнаружения критических FMT issues. |
| `gate-metrics.sh` | `scripts/gate-metrics.sh` | - WP-436: measure reflex/passthrough/llm routing from gate-decisions.jsonl |
| `generate-hot-files-list.sh` | `scripts/generate-hot-files-list.sh` | regenerates hot-files.list from install config (WP-450 S-50) |
| `generate-rules-registry.py` | `.claude/scripts/generate-rules-registry.py` | generate-rules-registry.py — собрать rules-registry.yaml из PACK-agent-rules/rules/AR.NNN.md. |
| `generate-skills-catalog.sh` | `scripts/generate-skills-catalog.sh` | генератор skills-catalog.yaml |
| `git-dirty-guard.sh` | `scripts/git-dirty-guard.sh` | protects a repo's periodic pull from a dirty working tree. |
| `guide-kit-sync.sh` | `scripts/guide-kit-sync.sh` | vendor a tagged release of iwesys/guide-kit into the |
| `headless-runner.sh` | `scripts/headless-runner.sh` | точка входа Headless-адаптера (DP.IWE.011-adapter-headless) |
| `hook-promote.sh` | `scripts/hook-promote.sh` | промоция личного хука в платформенный шаблон IWE |
| `iwe-audit.sh` | `scripts/iwe-audit.sh` | оркестратор аудита инсталляции IWE |
| `iwe-backup-check.sh` | `scripts/iwe-backup-check.sh` | Проверка здоровья системы резервного копирования IWE |
| `iwe-bug-report.sh` | `scripts/iwe-bug-report.sh` | обёртка для скилла /iwe-bug-report |
| `iwe-consent.sh` | `scripts/iwe-consent.sh` | iwe-consent.sh |
| `iwe-drift.sh` | `scripts/iwe-drift.sh` | MVP drift-отчёт по .claude/sync-manifest.yaml |
| `iwe-grep-secret.sh` | `scripts/iwe-grep-secret.sh` | Secret Drift Detector (WP-315) |
| `iwe-transcribe.sh` | `scripts/iwe-transcribe.sh` | транскрипция аудио/видео через MLX Whisper (Apple Silicon) |
| `iwe-w-reflection.sh` | `scripts/iwe-w-reflection.sh` | iwe-w-reflection.sh |
| `ke-classify.sh` | `scripts/ke-classify.sh` | классификатор captures-отчёта для auto-batch |
| `ke-queue-stats.sh` | `scripts/ke-queue-stats.sh` | статистика очереди Knowledge Extraction |
| `kimi-auto-heartbeat.sh` | `scripts/kimi-auto-heartbeat.sh` | kimi-auto-heartbeat.sh |
| `kimi-compaction-watchdog.sh` | `scripts/kimi-compaction-watchdog.sh` | Kimi Compaction Watchdog |
| `kimi-peer-adapter.sh` | `scripts/kimi-peer-adapter.sh` | kimi-peer-adapter.sh v3 — адаптер Kimi для peer-conversation.sh с PII-фильтрацией |
| `kimi-session-watchdog.sh` | `scripts/kimi-session-watchdog.sh` | kimi-session-watchdog.sh |
| `kimi-standalone-preflight.sh` | `scripts/kimi-standalone-preflight.sh` | kimi-standalone-preflight.sh |
| `kimi-whisper-safe.sh` | `scripts/kimi-whisper-safe.sh` | безопасная обёртка для whisper с защитой от |
| `lesson-close.sh` | `scripts/lesson-close.sh` | закрыть занятие в дневном файле (lesson/<date>.md) |
| `llm-proxy-launcher.sh` | `scripts/llm-proxy-launcher.sh` | обёртка для запуска llm-proxy.py с OpenRouter secrets (WP-366 Ф4.A) |
| `load-extensions.sh` | `.claude/scripts/load-extensions.sh` | unified loader для suffix extensions (R4.4 fix, WP-273 Этап 2). |
| `memory-active-wp-update.sh` | `scripts/memory-active-wp-update.sh` | обновление секции «Текущие РП» в MEMORY.md |
| `memory-bleed.sh` | `scripts/memory-bleed.sh` | детектор нарушений memory/ (WP-217 Ф10.2) |
| `memory-health.sh` | `scripts/memory-health.sh` | метрики здоровья memory/ (WP-217 Ф10.2) |
| `memory-migrate.sh` | `scripts/memory-migrate.sh` | добавление отсутствующих frontmatter-полей (WP-217 Ф10.2/Ф10.4) |
| `memory-validate.sh` | `scripts/memory-validate.sh` | валидация frontmatter memory/*.md (WP-217 Ф10.2) |
| `migrate-initial-marker.sh` | `scripts/migrate-initial-marker.sh` | добавить skeleton-marker IWE-INITIAL-NEEDED в Strategy.md |
| `migrate-skills-to-v2.sh` | `scripts/migrate-skills-to-v2.sh` | миграция существующих скиллов под стандарт SKILL.md v2 |
| `migrate-to-runtime-target.sh` | `scripts/migrate-to-runtime-target.sh` | миграция с dirty FMT (≤0.28.x) на Generated runtime (≥0.29.0). |
| `pack-ci-install.sh` | `scripts/pack-ci-install.sh` | Устанавливает CI guard (ID collision detector) во все Pack-репо в ~/IWE/ |
| `pending-phases-sweep.sh` | `scripts/pending-phases-sweep.sh` | обходит активные WP-context файлы и выводит pending фазы |
| `post-update-check-skills.sh` | `scripts/post-update-check-skills.sh` | post-update detector for SKILL.md routing blocks (WP-350 Ф18) |
| `pre-commit-secret-scan.sh` | `scripts/pre-commit-secret-scan.sh` | Pre-commit hook: блокирует случайный коммит секретов. |
| `promote-common.sh` | `scripts/promote-common.sh` | общая библиотека для promote-скриптов |
| `restore-from-exocortex.sh` | `scripts/restore-from-exocortex.sh` | восстановление памяти IWE из exocortex-бэкапа (closes #125) |
| `route-task.sh` | `scripts/route-task.sh` | Маршрутизатор задач IWE (DP.ROLE.059) |
| `script-promote.sh` | `scripts/script-promote.sh` | промоция личного скрипта (или всех общих скриптов) в платформенный шаблон IWE |
| `server-calendar.sh` | `scripts/server-calendar.sh` | кросс-платформенная замена mcp__ext-google-calendar для server-mode |
| `server-news.sh` | `scripts/server-news.sh` | кросс-платформенная замена WebSearch для server-mode |
| `session-guard.sh` | `scripts/session-guard.sh` | единый gate open/close/audit для всех агентов (Claude, Kimi, Hermes) |
| `settings-promote.sh` | `scripts/settings-promote.sh` | регистрация хука в .claude/settings.json шаблона |
| `setup-extractor-feeders.sh` | `scripts/setup-extractor-feeders.sh` | Onboarding скрипт для активации feeder-системы |
| `skill-promote.sh` | `scripts/skill-promote.sh` | промоция скилла в платформенный шаблон IWE (v2.1) |
| `skills-pull.sh` | `scripts/skills-pull.sh` | синхронизация L1 скиллов из FMT в личный IWE |
| `smoke-clean-env.sh` | `scripts/smoke-clean-env.sh` | Smoke-test для новых scripts/*.sh в FMT. see WP-347 PD-1. |
| `staging-audit.sh` | `scripts/staging-audit.sh` | детектор B12e Decay drift в STAGING.md |
| `style-check-post-run.sh` | `scripts/style-check-post-run.sh` | проверка стиля ответа Kimi после peer-сессии (WP-388 Ф9) |
| `style-promote.sh` | `scripts/style-promote.sh` | промоция файла-снимка стиля в платформенный шаблон IWE |
| `sync-agent-instructions.sh` | `scripts/sync-agent-instructions.sh` | генерация AGENTS.md из единого ядра CLAUDE.md + agent-blocks |
| `sync-version-badge.sh` | `scripts/sync-version-badge.sh` | синхронизация version badge в README.md с CHANGELOG.md |
| `test-route-task.sh` | `scripts/test-route-task.sh` | 10 кейсов для route-task.sh (WP-350 Ф14) |
| `validate-fmt-scripts.sh` | `scripts/validate-fmt-scripts.sh` | проверка FMT на личные хардкоды и нарушения конвенций |
| `validate-skill.sh` | `scripts/validate-skill.sh` | валидация SKILL.md v2 (pre-promote checklist) |
| `verify-context-budget.sh` | `scripts/verify-context-budget.sh` | M1 contract: hot-framework ≤55K tokens per session (WP-445 Ф6) |
| `verify-manifest.sh` | `scripts/verify-manifest.sh` | проверяет что update-manifest.json синхронизирован с git tree. |
| `verify-template-integrity.sh` | `scripts/verify-template-integrity.sh` | local mirror of the CI template-integrity gate. |
| `week-draft-append.sh` | `scripts/week-draft-append.sh` | обновить метрики текущего дня в черновике недельного поста. |
| `week-draft-init.sh` | `scripts/week-draft-init.sh` | создать пустой черновик недельного поста для новой недели. |
| `wp-sync-bundle.sh` | `.claude/scripts/wp-sync-bundle.sh` | детерминированный bundler контекста РП для sync-фазы WP Gate |

_Всего скриптов: 97_

