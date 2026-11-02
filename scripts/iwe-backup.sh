#!/usr/bin/env bash
# routing: utility  deterministic=true
# see DP.SC.159, DP.ROLE.059
# iwe-backup.sh — single entry point for running an IWE backup per the installation contract
#
# WP-7 Phase 267 stage 2 (peer session 2026-10-27-08-wp7-f267-stage2-backup-contract).
#
# CONTRACT (read from params.yaml on every run, nothing is cached):
#   whether on   backup_enabled: false — explicitly off, the script does nothing
#   with what    backup_engine: tar (default) | restic (only explicit, no automatic switch)
#   where        tar    — backup_dir (or iCloud on macOS by default)
#                restic — fixed protected storage ~/.iwe-backup/protect-repo
#                         (shared with iwe-backup-protect.sh); backup_dir is not used for restic
#   what         tar    — the whole IWE directory (without .git, node_modules, etc.)
#                restic — sources from iwe-backup-sources.yaml
#   The coverage of "what" deliberately differs between engines: a single list is a separate decision.
#
# USAGE:
#   iwe-backup.sh                  run a backup with the selected engine
#   iwe-backup.sh --with-optional  the same, restic also takes tier2 (not allowed for tar)
#
# EXIT CODES:
#   0 — snapshot taken, or backup is explicitly off / not decided (a one-line reason, not an error)
#   1 — snapshot not taken (the engine refused or the program was not found)
#   2 — contract invalid (unknown backup_engine, extra argument)

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
        if ! cap_backup_target_usable; then
            echo "ℹ️  Бэкап не запущен: цель лежит в iCloud Drive, которого на этой машине нет (или он выключен). Тревоги нет."
            echo "   Включить: включите iCloud Drive или задайте backup_dir вне iCloud; отказаться явно: backup_enabled: false."
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
