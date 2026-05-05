#!/bin/bash
# daily-report.sh — ежедневный отчёт работы scheduler
#
# Формирует отчёт: что должно было сработать, что сработало, что нет.
#
# Если DS-agent-workspace/ существует → пишет туда (scheduler/reports/).
# Иначе → DS-strategy/current/ (обратная совместимость).
#
# Использование:
#   daily-report.sh           # сформировать отчёт за сегодня
#   daily-report.sh --dry-run # показать отчёт, не записывать

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="$HOME/.local/state/exocortex"
LOG_DIR="{{HOME_DIR}}/logs/synchronizer"
STRATEGY_DIR="{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}"

# Agent Workspace: если существует — отчёты идут туда
AGENT_WORKSPACE="{{WORKSPACE_DIR}}/DS-agent-workspace"
if [ -d "$AGENT_WORKSPACE/.git" ]; then
    REPORT_DIR="$AGENT_WORKSPACE/scheduler/reports"
    ARCHIVE_DIR="$AGENT_WORKSPACE/scheduler/reports/archive"
    COMMIT_DIR="$AGENT_WORKSPACE"
    COMMIT_ADD_PATHS=("scheduler/reports/")
else
    REPORT_DIR="$STRATEGY_DIR/current"
    ARCHIVE_DIR="$STRATEGY_DIR/archive/scheduler-reports"
    COMMIT_DIR="$STRATEGY_DIR"
    COMMIT_ADD_PATHS=("current/SchedulerReport"*.md "archive/scheduler-reports/")
fi

DATE=$(date +%Y-%m-%d)
DOW=$(date +%u)
HOUR=$(date +%H)
WEEK=$(date +%V)

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

REPORT_FILE="$REPORT_DIR/SchedulerReport $DATE.md"
SCHEDULER_LOG="$LOG_DIR/scheduler-$DATE.log"
STRATEGIST_LOG="{{HOME_DIR}}/logs/strategist/$DATE.log"

mkdir -p "$ARCHIVE_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [daily-report] $1"
}

check_ran() {
    local marker="$1"
    if [ -f "$STATE_DIR/$marker-$DATE" ]; then
        cat "$STATE_DIR/$marker-$DATE"
        return 0
    fi
    return 1
}

check_ran_week() {
    local marker="$1"
    if [ -f "$STATE_DIR/$marker-W$WEEK" ]; then
        cat "$STATE_DIR/$marker-W$WEEK"
        return 0
    fi
    return 1
}

check_interval() {
    local marker="$1-last"
    if [ -f "$STATE_DIR/$marker" ]; then
        local ts ago
        ts=$(cat "$STATE_DIR/$marker")
        ago=$(( $(date +%s) - ts ))
        echo "${ago} сек назад"
        return 0
    fi
    return 1
}

