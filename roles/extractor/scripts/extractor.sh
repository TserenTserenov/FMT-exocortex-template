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
# WP-273 R5 fix (Round 5 Евгения): substituted runner живёт в .iwe-runtime/,
# но prompts/ — read-only, должны браться из FMT через $IWE_TEMPLATE.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
WORKSPACE="{{WORKSPACE_DIR}}"

# PROMPTS_DIR резолв: $IWE_TEMPLATE → standard FMT → relative (legacy)
if [ -n "${IWE_TEMPLATE:-}" ] && [ -d "$IWE_TEMPLATE/roles/extractor/prompts" ]; then
    PROMPTS_DIR="$IWE_TEMPLATE/roles/extractor/prompts"
elif [ -d "$WORKSPACE/FMT-exocortex-template/roles/extractor/prompts" ]; then
    PROMPTS_DIR="$WORKSPACE/FMT-exocortex-template/roles/extractor/prompts"
    echo "[$(date '+%H:%M:%S')] WARN: \$IWE_TEMPLATE не задана, fallback на $WORKSPACE/FMT-exocortex-template. source ~/.zshenv?" >&2
else
    PROMPTS_DIR="$REPO_DIR/prompts"
    echo "[$(date '+%H:%M:%S')] WARN: legacy PROMPTS_DIR fallback на $PROMPTS_DIR (pre-WP-273). Запустите migrate-to-runtime-target.sh." >&2
fi

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
    # macOS: osascript, Linux: notify-send, fallback: silent
    printf 'display notification "%s" with title "%s"' "$message" "$title" | osascript 2>/dev/null \
        || notify-send "$title" "$message" 2>/dev/null \
        || true
}

notify_telegram() {
    local scenario="$1"
    # WP-273 R5 fix: notify.sh — read-only из FMT (не substituted, нет плейсхолдеров).
    # Resolution order: $IWE_TEMPLATE → standard FMT path → runtime fallback (legacy).
    local notify_script
    if [ -n "${IWE_TEMPLATE:-}" ] && [ -f "$IWE_TEMPLATE/roles/synchronizer/scripts/notify.sh" ]; then
        notify_script="$IWE_TEMPLATE/roles/synchronizer/scripts/notify.sh"
    elif [ -f "$WORKSPACE/FMT-exocortex-template/roles/synchronizer/scripts/notify.sh" ]; then
        notify_script="$WORKSPACE/FMT-exocortex-template/roles/synchronizer/scripts/notify.sh"
    elif [ -n "${IWE_RUNTIME:-}" ] && [ -f "$IWE_RUNTIME/roles/synchronizer/scripts/notify.sh" ]; then
        notify_script="$IWE_RUNTIME/roles/synchronizer/scripts/notify.sh"
    else
        notify_script="$WORKSPACE/.iwe-runtime/roles/synchronizer/scripts/notify.sh"
    fi
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

    # WP-273 0.29.6 R6.1** escape: build-runtime НЕ должен подменять плейсхолдеры
    # в sed-выражениях этого runner'а (иначе runner после build ищет values вместо
    # placeholders в промптах). Собираем двойно-фигурные токены через bash-конкатенацию.
    local prompt
    local _gov_repo="${IWE_GOVERNANCE_REPO:-DS-strategy}"
    local _ws="${IWE_WORKSPACE:-$HOME/IWE}"
    local _gh_user="${GITHUB_USER:-your-username}"
    local _o='{''{' _c='}''}'
    prompt=$(sed \
        -e "s|${_o}GOVERNANCE_REPO${_c}|$_gov_repo|g" \
        -e "s|${_o}WORKSPACE_DIR${_c}|$_ws|g" \
        -e "s|${_o}GITHUB_USER${_c}|$_gh_user|g" \
        "$command_path")

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
    local strategy_dir="$WORKSPACE/{{GOVERNANCE_REPO}}"

    if [ -d "$strategy_dir/.git" ]; then
        # Очистить staging area
        git -C "$strategy_dir" reset --quiet 2>/dev/null || true

        # Стейджим ТОЛЬКО наши файлы
        git -C "$strategy_dir" add inbox/captures.md inbox/extraction-reports/ >> "$LOG_FILE" 2>&1 || true
        if ! git -C "$strategy_dir" diff --cached --quiet 2>/dev/null; then
            git -C "$strategy_dir" commit -m "inbox-check: extraction report $DATE" >> "$LOG_FILE" 2>&1 \
                && log "Committed $_gov_repo" \
                || log "WARN: git commit failed"
        else
            log "No new changes to commit in $_gov_repo"
        fi

        if ! git -C "$strategy_dir" diff --quiet origin/main..HEAD 2>/dev/null; then
            git -C "$strategy_dir" push >> "$LOG_FILE" 2>&1 && log "Pushed $_gov_repo" || log "WARN: git push failed"
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
        CAPTURES_FILE="$WORKSPACE/{{GOVERNANCE_REPO}}/inbox/captures.md"
        if [ -f "$CAPTURES_FILE" ]; then
            # Маркеры имеют вид `[analyzed 2026-MM-DD]`, `[processed 2026-MM-DD]`, `[duplicate]`, `[defer]` —
            # используем `\b` (word boundary), а не `\]`, чтобы ловить датированные маркеры.
            # Старый подход (PENDING - PROCESSED - ANALYZED с `grep -c '\[analyzed'`) ловил подстроки
            # в описаниях/цитатах → получался мультисчёт и ложные «N pending» срабатывания.
            ACTUAL_PENDING=$(grep -E '^### ' "$CAPTURES_FILE" 2>/dev/null | grep -vE '\[(analyzed|processed|duplicate|defer)\b' | wc -l | tr -d ' ')
            ACTUAL_PENDING=${ACTUAL_PENDING:-0}

            if [ "$ACTUAL_PENDING" -le 0 ]; then
                log "SKIP: No pending captures in inbox"
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
