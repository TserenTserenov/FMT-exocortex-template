#!/bin/bash
# scheduler.sh — central dispatcher for the Synchronizer role Synchronizer
#
# Lifecycle: `roles/synchronizer/install.sh` activates this script via
# launchd (macOS), systemd --user (Linux) or cron fallback. The role is optional:
# without installing it the script remains available for manual execution only
# (`scheduler.sh dispatch|status`).
#
# State: ~/.local/state/exocortex/ (run markers)
#
# Usage:
#   scheduler.sh dispatch    — check the schedule and run what is needed
#   scheduler.sh status      — show the status of all agents

set -euo pipefail

# Prevent sleep while the script is running
# macOS: caffeinate -diu (idle+display+user, running on battery; -s do NOT use — ignored when OBC→BATT)
# Linux: systemd-inhibit (if available)
if [[ "$(uname)" == "Darwin" ]]; then
    caffeinate -diu -w $$ &
elif command -v systemd-inhibit &>/dev/null; then
    systemd-inhibit --what=idle:sleep --who=scheduler --why="agent dispatch" --mode=block sleep infinity &
    _INHIBIT_PID=$!
    trap 'kill $_INHIBIT_PID 2>/dev/null' EXIT
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SYNC_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="$HOME/.local/state/exocortex"
LOG_DIR="$HOME/logs/synchronizer"
LOG_FILE="$LOG_DIR/scheduler-$(date +%Y-%m-%d).log"

# WP-273 R5 fix (Round 5 Evgenia): substituted runners in .iwe-runtime/, but
# role.yaml — read-only metadata (not substituted, no placeholders) — must
# be taken from FMT via $IWE_TEMPLATE. notify.sh — also read-only.
# WP-273 0.29.4 R6.1 fix (issue #271): runtime-resolution instead of build-time {{IWE_RUNTIME}} — as in notify.sh.
ROLES_DIR_RUNTIME="${IWE_RUNTIME:-${IWE_WORKSPACE:-$HOME/IWE}/.iwe-runtime}/roles"
ROLES_DIR_TEMPLATE="${IWE_TEMPLATE:-$HOME/IWE/IWE}/roles"
# WP-273 0.29.3: silent degradation guard. If IWE_TEMPLATE is empty — env incomplete.
if [ -z "${IWE_TEMPLATE:-}" ]; then
    echo "[$(date '+%H:%M:%S')] WARN: \$IWE_TEMPLATE is not set, scheduler uses fallback $HOME/IWE/IWE. source ~/.zshenv?" >&2
fi
ROLES_DIR="$ROLES_DIR_RUNTIME"  # backward-compat alias for downstream-logic
# notify.sh — read-only, not substituted (is taken from FMT, not from .iwe-runtime).
# Therefore notify.sh resolves templates from .iwe-runtime (see. #169): otherwise its
# $SCRIPT_DIR/templates points to FMT-copies with unresolved {{WORKSPACE_DIR}}.
if [ -n "${IWE_TEMPLATE:-}" ] && [ -f "$IWE_TEMPLATE/roles/synchronizer/scripts/notify.sh" ]; then
    NOTIFY_SH="$IWE_TEMPLATE/roles/synchronizer/scripts/notify.sh"
elif [ -f "$HOME/IWE/IWE/roles/synchronizer/scripts/notify.sh" ]; then
    NOTIFY_SH="$HOME/IWE/IWE/roles/synchronizer/scripts/notify.sh"
else
    NOTIFY_SH="$SCRIPT_DIR/notify.sh"  # legacy fallback
fi

# Task timeout (sec): prevents dispatch from being blocked by dispatch a hung task
TASK_TIMEOUT_SHORT=300    # 5 min — bash-bash scripts (code-scan, dt-collect, reindex)
TASK_TIMEOUT_LONG=1800    # 30 min — Claude CLI (strategist, scout, extractor)

