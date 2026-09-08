#!/bin/bash
# telegram.sh — общий helper для Telegram Bot API (WP-357 Ф4)
# Источник credentials: ~/.secrets/tg-bots (sourceable, должен экспортировать
# TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID).
# Использование: . "$SCRIPT_DIR/lib/telegram.sh" && telegram_send "сообщение"

TG_SECRETS_FILE="${TG_SECRETS_FILE:-$HOME/.secrets/tg-bots}"

# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/network-wait.sh"
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/notification-render.sh"

# Секреты нельзя читать или использовать при включённом xtrace: bash печатает
# значения присваиваний и аргументы curl в stderr. Диагностический `bash -x` уже
# раскрывал таким образом рабочий и пилотский токены.
telegram_load_creds() {
    local restore_xtrace=0
    local creds_rc=0

    case "$-" in
        *x*)
            restore_xtrace=1
            set +x
            ;;
    esac

    if [[ -f "$TG_SECRETS_FILE" ]]; then
        # shellcheck disable=SC1090
        if ! . "$TG_SECRETS_FILE"; then
            creds_rc=1
        fi
    fi
    if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]] || [[ -z "${TELEGRAM_CHAT_ID:-}" ]]; then
        echo "[telegram] ERROR: TELEGRAM_BOT_TOKEN или TELEGRAM_CHAT_ID не заданы" >&2
        creds_rc=1
    fi

    if [[ "$restore_xtrace" -eq 1 ]]; then
        set -x
    fi
    return "$creds_rc"
}

# telegram_send <text> [parse_mode]
# Kimi-fix #2 (critical, 26 мая): передаём $text через stdin, не через интерполяцию.
# Защита от command injection ($(cmd), backticks) и syntax break (''').
# Retry logic (WP-server-fix, 23 июня): 3 попытки, backoff 5/10s.
# DNS/network (curl exit 6/28) → retry. HTTP 4xx → fail-fast (wrong token, bad chat).
telegram_send() {
    local restore_xtrace=0
    local send_rc=0
    case "$-" in
        *x*)
            restore_xtrace=1
            set +x
            ;;
    esac

    if telegram_send_impl "$@"; then
        send_rc=0
    else
        send_rc=$?
    fi

    if [[ "$restore_xtrace" -eq 1 ]]; then
        set -x
    fi
    return "$send_rc"
}

telegram_send_impl() {
    local text="$1"
    local parse_mode="${2:-}"

    telegram_load_creds || return 1

    # WakeSystem race guard (WP-7): wait for DNS instead of burning all 3 curl
    # attempts in the first post-wake seconds (failures 18/21/22.07.2026).
    network_wait api.telegram.org 45 || true

    local payload
    payload=$(printf '%s' "$text" | python3 -c '
import sys, json
chat_id = sys.argv[1]
parse_mode = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else ""
text = sys.stdin.read()
data = {"chat_id": chat_id, "text": text}
if parse_mode:
    data["parse_mode"] = parse_mode
print(json.dumps(data))
' "$TELEGRAM_CHAT_ID" "$parse_mode") || return 1

    local attempt http_code http_body curl_exit curl_err
    local tmp_body="" tmp_err=""
    trap 'rm -f "${tmp_body:-}" "${tmp_err:-}"' RETURN
    for attempt in 1 2 3; do
        tmp_body=$(mktemp)
        tmp_err=$(mktemp)
        http_code=$(curl -sS -o "$tmp_body" -w "%{http_code}" -m 15 \
            -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -H "Content-Type: application/json" \
            -d "$payload" 2>"$tmp_err")
        curl_exit=$?
        http_body=$(cat "$tmp_body"); rm -f "$tmp_body"
        curl_err=$(cat "$tmp_err"); rm -f "$tmp_err"

        if [[ $curl_exit -eq 0 ]]; then
            # Kimi-fix #4: парсим JSON через python вместо хрупкого grep
            if printf '%s' "$http_body" | python3 -c 'import sys, json; sys.exit(0 if json.load(sys.stdin).get("ok") else 1)' 2>/dev/null; then
                return 0
            fi
            # HTTP 4xx (wrong token, chat not found): fail-fast, retry бессмысленен
            if [[ "${http_code:0:1}" == "4" ]]; then
                echo "[telegram] FAIL HTTP $http_code (no retry): ${http_body:0:150}" >&2
                return 1
            fi
            echo "[telegram] HTTP $http_code attempt $attempt: ${http_body:0:100}" >&2
        else
            # curl network error (6=DNS, 28=timeout): retryable
            echo "[telegram] curl exit $curl_exit attempt $attempt: ${curl_err:-<no stderr>}" >&2
        fi

        [[ $attempt -lt 3 ]] && sleep $((attempt * 5))
    done

    echo "[telegram] FAIL after 3 attempts" >&2
    return 1
}

# telegram_send_and_get_id <text> [parse_mode] — как telegram_send, но печатает
# message_id отправленного сообщения в stdout (WP-503 Ф8.5: поллер сопоставляет
# входящий reply_to_message.message_id с этим числом, чтобы найти РП, на который
# отвечает пилот). Отдельная функция, не расширение telegram_send — контракт
# той функции (только exit-код) используется в 12 местах, менять его рискованно.
# Использует TG_SECRETS_FILE того же вызывающего скрипта (может отличаться от
# прод-бота, см. TG_SECRETS_FILE у telegram-poller.sh — отдельный токен, WP-503 Ф5).
telegram_send_and_get_id() {
    local restore_xtrace=0
    local send_rc=0
    case "$-" in
        *x*)
            restore_xtrace=1
            set +x
            ;;
    esac

    if telegram_send_and_get_id_impl "$@"; then
        send_rc=0
    else
        send_rc=$?
    fi

    if [[ "$restore_xtrace" -eq 1 ]]; then
        set -x
    fi
    return "$send_rc"
}

telegram_send_and_get_id_impl() {
    local text="$1"
    local parse_mode="${2:-}"

    telegram_load_creds || return 1
    network_wait api.telegram.org 45 || true

    local payload
    payload=$(printf '%s' "$text" | python3 -c '
import sys, json
chat_id = sys.argv[1]
parse_mode = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else ""
text = sys.stdin.read()
data = {"chat_id": chat_id, "text": text}
if parse_mode:
    data["parse_mode"] = parse_mode
print(json.dumps(data))
' "$TELEGRAM_CHAT_ID" "$parse_mode") || return 1

    local http_body
    http_body=$(curl -sS -m 15 \
        -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null) || return 1

    printf '%s' "$http_body" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit(1)
if not d.get("ok"):
    sys.exit(1)
mid = d.get("result", {}).get("message_id")
if mid is None:
    sys.exit(1)
print(mid)
'
}
