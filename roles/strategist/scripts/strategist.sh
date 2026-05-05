#!/bin/bash
# Strategist (Стратег) Agent Runner
# Запускает Claude Code с заданным сценарием

set -e

# Предотвращаем сон: -i (idle, работает на батарее) -d (display) -u (user activity)
# Флаг -s (system sleep) не используем — он НЕ работает на батарее (OBC может переключить профиль)
# Linux: caffeinate отсутствует — guard через command -v (на Linux достаточно, что cron/systemd сам управляет sleep)
command -v caffeinate >/dev/null 2>&1 && caffeinate -diu -w $$ &

# Конфигурация
# WP-273 R5 fix (Round 5 Евгения): substituted runner живёт в .iwe-runtime/,
# но prompts/ и notify.sh — read-only данные, должны браться из FMT (immutable upstream).
# Архитектурный принцип: substituted в runtime, read-only из FMT через $IWE_TEMPLATE.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# WP-273 0.29.4 R6.1 fix: было хардкоженое имя governance-репо.
# Теперь подставляются плейсхолдеры из .exocortex.env через build-runtime.
WORKSPACE="{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}"

# PROMPTS_DIR резолв: $IWE_TEMPLATE (Generated runtime) → $HOME/IWE/FMT-exocortex-template (default) → relative (legacy fallback)
if [ -n "${IWE_TEMPLATE:-}" ] && [ -d "$IWE_TEMPLATE/roles/strategist/prompts" ]; then
    PROMPTS_DIR="$IWE_TEMPLATE/roles/strategist/prompts"
elif [ -d "$HOME/IWE/FMT-exocortex-template/roles/strategist/prompts" ]; then
    PROMPTS_DIR="$HOME/IWE/FMT-exocortex-template/roles/strategist/prompts"
    # WP-273 0.29.3 (sub-agent assessment R3): silent degradation guard.
    # Если IWE_TEMPLATE не экспортирована — env неполная, дальше будут проблемы.
    echo "[$(date '+%H:%M:%S')] WARN: \$IWE_TEMPLATE не задана, fallback на $HOME/IWE/FMT-exocortex-template. source ~/.zshenv?" >&2
else
    PROMPTS_DIR="$REPO_DIR/prompts"  # legacy: same dir as runner (pre-WP-273)
    echo "[$(date '+%H:%M:%S')] WARN: legacy PROMPTS_DIR fallback на $PROMPTS_DIR (pre-WP-273). Запустите migrate-to-runtime-target.sh." >&2
fi

LOG_DIR="$HOME/logs/strategist"
CLAUDE_PATH="{{CLAUDE_PATH}}"
CLAUDE_TIMEOUT=1800  # 30 мин — защита от зависания Claude CLI

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
                local $SIG{ALRM} = sub { kill "TERM", $pid; die "timeout\n"; };
                alarm $timeout;
                waitpid($pid, 0);
                alarm 0;
            };
            if ($@ && $@ eq "timeout\n") { waitpid($pid, WNOHANG); exit 124; }
            exit ($? >> 8);
        ' "$duration" "$@"
    }
fi

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
    # WP-273 R5: notify.sh — read-only из FMT, не substituted (нет плейсхолдеров).
    local notify_script
    if [ -n "${IWE_TEMPLATE:-}" ] && [ -f "$IWE_TEMPLATE/roles/synchronizer/scripts/notify.sh" ]; then
        notify_script="$IWE_TEMPLATE/roles/synchronizer/scripts/notify.sh"
    elif [ -f "$HOME/IWE/FMT-exocortex-template/roles/synchronizer/scripts/notify.sh" ]; then
        notify_script="$HOME/IWE/FMT-exocortex-template/roles/synchronizer/scripts/notify.sh"
    else
        notify_script="$REPO_DIR/../synchronizer/scripts/notify.sh"  # legacy fallback
    fi
    [ -f "$notify_script" ] && "$notify_script" strategist "$scenario" >> "$LOG_FILE" 2>&1 || true
}

