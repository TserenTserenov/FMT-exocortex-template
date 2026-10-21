#!/bin/bash
# SNAPSHOT — synced manually via script-promote.sh from IWE/scripts/. Do not edit here directly.
# notification-render.sh — translation of machine publish status into a human-readable
# phrase for Telegram-notifications (WP-538).
#
# Conversational style (DP.SC.050) is normally applied by the LLM-agent at response generation
# response; for the publish scripts (ds-publish.sh, ledger-publish.sh) LLM in the chain
# absent — this file carries the same rules (without service markers, without jargon,
# short phrase) in bash, for a finite set of canonical statuses.
# Technical detail (exit code, path, git-output) stays in stderr/audit-log
# of the calling script — is not passed here and is not sent to Telegram is not sent.
#
# Usage: . "$SCRIPT_DIR/lib/notification-render.sh" && notify_translate <status> <label>
# status: ok | fail | conflict | manual_action_required | retry — final
#   alphabet; an unknown status is not treated as a call error, falls into
#   fallback-branch below.
# label: short human-readable name of the process ("event log publication").
#
# Architecture was chosen in a peer-session with Codex (consensus, 3 turns, no escalations):
# sessions/2026-08/17/2026-08-17-07-wp538-notification-architecture/report.md

notify_translate() {
    local status="$1"
    local label="${2:-Publication}"

    case "$status" in
        ok)
            echo "✅ $label: completed successfully."
            ;;
        fail)
            echo "🚨 $label: did not succeed, all attempts exhausted. No action is needed right now — data is not lost, will retry on the next scheduled run."
            ;;
        conflict)
            echo "⚠️ $label: could not merge changes on its own — conflict. No action is needed right now — saved a copy for review, will sort it out in the next working session with you."
            ;;
        manual_action_required)
            echo "🆘 $label: cannot continue on my own — your decision is needed. Send me a message in chat, whenever you have a moment to take a look."
            ;;
        retry)
            echo "🔁 $label: did not succeed on the first attempt, trying again. No action needed."
            ;;
        *)
            echo "🚨 $label: failed due to a reason, that was not anticipated in advance. No action is needed right now — but if this happens several times in a row, send me a message, will look through the logs together."
            ;;
    esac
}
