#!/bin/bash
# notify.sh — single dispatch of exocortex notifications
#
# Usage:
#   notify.sh [--require-delivery] <agent> <scenario>
#
# --require-delivery: exit 0 ONLY if Telegram confirmed delivery. Without the flag
# behavior is as before (no token or a not-ok response - exit 0, text only in stdout),
# so the caller cannot tell from the exit code whether the message arrived. Codes with the flag:
#   3 - TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID not configured
#   4 - Telegram did not confirm sending
#   5 - message is empty, nothing to send
#
# Examples:
#   notify.sh strategist day-plan
#   notify.sh extractor inbox-check
#
# Templates: templates/<agent>.sh

set -e

# #169: emoji (🚦🔴🟡🟢⚫) from the DayPlan break python3 (json.dumps/html.escape) under the C/POSIX locale
# — UnicodeEncodeError: surrogates not allowed. Force UTF-8 for all python3 in the process,
# including the sourced template (escape_html, urllib.quote).
export PYTHONUTF8=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# #169: scheduler.sh calls notify.sh from FMT (read-only), and FMT templates hold unresolved
# {{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}} -> the path to the DayPlan is not resolved, the message is empty.
# Take templates from .iwe-runtime, where build-runtime.sh substituted the real paths
# (runtime-overlay.yaml: templates/*.sh in the substituted list). Anchor: IWE_RUNTIME -> IWE_WORKSPACE -> $HOME/IWE.
RUNTIME_TEMPLATES="${IWE_RUNTIME:-${IWE_WORKSPACE:-$HOME/IWE}/.iwe-runtime}/roles/synchronizer/scripts/templates"
if [ -z "${TEMPLATES_DIR:-}" ]; then
    if [ -d "$RUNTIME_TEMPLATES" ]; then
        TEMPLATES_DIR="$RUNTIME_TEMPLATES"
    else
        TEMPLATES_DIR="$SCRIPT_DIR/templates"
        echo "WARN: notify.sh fell back to FMT templates (.iwe-runtime not built?). Run setup/build-runtime.sh." >&2
    fi
fi
ENV_FILE="$HOME/.config/aist/env"

REQUIRE_DELIVERY=0
if [ "${1:-}" = "--require-delivery" ]; then
    REQUIRE_DELIVERY=1
    shift
fi

AVAILABLE=$(ls "$TEMPLATES_DIR"/*.sh 2>/dev/null | xargs -I{} basename {} .sh | tr '\n' '|' | sed 's/|$//')
AGENT="${1:?Ошибка: укажи агента (${AVAILABLE:-нет шаблонов})}"
SCENARIO="${2:?Ошибка: укажи сценарий}"

# Load env
if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

# Check env vars
if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    echo "SKIP: TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not set (configure ~/.config/aist/env)"
    [ "$REQUIRE_DELIVERY" -eq 1 ] && exit 3
    exit 0
fi

# Send to Telegram through iwe-notify (WP-568 Ф12 С4, peer-session 2026-11-08-06):
# the one place a template script calls the Bot API. Without a notification
# gateway on the workstation iwe-notify makes the same single direct send as
# before (HTML, buttons, TELEGRAM_PROXY/ALL_PROXY, "ok":true required) and logs
# it; with a gateway the gateway decides the channel and that is final (text
# only, no buttons), including pulse and --require-delivery. IWE_TG_BIN still
# names a gateway explicitly.
# iwe-notify-sources: strategist pulse synchronizer-notify
# Lookup: the copy shipped with this template first (it matches this script's
# flags), then the explicit override and the other known places.
find_iwe_notify() {
    local candidate
    for candidate in "$SCRIPT_DIR/../../../scripts/iwe-notify" "${IWE_NOTIFY_BIN:-}" \
        "${IWE_TEMPLATE:+$IWE_TEMPLATE/scripts/iwe-notify}" "${IWE_SCRIPTS:+$IWE_SCRIPTS/iwe-notify}" \
        "${IWE_WORKSPACE:-$HOME/IWE}/scripts/iwe-notify"; do
        if [ -n "$candidate" ] && [ -x "$candidate" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

# send_telegram <html text> [buttons json array]
# Without --require-delivery: always 0, the outcome only in stdout (as before).
# With it: 0 = delivered to the chat, 3 = no credentials, 4 = not delivered
# (failed, kept for a digest, quarantined, or iwe-notify missing).
send_telegram() {
    local text="$1"
    local buttons="${2:-[]}"
    local source_id notify_bin outcome
    local args=()

    text="${text:0:4000}"
    case "$AGENT" in
        strategist|pulse) source_id="$AGENT" ;;
        *) source_id="synchronizer-notify" ;;
    esac
    if ! notify_bin=$(find_iwe_notify); then
        echo "Telegram send FAILED: $AGENT/$SCENARIO (iwe-notify not found; run update.sh)"
        [ "$REQUIRE_DELIVERY" -eq 1 ] && return 4
        return 0
    fi
    args=(--source "$source_id" --html)
    [ "$buttons" = "[]" ] || args+=(--reply-markup "{\"inline_keyboard\":$buttons}")
    outcome=$(IWE_NOTIFY_GATEWAY="${IWE_TG_BIN:-${IWE_NOTIFY_GATEWAY:-}}" \
        "$notify_bin" "${args[@]}" -- "$text") || true
    outcome="${outcome#iwe-notify: outcome=}"
    # The outcome goes to stderr: callers match the stdout lines below whole
    # (scheduler.sh greps "Telegram notification sent: <agent>/<scenario>" with -x).
    echo "notify.sh: $AGENT/$SCENARIO outcome=${outcome:-unknown}" >&2
    case "$outcome" in
        sent|direct-sent)
            echo "Telegram notification sent: $AGENT/$SCENARIO"
            return 0 ;;
        deferred|quarantined)
            echo "Notification routed through the gate: $AGENT/$SCENARIO" ;;
        not-sent)
            echo "Telegram send FAILED: $AGENT/$SCENARIO (not configured)"
            [ "$REQUIRE_DELIVERY" -eq 1 ] && return 3 ;;
        *)
            echo "Telegram send FAILED: $AGENT/$SCENARIO (${outcome:-unknown})" ;;
    esac
    [ "$REQUIRE_DELIVERY" -eq 1 ] && return 4
    return 0
}

# Load the agent template
TEMPLATE="$TEMPLATES_DIR/$AGENT.sh"
if [ ! -f "$TEMPLATE" ]; then
    echo "ERROR: Template not found: $TEMPLATE" >&2
    exit 1
fi

source "$TEMPLATE"

MESSAGE=$(build_message "$SCENARIO")
BUTTONS=$(build_buttons "$SCENARIO" 2>/dev/null || echo "[]")

if [ -n "$MESSAGE" ]; then
    # Without the flag send_telegram stays a plain command, so `set -e` behaves as it
    # always did (a curl failure ends the script with curl's code). With the flag the
    # `||` is deliberate: the failure must reach the exit code as 4, not as curl's code.
    if [ "$REQUIRE_DELIVERY" -eq 1 ]; then
        send_telegram "$MESSAGE" "$BUTTONS" || exit $?
    else
        send_telegram "$MESSAGE" "$BUTTONS"
    fi
else
    echo "Empty message for $AGENT/$SCENARIO, skip"
    if [ "$REQUIRE_DELIVERY" -eq 1 ]; then
        exit 5
    fi
fi