run_claude() {
    local command_file="$1"
    local command_path="$PROMPTS_DIR/$command_file.md"

    if [ ! -f "$command_path" ]; then
        log "ERROR: Command file not found: $command_path"
        exit 1
    fi

    # Читаем содержимое команды.
    # WP-273 0.29.6 R6.1**: build-runtime подменял плейсхолдеры в этих sed-выражениях
    # → runner становился сломан после build (искал значение в промпте вместо плейсхолдера).
    # Escape: собираем двойно-фигурные токены через bash-конкатенацию — build-runtime sed
    # не находит цельный паттерн и не трогает.
    local prompt
    local _gov_repo="${IWE_GOVERNANCE_REPO:-DS-strategy}"
    local _ws="${IWE_WORKSPACE:-$HOME/IWE}"
    local _gh_user="${GITHUB_USER:-your-username}"
    local _o='{''{' _c='}''}'  # escape: build-runtime ищет цельный двойно-фигурный токен с UPPER_NAME внутри, поэтому конкатенация одиночных скобок его не матчит
    prompt=$(sed \
        -e "s|${_o}GOVERNANCE_REPO${_c}|$_gov_repo|g" \
        -e "s|${_o}WORKSPACE_DIR${_c}|$_ws|g" \
        -e "s|${_o}GITHUB_USER${_c}|$_gh_user|g" \
        "$command_path")

    # Inject current date + day of week (prevents LLM calendar arithmetic errors)
    local ru_date_context
    ru_date_context=$(python3 -c "
import datetime
days = ['Понедельник','Вторник','Среда','Четверг','Пятница','Суббота','Воскресенье']
months = ['января','февраля','марта','апреля','мая','июня','июля','августа','сентября','октября','ноября','декабря']
d = datetime.date.today()
print(f'{d.day} {months[d.month-1]} {d.year}, {days[d.weekday()]}')
")
    prompt="[Системный контекст] Сегодня: ${ru_date_context}. ISO: ${DATE}. День недели №${DAY_OF_WEEK} (1=Пн..7=Вс). ЯЗЫК: отвечай ТОЛЬКО на русском. Украинский, английский и другие языки запрещены.

${prompt}"

    log "Starting scenario: $command_file"
    log "Command file: $command_path"
    log "Date context: $ru_date_context"

    cd "$WORKSPACE"

    # Запуск Claude Code с содержимым команды как промпт (с timeout-защитой)
    local rc=0
    # NB: --dangerously-skip-permissions не используется — Claude Code блокирует флаг
    # под root/sudo (Linux cron). --allowedTools задаёт явный whitelist, чего достаточно.
    timeout "$CLAUDE_TIMEOUT" "$CLAUDE_PATH" \
        --allowedTools "Read,Write,Edit,Glob,Grep,Bash" \
        -p "$prompt" \
        >> "$LOG_FILE" 2>&1 || rc=$?

    if [ $rc -eq 124 ]; then
        log "WARN: Claude CLI timed out after ${CLAUDE_TIMEOUT}s for scenario: $command_file"
    elif [ $rc -ne 0 ]; then
        log "WARN: Claude CLI exited with code $rc for scenario: $command_file"
    fi

    if [ $rc -eq 0 ]; then
        log "SUCCESS scenario: $command_file"
    else
        log "FAILED scenario: $command_file (rc=$rc)"
    fi

    # Push changes to GitHub (чтобы бот мог читать через API)
    if git -C "$WORKSPACE" diff --quiet origin/main..HEAD 2>/dev/null; then
        log "No unpushed commits"
    else
        git -C "$WORKSPACE" pull --rebase >> "$LOG_FILE" 2>&1 && log "Pulled (rebase)" || log "WARN: pull --rebase failed"
        git -C "$WORKSPACE" push >> "$LOG_FILE" 2>&1 && log "Pushed to GitHub" || log "WARN: git push failed"
    fi

    # Очистить staging area после Claude сессии (предотвращает staging leak в следующие скрипты)
    # НЕ трогаем working tree — только unstage orphaned changes
    git -C "$WORKSPACE" reset --quiet 2>/dev/null || true
    log "Cleared staging area after Claude session"

    # macOS notification
    local summary
    summary=$(tail -5 "$LOG_FILE" | grep -v '^\[' | head -3)
    notify "Стратег: $command_file" "$summary"
    return $rc
}

# Проверка: уже запускался ли сценарий сегодня
already_ran_today() {
    local scenario="$1"
    [ -f "$LOG_FILE" ] && grep -q "SUCCESS scenario: $scenario" "$LOG_FILE"
}

# File-based lock to prevent concurrent execution (RunAtLoad + CalendarInterval race)
# mkdir — атомарная операция на POSIX, исключает TOCTOU race condition
LOCK_DIR="$LOG_DIR/locks"
mkdir -p "$LOCK_DIR"

acquire_lock() {
    local scenario="$1"
    local lockdir="$LOCK_DIR/${scenario}.${DATE}.lck"
    if ! mkdir "$lockdir" 2>/dev/null; then
        local pid
        pid=$(cat "$lockdir/pid" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            log "SKIP: $scenario already running (PID $pid)"
            exit 2  # non-zero → scheduler won't mark_done
        else
            log "WARN: removing stale lock (PID $pid no longer exists): $lockdir"
            rm -rf "$lockdir"
            mkdir "$lockdir" || { log "ERROR: failed to acquire lock for $scenario"; exit 1; }
        fi
    fi
    echo $$ > "$lockdir/pid" || { rm -rf "$lockdir"; log "ERROR: failed to write PID for $scenario"; exit 1; }
    trap "rm -rf \"$lockdir\" 2>/dev/null" EXIT
}

# Читаем strategy_day из конфига (L4 Personal)
RHYTHM_CONFIG="$HOME/.claude/projects/-Users-$(whoami)-IWE/memory/day-rhythm-config.yaml"
STRATEGY_DAY_NAME=$(grep 'strategy_day:' "$RHYTHM_CONFIG" 2>/dev/null | awk '{print $2}' || echo "monday")
# Конвертируем имя дня в номер (1=Mon..7=Sun)
case "$STRATEGY_DAY_NAME" in
    monday)    STRATEGY_DAY_NUM=1 ;;
    tuesday)   STRATEGY_DAY_NUM=2 ;;
    wednesday) STRATEGY_DAY_NUM=3 ;;
    thursday)  STRATEGY_DAY_NUM=4 ;;
    friday)    STRATEGY_DAY_NUM=5 ;;
    saturday)  STRATEGY_DAY_NUM=6 ;;
    sunday)    STRATEGY_DAY_NUM=7 ;;
    *)         STRATEGY_DAY_NUM=1 ;;  # fallback: monday
