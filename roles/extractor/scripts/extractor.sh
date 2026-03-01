#!/bin/bash
# Knowledge Extractor Agent Runner
# Запускает Claude Code с заданным процессом KE
#
# Использование:
#   extractor.sh inbox-check     # headless: обработка inbox (launchd)
#   extractor.sh audit           # headless: аудит Pack'ов
#   extractor.sh session-close   # convenience wrapper
#   extractor.sh on-demand       # convenience wrapper

set -e

# Конфигурация
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
WORKSPACE="{{WORKSPACE_DIR}}"
PROMPTS_DIR="$REPO_DIR/prompts"
LOG_DIR="{{HOME_DIR}}/logs/extractor"
CLAUDE_PATH="{{CLAUDE_PATH}}"
ENV_FILE="{{HOME_DIR}}/.config/aist/env"

# AI CLI: переопределение через переменные окружения (см. strategist.sh)
AI_CLI="${AI_CLI:-$CLAUDE_PATH}"
AI_CLI_PROMPT_FLAG="${AI_CLI_PROMPT_FLAG:--p}"
AI_CLI_EXTRA_FLAGS="${AI_CLI_EXTRA_FLAGS:---dangerously-skip-permissions --allowedTools Read,Write,Edit,Glob,Grep,Bash}"

# Создаём папку для логов
mkdir -p "$LOG_DIR"

DATE=$(date +%Y-%m-%d)
HOUR=$(date +%H)
LOG_FILE="$LOG_DIR/$DATE.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

notify() {
    local title="$1"
    local message="$2"
    printf 'display notification "%s" with title "%s"' "$message" "$title" | osascript 2>/dev/null || true
}

notify_telegram() {
    local scenario="$1"
    local notify_script="$WORKSPACE/FMT-exocortex-template/roles/synchronizer/scripts/notify.sh"
    if [ -f "$notify_script" ]; then
        "$notify_script" extractor "$scenario" >> "$LOG_FILE" 2>&1 || true
    fi
}

# Загрузка переменных окружения
load_env() {
    if [ -f "$ENV_FILE" ]; then
        set -a
        source "$ENV_FILE"
        set +a
    fi
}

run_claude() {
    local command_file="$1"
    local extra_args="$2"
    local command_path="$PROMPTS_DIR/$command_file.md"

    if [ ! -f "$command_path" ]; then
        log "ERROR: Command file not found: $command_path"
        exit 1
    fi

    local prompt
    prompt=$(cat "$command_path")

    # Добавить extra args к промпту
    if [ -n "$extra_args" ]; then
        prompt="$prompt

## Дополнительный контекст

$extra_args"
    fi

    log "Starting process: $command_file"
    log "Command file: $command_path"

    cd "$WORKSPACE"

    # Запуск AI CLI с промптом
    "$AI_CLI" $AI_CLI_EXTRA_FLAGS \
        $AI_CLI_PROMPT_FLAG "$prompt" \
        >> "$LOG_FILE" 2>&1

    log "Completed process: $command_file"

    # Commit + push changes (отчёты, помеченные captures)
    local strategy_dir="$WORKSPACE/DS-strategy"

    if [ -d "$strategy_dir/.git" ]; then
        # Очистить staging area
        git -C "$strategy_dir" reset --quiet 2>/dev/null || true

        # Стейджим ТОЛЬКО наши файлы
        git -C "$strategy_dir" add inbox/captures.md inbox/extraction-reports/ >> "$LOG_FILE" 2>&1 || true
        if ! git -C "$strategy_dir" diff --cached --quiet 2>/dev/null; then
            git -C "$strategy_dir" commit -m "inbox-check: extraction report $DATE" >> "$LOG_FILE" 2>&1 \
                && log "Committed DS-strategy" \
                || log "WARN: git commit failed"
        else
            log "No new changes to commit in DS-strategy"
        fi

        if ! git -C "$strategy_dir" diff --quiet origin/main..HEAD 2>/dev/null; then
            git -C "$strategy_dir" push >> "$LOG_FILE" 2>&1 && log "Pushed DS-strategy" || log "WARN: git push failed"
        fi
    fi

    # macOS notification
    notify "KE: $command_file" "Процесс завершён"
}

# Проверка рабочих часов
is_work_hours() {
    local hour
    hour=$(date +%H)
    [ "$hour" -ge 7 ] && [ "$hour" -le 23 ]
}

# Загружаем env
load_env

# Определяем процесс
case "$1" in
    "inbox-check")
        if ! is_work_hours; then
            log "SKIP: inbox-check outside work hours ($HOUR:00)"
            exit 0
        fi

        # Быстрая проверка: есть ли captures в inbox
        CAPTURES_FILE="$WORKSPACE/DS-strategy/inbox/captures.md"
        if [ -f "$CAPTURES_FILE" ]; then
            PENDING=$(grep -c '^### ' "$CAPTURES_FILE" 2>/dev/null) || PENDING=0
            PROCESSED=$(grep -c '\[processed' "$CAPTURES_FILE" 2>/dev/null) || PROCESSED=0
            ACTUAL_PENDING=$((PENDING - PROCESSED))

            if [ "$ACTUAL_PENDING" -le 0 ]; then
                log "SKIP: No pending captures in inbox (total=$PENDING, processed=$PROCESSED)"
                exit 0
            fi

            log "Found $ACTUAL_PENDING pending captures in inbox"
        else
            log "SKIP: captures.md not found"
            exit 0
        fi

        run_claude "inbox-check"
        notify_telegram "inbox-check"
        ;;

    "audit")
        log "Running knowledge audit"
        run_claude "knowledge-audit"
        notify_telegram "audit"
        ;;

    "session-close")
        log "Running session-close extraction"
        run_claude "session-close"
        ;;

    "on-demand")
        log "Running on-demand extraction"
        run_claude "on-demand"
        ;;

    *)
        echo "Knowledge Extractor (R2)"
        echo ""
        echo "Usage: $0 <process>"
        echo ""
        echo "Processes:"
        echo "  inbox-check    Headless: обработка pending captures (launchd, 3h)"
        echo "  audit          Аудит Pack'ов"
        echo "  session-close  Экстракция при закрытии сессии"
        echo "  on-demand      Экстракция по запросу"
        exit 1
        ;;
esac

log "Done"
