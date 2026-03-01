#!/bin/bash
# scheduler.sh — центральный диспетчер агентов экзокортекса
#
# Вызывается launchd (com.exocortex.scheduler) в нужные моменты.
# Состояние: ~/.local/state/exocortex/ (маркеры запуска)
#
# Использование:
#   scheduler.sh dispatch    — проверить расписание и запустить что нужно
#   scheduler.sh status      — показать состояние всех агентов

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SYNC_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="$HOME/.local/state/exocortex"
LOG_DIR="$HOME/logs/synchronizer"
LOG_FILE="$LOG_DIR/scheduler-$(date +%Y-%m-%d).log"

ROLES_DIR="{{WORKSPACE_DIR}}/FMT-exocortex-template/roles"
NOTIFY_SH="$SCRIPT_DIR/notify.sh"

# Role runner discovery: reads runner path from role.yaml, fallback to convention
get_role_runner() {
    local role="$1"
    local yaml="$ROLES_DIR/$role/role.yaml"
    if [ -f "$yaml" ]; then
        local runner
        runner=$(grep '^runner:' "$yaml" | sed 's/runner: *//' | tr -d '"' | tr -d "'")
        [ -n "$runner" ] && echo "$ROLES_DIR/$role/$runner" && return
    fi
    # Fallback: convention-based path
    echo "$ROLES_DIR/$role/scripts/$role.sh"
}

STRATEGIST_SH="$(get_role_runner strategist)"
EXTRACTOR_SH="$(get_role_runner extractor)"

# Текущее время
HOUR=$(date +%H)
DOW=$(date +%u)   # 1=Mon, 7=Sun
DATE=$(date +%Y-%m-%d)
WEEK=$(date +%V)
NOW=$(date +%s)

mkdir -p "$STATE_DIR" "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scheduler] $1" | tee -a "$LOG_FILE"
}

# === Управление состоянием ===

ran_today() {
    [ -f "$STATE_DIR/$1-$DATE" ]
}

ran_this_week() {
    [ -f "$STATE_DIR/$1-W$WEEK" ]
}

mark_done() {
    echo "$(date '+%H:%M:%S')" > "$STATE_DIR/$1-$DATE"
}

mark_done_week() {
    echo "$DATE $(date '+%H:%M:%S')" > "$STATE_DIR/$1-W$WEEK"
}

last_run_seconds_ago() {
    local marker="$STATE_DIR/$1-last"
    if [ -f "$marker" ]; then
        local prev
        prev=$(cat "$marker")
        echo $(( NOW - prev ))
    else
        echo 999999
    fi
}

mark_interval() {
    echo "$NOW" > "$STATE_DIR/$1-last"
}

# === Очистка старых маркеров (>7 дней) ===

cleanup_state() {
    find "$STATE_DIR" -name "*-202*" -mtime +7 -delete 2>/dev/null || true
}

# === Pre-archive: мгновенная очистка вчерашнего DayPlan (< 1 сек) ===
# Разделяет архивацию (мгновенно) и генерацию (15+ мин Claude Code).
# Гарантирует: даже если генерация ещё не началась, старый план не висит в current/.
pre_archive_dayplan() {
    local strategy_dir="$HOME/Github/DS-strategy"
    local archive_dir="$strategy_dir/archive/day-plans"
    local moved=0

    mkdir -p "$archive_dir"

    for dayplan in "$strategy_dir/current"/DayPlan\ 20*.md; do
        [ -f "$dayplan" ] || continue
        local fname
        fname=$(basename "$dayplan")
        # Пропускаем сегодняшний план
        if [[ "$fname" == *"$DATE"* ]]; then continue; fi
        # Архивируем вчерашний (и любой более старый)
        git -C "$strategy_dir" mv "$dayplan" "$archive_dir/" 2>/dev/null || mv "$dayplan" "$archive_dir/"
        moved=$((moved + 1))
        log "pre-archive: moved $fname → archive/day-plans/"
    done

    if [ "$moved" -gt 0 ]; then
        git -C "$strategy_dir" pull --rebase 2>/dev/null || true
        git -C "$strategy_dir" add current/ archive/day-plans/ 2>/dev/null || true
        git -C "$strategy_dir" commit -m "chore: archive $moved old DayPlan(s)" 2>/dev/null || true
        git -C "$strategy_dir" push 2>/dev/null || true
        log "pre-archive: committed and pushed ($moved file(s))"
    fi
}

# === Диспетчер ===

