#!/bin/bash
# notify.sh — unified dispatch exocortex notifications
#
# Usage:
#   notify.sh <agent> <scenario>
#
# Examples:
#   notify.sh strategist day-plan
#   notify.sh extractor inbox-check
#
# Templates: templates/<agent>.sh

set -e

# #169: emoji (🚦🔴🟡🟢⚫) from DayPlan break python3 (json.dumps/html.escape) under locale C/POSIX
# — UnicodeEncodeError: surrogates not allowed. Force UTF-8 for all python3 in the process,
# including sourced-template (escape_html, urllib.quote).
export PYTHONUTF8=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# #169: scheduler.sh calls notify.sh from FMT (read-only), and FMT-templates contain unresolved
# {{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}} → path to DayPlan does not resolve, message is empty.
# Load templates from .iwe-runtime, into which build-runtime.sh substituted real paths
# (runtime-overlay.yaml: templates/*.sh in the list substituted). Anchor: IWE_RUNTIME → IWE_WORKSPACE → $HOME/IWE.
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

AVAILABLE=$(ls "$TEMPLATES_DIR"/*.sh 2>/dev/null | xargs -I{} basename {} .sh | tr '\n' '|' | sed 's/|$//')
AGENT="${1:?Error: specify an agent (${AVAILABLE:-no templates})}"
SCENARIO="${2:?Error: specify a scenario}"

# Loading env
if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

# Checking env vars
if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    echo "SKIP: TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not set (configure ~/.config/aist/env)"
    exit 0
fi

# Sending to Telegram
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
    fi
}

# Loading agent template
TEMPLATE="$TEMPLATES_DIR/$AGENT.sh"
if [ ! -f "$TEMPLATE" ]; then
    echo "ERROR: Template not found: $TEMPLATE" >&2
    exit 1
fi

source "$TEMPLATE"

MESSAGE=$(build_message "$SCENARIO")
BUTTONS=$(build_buttons "$SCENARIO" 2>/dev/null || echo "[]")

if [ -n "$MESSAGE" ]; then
    send_telegram "$MESSAGE" "$BUTTONS"
else
    echo "Empty message for $AGENT/$SCENARIO, skip"
fi
