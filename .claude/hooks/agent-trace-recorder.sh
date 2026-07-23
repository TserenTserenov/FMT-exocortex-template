#!/bin/bash
# WP-295 Ф1 шаг 5: agent-trace-recorder hook.
# Перехватывает PostToolUse и Stop события Claude Code, эмитит agent.trace.* events
# в локальный NDJSON. Async upload в event-gateway через agent-trace-uploader.sh.
#
# see DP.SC.037 (agent-trace), DP.ROLE.047 (Trace Recorder).
#
# Регистрация в settings.json:
#   "PostToolUse": [{ hooks: [{ command: ".../agent-trace-recorder.sh" }] }]
#   "Stop": [{ hooks: [{ command: ".../agent-trace-recorder.sh" }] }]
#
# Интеграции (см. WP-295 § Интеграции):
#   - $CLAUDE_TASK_ID — task_id от iwe-agent-dispatcher.py (WP-324), пишется в context_summary
#   - $CLAUDE_AGENT_ID — модель агента (default: claude-opus-4-7)
#   - git status при Stop → produced_artifact_ids
#
# Никогда не блокирует (exit 0 при любой ошибке).

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

LOG_DIR="${HOME}/.claude/logs/agent-trace"
STATE_DIR="${HOME}/.claude/state/agent-trace"
mkdir -p "$LOG_DIR" "$STATE_DIR" 2>/dev/null || exit 0

INPUT=$(cat 2>/dev/null || echo "{}")
HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)
CLAUDE_SESSION=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)

[ -z "$CLAUDE_SESSION" ] && exit 0  # без session_id ничего не пишем

# Маппинг Claude Code session_id → наш UUID v4 (для agent_trace.session.session_id PK).
STATE_FILE="${STATE_DIR}/${CLAUDE_SESSION}.uuid"
if [ -f "$STATE_FILE" ]; then
    SESSION_UUID=$(cat "$STATE_FILE")
else
    SESSION_UUID=$(uuidgen | tr '[:upper:]' '[:lower:]')
    echo "$SESSION_UUID" > "$STATE_FILE"

    # Эмитим session.start (lazy init на первом hook'е этой сессии).
    NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    AGENT_ID="${CLAUDE_AGENT_ID:-claude-opus-4-7}"
    TASK_ID="${CLAUDE_TASK_ID:-}"
    # Улучшенный WP detection — пробуем несколько источников (WP-295 fix)
    WP_ID=""
    # 1. Из CLAUDE_TASK_ID (может содержать WP-xxx)
    if [ -n "${CLAUDE_TASK_ID:-}" ]; then
        WP_ID=$(echo "$CLAUDE_TASK_ID" | grep -oE "WP-[0-9]+" | head -1 || echo "")
    fi
    # 2. Из текущей директории
    if [ -z "$WP_ID" ] && [ -n "$CWD" ]; then
        WP_ID=$(echo "$CWD" | grep -oE "WP-[0-9]+" | head -1 || echo "")
    fi
    # 3. Из git branch (если CWD — git repo)
    if [ -z "$WP_ID" ] && [ -n "$CWD" ] && [ -d "$CWD/.git" ]; then
        BRANCH=$(cd "$CWD" && git branch --show-current 2>/dev/null || echo "")
        WP_ID=$(echo "$BRANCH" | grep -oE "WP-[0-9]+" | head -1 || echo "")
    fi
    # 4. Из последних коммитов (heuristic: часто коммит начинается с WP-xxx)
    if [ -z "$WP_ID" ] && [ -n "$CWD" ] && [ -d "$CWD/.git" ]; then
        RECENT_COMMIT=$(cd "$CWD" && git log -1 --pretty=%s 2>/dev/null || echo "")
        WP_ID=$(echo "$RECENT_COMMIT" | grep -oE "WP-[0-9]+" | head -1 || echo "")
    fi
    CTX_SUMMARY=""
    [ -n "$TASK_ID" ] && CTX_SUMMARY="task:${TASK_ID}"

    NDJSON="${LOG_DIR}/${SESSION_UUID}.ndjson"
    jq -nc \
        --arg sid "$SESSION_UUID" --arg aid "$AGENT_ID" --arg ts "$NOW" \
        --arg ctx "$CTX_SUMMARY" --arg wp "$WP_ID" \
        '{event_type: "agent_session_start", schema_version: "v1", emitted_at: $ts, payload: {
            session_id: $sid,
            agent_id: $aid,
            started_at: $ts,
            context_summary: (if $ctx != "" then $ctx else null end),
            wp_id: (if $wp != "" then $wp else null end)
        }}' >> "$NDJSON" 2>/dev/null || true
fi

NDJSON="${LOG_DIR}/${SESSION_UUID}.ndjson"