dispatch() {
    log "dispatch started (hour=$HOUR, dow=$DOW)"
    local ran=0

    # --- Pre-archive: убрать вчерашний DayPlan ДО генерации нового ---
    pre_archive_dayplan

    # --- Стратег: week-review (Пн, до morning) ---
    if [ "$DOW" = "1" ] && ! ran_this_week "strategist-week-review"; then
        log "→ strategist week-review (catch-up: hour=$HOUR)"
        if "$STRATEGIST_SH" week-review >> "$LOG_FILE" 2>&1; then
            mark_done_week "strategist-week-review"
        else
            log "WARN: strategist week-review failed (will retry next dispatch)"
        fi
        ran=1
    fi

    # --- Стратег: morning (04:00-21:59) ---
    if (( 10#$HOUR >= 4 && 10#$HOUR < 22 )) && ! ran_today "strategist-morning"; then
        log "→ strategist morning (catch-up: hour=$HOUR)"
        if "$STRATEGIST_SH" morning >> "$LOG_FILE" 2>&1; then
            mark_done "strategist-morning"
        else
            log "WARN: strategist morning failed (will retry next dispatch)"
        fi
        ran=1
    fi

    # --- Стратег: note-review (22:00+) ---
    if (( 10#$HOUR >= 22 )) && ! ran_today "strategist-note-review"; then
        log "→ strategist note-review (catch-up: hour=$HOUR)"
        if "$STRATEGIST_SH" note-review >> "$LOG_FILE" 2>&1; then
            mark_done "strategist-note-review"
        else
            log "WARN: strategist note-review failed (will retry next dispatch)"
        fi
        ran=1
    elif (( 10#$HOUR < 12 )); then
        local yesterday
        yesterday=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d "yesterday" +%Y-%m-%d 2>/dev/null || true)
        if [ -n "$yesterday" ] && [ ! -f "$STATE_DIR/strategist-note-review-$yesterday" ]; then
            log "→ strategist note-review (catch-up for yesterday $yesterday)"
            if "$STRATEGIST_SH" note-review >> "$LOG_FILE" 2>&1; then
                echo "$(date '+%H:%M:%S') catch-up" > "$STATE_DIR/strategist-note-review-$yesterday"
            else
                log "WARN: strategist note-review catch-up failed"
            fi
            ran=1
        fi
    fi

    # --- Синхронизатор: code-scan (ежедневно) ---
    if ! ran_today "synchronizer-code-scan"; then
        log "→ synchronizer code-scan (hour=$HOUR)"
        if "$SCRIPT_DIR/code-scan.sh" >> "$LOG_FILE" 2>&1; then
            mark_done "synchronizer-code-scan"
        else
            log "WARN: code-scan failed (will retry next dispatch)"
        fi
        ran=1
    fi

    # --- Синхронизатор: daily-report (после code-scan и strategist morning) ---
    if ! ran_today "synchronizer-daily-report"; then
        if ran_today "strategist-morning" || (( 10#$HOUR >= 6 )); then
            log "→ synchronizer daily-report (hour=$HOUR)"
            if "$SCRIPT_DIR/daily-report.sh" >> "$LOG_FILE" 2>&1; then
                mark_done "synchronizer-daily-report"
            else
                log "WARN: daily-report failed (will retry next dispatch)"
            fi
            ran=1
        fi
    fi

    # --- Экстрактор: inbox-check (каждые 3ч, 07-23) ---
    if (( 10#$HOUR >= 7 && 10#$HOUR <= 23 )); then
        local elapsed
        elapsed=$(last_run_seconds_ago "extractor-inbox-check")
        if [ "$elapsed" -ge 10800 ]; then
            log "→ extractor inbox-check (${elapsed}s since last)"
            if "$EXTRACTOR_SH" inbox-check >> "$LOG_FILE" 2>&1; then
                mark_interval "extractor-inbox-check"
            else
                log "WARN: extractor inbox-check failed (will retry next dispatch)"
            fi
            ran=1
        fi
    fi

    if [ "$ran" -eq 0 ]; then
        log "dispatch: nothing to run"
    fi

    cleanup_state
    log "dispatch completed"
}

# === Статус ===

show_status() {
    echo "=== Exocortex Scheduler Status ==="
    echo "Date: $DATE  Hour: $HOUR  DOW: $DOW  Week: W$WEEK"
    echo ""

    echo "--- Today's runs ---"
    local daily_files
    daily_files=$(ls "$STATE_DIR"/*-"$DATE" 2>/dev/null || true)
    if [ -n "$daily_files" ]; then
        echo "$daily_files" | while read -r f; do
            echo "  $(basename "$f"): $(cat "$f")"
        done
    else
        echo "  (none)"
    fi

    echo ""
    echo "--- Interval markers ---"
    local interval_files
    interval_files=$(ls "$STATE_DIR"/*-last 2>/dev/null || true)
    if [ -n "$interval_files" ]; then
        echo "$interval_files" | while read -r f; do
            local ts ago
            ts=$(cat "$f")
            ago=$(( NOW - ts ))
            echo "  $(basename "$f"): ${ago}s ago"
        done
    else
        echo "  (none)"
    fi

    echo ""
    echo "--- Week markers ---"
    local week_files
    week_files=$(ls "$STATE_DIR"/*-W"$WEEK" 2>/dev/null || true)
    if [ -n "$week_files" ]; then
        echo "$week_files" | while read -r f; do
            echo "  $(basename "$f"): $(cat "$f")"
        done
    else
        echo "  (none)"
    fi
}

# === Main ===

case "${1:-}" in
    dispatch)
        dispatch
        ;;
    status)
        show_status
        ;;
    *)
        echo "Usage: scheduler.sh {dispatch|status}"
        echo ""
        echo "  dispatch  — check schedules and run due agents"
        echo "  status    — show current state of all agents"
        exit 1
        ;;
esac
