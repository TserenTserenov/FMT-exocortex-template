#!/bin/bash
# Strategist (Стратег) Agent Runner
# Запускает Claude Code с заданным сценарием

set -e

# Конфигурация
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
WORKSPACE="$HOME/Github/DS-strategy"
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

notify_telegram() {
    local scenario="$1"
    "$HOME/Github/DS-synchronizer/scripts/notify.sh" strategist "$scenario" >> "$LOG_FILE" 2>&1 || true
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

    # Push changes to GitHub (чтобы бот мог читать через API)
    if git -C "$WORKSPACE" diff --quiet origin/main..HEAD 2>/dev/null; then
        log "No unpushed commits"
    else
        git -C "$WORKSPACE" push >> "$LOG_FILE" 2>&1 && log "Pushed to GitHub" || log "WARN: git push failed"
    fi

    # macOS notification
    local summary
    summary=$(tail -5 "$LOG_FILE" | grep -v '^\[' | head -3)
    notify "Стратег: $command_file" "$summary"
}

# Проверка: уже запускался ли сценарий сегодня
already_ran_today() {
    local scenario="$1"
    [ -f "$LOG_FILE" ] && grep -q "Completed scenario: $scenario" "$LOG_FILE"
}

# Определяем какой сценарий запускать
case "$1" in
    "morning")
        # Определяем нужный сценарий
        if [ "$DAY_OF_WEEK" -eq 1 ]; then
            SCENARIO="session-prep"
        else
            SCENARIO="day-plan"
        fi

        # Защита от повторного запуска (RunAtLoad + CalendarInterval)
        if already_ran_today "$SCENARIO"; then
            log "SKIP: $SCENARIO already completed today"
            exit 0
        fi

        if [ "$DAY_OF_WEEK" -eq 1 ]; then
            log "Monday morning: running session prep"
            run_claude "session-prep"
            notify_telegram "session-prep"
        else
            log "Morning: running day plan"
            run_claude "day-plan"
            notify_telegram "day-plan"
        fi
        ;;
    "evening")
        log "Evening: running evening review"
        run_claude "evening"
        notify_telegram "evening"
        ;;
    "week-review")
        log "Sunday: running week review"
        run_claude "week-review"
        notify_telegram "week-review"
        ;;
    "session-prep")
        log "Manual: running session prep"
        run_claude "session-prep"
        notify_telegram "session-prep"
        ;;
    "day-plan")
        log "Manual: running day plan"
        run_claude "day-plan"
        notify_telegram "day-plan"
        ;;
    "note-review")
        log "Evening: running note review"
        run_claude "note-review"
        notify_telegram "note-review"
        ;;
    "day-close")
        log "Manual: running day close"
        run_claude "day-close"
        notify_telegram "day-close"
        ;;
    "strategy-session")
        log "Manual: running strategy session (interactive)"
        run_claude "strategy-session"
        ;;
    *)
        echo "Usage: $0 {morning|note-review|week-review|session-prep|strategy-session|day-plan|day-close}"
        echo ""
        echo "Scenarios:"
        echo "  morning           - 4:00 EET daily (session-prep on Mon, day-plan others)"
        echo "  note-review       - 23:00 EET daily (review fleeting notes + clean inbox)"
        echo "  week-review       - Sunday 19:00 EET review for club"
        echo "  session-prep      - Manual session prep (headless preparation)"
        echo "  strategy-session  - Manual strategy session (interactive with user)"
        echo "  day-plan          - Manual day plan"
        echo "  day-close         - Manual day close (update WeekPlan + MEMORY + backup)"
        exit 1
        ;;
esac

log "Done"
