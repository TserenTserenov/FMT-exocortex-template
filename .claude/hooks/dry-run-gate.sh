#!/bin/bash
# Dry-run Gate Hook (PreToolUse)
# Контракт: memory/dry-run-contract.md
# WP-265 Ф5.2 (ArchGate v3 — вариант F3 sentinel-only).
#
# Назначение: блокировать write-tools при наличии валидного sentinel-файла.
# Sentinel: /tmp/iwe-dry-run-${CLAUDE_SESSION_ID:-noid}.flag
# TTL: 600 секунд (10 минут) от mtime.
#
# Принципы:
# - fail-CLOSED при отсутствии jq (контракт §Fail-safe)
# - exit 0 = allow (sentinel отсутствует / TTL истёк)
# - exit 2 = block (с диагностикой в stderr)

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# Fail-CLOSED: jq обязателен
if ! command -v jq >/dev/null 2>&1; then
    echo "[dry-run-gate] FAIL-CLOSED: jq missing, blocking by default" >&2
    exit 2
fi

# SESSION_ID — от Claude Code или fallback
SID="${CLAUDE_SESSION_ID:-noid}"
SENTINEL="/tmp/iwe-dry-run-${SID}.flag"

# Если sentinel не существует — dry-run неактивен, allow всё
[ ! -f "$SENTINEL" ] && exit 0

# TTL: проверить mtime, удалить и allow если старше 600s
NOW=$(date +%s)
case "$(uname)" in
    Darwin) MTIME=$(stat -f %m "$SENTINEL" 2>/dev/null) ;;
    *)      MTIME=$(stat -c %Y "$SENTINEL" 2>/dev/null) ;;
esac
if [ -n "$MTIME" ]; then
    AGE=$((NOW - MTIME))
    if [ "$AGE" -gt 600 ]; then
        rm -f "$SENTINEL" 2>/dev/null
        exit 0
    fi
fi

# Прочитать tool_name и tool_input из stdin
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')
[ -z "$TOOL_NAME" ] && exit 0

# Метаданные sentinel (для диагностики)
SENTINEL_META=$(cat "$SENTINEL" 2>/dev/null || echo '{}')
SENTINEL_INITIATOR=$(echo "$SENTINEL_META" | jq -r '.initiator // "unknown"' 2>/dev/null || echo "unknown")
SENTINEL_CREATED=$(echo "$SENTINEL_META" | jq -r '.created_at // "unknown"' 2>/dev/null || echo "unknown")

block() {
    local target="$1"
    {
        echo "[dry-run-gate] BLOCKED: $TOOL_NAME on $target"
        echo "Reason: dry-run mode active (sentinel created at $SENTINEL_CREATED, by $SENTINEL_INITIATOR)"
        echo "Expected: tool blocked by contract, this is rehearsal failure point"
    } >&2
    exit 2
}

# === Прямые write-tools: Write, Edit, MultiEdit, NotebookEdit ===
case "$TOOL_NAME" in
    Write|Edit|MultiEdit|NotebookEdit)
        FP=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""')
        block "${FP:-<no path>}"
        ;;
esac

