#!/usr/bin/env bash
# routing: helper  skill=day-open,week-close  called-by=skill-day-open  deterministic=true
# see DP.SC.NNN (pending IntegrationGate), peer-session 2026-06-01-18
#
# fmt-critical-alert.sh — MVP-механизм обнаружения критических FMT issues.
#
# WP-356 Ф?, peer-session 2026-06-01-18-fmt-issues-triage-verify, 2026-06-01.
#
# РОЛЬ: helper для скиллов day-open / week-close. Запрашивает у GitHub
# открытые issues с label critical/deadline в FMT-exocortex-template и:
#   - выводит markdown-таблицу в stdout (для DayPlan/WeekClose отчёта)
#   - отправляет Telegram-уведомление если есть critical issues и есть
#     TG_BOT_TOKEN+TG_CHAT_ID в окружении (MVP detection chain — закрывает
#     gap для weekend P0).
#
# Принцип «детектор отчитывается, оператор делает»: скрипт ТОЛЬКО детектит,
# никаких автофиксов.
#
# Usage:
#   bash fmt-critical-alert.sh                  # markdown-таблица + TG если настроен
#   bash fmt-critical-alert.sh --no-telegram    # только stdout, без TG
#   bash fmt-critical-alert.sh --repo OWNER/R   # альтернативный репо (default FMT-exocortex-template)
#   bash fmt-critical-alert.sh -h | --help
#
# Exit code:
#   0 — нет critical/deadline issues (или они есть и оповещение отправлено)
#   1 — есть critical issues, но TG_BOT_TOKEN/TG_CHAT_ID не настроены (warning только в stdout)
#   2 — ошибка вызова gh (нет авторизации, repo недоступен)
#
# Требования: bash, gh, curl, jq. Без внешних зависимостей.

set -eu

# Repo resolution: IWE_FMT_REPO env → GITHUB_USER env → params.yaml → exit with hint.
# Не hardcode'им автора шаблона: скрипт работает в forks любого пилота.
REPO="${IWE_FMT_REPO:-}"
if [ -z "$REPO" ] && [ -n "${GITHUB_USER:-}" ]; then
    REPO="${GITHUB_USER}/FMT-exocortex-template"
fi
if [ -z "$REPO" ] && [ -f "${IWE_ROOT:-$HOME/IWE}/params.yaml" ]; then
    GH_USER=$(grep -E "^github_user:" "${IWE_ROOT:-$HOME/IWE}/params.yaml" 2>/dev/null | sed -E 's/^github_user:[[:space:]]*//; s/^"//; s/"$//')
    [ -n "$GH_USER" ] && REPO="${GH_USER}/FMT-exocortex-template"
fi
if [ -z "$REPO" ]; then
    echo "Error: cannot resolve FMT repo. Set IWE_FMT_REPO or GITHUB_USER env, or add 'github_user: <login>' to params.yaml." >&2
    exit 2
fi

SEND_TG=true
LABEL_QUERY="critical,deadline"

while [ $# -gt 0 ]; do
    case "$1" in
        --no-telegram) SEND_TG=false; shift ;;
        --repo) REPO="$2"; shift 2 ;;
        --labels) LABEL_QUERY="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | head -30
            exit 0
            ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

# Проверка зависимостей
command -v gh >/dev/null 2>&1 || { echo "Error: gh CLI not found" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq not found" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "Error: curl not found" >&2; exit 2; }

# gh auth check (proactive, иначе error будет в gh issue list но с менее ясным сообщением)
if ! gh auth status >/dev/null 2>&1; then
    echo "Error: gh not authenticated. Run 'gh auth login' first." >&2
    exit 2
fi

# Запрос issues
set +e
ISSUES_JSON=$(gh issue list -R "$REPO" --state open --label "$LABEL_QUERY" --json number,title,labels,url 2>&1)
GH_RC=$?
set -e

if [ $GH_RC -ne 0 ]; then
    echo "Error: gh issue list failed (rc=$GH_RC):" >&2
    echo "$ISSUES_JSON" >&2
    exit 2
fi

# Если массив пуст — тихий success
set +e
COUNT=$(echo "$ISSUES_JSON" | jq 'length' 2>&1)
JQ_RC=$?
set -e
if [ $JQ_RC -ne 0 ]; then
    echo "Error: invalid JSON from gh (jq rc=$JQ_RC). Output:" >&2
    echo "$ISSUES_JSON" | head -5 >&2
    exit 2
fi
if [ "$COUNT" = "0" ]; then
    # Нет критичных issues — markdown-таблица не нужна
    echo "_FMT critical/deadline issues:_ 0 (✅ clean)"
    exit 0
fi

# Markdown-таблица для DayPlan / WeekClose отчёта
echo "## ⚠️ FMT критические issues ($COUNT)"
echo ""
echo "| # | Issue | Labels |"
echo "|---|---|---|"
echo "$ISSUES_JSON" | jq -r '.[] | "| #\(.number) | [\(.title)](\(.url)) | \([.labels[].name] | join(", ")) |"'
echo ""

# Telegram alert (MVP)
if $SEND_TG; then
    if [ -z "${TG_BOT_TOKEN:-}" ] || [ -z "${TG_CHAT_ID:-}" ]; then
        echo "_TG alert skipped:_ TG_BOT_TOKEN or TG_CHAT_ID not set in environment."
        exit 1
    fi

    # Build message
    TG_MSG="🔴 FMT critical issues ($COUNT):"$'\n'
    while IFS= read -r line; do
        TG_MSG="$TG_MSG"$'\n'"$line"
    done < <(echo "$ISSUES_JSON" | jq -r '.[] | "  #\(.number): \(.title)\n    \(.url)"')

    # Send
    set +e
    TG_RESPONSE=$(curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT_ID}" \
        --data-urlencode "text=${TG_MSG}" 2>&1)
    CURL_RC=$?
    set -e

    if [ $CURL_RC -ne 0 ]; then
        echo "_TG alert failed:_ curl exit $CURL_RC"
        exit 1
    fi

    OK=$(echo "$TG_RESPONSE" | jq -r '.ok // false' 2>/dev/null)
    if [ "$OK" = "true" ]; then
        echo "_TG alert sent:_ chat ${TG_CHAT_ID}"
    else
        echo "_TG alert response:_ $TG_RESPONSE"
        exit 1
    fi
fi
