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

# Предотвращаем сон пока скрипт работает
# macOS: caffeinate -diu (idle+display+user, работает на батарее; -s НЕ используем — игнорируется при OBC→BATT)
# Linux: systemd-inhibit (если доступен)
if [[ "$(uname)" == "Darwin" ]]; then
    caffeinate -diu -w $$ &
elif command -v systemd-inhibit &>/dev/null; then
    systemd-inhibit --what=idle:sleep --who=scheduler --why="agent dispatch" --mode=block sleep infinity &
    _INHIBIT_PID=$!
    trap 'kill $_INHIBIT_PID 2>/dev/null' EXIT
fi

# Cross-platform date offset: portable_date_offset <days_back> <format>
portable_date_offset() {
    local days="$1"
    local fmt="${2:-%Y-%m-%d}"
    date -v-${days}d +"$fmt" 2>/dev/null || date -d "$days days ago" +"$fmt" 2>/dev/null
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SYNC_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="$HOME/.local/state/exocortex"
LOG_DIR="$HOME/logs/synchronizer"
LOG_FILE="$LOG_DIR/scheduler-$(date +%Y-%m-%d).log"

# WP-273 R5 fix (Round 5 Евгения): substituted runners в .iwe-runtime/, но
# role.yaml — read-only метаданные (не substituted, нет плейсхолдеров) — должны
# браться из FMT через $IWE_TEMPLATE. notify.sh — также read-only.
ROLES_DIR_RUNTIME="{{IWE_RUNTIME}}/roles"
ROLES_DIR_TEMPLATE="${IWE_TEMPLATE:-$HOME/IWE/FMT-exocortex-template}/roles"
# WP-273 0.29.3: silent degradation guard. Если IWE_TEMPLATE пуста — env неполная.
if [ -z "${IWE_TEMPLATE:-}" ]; then
    echo "[$(date '+%H:%M:%S')] WARN: \$IWE_TEMPLATE не задана, scheduler использует fallback $HOME/IWE/FMT-exocortex-template. source ~/.zshenv?" >&2
fi
ROLES_DIR="$ROLES_DIR_RUNTIME"  # backward-compat alias для downstream-логики
# notify.sh — read-only, не substituted
if [ -n "${IWE_TEMPLATE:-}" ] && [ -f "$IWE_TEMPLATE/roles/synchronizer/scripts/notify.sh" ]; then
    NOTIFY_SH="$IWE_TEMPLATE/roles/synchronizer/scripts/notify.sh"
elif [ -f "$HOME/IWE/FMT-exocortex-template/roles/synchronizer/scripts/notify.sh" ]; then
    NOTIFY_SH="$HOME/IWE/FMT-exocortex-template/roles/synchronizer/scripts/notify.sh"
else
    NOTIFY_SH="$SCRIPT_DIR/notify.sh"  # legacy fallback
fi

# Таймаут на задачи (сек): предотвращает блокировку dispatch зависшей задачей
TASK_TIMEOUT_SHORT=300    # 5 мин — bash-скрипты (code-scan, dt-collect, reindex)
TASK_TIMEOUT_LONG=1800    # 30 мин — Claude CLI (strategist, scout, extractor)

# Role runner discovery: role.yaml — read-only из FMT (template), runner — substituted из runtime.
# WP-273 R5: разделили location'ы — yaml из template, runner из runtime.
get_role_runner() {
    local role="$1"
    local yaml="$ROLES_DIR_TEMPLATE/$role/role.yaml"
    if [ -f "$yaml" ]; then
        local runner
        runner=$(grep '^runner:' "$yaml" | sed 's/runner: *//' | tr -d '"' | tr -d "'")
        [ -n "$runner" ] && echo "$ROLES_DIR_RUNTIME/$role/$runner" && return
    fi
    # Fallback: convention-based path (substituted runner в runtime)
    echo "$ROLES_DIR_RUNTIME/$role/scripts/$role.sh"
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

# macOS не имеет GNU timeout — используем perl fallback
if ! command -v timeout &>/dev/null; then
    timeout() {
        local duration="$1"; shift
        perl -e '
            use POSIX ":sys_wait_h";
            my $timeout = shift @ARGV;
            my $pid = fork();
            if ($pid == 0) { exec @ARGV; die "exec failed: $!"; }
            eval {
                local $SIG{ALRM} = sub { die "alarm" };
                alarm($timeout);
                waitpid($pid, 0);
                alarm(0);
            };
            if ($@ =~ /alarm/) { kill("TERM", $pid); sleep(1); kill("KILL", $pid); waitpid($pid, WNOHANG); exit(124); }
            exit($? >> 8);
        ' "$duration" "$@"
    }
fi

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
    local strategy_dir="{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}"
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
        # ВАЖНО: добавляем ТОЛЬКО перемещённые файлы, не всю директорию.
        # `git add current/` может подхватить грязные unstaged файлы (баг 21 мар 2026).
        git -C "$strategy_dir" add -- archive/day-plans/ 2>/dev/null || true
        git -C "$strategy_dir" add -u -- current/ 2>/dev/null || true
        git -C "$strategy_dir" commit -m "chore: archive $moved old DayPlan(s)" 2>/dev/null || true
        git -C "$strategy_dir" push 2>/dev/null || true
        log "pre-archive: committed and pushed ($moved file(s))"
    fi
}

# === Диспетчер ===

dispatch() {
    # WP-273 0.29.4 R6.5: self-reentrancy guard. Если предыдущий dispatch ещё работает
    # (Claude CLI 30 мин), launchd может запустить следующий — двойной morning strategist.
    # Используем flock на $STATE_DIR/scheduler.lock (non-blocking: новый dispatch выходит сразу).
    if command -v flock >/dev/null 2>&1; then
        exec 8>"$STATE_DIR/scheduler.lock"
        if ! flock -n 8; then
            log "SKIP: another scheduler dispatch уже работает (flock contended)"
            return 0
        fi
    fi

    # WP-273 0.29.4 R6.3: shared lock на runtime swap — ждём если build-runtime в процессе.
    if command -v flock >/dev/null 2>&1 && [ -f "${IWE_WORKSPACE:-$HOME/IWE}/.iwe-runtime.lock" ]; then
        exec 7>"${IWE_WORKSPACE:-$HOME/IWE}/.iwe-runtime.lock"
        flock -s -w 5 7 2>/dev/null || log "WARN: runtime lock contended >5s — proceeding (read paths могут быть устаревшими)"
    fi

    log "dispatch started (hour=$HOUR, dow=$DOW)"
    local ran=0

    # --- Pre-archive: убрать вчерашний DayPlan ДО генерации нового ---
    pre_archive_dayplan

    # --- AC sleep check (macOS): на зарядке Mac не должен засыпать ---
    if [[ "$(uname)" == "Darwin" ]] && ! ran_today "pmset-check"; then
        local ac_sleep
        ac_sleep=$(pmset -g custom 2>/dev/null | sed -n '/AC Power/,/Battery Power/p' | grep '^ sleep' | awk '{print $2}')
        if [ -n "$ac_sleep" ] && [ "$ac_sleep" != "0" ]; then
            log "⚠️  AC sleep=$ac_sleep (should be 0) — Mac will sleep on charger. Fix: sudo pmset -c sleep 0"
        fi
        mark_done "pmset-check"
    fi

    # --- Стратег: week-review (Пн, до morning) ---
    if [ "$DOW" = "1" ] && ! ran_this_week "strategist-week-review"; then
        log "→ strategist week-review (catch-up: hour=$HOUR)"
        if timeout "$TASK_TIMEOUT_LONG" "$STRATEGIST_SH" week-review >> "$LOG_FILE" 2>&1; then
            mark_done_week "strategist-week-review"
        else
            log "WARN: strategist week-review failed (will retry next dispatch)"
        fi
        ran=1
    fi

    # --- Стратег: morning (04:00-21:59) ---
    if (( 10#$HOUR >= 4 && 10#$HOUR < 22 )) && ! ran_today "strategist-morning"; then
        log "→ strategist morning (catch-up: hour=$HOUR)"
        if timeout "$TASK_TIMEOUT_LONG" "$STRATEGIST_SH" morning >> "$LOG_FILE" 2>&1; then
            mark_done "strategist-morning"
        else
            log "WARN: strategist morning failed (will retry next dispatch)"
        fi
        ran=1
    fi

    # --- Стратег: note-review (22:00+) ---
    if (( 10#$HOUR >= 22 )) && ! ran_today "strategist-note-review"; then
        log "→ strategist note-review (catch-up: hour=$HOUR)"
        if timeout "$TASK_TIMEOUT_LONG" "$STRATEGIST_SH" note-review >> "$LOG_FILE" 2>&1; then
            mark_done "strategist-note-review"
        else
            log "WARN: strategist note-review failed (will retry next dispatch)"
        fi
        ran=1
    elif (( 10#$HOUR < 12 )); then
        local yesterday
        yesterday=$(portable_date_offset 1)
        if [ -n "$yesterday" ] && [ ! -f "$STATE_DIR/strategist-note-review-$yesterday" ]; then
            log "→ strategist note-review (catch-up for yesterday $yesterday)"
            if timeout "$TASK_TIMEOUT_LONG" "$STRATEGIST_SH" note-review >> "$LOG_FILE" 2>&1; then
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
        if timeout "$TASK_TIMEOUT_SHORT" "$SCRIPT_DIR/code-scan.sh" >> "$LOG_FILE" 2>&1; then
            mark_done "synchronizer-code-scan"
        else
            log "WARN: code-scan failed (will retry next dispatch)"
        fi
        ran=1
    fi

    # --- Синхронизатор: dt-collect (после code-scan) ---
    # AUTHOR-ONLY: требует NEON_URL + DT_USER_ID в ~/.config/aist/env (секреты автора
    # шаблона). Пользовательский путь — через event-gateway, фаза в WP-253 роадмапе.
    if ! ran_today "synchronizer-dt-collect"; then
        if [ -f "$HOME/.config/aist/env" ] && grep -qE '^NEON_URL=' "$HOME/.config/aist/env" \
           && grep -qE '^DT_USER_ID=' "$HOME/.config/aist/env"; then
            log "→ synchronizer dt-collect (hour=$HOUR)"
            if timeout "$TASK_TIMEOUT_SHORT" "$SCRIPT_DIR/dt-collect.sh" >> "$LOG_FILE" 2>&1; then
                mark_done "synchronizer-dt-collect"
            else
                log "WARN: dt-collect failed (will retry next dispatch)"
            fi
            ran=1
        fi
        # Если env отсутствует — молча пропускаем (author-only, у пользователей нет секретов).
    fi

    # --- Синхронизатор: daily-report (после code-scan и strategist morning) ---
    if ! ran_today "synchronizer-daily-report"; then
        if ran_today "strategist-morning" || (( 10#$HOUR >= 6 )); then
            log "→ synchronizer daily-report (hour=$HOUR)"
            if timeout "$TASK_TIMEOUT_SHORT" "$SCRIPT_DIR/daily-report.sh" >> "$LOG_FILE" 2>&1; then
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
            if timeout "$TASK_TIMEOUT_LONG" "$EXTRACTOR_SH" inbox-check >> "$LOG_FILE" 2>&1; then
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