# Role runner discovery: role.yaml — read-only from FMT (template), runner — substituted from runtime.
# WP-273 R5: split location's — yaml from template, runner from runtime.
get_role_runner() {
    local role="$1"
    local yaml="$ROLES_DIR_TEMPLATE/$role/role.yaml"
    if [ -f "$yaml" ]; then
        local runner
        runner=$(grep '^runner:' "$yaml" | sed 's/runner: *//' | tr -d '"' | tr -d "'")
        [ -n "$runner" ] && echo "$ROLES_DIR_RUNTIME/$role/$runner" && return
    fi
    # Fallback: convention-based path (substituted runner at runtime)
    echo "$ROLES_DIR_RUNTIME/$role/scripts/$role.sh"
}

STRATEGIST_SH="$(get_role_runner strategist)"
EXTRACTOR_SH="$(get_role_runner extractor)"

# Current time
HOUR=$(date +%H)
DOW=$(date +%u)   # 1=Mon, 7=Sun
DATE=$(date +%Y-%m-%d)
WEEK=$(date +%V)
NOW=$(date +%s)

mkdir -p "$STATE_DIR" "$LOG_DIR"

# macOS does not have GNU timeout — using perl fallback
if ! command -v timeout &>/dev/null; then
    timeout() {
        local duration="$1"; shift
        perl -e '
            use POSIX ":sys_wait_h";
            my $timeout = shift @ARGV;
            my $pid = fork();
            defined($pid) or die "fork failed: $!";
            if ($pid == 0) {
                POSIX::setpgid(0, 0) == 0 or die "setpgid failed: $!";
                exec @ARGV; die "exec failed: $!";
            }
            eval {
                local $SIG{ALRM} = sub { die "alarm" };
                alarm($timeout);
                waitpid($pid, 0);
                alarm(0);
            };
            if ($@ =~ /alarm/) {
                kill("TERM", -$pid);
                sleep(1);
                kill("KILL", -$pid);
                waitpid($pid, WNOHANG);
                exit(124);
            }
            exit($? >> 8);
        ' "$duration" "$@"
    }
fi

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scheduler] $1" | tee -a "$LOG_FILE"
}

# Strategist exit 2 means that its own non-blocking lock is already held by a
# live run. This is a neutral skip: keep the marker absent so a later dispatch
# retries, but do not report the concurrent healthy run as a failure (#527).
run_strategist_scenario() {
    local scenario="$1"
    local rc=0

    timeout "$TASK_TIMEOUT_LONG" "$STRATEGIST_SH" "$scenario" >> "$LOG_FILE" 2>&1 || rc=$?
    case "$rc" in
        0)
            return 0
            ;;
        2)
            log "SKIP: strategist $scenario already running (lock held; will retry next dispatch)"
            ;;
        75)
            log "ALARM: strategist $scenario deferred: template update incomplete (rc=75; finish or repair update.sh; will retry next dispatch)"
            if [ "$scenario" = morning ]; then
                notify_incomplete_morning_update || true
            fi
            ;;
        76)
            log "ALARM: strategist $scenario exhausted today's automatic attempts (rc=76; manual retry remains available)"
            ;;
        77)
            if [ "$scenario" = week-review ] && week_review_exhausted_today; then
                log "ALARM: strategist week-review automatic retry paused (rc=77; delivery outcome uncertain or attempts exhausted; inspect status before manual retry)"
            else
                log "WARN: strategist $scenario failed (rc=77; next dispatch will recheck status)"
            fi
            ;;
        *)
            log "WARN: strategist $scenario failed (rc=$rc; will retry next dispatch)"
            ;;
    esac
    return "$rc"
}

# === State management ===

ran_today() {
    [ -f "$STATE_DIR/$1-$DATE" ]
}

ran_this_week() {
    [ -f "$STATE_DIR/$1-W$WEEK" ]
}

# #1067: use the strategist's published status record, never its mixed log:
# model stdout in that log can contain forged GAVE UP/RECORDED markers. UNKNOWN
# means a run may have delivered before its final status write failed; pause.
week_review_exhausted_today() {
    local status_file="$HOME/logs/strategist/week-review-last-status"
    local stamped_at outcome rc failed_runs extra
    [ -f "$status_file" ] && [ ! -L "$status_file" ] || return 1
    IFS=$'\t' read -r stamped_at outcome rc failed_runs extra < "$status_file" || return 1
    [ -z "$extra" ] && [ "${stamped_at%% *}" = "$DATE" ] &&
        { { [ "$outcome" = FAILED ] && [[ "$rc" =~ ^[0-9]+$ ]] &&
            { [ "$failed_runs" = 2 ] || [ -z "$failed_runs" ]; }; } ||
          { [ "$outcome" = UNKNOWN ] && [ "$rc" = 77 ] &&
            { [ "$failed_runs" = 1 ] || [ "$failed_runs" = 2 ]; }; }; }
}

