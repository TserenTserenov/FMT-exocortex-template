#!/bin/bash
# SNAPSHOT — synced manually via script-promote.sh from FMT-exocortex-template/scripts/. Do not edit here directly.
# notification-render.sh — translating a machine publication status into a human-readable
# phrase for Telegram notifications (WP-538).
#
# The conversational style (DP.SC.050) is usually applied by an LLM agent when generating
# a reply; the publication scripts (ds-publish.sh, ledger-publish.sh) have no LLM
# in the chain — this file carries over the same rules (no service labels, no jargon,
# a short phrase) into bash, for a finite set of canonical statuses.
# Technical detail (exit code, path, git output) stays in stderr/the audit log
# of the calling script — it is not passed here and does not go to Telegram.
#
# Usage: . "$SCRIPT_DIR/lib/notification-render.sh" && notify_translate <status> <label>
# status: ok | fail | conflict | manual_action_required | retry — a finite
#   alphabet; an unknown status is not a call error, it falls into the
#   fallback branch below.
# label: a short human name of the process ("публикация журнала событий").
#
# The architecture was chosen in a peer session with Codex (consensus, 3 turns, no escalations):
# sessions/2026-08/17/2026-08-17-07-wp538-notification-architecture/report.md

notify_translate() {
    local status="$1"
    local label="${2:-Публикация}"

    case "$status" in
        ok)
            echo "✅ $label: прошло успешно."
            ;;
        fail)
            echo "🚨 $label: не получилось, попытки закончились. Действие не нужно прямо сейчас — данные не потеряны, повторю на следующем плановом запуске."
            ;;
        conflict)
            echo "⚠️ $label: не смог сам объединить изменения — конфликт. Действие не нужно прямо сейчас — сохранил копию для разбора, разберу в следующей рабочей сессии с тобой."
            ;;
        manual_action_required)
            echo "🆘 $label: сам продолжить не могу — нужно твоё решение. Напиши мне в чат, когда будет время посмотреть."
            ;;
        retry)
            echo "🔁 $label: с первого раза не вышло, пробую ещё раз. Действие не нужно."
            ;;
        *)
            echo "🚨 $label: упало по причине, которую заранее не предусмотрел. Действие не нужно прямо сейчас — но если это повторится несколько раз подряд, напиши мне, посмотрю логи вместе."
            ;;
    esac
}
