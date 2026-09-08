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
#   2 — ошибка вызова gh (нет авторизации, repo недоступен, issue tracker отключён)
#      или issue tracker отключён (issue #340 — отличаем от «0 issues»).
#
# Требования: bash, gh, curl, jq. Без внешних зависимостей.

set -eu

SCRIPT_PATH="${BASH_SOURCE[0]}"
case "$SCRIPT_PATH" in /*) ;; *) SCRIPT_PATH="$PWD/$SCRIPT_PATH" ;; esac
SCRIPT_DIR="$(cd "${SCRIPT_PATH%/*}" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

SEND_TG=true
REPO_ARG=""
# stale-unattended added (pipeline fix): issues triaged but unfixed for 14+ days were invisible
# after the 2-day Day Open window. Now they surface here at Week Close.
LABEL_QUERY="critical,deadline,stale-unattended"

while [ $# -gt 0 ]; do
    case "$1" in
        --no-telegram) SEND_TG=false; shift ;;
        --repo) [ $# -ge 2 ] || { echo "--repo requires OWNER/REPO" >&2; exit 1; }; REPO_ARG="$2"; shift 2 ;;
        --labels) LABEL_QUERY="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | head -30
            exit 0
            ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

# Repo resolution happens after argument parsing so --repo works even when no
# ambient config exists. Precedence: CLI → process env → .exocortex.env → params.
ROOT=$(iwe_resolve_root "${IWE_WORKSPACE:-${IWE_ROOT:-}}") || exit 2
ENV_FILE="$ROOT/.exocortex.env"
ENV_REPO=$(iwe_env_get "$ENV_FILE" IWE_FMT_REPO 2>/dev/null || true)
ENV_GITHUB_USER=$(iwe_env_get "$ENV_FILE" GITHUB_USER 2>/dev/null || true)
REPO="${REPO_ARG:-${IWE_FMT_REPO:-${ENV_REPO:-}}}"
GH_USER="${GITHUB_USER:-${ENV_GITHUB_USER:-}}"
if [ -z "$REPO" ] && [ -n "$GH_USER" ]; then
    REPO="${GH_USER}/FMT-exocortex-template"
fi
if [ -z "$REPO" ] && [ -f "$ROOT/params.yaml" ]; then
    GH_USER=$(grep -E "^github_user:" "$ROOT/params.yaml" 2>/dev/null | sed -E 's/^github_user:[[:space:]]*//; s/^"//; s/"$//')
    [ -n "$GH_USER" ] && REPO="${GH_USER}/FMT-exocortex-template"
fi
if [ -z "$REPO" ]; then
    echo "Error: cannot resolve FMT repo. Use --repo, IWE_FMT_REPO/GITHUB_USER, or $ENV_FILE." >&2
    exit 2
fi

# Проверка зависимостей
command -v gh >/dev/null 2>&1 || { echo "Error: gh CLI not found" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq not found" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "Error: curl not found" >&2; exit 2; }

# gh auth check (proactive, иначе error будет в gh issue list но с менее ясным сообщением)
if ! gh auth status >/dev/null 2>&1; then
    echo "Error: gh not authenticated. Run 'gh auth login' first." >&2
    exit 2
fi

# --- Repo verification: detect forks and disabled issue trackers ---
# issue #340: a user's fork with an empty tracker was reported as "clean" forever.
# Resolve the actual upstream for forks and refuse to silently treat a disabled
# tracker as "no issues".
set +e
REPO_INFO=$(gh api "repos/${REPO}" --jq '{fork: .fork, parent: .parent.full_name, has_issues: .has_issues}' 2>&1)
REPO_INFO_RC=$?
set -e
if [ $REPO_INFO_RC -ne 0 ]; then
    echo "Error: cannot fetch repo info for ${REPO} (gh rc=$REPO_INFO_RC): ${REPO_INFO}" >&2
    exit 2
fi

ISSUE_REPO="$REPO"
FORK_PARENT=$(echo "$REPO_INFO" | jq -r '.parent // empty')
if [ -n "$FORK_PARENT" ]; then
    echo "_Note: ${REPO} is a fork; querying upstream ${FORK_PARENT} for critical issues._"
    ISSUE_REPO="$FORK_PARENT"
fi

set +e
ISSUE_REPO_INFO=$(gh api "repos/${ISSUE_REPO}" --jq '{has_issues: .has_issues}' 2>&1)
ISSUE_REPO_INFO_RC=$?
set -e
if [ $ISSUE_REPO_INFO_RC -ne 0 ]; then
    echo "Error: cannot fetch repo info for ${ISSUE_REPO} (gh rc=$ISSUE_REPO_INFO_RC): ${ISSUE_REPO_INFO}" >&2
    exit 2
fi

HAS_ISSUES=$(echo "$ISSUE_REPO_INFO" | jq -r '.has_issues // "unknown"')
if [ "$HAS_ISSUES" != "true" ]; then
    echo "_FMT critical/deadline/stale issues:_ tracker disabled for ${ISSUE_REPO} (⚠️ cannot check)"
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
    gh api "repos/${ISSUE_REPO}/issues?state=open&labels=${encoded_label}" \
        --jq '[.[] | select(.pull_request == null) | {number, title, labels: [.labels[].name], url: .html_url}]' \
        > "$tmp" 2>/dev/null
    api_rc=$?
    if [ $api_rc -ne 0 ]; then
        echo "Error: gh api failed for label='$label_trim' (rc=$api_rc) on repo ${ISSUE_REPO}" >&2
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
    # Нет критичных/застрявших issues — markdown-таблица не нужна
    echo "_FMT critical/deadline/stale issues:_ 0 (✅ clean)"
    exit 0
fi

# Markdown-таблица для DayPlan / WeekClose отчёта
echo "## ⚠️ FMT issues требуют внимания ($COUNT)"
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
    TG_MSG="🔴 FMT issues требуют внимания ($COUNT):"$'\n'
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
