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
# Note: gh issue list --label "X,Y" применяет AND-логику (issue должен иметь оба label).
# Нам нужен OR — issue хотя бы с одним из label'ов. Используем gh api repos/.../issues?labels=
# (REST API также AND) с отдельным запросом per label + jq merge с dedup.
set +e
LABELS_ARRAY=()
IFS=',' read -ra LABELS_ARRAY <<< "$LABEL_QUERY"
if [ ${#LABELS_ARRAY[@]} -eq 0 ] || { [ ${#LABELS_ARRAY[@]} -eq 1 ] && [ -z "${LABELS_ARRAY[0]}" ]; }; then
    echo "Error: --labels is empty" >&2
    exit 2
fi
TMP_JSONS=()
for label in "${LABELS_ARRAY[@]}"; do
    tmp=$(mktemp)
    label_trim=$(echo "$label" | tr -d '[:space:]')
    encoded_label=$(printf '%s' "$label_trim" | python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read()))")
    gh api "repos/${REPO}/issues?state=open&labels=${encoded_label}" \
        --jq '[.[] | select(.pull_request == null) | {number, title, labels: [.labels[].name], url: .html_url}]' \
        > "$tmp" 2>/dev/null
    api_rc=$?
    if [ $api_rc -ne 0 ]; then
        echo "Error: gh api failed for label='$label_trim' (rc=$api_rc)" >&2
        rm -f "$tmp"
        if [ ${#TMP_JSONS[@]} -gt 0 ]; then
            rm -f "${TMP_JSONS[@]}"
        fi
        exit 2
    fi
    TMP_JSONS+=("$tmp")
done

# Merge + dedup by number
ISSUES_JSON=$(python3 -c "
import json, sys
seen = set()
out = []
for f in sys.argv[1:]:
    with open(f) as fh:
        for i in json.load(fh):
            if i['number'] not in seen:
                seen.add(i['number'])
                out.append(i)
print(json.dumps(out, ensure_ascii=False))
" "${TMP_JSONS[@]}" 2>&1)
PY_RC=$?
rm -f "${TMP_JSONS[@]}"
set -e

if [ $PY_RC -ne 0 ]; then
    echo "Error: failed to merge label-query results (python rc=$PY_RC):" >&2
    echo "$ISSUES_JSON" >&2
    exit 2
fi

# Если массив пуст — тихий success
set +e
COUNT=$(echo "$ISSUES_JSON" | jq 'length' 2>&1)
JQ_RC=$?
set -e
if [ $JQ_RC -ne 0 ]; then
    echo "Error: invalid JSON (jq rc=$JQ_RC). Output:" >&2
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
echo "$ISSUES_JSON" | jq -r '.[] | "| #\(.number) | [\(.title)](\(.url)) | \(.labels | join(", ")) |"'
echo ""

# Telegram alert (MVP)
if $SEND_TG; then
    # Fallback chain: TG_BOT_TOKEN → TELEGRAM_BOT_TOKEN (legacy/IWE-standard name from ~/.exocortex.env)
    TG_TOKEN="${TG_BOT_TOKEN:-${TELEGRAM_BOT_TOKEN:-}}"
    TG_CHAT="${TG_CHAT_ID:-${TELEGRAM_CHAT_ID:-}}"
    if [ -z "$TG_TOKEN" ] || [ -z "$TG_CHAT" ]; then
        echo "_TG alert skipped:_ TG_BOT_TOKEN/TELEGRAM_BOT_TOKEN or TG_CHAT_ID/TELEGRAM_CHAT_ID not set in environment."
        exit 1
    fi

    # Build message
    TG_MSG="🔴 FMT critical issues ($COUNT):"$'\n'
    while IFS= read -r line; do
        TG_MSG="$TG_MSG"$'\n'"$line"
    done < <(echo "$ISSUES_JSON" | jq -r '.[] | "  #\(.number): \(.title)\n    \(.url)"')

    # Send
    set +e
    TG_RESPONSE=$(curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT}" \
        --data-urlencode "text=${TG_MSG}" 2>&1)
    CURL_RC=$?
    set -e

    if [ $CURL_RC -ne 0 ]; then
        echo "_TG alert failed:_ curl exit $CURL_RC"
        exit 1
    fi

    OK=$(echo "$TG_RESPONSE" | jq -r '.ok // false' 2>/dev/null)
    if [ "$OK" = "true" ]; then
        # Маскируем chat_id в STDOUT (DayPlan/WeekReport коммитятся в Git — PII-сигнал).
        TG_CHAT_MASKED="${TG_CHAT:0:3}***"
        echo "_TG alert sent:_ chat ${TG_CHAT_MASKED}"
    else
        echo "_TG alert response:_ $TG_RESPONSE"
        exit 1
    fi
fi
