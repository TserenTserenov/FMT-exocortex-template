---
valid_from: 2026-07-20
type: reference
horizon: warm
domains: [agent-core]
status: active
owner: user
schema_version: 1
name: "Agent Core — элаборация"
description: "Полные формулировки блоков SYNC-CORE/CLAUDE.md §1-2, свёрнутых при M2-слиме (WP-7 HOTBUDGET-M2). Восстановлено из git-истории (commit fee0f85^) — issue #283."
---
# Agent Core — элаборация

> Слим-версии этих правил живут в `CLAUDE.md` (SYNC-CORE блок + §1-2). Здесь — полные формулировки для случаев, когда hot-каркас не даёт достаточно контекста (конфликт-резолюция, редкие ветки, примеры).

## Pull-on-Touch (CLAUDE.md §2 п.4) — конфликт-резолюция

`git pull --rebase` при первом **обращении** к репо за сессию (любое — `ls`/`Read`/`find`/`grep`/Edit/commit), один раз на репо, lazy. Применяется ко ВСЕМ git-репо в рабочей директории, не только governance.

Перед pull — `git status`:
- **dirty** → stash или пропустить с пометкой «вывод potentially stale»
- **rebase conflict** → два варианта: (А) stash незафиксированных изменений + пометить вывод как potentially stale → продолжить; (Б) прервать сессию + отчёт пилоту. **Default: вариант А.** Без автоматического разрешения конфликта.
- **Сетевой fail** → работать с локальной копией, помечать выводы как potentially stale.

Причина расширения с «изменения» на «обращения»: 5 мая 2026 ложный диагноз «Day Open пропущен» из-за чтения устаревшей локальной копии governance-репо (origin был на 3 коммита впереди).

## Git Staging — примеры (CLAUDE.md SYNC-CORE)

**NEVER `git add -u`, `git add .`, `git add -A`** — подхватывают изменения ДРУГИХ агентов (Kimi/Hermes работают параллельно в том же репо) → неверная атрибуция, случайный коммит чужой работы.

**Всегда стейджить только конкретные файлы:**
```bash
# Correct
git add path/to/specific-file.md

# FORBIDDEN — captures other agents' work
git add -u
git add .
git add -A
```

**Перед каждым коммитом — проверить staged scope:**
```bash
git diff --cached --name-only
```
Если появились неожиданные файлы — `git restore --staged <file>` до коммита.

## State-Transition Gate — cross-axis (CLAUDE.md Pre-action Gates)

> Этот раздел — не восстановление из M2-слима (правило появилось позже, WP-457, и в дo-слимовой версии CLAUDE.md его не было). Источник — `memory/protocol-open.md` (актуальная версия), продублировано сюда как элаборация ссылки «cross-axis → agent-core.md» из CLAUDE.md.

Модель осей — `archive/wp-contexts/WP-457/CONCEPT-user-states.md §5` (в авторском governance-репо). Если действие затрагивает несколько осей одновременно (permission/belonging/engagement/mastery) — фиксировать переход как `provisional` до прохождения ArchGate (Ф9), не выбирать одну ось произвольно.

## Status Reporting — командный режим и fail-safe (CLAUDE.md SYNC-CORE)

**Командный режим (WP-398 Ф5):** если работаешь с файлами из командного репо (несколько участников в одном репо), передавай `repo="org/repo-name"` в `agent_status_update`. Это позволяет другим агентам команды видеть твои активные файлы и избегать конфликтов.

Пример:
```
agent_status_update(agent="claude-code", status=working, task="WP-X фаза", files=["src/marathon.py"], repo="TserenTserenov/DS-strategy")
```

**Fail-safe:** если статус не обновлён вручную — детерминированно пишет `scripts/agent-status-report.sh <agent> <status> [task] [files-csv]` (Claude — из Stop-хука, Kimi — из `kimi-peer-adapter.sh`). Не отменяет primary-путь через MCP-инструмент.

## WP-REGISTRY Naming — примеры ✅/❌ (CLAUDE.md SYNC-CORE)

Запрещено в колонке «Название»: даты закрытия, ссылки на peer-сессии, метрики фаз, SHA коммитов, результаты проверок, количество тестов, любые другие служебные данные.

- ✅ `Алгоритм диагностики`
- ❌ `Алгоритм диагностики — closed 30 мая (PHASE1=5, MANDATORY=5...)`

**Куда писать остальное:**
- Итог закрытия РП → раздел `## Закрытие` в `archive/wp-contexts/WP-NNN-*.md`
- Текущие фазы и прогресс → frontmatter поля `phases`/`progress` в `inbox/WP-NNN/WP-NNN.md`

**При начале работы с РП:** прочитать `inbox/WP-NNN/WP-NNN.md`. При изменении статуса фаз → обновить frontmatter карточки, НЕ имя реестра.

## Calendar Events — шаги восстановления (CLAUDE.md SYNC-CORE)

Если событие создано после 09:00 по ошибке:
1. Удалить неверное событие немедленно.
2. Пересоздать до 09:00 того же дня, либо на ближайшем доступном слоте до 09:00.
3. Сообщить пилоту об ошибке.

## Code Style — доставка/детекторы по агенту (CLAUDE.md SYNC-CORE)

У Claude правила P0-P5 приходят через hook (`inject-code-style.sh` — UserPromptSubmit, инжектирует напоминание при правке кода). Детектор-страховка `code-style-hook.sh` пишет находки P1/P2/P4 в единый лог стиля для последующего ревью.

## Источник

Большая часть содержимого восстановлена из `git show fee0f85^:CLAUDE.md` (родительский коммит перед M2-слимом 2026-07-16, WP-7 HOTBUDGET-M2) — Pull-on-Touch, Git Staging, Status Reporting, WP-REGISTRY Naming, Calendar Events, Code Style. Коммит `fee0f85` перенёс слим-версии в CLAUDE.md, но не создал этот файл-приёмник — issue #283. Раздел State-Transition Gate — отдельный источник, см. пометку внутри раздела.
