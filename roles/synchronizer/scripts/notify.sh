#!/bin/bash
# notify.sh — single dispatch of exocortex notifications
#
# Usage:
#   notify.sh [--require-delivery] [--force] <agent> <scenario>
#
# --require-delivery: exit 0 ONLY if Telegram confirmed delivery. Without the flag
# behavior is as before (no token or a not-ok response - exit 0, text only in stdout),
# so the caller cannot tell from the exit code whether the message arrived. Codes with the flag:
#   3 - TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID not configured
#   4 - Telegram did not confirm sending
#   5 - message is empty, nothing to send
#
# --force: send even if the same text was already sent today for this <agent>/<scenario>.
#
# Duplicate guard (issue found 11.11.2026: the day-plan digest arrived 2-3 times a
# morning): for a scenario listed in IWE_NOTIFY_DEDUPE (default `strategist/day-plan`)
# the same text is sent at most once per calendar day. Two legitimate senders of one
# digest (the scenario runner and the prompt that tells the model to run this script)
# then produce one message instead of two. The guard is an allowlist, not a blanket:
# a scenario may legitimately repeat identical text (a re-run after a fix, a pulse),
# so only the named ones are suppressed. Entries are `<agent>/<scenario>`, or
# `<agent>/*`, or `all`. The marker is written only after a confirmed send, so a
# failed delivery is retried instead of being suppressed. A changed text (new plan,
# new report) sends normally; --force bypasses the check for a deliberate resend.
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
FORCE_SEND=0
while [ $# -gt 0 ]; do
    case "$1" in
        --require-delivery) REQUIRE_DELIVERY=1; shift ;;
        --force) FORCE_SEND=1; shift ;;
        *) break ;;
    esac
done

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
SEND_OUTCOME=""
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
            SEND_OUTCOME=sent
            echo "Telegram notification sent: $AGENT/$SCENARIO"
            return 0 ;;
        deferred|quarantined)
            SEND_OUTCOME=deferred
            echo "Notification routed through the gate: $AGENT/$SCENARIO" ;;
        not-sent)
            SEND_OUTCOME=not-sent
            echo "Telegram send FAILED: $AGENT/$SCENARIO (not configured)"
            [ "$REQUIRE_DELIVERY" -eq 1 ] && return 3 ;;
        *)
            SEND_OUTCOME=failed
            echo "Telegram send FAILED: $AGENT/$SCENARIO (${outcome:-unknown})" ;;
    esac
    [ "$REQUIRE_DELIVERY" -eq 1 ] && return 4
    return 0
}

# --- duplicate guard -------------------------------------------------------
# One message per <agent>/<scenario> per calendar day while the text is identical.
# The marker lives next to the other runtime state, never in the repo: the same
# text sent tomorrow is a new message, not a duplicate.
NOTIFY_STATE_DIR="${IWE_RUNTIME:-${IWE_WORKSPACE:-$HOME/IWE}/.iwe-runtime}/state/notify-sent"

notify_marker() {  # path of this <agent>/<scenario> marker, sanitised for the filesystem
    printf '%s/%s-%s.last' "$NOTIFY_STATE_DIR" \
        "$(printf '%s' "$AGENT" | tr -c 'A-Za-z0-9._-' '_')" \
        "$(printf '%s' "$SCENARIO" | tr -c 'A-Za-z0-9._-' '_')"
}

notify_hash() {  # <text> -> sha256 (empty when no hashing tool: the guard then stays out of the way)
    local text="$1" h=""
    if command -v sha256sum >/dev/null 2>&1; then
        h=$(printf '%s' "$text" | sha256sum | cut -d' ' -f1)
    elif command -v shasum >/dev/null 2>&1; then
        h=$(printf '%s' "$text" | shasum -a 256 | cut -d' ' -f1)
    elif command -v md5sum >/dev/null 2>&1; then
        h=$(printf '%s' "$text" | md5sum | cut -d' ' -f1)
    fi
    printf '%s' "$h"
}

notify_is_duplicate() {  # <text> -> 0 when the same text was already sent today
    local text="$1" marker hash stored_date stored_hash
    marker=$(notify_marker)
    [ -f "$marker" ] || return 1
    hash=$(notify_hash "$text")
    [ -n "$hash" ] || return 1
    stored_date=$(sed -n '1p' "$marker" 2>/dev/null)
    stored_hash=$(sed -n '2p' "$marker" 2>/dev/null)
    [ "$stored_date" = "$(date +%F)" ] && [ "$stored_hash" = "$hash" ]
}

# The guard is an allowlist: a scenario that is not named keeps the old behaviour
# (send every time), because identical repeats are legitimate for most of them.
NOTIFY_DEDUPE_SCOPES="${IWE_NOTIFY_DEDUPE:-strategist/day-plan}"

notify_dedupe_enabled() {
    local item
    for item in $NOTIFY_DEDUPE_SCOPES; do
        case "$item" in
            all|"$AGENT/$SCENARIO"|"$AGENT/*"|"*/$SCENARIO") return 0 ;;
        esac
    done
    return 1
}

notify_mark_sent() {  # <text>; a marker that cannot be written never blocks the next send
    local text="$1" hash marker
    hash=$(notify_hash "$text")
    [ -n "$hash" ] || return 0
    marker=$(notify_marker)
    mkdir -p "$NOTIFY_STATE_DIR" 2>/dev/null \
        || { echo "WARN: cannot create $NOTIFY_STATE_DIR (duplicate guard off)" >&2; return 0; }
    printf '%s\n%s\n' "$(date +%F)" "$hash" > "$marker" 2>/dev/null \
        || echo "WARN: cannot write $marker (duplicate guard off)" >&2
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
    # Duplicate guard: for the named scenarios, a message whose text is unchanged
    # since a confirmed send today is not sent again. Exit 0 with the flag: the
    # owner has the message, so "delivered" stays true; the SKIP line names why.
    if [ "$FORCE_SEND" -eq 0 ] && notify_dedupe_enabled && notify_is_duplicate "$MESSAGE"; then
        echo "SKIP: duplicate notification $AGENT/$SCENARIO (same text already sent today; --force to resend)"
        exit 0
    fi
    # Without the flag send_telegram stays a plain command, so `set -e` behaves as it
    # always did (a curl failure ends the script with curl's code). With the flag the
    # `||` is deliberate: the failure must reach the exit code as 4, not as curl's code.
    if [ "$REQUIRE_DELIVERY" -eq 1 ]; then
        send_telegram "$MESSAGE" "$BUTTONS" || exit $?
    else
        send_telegram "$MESSAGE" "$BUTTONS"
    fi
    if [ "$SEND_OUTCOME" = sent ]; then
        notify_mark_sent "$MESSAGE"
    fi
else
    echo "Empty message for $AGENT/$SCENARIO, skip"
    if [ "$REQUIRE_DELIVERY" -eq 1 ]; then
        exit 5
    fi
fi