# === MCP-write whitelist (точные совпадения tool_name) ===
case "$TOOL_NAME" in
    mcp__claude_ai_IWE__personal_write|\
    mcp__claude_ai_IWE__personal_delete|\
    mcp__claude_ai_IWE__personal_create_pack|\
    mcp__claude_ai_IWE__personal_propose_capture|\
    mcp__claude_ai_IWE__personal_reindex_source|\
    mcp__claude_ai_IWE__personal_scaffold_notes|\
    mcp__claude_ai_IWE__dt_write_digital_twin|\
    mcp__claude_ai_IWE__create_repository|\
    mcp__claude_ai_IWE__github_connect|\
    mcp__claude_ai_IWE__github_disconnect|\
    mcp__claude_ai_IWE__knowledge_feedback|\
    mcp__claude_ai_Gmail__create_draft|\
    mcp__claude_ai_Gmail__create_label|\
    mcp__claude_ai_Gmail__label_message|\
    mcp__claude_ai_Gmail__label_thread|\
    mcp__claude_ai_Gmail__unlabel_message|\
    mcp__claude_ai_Gmail__unlabel_thread|\
    mcp__claude_ai_Google_Calendar__create_event|\
    mcp__claude_ai_Google_Calendar__delete_event|\
    mcp__claude_ai_Google_Calendar__update_event|\
    mcp__claude_ai_Google_Calendar__respond_to_event|\
    mcp__claude_ai_Google_Drive__create_file|\
    mcp__ext-google-calendar__create-event|\
    mcp__ext-google-calendar__create-events|\
    mcp__ext-google-calendar__delete-event|\
    mcp__ext-google-calendar__update-event|\
    mcp__ext-google-calendar__respond-to-event|\
    mcp__ext-google-drive__copy_file|\
    mcp__ext-google-drive__create_file|\
    mcp__ext-google-drive__create_folder|\
    mcp__ext-google-drive__delete_file|\
    mcp__ext-google-drive__move_file|\
    mcp__ext-google-drive__update_file|\
    mcp__ext-google-drive__share_file|\
    mcp__ext-linear__create_issue|\
    mcp__ext-linear__update_issue|\
    mcp__ext-railway__create-environment|\
    mcp__ext-railway__create-project-and-link|\
    mcp__ext-railway__deploy|\
    mcp__ext-railway__deploy-template|\
    mcp__ext-railway__generate-domain|\
    mcp__ext-railway__link-environment|\
    mcp__ext-railway__link-service|\
    mcp__ext-railway__set-variables)
        block "$TOOL_NAME"
        ;;
esac

# === Bash matchers ===
if [ "$TOOL_NAME" = "Bash" ]; then
    CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
    [ -z "$CMD" ] && exit 0

    # Удалить «> /dev/null» из команды для проверки опасных redirect'ов
    CHECK=$(echo "$CMD" | sed -E 's@>[[:space:]]*/dev/null@@g; s@2>&1@@g')

    # Опасные паттерны
    if echo "$CHECK" | grep -qE '(^|[[:space:]&;|])git[[:space:]]+(commit|push|pull|reset|merge|rebase|checkout[[:space:]]+-)([[:space:]]|$)'; then
        block "$CMD"
    fi
    if echo "$CHECK" | grep -qE '[[:space:]]>[[:space:]]'; then
        block "$CMD (redirect to file)"
    fi
    if echo "$CHECK" | grep -qE '[[:space:]]>>[[:space:]]'; then
        block "$CMD (append to file)"
    fi
    if echo "$CHECK" | grep -qiE 'psql.*-c.*("|'\'')[^"'\'']*\\b(INSERT|UPDATE|DELETE|TRUNCATE|DROP|ALTER)\\b'; then
        block "$CMD (SQL write)"
    fi
    if echo "$CHECK" | grep -qE 'curl[[:space:]]+(-X[[:space:]]*)?(POST|PUT|DELETE|PATCH)|curl[[:space:]]+.*(--data|-d[[:space:]])'; then
        block "$CMD (HTTP write)"
    fi
    if echo "$CHECK" | grep -qE '(^|[[:space:]&;|])(rm|mv)([[:space:]]+-[a-zA-Z]+)?[[:space:]]+[^[:space:]]'; then
        block "$CMD (filesystem mutation)"
    fi
    if echo "$CHECK" | grep -qE '(^|[[:space:]&;|])tee([[:space:]]+-[a-zA-Z]+)?[[:space:]]+[^[:space:]]'; then
        block "$CMD (tee write)"
    fi
    if echo "$CHECK" | grep -qE '(^|[[:space:]&;|])sed[[:space:]]+(-[a-zA-Z]*i)([[:space:]]|$)'; then
        block "$CMD (sed in-place)"
    fi
fi

# Read-only: allow
exit 0
