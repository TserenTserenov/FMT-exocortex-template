#!/bin/bash
# Dry-run Gate Hook (PreToolUse)
# Контракт: memory/dry-run-contract.md
# WP-265 Ф5.2 (ArchGate v3 — вариант F3 sentinel-only). v2: WP-7/BUGTRIAGE2 (issue #237).
#
# Назначение: блокировать write-tools при наличии валидного sentinel-файла.
# Sentinel: единый файл /tmp/iwe-dry-run.flag (не session-bound).
# Причина единого имени: CLAUDE_SESSION_ID не пробрасывается в окружение
# субагентов, поэтому session-bound имя было ненадёжно в самом частом пути
# smoke-теста — sentinel создавал главный агент, subagent Stop-хук снимал
# по своему (пустому) SID, чужой sentinel оставался и залипал на весь TTL.
# Единый файл убирает рассинхрон создания/очистки одним ходом (issue #237 п.2).
# TTL: 600 секунд (10 минут) от mtime.
#
# Принципы:
# - jq отсутствует → skip с явной диагностикой (setup должен ставить jq; см. issue #192)
# - exit 0 = allow (sentinel отсутствует / TTL истёк / gate skipped из-за missing jq)
# - exit 2 = block (с диагностикой в stderr)

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

SENTINEL=/tmp/iwe-dry-run.flag

# jq нужен для разбора payload. Если его нет, не брикуем все write-tools:
# setup/requirements должны установить jq, а gate явно сообщает, что проверка пропущена.
if ! command -v jq >/dev/null 2>&1; then
    echo "[dry-run-gate] SKIPPED: jq missing; install jq to enable dry-run protection" >&2
    exit 0
fi

# Sentinel отсутствует — dry-run неактивен, allow всё
[ -f "$SENTINEL" ] || exit 0

case "$(uname)" in
    Darwin) MTIME=$(stat -f %m "$SENTINEL" 2>/dev/null) ;;
    *)      MTIME=$(stat -c %Y "$SENTINEL" 2>/dev/null) ;;
esac

if [ -z "$MTIME" ]; then
    # Файл исчез между test и stat (race с параллельной очисткой) — allow.
    exit 0
fi

NOW=$(date +%s)
if [ $((NOW - MTIME)) -gt 600 ]; then
    rm -f "$SENTINEL" 2>/dev/null
    exit 0
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

# === MCP-write: IWE Gateway tools (namespace-agnostic action match) ===
# Префикс MCP-инструмента дрейфует между способами подключения к одному Gateway
# (server "iwe-knowledge", mcp.aisystant.com/mcp):
#   mcp__claude_ai_IWE__<action>            — legacy connector с именем "IWE"
#   mcp__iwe_knowledge_<action>             — OMP runtime (одинарный разделитель "_")
#   mcp__iwe-knowledge__<action>            — project .mcp.json (server id "iwe-knowledge")
#   mcp__claude_ai_https_..._mcp__<action>  — connector с именем из URL
# Exact-list по префиксу устаревает при каждой миграции namespace и пропускает
# write-инструменты (bug: gate не блокировал mcp__iwe-knowledge__personal_write и др.).
# Решение: сверять ДЕЙСТВИЕ (суффикс после последнего разделителя), а не полное имя.
# Паттерн "*_<action>" ловит и "__<action>" (двойной разделитель), и "_<action>" (OMP).
if [[ "$TOOL_NAME" == mcp__* ]]; then
    for action in \
        personal_write personal_delete personal_create_pack personal_propose_capture \
        personal_reindex_source personal_scaffold_notes personal_connect_source \
        personal_disconnect_source personal_purge_source personal_generate_fault_remind \
        dt_write_digital_twin create_repository github_connect github_disconnect \
        knowledge_feedback knowledge_reindex_source send_telegram_message \
        run_strategist run_extractor capture_trace grant_consent \
        agent_status_update request_equipment_upgrade; do
        if [[ "$TOOL_NAME" == *"_${action}" ]]; then
            block "$TOOL_NAME (action: $action)"
        fi
    done
fi

