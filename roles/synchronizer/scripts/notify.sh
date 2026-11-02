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

# Send to Telegram
send_telegram() {
    local text="$1"
    local buttons="${2:-[]}"

    text="${text:0:4000}"

    local escaped_text
    escaped_text=$(printf '%s' "$text" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')

    local json_body
    if [ "$buttons" = "[]" ]; then
        json_body=$(printf '{"chat_id":"%s","text":%s,"parse_mode":"HTML","disable_web_page_preview":true}' \
            "$TELEGRAM_CHAT_ID" "$escaped_text")
    else
        json_body=$(printf '{"chat_id":"%s","text":%s,"parse_mode":"HTML","disable_web_page_preview":true,"reply_markup":{"inline_keyboard":%s}}' \
            "$TELEGRAM_CHAT_ID" "$escaped_text" "$buttons")
    fi

    local response
    local curl_proxy_args=()
    if [ -n "${TELEGRAM_PROXY:-}" ]; then
        curl_proxy_args=(--proxy "$TELEGRAM_PROXY")
    elif [ -n "${ALL_PROXY:-}" ]; then
        curl_proxy_args=(--proxy "$ALL_PROXY")
    fi

    response=$(curl -s --connect-timeout 5 --max-time 10 "${curl_proxy_args[@]}" -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "$json_body")

    local ok
    ok=$(echo "$response" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("ok",""))' 2>/dev/null || echo "")

    if [ "$ok" = "True" ]; then
        echo "Telegram notification sent: $AGENT/$SCENARIO"
    else
        echo "Telegram send FAILED: $AGENT/$SCENARIO"
        echo "Response: $response"
        [ "$REQUIRE_DELIVERY" -eq 1 ] && return 4
    fi
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