# Hook-event-specific логика.
case "$HOOK_EVENT" in
    PostToolUse)
        # Эмитим tool_call для значимых tools (Bash/WebFetch/WebSearch).
        # Edit/Write/Read — слишком много шума, не пишем (artifact-emission, не reasoning).
        case "$TOOL_NAME" in
            Bash|WebFetch|WebSearch|mcp__*)
                NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
                TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // {}' 2>/dev/null || echo "{}")
                TOOL_RESPONSE=$(echo "$INPUT" | jq -c '.tool_response // {}' 2>/dev/null || echo "{}")

                # Sanitize tool_response: ensure valid JSON and cap size to avoid malformed NDJSON.
                if ! echo "$TOOL_RESPONSE" | jq -e . >/dev/null 2>&1; then
                    TOOL_RESPONSE='{"truncated":true,"reason":"invalid_json"}'
                fi
                # PostgreSQL JSON rejects NULL byte \u0000; strip it from tool_response.
                TOOL_RESPONSE=$(echo "$TOOL_RESPONSE" | jq -c 'walk(if type == "string" then gsub("\u0000"; "") else . end)' 2>/dev/null || echo "$TOOL_RESPONSE")
                raw_response_size=$(echo -n "$TOOL_RESPONSE" | wc -c | tr -d ' ')
                if [ "$raw_response_size" -gt 8192 ]; then
                    TOOL_RESPONSE=$(echo "$TOOL_RESPONSE" | jq -c --argjson size "$raw_response_size" \
                        '{truncated: true, original_size_bytes: $size, preview: (. | tostring | .[0:1024])}' \
                        2>/dev/null || echo '{"truncated":true,"reason":"cap_failed"}')
                fi

                # input_hash = sha256(canonicalized tool_input)
                # GNU-first (sha256sum, coreutils — every Linux, absent on macOS by default),
                # shasum -a 256 fallback (macOS default) — WP-5 Ubuntu-audit факт #4: bare
                # shasum with no fallback silently broke on Ubuntu installs without it.
                if command -v sha256sum >/dev/null 2>&1; then
                    INPUT_HASH="sha256:$(echo -n "$TOOL_INPUT" | sha256sum | cut -d' ' -f1)"
                else
                    INPUT_HASH="sha256:$(echo -n "$TOOL_INPUT" | shasum -a 256 | cut -d' ' -f1)"
                fi
                # response_size_bytes = TRUE pre-cap size (capped object would report ~80 bytes).
                RESPONSE_SIZE="$raw_response_size"

                jq -nc \
                    --arg sid "$SESSION_UUID" --arg tn "$TOOL_NAME" --arg ih "$INPUT_HASH" \
                    --argjson tin "$TOOL_INPUT" --argjson tres "$TOOL_RESPONSE" \
                    --argjson rsz "$RESPONSE_SIZE" --arg ts "$NOW" \
                    '{event_type: "agent_tool_called", schema_version: "v1", emitted_at: $ts, payload: {
                        session_id: $sid,
                        decision_id: null,
                        tool_name: $tn,
                        input_hash: $ih,
                        input_payload: $tin,
                        response: $tres,
                        response_size_bytes: $rsz,
                        called_at: $ts
                    }}' >> "$NDJSON" 2>/dev/null || true
                ;;
        esac
        ;;
    Stop)
        # Session end + produced_artifact_ids из git diff (commits с момента session.start).
        NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

        # Соберём produced_artifact_ids: последние коммиты + изменённые файлы.
        ARTIFACTS="[]"
        if command -v git >/dev/null 2>&1 && [ -n "$CWD" ] && [ -d "$CWD/.git" ]; then
            # Коммиты этой сессии (heuristic: за последний час).
            COMMITS=$(cd "$CWD" && git log --since="1 hour ago" --pretty=tformat:"git:commit:%h" 2>/dev/null | head -5 || true)
            ARTIFACTS=$(echo "$COMMITS" | jq -R -s -c 'split("\n") | map(select(length > 0))' 2>/dev/null || echo "[]")
        fi

        jq -nc \
            --arg sid "$SESSION_UUID" --arg ts "$NOW" --argjson art "$ARTIFACTS" \
            '{event_type: "agent_session_end", schema_version: "v1", emitted_at: $ts, payload: {
                session_id: $sid,
                ended_at: $ts,
                closed_status: "completed",
                produced_artifact_ids: $art
            }}' >> "$NDJSON" 2>/dev/null || true

        # Очистка state-файла, чтобы новая сессия с тем же CLAUDE_SESSION (теоретически) получила новый UUID.
        rm -f "$STATE_FILE" 2>/dev/null || true
        ;;
esac

exit 0