# A manual retry can succeed after the cap. The next scheduler dispatch then
# observes its dated success status and records the weekly postcondition.
week_review_recovered_today() {
    local status_file="$HOME/logs/strategist/week-review-last-status"
    local stamped_at outcome rc failed_runs extra
    [ -f "$status_file" ] && [ ! -L "$status_file" ] || return 1
    IFS=$'\t' read -r stamped_at outcome rc failed_runs extra < "$status_file" || return 1
    [ -z "$extra" ] && [ "${stamped_at%% *}" = "$DATE" ] &&
        [ "$outcome" = SUCCESS ] && [ "$rc" = 0 ] && [ "$failed_runs" = 0 ]
}

mark_done() {
    echo "$(date '+%H:%M:%S')" > "$STATE_DIR/$1-$DATE"
}

# The strategist exits 75 before its own notifier is available. Use the existing
# day-open-failed path here; a failed send (which notify.sh may report with exit 0)
# must not consume the one-per-day notice or the morning retry.
notify_incomplete_morning_update() {
    local notice="strategist-morning-update-alert" output="" notify_rc=0
    ran_today "$notice" && return 0
    if [ ! -f "$NOTIFY_SH" ]; then
        log "WARN: Day Open update-incomplete notification unavailable; will retry next dispatch"
        return 1
    fi
    # Bound the whole notifier below TASK_TIMEOUT_SHORT (300s). The macOS
    # fallback kills its process group, including children that inherited the
    # command substitution's stdout; notify.sh also bounds curl itself.
    output=$(DAY_OPEN_FAILED_REASON=update-incomplete DAY_OPEN_FAILED_RC=75 \
        timeout 15 "$NOTIFY_SH" strategist day-open-failed 2>&1) || notify_rc=$?
    if [ "$notify_rc" -eq 0 ] && printf '%s\n' "$output" | grep -qxF \
        'Telegram notification sent: strategist/day-open-failed'; then
        if mark_done "$notice"; then
            log "Day Open update-incomplete notification delivered"
            return 0
        fi
    fi
    log "WARN: Day Open update-incomplete notification not confirmed (notifier rc=$notify_rc); will retry next dispatch"
    return 1
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

# "Every N hours" tasks are gated on the time since the previous dispatch START
# (mark_interval stores NOW), and the timer fires every N hours too. A dispatch may
# start a few seconds earlier than the previous one did: 15:00:52 -> 18:00:51 is
# 10799 s < 10800 and the extractor lost a whole interval (a pilot's remote host, 21.09.2026).
# The slack absorbs that jitter; it is far below any interval, so a manual dispatch
# still holds the next timer tick off.
INTERVAL_SLACK_SECONDS=300

# interval_reached ELAPSED_SECONDS INTERVAL_SECONDS
interval_reached() {
    [ "$1" -ge $(( $2 - INTERVAL_SLACK_SECONDS )) ]
}

# === Cleanup of old markers (>7 days) ===

cleanup_state() {
    find "$STATE_DIR" -name "*-202*" -mtime +7 -delete 2>/dev/null || true
}

# === Dispatcher ===

dispatch() {
    # WP-273 0.29.4 R6.5: self-reentrancy guard. If the previous dispatch is still running
    # (Claude CLI 30 min), launchd may start the next — duplicate morning strategist.
    # Using flock on $STATE_DIR/scheduler.lock (non-blocking: new dispatch exits immediately).
    if command -v flock >/dev/null 2>&1; then
        exec 8>"$STATE_DIR/scheduler.lock"
        if ! flock -n 8; then
            log "SKIP: another scheduler dispatch is already running (flock contended)"
            return 0
        fi
    fi

    # WP-273 0.29.4 R6.3: shared lock on runtime swap — wait if build-runtime in progress.
    if command -v flock >/dev/null 2>&1 && [ -f "${IWE_WORKSPACE:-$HOME/IWE}/.iwe-runtime.lock" ]; then
        exec 7>"${IWE_WORKSPACE:-$HOME/IWE}/.iwe-runtime.lock"
        flock -s -w 5 7 2>/dev/null || log "WARN: runtime lock contended >5s — proceeding (read paths may be stale)"
    fi

    log "dispatch started (hour=$HOUR, dow=$DOW)"
    local ran=0

    # --- AC sleep check (macOS): on AC power Mac should not sleep ---
    if [[ "$(uname)" == "Darwin" ]] && ! ran_today "pmset-check"; then
        local ac_sleep
        ac_sleep=$(pmset -g custom 2>/dev/null | sed -n '/AC Power/,/Battery Power/p' | grep '^ sleep' | awk '{print $2}')
        if [ -n "$ac_sleep" ] && [ "$ac_sleep" != "0" ]; then
            log "⚠️  AC sleep=$ac_sleep (should be 0) — Mac will sleep on charger. Fix: sudo pmset -c sleep 0"
        fi
        mark_done "pmset-check"
    fi

    # --- Strategist: week-review (Mon, before morning) ---
    if [ "$DOW" = "1" ] && ! ran_this_week "strategist-week-review"; then
        if week_review_recovered_today; then
            mark_done_week "strategist-week-review"
            log "week-review manual recovery confirmed; weekly marker recorded"
        elif week_review_exhausted_today; then
            log "SKIP: strategist week-review automatic retry paused (attempts exhausted or delivery outcome uncertain); inspect status before manual retry"
        else
            log "→ strategist week-review (catch-up: hour=$HOUR)"
            if run_strategist_scenario "week-review"; then
                mark_done_week "strategist-week-review"
            fi
        fi
        ran=1
    fi

    # --- Strategist: morning (04:00-21:59) ---
    if (( 10#$HOUR >= 4 && 10#$HOUR < 22 )) && ! ran_today "strategist-morning"; then
        log "→ strategist morning (catch-up: hour=$HOUR)"
        if run_strategist_scenario "morning"; then
            mark_done "strategist-morning"
        fi
        ran=1
    fi

    # --- Strategist: note-review — no scheduled runs (template owner's decision, July 2026) ---
    # Notes are reviewed ONLY by hand, in a live session with the pilot (e.g. the Day Open
    # "Note review" section). The nightly run kept stripping bold and archiving notes without
    # a pilot decision, so BOTH scheduler paths are gone: the evening run (22:00+) and the
    # morning catch-up for "yesterday". A manual `strategist.sh note-review` from a terminal
    # still works, but it has no chat: it only marks notes and writes proposals, the model archives
    # nothing (only the cleanup safety net may archive a note whose bold the pilot already removed).

    # --- Synchronizer: code-scan (daily) ---
    if ! ran_today "synchronizer-code-scan"; then
        log "→ synchronizer code-scan (hour=$HOUR)"
        if timeout "$TASK_TIMEOUT_SHORT" "$SCRIPT_DIR/code-scan.sh" >> "$LOG_FILE" 2>&1; then
            mark_done "synchronizer-code-scan"
        else
            log "WARN: code-scan failed (will retry next dispatch)"
        fi
        ran=1
    fi

    # --- Synchronizer: dt-collect (after code-scan) ---
    # AUTHOR-ONLY: requires NEON_URL + DT_USER_ID in ~/.config/aist/env (author secrets
    # template). User path — via event-gateway, phase in WP-253 roadmap.
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
        # If env is absent — skip silently (author-only, users do not have secrets).
    fi

    # --- Synchronizer: daily-report (after code-scan and strategist morning) ---
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

    # --- Extractor: inbox-check (every 3h, 07-23) ---
    if (( 10#$HOUR >= 7 && 10#$HOUR <= 23 )); then
        local elapsed
        elapsed=$(last_run_seconds_ago "extractor-inbox-check")
        if interval_reached "$elapsed" 10800; then
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

# === Status ===

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