esac

# Определяем какой сценарий запускать
case "$1" in
    "morning")
        # Определяем нужный сценарий: strategy_day → session-prep, иначе → day-plan
        if [ "$DAY_OF_WEEK" -eq "$STRATEGY_DAY_NUM" ]; then
            SCENARIO="session-prep"
        else
            SCENARIO="day-plan"
        fi

        # Защита от повторного запуска (RunAtLoad + CalendarInterval race condition)
        acquire_lock "$SCENARIO"
        if already_ran_today "$SCENARIO"; then
            log "SKIP: $SCENARIO already completed today"
            exit 0
        fi

        if [ "$DAY_OF_WEEK" -eq "$STRATEGY_DAY_NUM" ]; then
            log "Strategy day ($STRATEGY_DAY_NAME): running session prep"
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
        acquire_lock "week-review"
        if already_ran_today "week-review"; then
            log "SKIP: week-review already completed today"
            exit 0
        fi
        log "Sunday: running week review"
        run_claude "week-review"
        # Fallback push for Knowledge Index (week-review creates a post there)
        # KI_REPO may not exist for all users — guard with [ -d ]
        KI_REPO="$HOME/IWE/DS-Knowledge-Index"
        if [ -d "$KI_REPO/.git" ] && git -C "$KI_REPO" log --oneline -1 --since="1 hour ago" --grep="week-review" 2>/dev/null | grep -q .; then
            git -C "$KI_REPO" push >> "$LOG_FILE" 2>&1 && log "Pushed Knowledge Index (fallback)" || log "WARN: KI push failed"
        fi
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
        acquire_lock "note-review"
        log "Evening: running note review"
        # Canary: count bold notes before (exclude 🔄 — deferred ideas stay bold by design)
        # NB: `grep -c` при exit 1 (no matches) печатает "0" до `||`, так что `|| echo 0`
        # давал двухстрочный "0\n0" и ломал арифметику. Используем `|| true` + fallback.
        FLEETING="$WORKSPACE/inbox/fleeting-notes.md"
        BOLD_BEFORE=$(grep -c '^\*\*' "$FLEETING" 2>/dev/null || true); BOLD_BEFORE=${BOLD_BEFORE:-0}
        BOLD_NEW_BEFORE=$(grep -vc '🔄' <(grep '^\*\*' "$FLEETING" 2>/dev/null) 2>/dev/null || true); BOLD_NEW_BEFORE=${BOLD_NEW_BEFORE:-0}
        log "Canary: $BOLD_BEFORE bold total ($BOLD_NEW_BEFORE new, $(( BOLD_BEFORE - BOLD_NEW_BEFORE )) deferred 🔄)"

        run_claude "note-review"

        # Canary: count bold notes after (needs to be visible for alert at line ~274)
        BOLD_AFTER=$(grep -c '^\*\*' "$FLEETING" 2>/dev/null || true); BOLD_AFTER=${BOLD_AFTER:-0}
        BOLD_NEW_AFTER=$(grep -vc '🔄' <(grep '^\*\*' "$FLEETING" 2>/dev/null) 2>/dev/null || true); BOLD_NEW_AFTER=${BOLD_NEW_AFTER:-0}
        # Non-blocking diagnostic (isolated from set -e to protect cleanup below)
        (
            log "Canary: $BOLD_AFTER bold total ($BOLD_NEW_AFTER new)"
            NON_BOLD=$(grep -c '^[^*#>-]' "$FLEETING" 2>/dev/null || true); NON_BOLD=${NON_BOLD:-0}
            log "Non-bold content lines: $NON_BOLD"
            if [ "$BOLD_NEW_AFTER" -ge "$BOLD_NEW_BEFORE" ] && [ "$BOLD_NEW_BEFORE" -gt 0 ]; then
                log "WARN: Note-Review Step 10 may have failed — new bold notes did not decrease ($BOLD_NEW_BEFORE → $BOLD_NEW_AFTER)"
            fi
        ) || true

        # Deterministic cleanup: archive non-bold, non-🔄 notes (safety net for LLM Step 10)
        log "Running deterministic cleanup..."
        CLEANUP_OUTPUT=$(python3 "$SCRIPT_DIR/cleanup-processed-notes.py" 2>&1) || true
        log "Cleanup: $CLEANUP_OUTPUT"

        # If cleanup made changes, commit and push
        if ! git -C "$WORKSPACE" diff --quiet -- inbox/fleeting-notes.md archive/notes/Notes-Archive.md 2>/dev/null; then
            git -C "$WORKSPACE" add inbox/fleeting-notes.md archive/notes/Notes-Archive.md
            git -C "$WORKSPACE" commit -m "chore: auto-cleanup processed notes from fleeting-notes.md" >> "$LOG_FILE" 2>&1 || true
            git -C "$WORKSPACE" pull --rebase >> "$LOG_FILE" 2>&1 && log "Cleanup: pulled (rebase)" || log "WARN: cleanup pull --rebase failed"
            git -C "$WORKSPACE" push >> "$LOG_FILE" 2>&1 && log "Cleanup: pushed" || log "WARN: cleanup push failed"
        else
            log "Cleanup: no changes to commit"
        fi

        # Alert if LLM failed AND cleanup was needed (only for NEW bold, not deferred 🔄)
        if [ "$BOLD_NEW_AFTER" -ge "$BOLD_NEW_BEFORE" ] && [ "$BOLD_NEW_BEFORE" -gt 0 ]; then
            ENV_FILE="$HOME/.config/aist/env"
            if [ -f "$ENV_FILE" ]; then
                set -a; source "$ENV_FILE"; set +a
                ALERT_TEXT="⚠️ <b>Note-Review canary</b>: Step 10 не сработал ($BOLD_NEW_BEFORE → $BOLD_NEW_AFTER new bold). Deterministic cleanup applied."
                ALERT_JSON=$(printf '%s' "$ALERT_TEXT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
                curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
                    -H "Content-Type: application/json" \
                    -d "{\"chat_id\":\"${TELEGRAM_CHAT_ID}\",\"text\":${ALERT_JSON},\"parse_mode\":\"HTML\"}" >> "$LOG_FILE" 2>&1 || true
            fi
        fi

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
