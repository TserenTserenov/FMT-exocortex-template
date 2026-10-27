#!/usr/bin/env bash
# routing: utility  deterministic=true
# see DP.SC.159, DP.ROLE.059
# iwe-backup.sh — единая точка запуска бэкапа IWE по договору установки
#
# WP-7 Ф267 этап 2 (пир-сессия 2026-10-27-08-wp7-f267-stage2-backup-contract).
#
# ДОГОВОР (читается из params.yaml при каждом запуске, ничего не кэшируется):
#   включён ли   backup_enabled: false — выключен явно, скрипт ничего не делает
#   чем          backup_engine: tar (по умолчанию) | restic (только явно, автоперехода нет)
#   куда         tar    — backup_dir (либо iCloud на macOS по умолчанию)
#                restic — фиксированное защитное хранилище ~/.iwe-backup/protect-repo
#                         (общее с iwe-backup-protect.sh); backup_dir для restic не используется
#   что          tar    — весь каталог IWE (без .git, node_modules и т.п.)
#                restic — источники из iwe-backup-sources.yaml
#   Охват «что» у движков различается сознательно: единый список — отдельное решение.
#
# USAGE:
#   iwe-backup.sh                  запустить бэкап выбранным движком
#   iwe-backup.sh --with-optional  то же, restic берёт ещё и tier2 (для tar недопустимо)
#
# EXIT CODES:
#   0 — снимок снят, либо бэкап выключен явно / не решён (одна строка причины, не ошибка)
#   1 — снимок не снят (движок отказал или программа не найдена)
#   2 — договор недопустим (неизвестный backup_engine, лишний аргумент)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.claude/lib/iwe-env-bootstrap.sh" || exit 1
source "$SCRIPT_DIR/lib/iwe-capabilities.sh" || exit 1

if cap_backup_off; then
    echo "ℹ️  Бэкап выключен явно (backup_enabled: false) — ничего не делаю."
    exit 0
fi

ENGINE="$(cap_backup_engine)"
if [ "$ENGINE" = invalid ]; then
    echo "❌ Недопустимое значение backup_engine в params.yaml. Допустимо: tar (по умолчанию) или restic." >&2
    echo "   Бэкап не запущен: молча подставлять другой движок нельзя (у них разное шифрование и хранение)." >&2
    exit 2
fi

case "$ENGINE" in
    tar)
        if [ $# -gt 0 ]; then
            echo "❌ Для движка tar аргументы не поддерживаются: $*" >&2
            exit 2
        fi
        if [ -z "${IWE_ICLOUD_BACKUP_DIR:-}" ]; then
            echo "ℹ️  Бэкап не настроен: в params.yaml нет backup_dir, а iCloud по умолчанию есть только на macOS. Тревоги нет."
            echo "   Включить: задайте backup_dir; отказаться явно: backup_enabled: false."
            exit 0
        fi
        ENGINE_SCRIPT="$SCRIPT_DIR/backup-icloud.sh"
        ;;
    restic)
        if [ -n "$(cap_backup_dir_param)" ]; then
            echo "ℹ️  backup_dir относится к архивам tar и для restic не используется: restic пишет в защитное хранилище ~/.iwe-backup/protect-repo."
        fi
        ENGINE_SCRIPT="$SCRIPT_DIR/iwe-backup-run.sh"
        ;;
esac

# The stored full path, not the PATH of whoever started us (a scheduler has a short one).
if ! PROGRAM_PATH="$(cap_resolve "$ENGINE")"; then
    echo "❌ Программа $ENGINE не найдена — бэкап не запущен. Определить заново: bash scripts/iwe-capabilities.sh probe" >&2
    exit 1
fi
PATH="$(dirname "$PROGRAM_PATH"):$PATH"
export PATH

exec bash "$ENGINE_SCRIPT" "$@"
