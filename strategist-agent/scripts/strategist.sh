#!/bin/bash
# Strategist Agent Runner
# Запускает Claude Code с заданным сценарием

set -e

# Конфигурация
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
WORKSPACE="$HOME/Github/my-strategy"
PROMPTS_DIR="$REPO_DIR/prompts"
LOG_DIR="$HOME/logs/strategist"
CLAUDE_PATH="{{CLAUDE_PATH}}"

# Создаём папку для логов
mkdir -p "$LOG_DIR"

# Определяем день недели и тип сценария
DAY_OF_WEEK=$(date +%u)  # 1=Mon, 7=Sun
DATE=$(date +%Y-%m-%d)

# Лог файл
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

run_claude() {
    local command_file="$1"
    local command_path="$PROMPTS_DIR/$command_file.md"

    if [ ! -f "$command_path" ]; then
        log "ERROR: Command file not found: $command_path"
        exit 1
    fi

    # Читаем содержимое команды
    local prompt
    prompt=$(cat "$command_path")

    log "Starting scenario: $command_file"
    log "Command file: $command_path"

    cd "$WORKSPACE"

    # Запуск Claude Code с содержимым команды как промпт
    "$CLAUDE_PATH" --dangerously-skip-permissions \
        --allowedTools "Read,Write,Edit,Glob,Grep,Bash" \
        -p "$prompt" \
        >> "$LOG_FILE" 2>&1

    log "Completed scenario: $command_file"

    # macOS notification
    local summary
    summary=$(tail -5 "$LOG_FILE" | grep -v '^\[' | head -3)
    notify "Strategist: $command_file" "$summary"
}

# Проверка: уже запускался ли сценарий сегодня
already_ran_today() {
    local scenario="$1"
    [ -f "$LOG_FILE" ] && grep -q "Completed scenario: $scenario" "$LOG_FILE"
}

# Определяем какой сценарий запускать
case "$1" in
    "morning")
        if [ "$DAY_OF_WEEK" -eq 1 ]; then
            SCENARIO="strategy"
        else
            SCENARIO="day-plan"
        fi

        if already_ran_today "$SCENARIO"; then
            log "SKIP: $SCENARIO already completed today"
            exit 0
        fi

        if [ "$DAY_OF_WEEK" -eq 1 ]; then
            log "Monday morning: running strategy session"
            run_claude "strategy"
        else
            log "Morning: running day plan"
            run_claude "day-plan"
        fi
        ;;
    "evening")
        log "Evening: running evening review"
        run_claude "evening"
        ;;
    "week-review")
        log "Sunday: running week review"
        run_claude "week-review"
        ;;
    "strategy")
        log "Manual: running strategy session"
        run_claude "strategy"
        ;;
    "day-plan")
        log "Manual: running day plan"
        run_claude "day-plan"
        ;;
    "day-close")
        log "Manual: running day close"
        run_claude "day-close"
        ;;
    *)
        echo "Usage: $0 {morning|evening|week-review|strategy|day-plan|day-close}"
        echo ""
        echo "Scenarios:"
        echo "  morning     - {{TIMEZONE_DESC}} daily (strategy on Mon, day-plan others)"
        echo "  evening     - End of day review"
        echo "  week-review - Sunday night review"
        echo "  strategy    - Manual strategy session"
        echo "  day-plan    - Manual day plan"
        echo "  day-close   - Manual day close"
        exit 1
        ;;
esac

log "Done"
