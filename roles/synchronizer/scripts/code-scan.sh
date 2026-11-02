#!/bin/bash
# code-scan.sh — nightly scan of Downstream repos (activity statistics)
#
# Walks the downstream repositories, collects commits for the last 24h,
# logs the activity.
#
# Usage:
#   code-scan.sh           # scan all downstream repos
#   code-scan.sh --dry-run # show what it finds, do not write
#
# Trigger: scheduler.sh dispatch (daily)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# WP-273 0.29.4 R6.1 fix (issue #271): runtime resolve instead of build-time {{WORKSPACE_DIR}} — as in strategist.sh.
WORKSPACE="${IWE_WORKSPACE:-$HOME/IWE}"
LOG_DIR="$HOME/logs/synchronizer"
DATE=$(date +%Y-%m-%d)
LOG_FILE="$LOG_DIR/code-scan-$DATE.log"

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [code-scan] $1" | tee -a "$LOG_FILE"
}

# === Downstream repo discovery ===

discover_repos() {
    local repos=()

    # Governance repo — excluded from scanning
    local exclude=(
        "${IWE_GOVERNANCE_REPO:-DS-strategy}"
    )

    for dir in "$WORKSPACE"/DS-*/; do
        [ -d "$dir/.git" ] || continue
        local name
        name=$(basename "$dir")
        local skip=false
        for ex in "${exclude[@]}"; do
            [ "$name" = "$ex" ] && skip=true && break
        done
        [ "$skip" = true ] && continue
        repos+=("$dir")
    done

    printf '%s\n' "${repos[@]}"
}

# === Main loop ===

scan_repos() {
    local total_repos=0
    local total_commits=0

    while IFS= read -r repo_dir; do
        repo_dir="${repo_dir%/}"
        local repo_name
        repo_name=$(basename "$repo_dir")

        local commits
        commits=$(git -C "$repo_dir" log --since="24 hours ago" --oneline --no-merges 2>/dev/null || true)

        if [ -z "$commits" ]; then
            log "SKIP: $repo_name — нет коммитов за 24ч"
            continue
        fi

        local count
        count=$(echo "$commits" | wc -l | tr -d ' ')
        log "FOUND: $repo_name — $count коммитов"

        total_repos=$((total_repos + 1))
        total_commits=$((total_commits + count))

    done < <(discover_repos)

    log "Итого: $total_repos репо, $total_commits коммитов"

    # Telegram notification
    if [ "$DRY_RUN" = false ] && [ "$total_repos" -gt 0 ]; then
        "$SCRIPT_DIR/notify.sh" synchronizer code-scan 2>/dev/null || true
    fi
}

log "=== Code Scan Started ==="
scan_repos
log "=== Code Scan Completed ==="