# === MCP-write: vendor tools (exact tool_name — префиксы вендоров стабильны) ===
case "$TOOL_NAME" in
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
#
# v2 (issue #237): вместо grep по всей строке команды — три прохода:
#  1) вырезать кавычные спаны (текст внутри '...'/"..." не может изображать
#     команду — раньше `echo "see: git commit"` ложно матчился, issue #237 п.4);
#  2) разбить нормализованную строку на простые команды по разделителям
#     ; & | && || ( ) { } $( ` — раньше `(git commit -am x)` в скобках
#     проходил незамеченным, issue #237 п.1;
#  3) классифицировать каждый фрагмент по первому слову (после пропуска
#     VAR=val/command/env/nohup/time/sudo), а не искать подстроку где попало.
#
# Единственное исключение из шага 1 — psql: SQL живёт внутри кавычек, поэтому
# SQL-write матчится по НЕнормализованной команде, но только когда первое
# слово фрагмента — psql (иначе `grep "psql -c INSERT" file` снова ложно бьёт).
if [ "$TOOL_NAME" = "Bash" ]; then
    CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
    [ -z "$CMD" ] && exit 0

    # Шаг 1: убрать кавычные спаны и безвредные redirect-в-null.
    NORM=$(printf '%s' "$CMD" | sed -E \
        -e "s/'[^']*'/ QSTR /g" \
        -e 's/"[^"]*"/ QSTR /g' \
        -e 's@[0-9]?>[[:space:]]*/dev/null@ @g' \
        -e 's@2>&1@ @g')

    # Редирект в реальный файл — проверяем по нормализованной строке целиком
    # (позиционно-независим относительно сегментации ниже, как и раньше).
    if echo "$NORM" | grep -qE '[[:space:]]>>?[[:space:]]'; then
        block "$CMD (redirect to file)"
    fi

    # Шаг 2: разбить на простые команды.
    SPLIT=$(printf '%s\n' "$NORM" | sed -E 's/\$\(|`|[(){}&;]|\|\|?|&&/\n/g')

    while IFS= read -r SEG; do
        [ -z "$SEG" ] && continue
        # shellcheck disable=SC2086
        set -- $SEG
        # Пропустить VAR=val / command / env / nohup / time / sudo — переход к реальной команде.
        while [ $# -gt 0 ]; do
            case "$1" in
                *=*) shift ;;
                command|env|nohup|time|sudo) shift ;;
                *) break ;;
            esac
        done
        [ $# -eq 0 ] && continue
        W0=$1

        case "$W0" in
            git)
                shift
                # Пропустить global opts: -C dir, --git-dir=X, --work-tree=X, -c key=val
                while [ $# -gt 0 ]; do
                    case "$1" in
                        -C|--git-dir|--work-tree) shift 2 ;;
                        --git-dir=*|--work-tree=*) shift ;;
                        -c) shift 2 ;;
                        -c*) shift ;;
                        *) break ;;
                    esac
                done
                case "${1:-}" in
                    add|commit|push|pull|reset|merge|rebase|mv|rm) block "$CMD (git write)" ;;
                    checkout) case "${2:-}" in -*) block "$CMD (git checkout -)" ;; esac ;;
                esac
                ;;
            rm|mv)
                shift
                ARGS=""
                for a in "$@"; do
                    case "$a" in
                        -*) ;;
                        *) ARGS="$ARGS $a" ;;
                    esac
                done
                # Cleanup-исключение: собственный dry-run sentinel — единственный allow.
                [ "$ARGS" = " $SENTINEL" ] && continue
                block "$CMD (filesystem mutation)"
                ;;
            tee)
                case "${2:-}" in
                    /dev/null) ;;
                    *) block "$CMD (tee write)" ;;
                esac
                ;;
            sed)
                echo "$SEG" | grep -qE '(^|[[:space:]])-[a-zA-Z]*i' && block "$CMD (sed in-place)"
                ;;
            curl)
                echo "$SEG" | grep -qE '(-X[[:space:]]*)?(POST|PUT|DELETE|PATCH)|--data|(^|[[:space:]])-d([[:space:]]|$)' \
                    && block "$CMD (HTTP write)"
                ;;
            psql)
                # SQL живёт в кавычках исходной команды — проверяем оригинал $CMD,
                # но только т.к. первое слово фрагмента уже подтверждено как psql.
                echo "$CMD" | grep -qiE '(INSERT|UPDATE|DELETE|TRUNCATE|DROP|ALTER)[[:space:]]' \
                    && block "$CMD (SQL write)"
                ;;
            bash|sh|zsh|eval|source|.|xargs)
                block "$CMD (indirect execution under dry-run)"
                ;;
        esac
    done <<< "$SPLIT"
fi

# Read-only: allow
exit 0
