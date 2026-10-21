#!/bin/bash
# daily-report.sh — daily scheduler activity report scheduler
#
# Generates a report: what was supposed to fire, what did fire, what did not.
#
# If DS-agent-workspace/ exists → writes there (scheduler/reports/).
# Otherwise → DS-strategy/current/ (backward compatibility).
#
# Usage:
#   daily-report.sh           # generate report for today
#   daily-report.sh --dry-run # show report, do not write

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="$HOME/.local/state/exocortex"
LOG_DIR="$HOME/logs/synchronizer"
# WP-273 0.29.4 R6.1 fix (issue #271): runtime-resolve instead of build-time placeholders — as in strategist.sh.
STRATEGY_DIR="${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}"

# Agent Workspace: if it exists — reports go there
AGENT_WORKSPACE="${IWE_WORKSPACE:-$HOME/IWE}/DS-agent-workspace"
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
STRATEGIST_LOG="$HOME/logs/strategist/$DATE.log"

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
        echo "${ago} sec ago"
        return 0
    fi
    return 1
}

compute_traffic_light() {
    local color="GREEN"
    local issues=""

    if ! check_ran "synchronizer-code-scan" &>/dev/null; then
        color="RED"
        issues+="code-scan did not start; "
    fi

    if (( 10#$HOUR >= 6 )) && ! check_ran "strategist-morning" &>/dev/null; then
        color="RED"
        issues+="strategist morning did not start; "
    fi

    if [ -f "$SCHEDULER_LOG" ] && grep -q "push failed" "$SCHEDULER_LOG" 2>/dev/null; then
        if [ "$color" = "GREEN" ]; then color="YELLOW"; fi
        issues+="push failed (Mac offline?); "
    fi

    if [ "$DOW" = "1" ] && ! check_ran_week "strategist-week-review" &>/dev/null; then
        if [ "$color" = "GREEN" ]; then color="YELLOW"; fi
        issues+="week-review did not start (Mon!); "
    fi

    local emoji label
    case "$color" in
        GREEN)  emoji="🟢"; label="Environment ready" ;;
        YELLOW) emoji="🟡"; label="Environment running with warnings" ;;
        RED)    emoji="🔴"; label="Critical failure — attention required" ;;
    esac

    echo "$emoji|$label|${issues:-none}"
}

generate_report() {
    local report=""

    report+="---
type: scheduler-report
date: $DATE
week: W$WEEK
agent: Synchronizer
---

# Scheduler report: $DATE

"

    local tl_result tl_emoji tl_label tl_issues
    tl_result=$(compute_traffic_light)
    tl_emoji=$(echo "$tl_result" | cut -d'|' -f1)
    tl_label=$(echo "$tl_result" | cut -d'|' -f2)
    tl_issues=$(echo "$tl_result" | cut -d'|' -f3)

    report+="## $tl_emoji $tl_label

"
    if [ "$tl_issues" != "none" ]; then
        report+="> **Warnings:** $tl_issues

"
    fi

    report+="## Results

| # | Task | Status | Time |
|---|--------|--------|-------|"

    # 1. Code-scan
    local cs_time
    if cs_time=$(check_ran "synchronizer-code-scan"); then
        report+="
| 1 | Code scan | **✅** | $cs_time |"
    else
        report+="
| 1 | Code scan | **❌** | — |"
    fi

    # 2. Morning strategist
    local sm_time
    if sm_time=$(check_ran "strategist-morning"); then
        report+="
| 2 | Morning strategist | **✅** | $sm_time |"
    else
        report+="
| 2 | Morning strategist | **❌** | — |"
    fi

    # The note-review row and its traffic-light check are gone: the scheduler no longer runs
    # note-review (template owner's decision, July 2026), so a missing marker is not a failure.

    # 3. Week-review (Mon)
    if [ "$DOW" = "1" ]; then
        local wr_time
        if wr_time=$(check_ran_week "strategist-week-review"); then
            report+="
| 3 | Week review | **✅** | $wr_time |"
        else
            report+="
| 3 | Week review | **❌** | — |"
        fi
    fi

    # 4. Extractor inbox-check
    local ic_detail
    if ic_detail=$(check_interval "extractor-inbox-check"); then
        report+="
| 4 | Inbox check | **✅** | $ic_detail |"
    else
        report+="
| 4 | Inbox check | **❌** | — |"
    fi

    report+="

"

    # Errors
    report+="## Errors and warnings
"
    local warnings=""
    if [ -f "$SCHEDULER_LOG" ]; then
        warnings=$(grep -E "WARN:|ERROR:|failed" "$SCHEDULER_LOG" 2>/dev/null | sed 's/^/- /' || true)
    fi

    if [ -n "$warnings" ]; then
        report+="
$warnings

**What to do:**
"
        if echo "$warnings" | grep -q "push failed" 2>/dev/null; then
            report+="- **push failed:** Mac was offline. Run \`cd $STRATEGY_DIR && git pull --rebase && git push\`
"
        fi
    else
        report+="
No errors. ✅
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
    log "DRY RUN — report not written"
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
