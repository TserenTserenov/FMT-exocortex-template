#!/bin/bash
# notification-render.sh — translation of machine publication status into a human-readable
# phrase for Telegram-notifications (WP-538).
#
# Conversational style (DP.SC.050) is normally applied LLM-agent at generation
# response; for publication scripts (ds-publish.sh, ledger-publish.sh) LLM in the chain
# absent — this file carries the same rules (no service markers, no jargon,
# short phrase) in bash, for the finite set of canonical statuses.
# Technical detail (exit code, path, git-output) stays in stderr/audit-log
# of the calling script — is not passed here and does not go to Telegram does not get sent.
#
# Usage: . "$SCRIPT_DIR/lib/notification-render.sh" && notify_translate <status> <label>
# status: ok | fail | conflict | manual_action_required | retry — final
#   alphabet; an unknown status is not treated as a call error, falls into
#   fallback-branch below.
# label: short human-readable name of the process ("event log publication").
#
# Architecture chosen in a peer-session with Codex (consensus, 3 turns, no escalations):
# sessions/2026-08/17/2026-08-17-07-wp538-notification-architecture/report.md

notify_translate() {
    local status="$1"
    local label="${2:-Publication}"

    case "$status" in
        ok)
            echo "✅ $label: completed successfully."
            ;;
        fail)
            echo "🚨 $label: did not succeed, all attempts exhausted. No action needed right now — data is not lost, will retry on the next scheduled run."
            ;;
        conflict)
            echo "⚠️ $label: could not merge changes on its own — conflict. No action needed right now — saved a copy for review, will sort it out in the next working session with you."
            ;;
        manual_action_required)
            echo "🆘 $label: cannot continue on my own — your decision is needed. Write to me in chat, when you have time to take a look."
            ;;
        retry)
            echo "🔁 $label: did not work on the first attempt, trying again. No action needed."
            ;;
        *)
            echo "🚨 $label: failed due to a reason, that was not anticipated in advance. No action needed right now — but if this repeats several times in a row, write to me, will look through the logs together."
            ;;
    esac
}
