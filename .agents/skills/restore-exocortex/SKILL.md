---
# see DP.SC.153 (родительский), #125
name: restore-exocortex
description: "Restore IWE memory from an exocortex backup on a new device or after data loss — NL wrapper around restore-from-exocortex.sh."
version: 1.0.0
layer: L1
status: active
triggers:
  slash: [/restore-exocortex]
  phrases: ["восстанови экзокортекс", "восстанови память", "восстановить exocortex", "restore exocortex", "подними память на новом устройстве"]
owner_role: R6
annotations:
  destructive: true
  interactive: true
related: ["#125"]
---

# /restore-exocortex — Восстановление памяти из exocortex

> **Роль:** R6 Кодировщик
> **Триггер:** «восстанови экзокортекс / память», новое устройство, потеря/повреждение `memory/`
> **Service Clause:** DP.SC.153 (родительский, скиллы); реализация #125

## Обещание (контракт)

**Вход:** (опц.) путь к governance-репо. По умолчанию `$WORKSPACE_DIR/$GOVERNANCE_REPO` (`~/IWE/DS-strategy`).
**Выход:** восстановленные `memory/` + `extensions/` + `CLAUDE.md` + симлинк `memory/`; отчёт + напоминание перезапустить Claude Code.
**Инвариант:** НЕ перезаписывает населённую `memory/` или `extensions/` без явного подтверждения пользователя.

> **Оркестрация, не реализация.** Скилл судит (свежее устройство vs существующая инсталляция, резолв пути, подтверждение) и зовёт детерминированный примитив `scripts/restore-from-exocortex.sh`. Сам file-ops не делает. На голом терминале без агента используется скрипт напрямую — это bootstrap-путь (см. SETUP-GUIDE).

## Алгоритм

### Шаг 1. Резолв скрипта и пути
- Скрипт: `$IWE_SCRIPTS/restore-from-exocortex.sh` → fallback `$WORKSPACE_DIR/FMT-exocortex-template/scripts/restore-from-exocortex.sh`. Нет файла → см. Режим отказа.
- Governance-репо: аргумент пользователя, иначе `$WORKSPACE_DIR/${GOVERNANCE_REPO:-DS-strategy}`. Убедиться, что `<gov>/exocortex/` существует.

### Шаг 2. Pre-flight (judgment — здесь LLM уместен)
- Определить целевую auto-memory: `~/.claude/projects/$(echo "$HOME" | tr '/_.' '-')-IWE/memory` (Claude Code слугифицирует `/`, `_`, `.` → `-`; `tr '/' '-'` промахнётся при `_` в username).
- **Пусто/нет** → свежее устройство, восстановление без `--force`.
- **Населена** → существующая инсталляция. Это destructive: показать `--dry-run` и **спросить подтверждение** перед `--force` (Правило 7, исключение «необратимое»).

### Шаг 3. Превью → восстановление
1. Всегда сначала `restore-from-exocortex.sh <gov> --dry-run` — показать пользователю, что будет сделано.
2. После согласия (или сразу, если memory пуста) — запуск без `--dry-run` (с `--force`, если memory населена и пользователь подтвердил).

### Шаг 4. Отчёт
- Сколько memory-файлов восстановлено, восстановлен ли `CLAUDE.md`, создан ли симлинк.
- **Напомнить: перезапустить Claude Code** — память грузится при старте сессии.

## Режим отказа

| Сценарий | Поведение |
|---------|-----------|
| `exocortex/` не найден | Стоп: backup отсутствует/не запушен. Подсказать `git pull` governance-репо или проверить путь |
| Скрипт не найден | До мержа #151 — взять из ветки: `git checkout feat/exocortex-sync-restore -- scripts/restore-from-exocortex.sh`; иначе bug-report |
| memory населена, нет подтверждения | НЕ перезаписывать. Показать dry-run, ждать явного «да»/`--force` |
| Агент ещё не настроен (голое устройство) | Скилл недоступен → инструктировать запуск скрипта из терминала (bootstrap-путь, SETUP-GUIDE) |

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