compute_traffic_light() {
    local color="GREEN"
    local issues=""

    if ! check_ran "synchronizer-code-scan" &>/dev/null; then
        color="RED"
        issues+="code-scan не запустился; "
    fi

    if (( 10#$HOUR >= 6 )) && ! check_ran "strategist-morning" &>/dev/null; then
        color="RED"
        issues+="strategist morning не запустился; "
    fi

    if [ -f "$SCHEDULER_LOG" ] && grep -q "push failed" "$SCHEDULER_LOG" 2>/dev/null; then
        if [ "$color" = "GREEN" ]; then color="YELLOW"; fi
        issues+="push failed (Mac оффлайн?); "
    fi

    if (( 10#$HOUR >= 23 )) && ! check_ran "strategist-note-review" &>/dev/null; then
        if [ "$color" = "GREEN" ]; then color="YELLOW"; fi
        issues+="note-review не запустился; "
    fi

    if [ "$DOW" = "1" ] && ! check_ran_week "strategist-week-review" &>/dev/null; then
        if [ "$color" = "GREEN" ]; then color="YELLOW"; fi
        issues+="week-review не запустился (Пн!); "
    fi

    local emoji label
    case "$color" in
        GREEN)  emoji="🟢"; label="Среда готова к работе" ;;
        YELLOW) emoji="🟡"; label="Среда работает с замечаниями" ;;
        RED)    emoji="🔴"; label="Критический сбой — требуется внимание" ;;
    esac

    echo "$emoji|$label|${issues:-нет}"
}

generate_report() {
    local report=""

    report+="---
type: scheduler-report
date: $DATE
week: W$WEEK
agent: Синхронизатор
---

# Отчёт планировщика: $DATE

"

    local tl_result tl_emoji tl_label tl_issues
    tl_result=$(compute_traffic_light)
    tl_emoji=$(echo "$tl_result" | cut -d'|' -f1)
    tl_label=$(echo "$tl_result" | cut -d'|' -f2)
    tl_issues=$(echo "$tl_result" | cut -d'|' -f3)

    report+="## $tl_emoji $tl_label

"
    if [ "$tl_issues" != "нет" ]; then
        report+="> **Замечания:** $tl_issues

"
    fi

    report+="## Результаты

| # | Задача | Статус | Время |
|---|--------|--------|-------|"

    # 1. Code-scan
    local cs_time
    if cs_time=$(check_ran "synchronizer-code-scan"); then
        report+="
| 1 | Сканирование кода | **✅** | $cs_time |"
    else
        report+="
| 1 | Сканирование кода | **❌** | — |"
    fi

    # 2. Стратег утренний
    local sm_time
    if sm_time=$(check_ran "strategist-morning"); then
        report+="
| 2 | Стратег утренний | **✅** | $sm_time |"
    else
        report+="
| 2 | Стратег утренний | **❌** | — |"
    fi

    # 3. Note-review (после 22:00)
    if (( 10#$HOUR >= 22 )); then
        local nr_time
        if nr_time=$(check_ran "strategist-note-review"); then
            report+="
| 3 | Разбор заметок | **✅** | $nr_time |"
        else
            report+="
| 3 | Разбор заметок | **❌** | — |"
        fi
    fi

    # 4. Week-review (Пн)
    if [ "$DOW" = "1" ]; then
        local wr_time
        if wr_time=$(check_ran_week "strategist-week-review"); then
            report+="
| 4 | Обзор недели | **✅** | $wr_time |"
        else
            report+="
| 4 | Обзор недели | **❌** | — |"
        fi
    fi

    # 5. Экстрактор inbox-check
    local ic_detail
    if ic_detail=$(check_interval "extractor-inbox-check"); then
        report+="
| 5 | Проверка входящих | **✅** | $ic_detail |"
    else
        report+="
| 5 | Проверка входящих | **❌** | — |"
    fi

    report+="

"

    # Ошибки
    report+="## Ошибки и предупреждения
"
    local warnings=""
    if [ -f "$SCHEDULER_LOG" ]; then
        warnings=$(grep -E "WARN:|ERROR:|failed" "$SCHEDULER_LOG" 2>/dev/null | sed 's/^/- /' || true)
    fi

    if [ -n "$warnings" ]; then
        report+="
$warnings

**Что делать:**
"
        if echo "$warnings" | grep -q "push failed" 2>/dev/null; then
            report+="- **push failed:** Mac был оффлайн. Запусти \`cd {{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}} && git pull --rebase && git push\`
"
        fi
    else
        report+="
Нет ошибок. ✅
"
    fi

    echo "$report"
}

archive_old_reports() {
    mkdir -p "$ARCHIVE_DIR"
    local count=0
    for old_report in "$REPORT_DIR"/SchedulerReport\ 20*.md; do
        [ -f "$old_report" ] || continue
        local basename
        basename=$(basename "$old_report")
        [[ "$basename" == *"$DATE"* ]] && continue
        git -C "$COMMIT_DIR" mv "$old_report" "$ARCHIVE_DIR/" 2>/dev/null || mv "$old_report" "$ARCHIVE_DIR/"
        log "Archived: $basename"
        count=$((count + 1))
    done
}

# === Main ===

log "=== Daily Report Started ==="

REPORT=$(generate_report)

if [ "$DRY_RUN" = true ]; then
    echo "$REPORT"
    log "DRY RUN — отчёт не записан"
else
    echo "$REPORT" > "$REPORT_FILE"
    log "Report written: $REPORT_FILE"

    cd "$COMMIT_DIR"
    # Staging Isolation: stash → pull → pop → reset → add only own files
    # Without stash, pull --rebase fails when Claude sessions leave unstaged changes
    stash_count_before=""
    stash_count_after=""
    stash_count_before=$(git stash list 2>/dev/null | wc -l)
    git stash -u --quiet 2>/dev/null || true
    git pull --rebase --quiet 2>/dev/null || log "WARN: pull --rebase failed (offline?)"
    stash_count_after=$(git stash list 2>/dev/null | wc -l)
    if [ "$stash_count_after" -gt "$stash_count_before" ]; then
        git stash pop --quiet 2>/dev/null || log "WARN: stash pop failed"
    fi
    git reset --quiet 2>/dev/null || true

    archive_old_reports

    for p in "${COMMIT_ADD_PATHS[@]}"; do
        git add "$p" 2>/dev/null || true
    done

    if ! git diff --cached --quiet 2>/dev/null; then
        git commit -m "auto: scheduler report $DATE" --quiet
        git push --quiet 2>/dev/null || log "WARN: push failed"
        log "Committed and pushed"
    else
        log "No changes to commit"
    fi
fi

log "=== Daily Report Completed ==="
