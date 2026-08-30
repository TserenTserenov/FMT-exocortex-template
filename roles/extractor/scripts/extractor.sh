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

# Guard: сырой файл в FMT-exocortex-template никогда не подставляет плейсхолдеры
# (build-runtime.sh подставляет их только в собранную копию под .iwe-runtime/).
# Запуск отсюда напрямую тихо создаёт директории с буквальным именем "{{HOME_DIR}}"
# (bug-2026-07-02-home-dir-placeholder-literal-directory.md).
case "$SCRIPT_DIR" in
    */FMT-exocortex-template/roles/extractor/scripts)
        echo "FATAL: extractor.sh запущен из сырого шаблона FMT-exocortex-template — плейсхолдеры не подставлены." >&2
        echo "  Используй собранную копию: \$IWE_RUNTIME/roles/extractor/scripts/extractor.sh" >&2
        exit 1
        ;;
esac

# WP-273 0.29.4 R6.1 fix (issue #271): runtime-резолв вместо build-time {{WORKSPACE_DIR}} — как в strategist.sh.
WORKSPACE="${IWE_WORKSPACE:-$HOME/IWE}"

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

LOG_DIR="$HOME/logs/extractor"
if [ -n "${CLAUDE_CLI_PATH:-}" ]; then
    CLAUDE_PATH="$CLAUDE_CLI_PATH"
elif command -v claude &>/dev/null; then
    CLAUDE_PATH="$(command -v claude)"
elif [ -x "$HOME/.local/bin/claude" ]; then
    CLAUDE_PATH="$HOME/.local/bin/claude"
elif [ -x "$HOME/.npm-global/bin/claude" ]; then
    CLAUDE_PATH="$HOME/.npm-global/bin/claude"
else
    CLAUDE_PATH="{{CLAUDE_PATH}}"  # fallback: build-runtime должен был подставить
fi
if [ ! -x "$CLAUDE_PATH" ]; then
    echo "[$(date '+%H:%M:%S')] ERROR: claude CLI не найден (CLAUDE_CLI_PATH/PATH/~/.local/bin/~/.npm-global/fallback='$CLAUDE_PATH')." >&2
    exit 127
fi
ENV_FILE="$HOME/.config/aist/env"

# AI CLI: переопределение через переменные окружения (см. strategist.sh)
AI_CLI="${AI_CLI:-$CLAUDE_PATH}"
AI_CLI_PROMPT_FLAG="${AI_CLI_PROMPT_FLAG:--p}"
AI_CLI_EXTRA_FLAGS="${AI_CLI_EXTRA_FLAGS:---dangerously-skip-permissions --allowedTools Read,Write,Edit,Glob,Grep,Bash}"

# issue #17: load NOTIFY_SH_PATH from params.yaml if not already set in environment
if [ -z "${NOTIFY_SH_PATH:-}" ]; then
    _params="${IWE_WORKSPACE:-$HOME/IWE}/params.yaml"
    if [ -f "$_params" ]; then
        _notify_val=$(grep -E '^notify_sh_path:' "$_params" | sed 's/^notify_sh_path:[[:space:]]*//;s/^"//;s/"$//;s/^'"'"'//;s/'"'"'$//' | tr -d '[:space:]')
        [ -n "$_notify_val" ] && export NOTIFY_SH_PATH="$_notify_val"
    fi
fi

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
    # issue #17: NOTIFY_SH_PATH override for Linux/Docker (set in params.yaml or .exocortex.env)
    if [ -n "${NOTIFY_SH_PATH:-}" ] && [ -x "$NOTIFY_SH_PATH" ]; then
        "$NOTIFY_SH_PATH" "$title" "$message" 2>/dev/null || true
    else
        # macOS: osascript, Linux: notify-send, fallback: silent
        printf 'display notification "%s" with title "%s"' "$message" "$title" | osascript 2>/dev/null \
            || notify-send "$title" "$message" 2>/dev/null \
            || true
    fi
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
    local extra_args="${2:-}"
    local commit_mode="${3:-main}"
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
    if ! "$AI_CLI" $AI_CLI_EXTRA_FLAGS \
        $AI_CLI_PROMPT_FLAG "$prompt" \
        >> "$LOG_FILE" 2>&1; then
        log "ERROR: AI CLI failed for $command_file"
        return 1
    fi

    log "Completed process: $command_file"

    # Commit + push changes (отчёты, помеченные captures)
    local strategy_dir="$WORKSPACE/${IWE_GOVERNANCE_REPO:-DS-strategy}"

    if git -C "$strategy_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        # WP-429 Ф6.5: пре-фильтры на новых extraction-reports ДО commit — advisory,
        # не блокирует (WP-429 паттерн: детектор предлагает, не правит; решение по
        # находке — R15 на /apply-captures). Только реально новые (untracked) отчёты
        # этого прогона, не весь каталог — иначе шумит на старых уже прошедших отчётах.
        local prefilter_script="$SCRIPT_DIR/wp429-extractor-prefilters.py"
        if [ -f "$prefilter_script" ] && command -v python3 >/dev/null 2>&1; then
            local new_report
            for new_report in $(git -C "$strategy_dir" ls-files --others --exclude-standard -- inbox/extraction-reports/ 2>/dev/null); do
                python3 "$prefilter_script" --report "$strategy_dir/$new_report" >> "$LOG_FILE" 2>&1 \
                    && log "Pre-filters clean: $new_report" \
                    || log "Pre-filters found signals (advisory): $new_report — см. $LOG_FILE"
            done
        fi

        if ! commit_extractor_changes "$strategy_dir" "$_gov_repo" "$commit_mode"; then
            return 1
        fi
    fi

    # macOS notification
    notify "KE: $command_file" "Процесс завершён"
}

commit_extractor_changes() {
    local strategy_dir="$1"
    local repo_name="$2"
    local commit_mode="${3:-main}"
    local branch head_before origin_before head_after origin_after target_changes

    EXTRACTOR_COMMIT_RESULT=""
    EXTRACTOR_PUBLISHED_SHA=""

    if ! branch=$(git -C "$strategy_dir" branch --show-current 2>/dev/null); then
        log "WARN: cannot determine branch for $repo_name; skipping commit"
        EXTRACTOR_COMMIT_RESULT="blocked"
        return 0
    fi
    if [ "$branch" != "main" ] && \
       { [ "$commit_mode" != "isolated-inbox" ] || [[ "$branch" != extractor/inbox-check-* ]]; }; then
        log "SKIP: $repo_name is on branch '$branch', expected 'main'"
        EXTRACTOR_COMMIT_RESULT="blocked"
        return 0
    fi

    if ! head_before=$(git -C "$strategy_dir" rev-parse HEAD 2>/dev/null) || \
       ! origin_before=$(git -C "$strategy_dir" rev-parse origin/main 2>/dev/null); then
        log "WARN: cannot resolve HEAD or origin/main for $repo_name; skipping commit"
        EXTRACTOR_COMMIT_RESULT="blocked"
        return 0
    fi
    if [ "$head_before" != "$origin_before" ]; then
        log "SKIP: $repo_name is not aligned with origin/main; skipping commit"
        EXTRACTOR_COMMIT_RESULT="blocked"
        return 0
    fi

    # Не трогаем файлы экстрактора, если их уже подготовил другой процесс.
    # `commit --only` сохраняет staging всех остальных путей без ручного reset.
    if ! git -C "$strategy_dir" diff --cached --quiet -- \
        inbox/captures.md inbox/captures/ inbox/extraction-reports/; then
        log "SKIP: extractor paths are already staged; skipping commit"
        EXTRACTOR_COMMIT_RESULT="blocked"
        return 0
    fi

    target_changes=$(git -C "$strategy_dir" status --porcelain --untracked-files=all -- \
        inbox/captures.md inbox/captures/ inbox/extraction-reports/)
    if [ -z "$target_changes" ]; then
        log "No new changes to commit in $repo_name"
        EXTRACTOR_COMMIT_RESULT="no_changes"
        return 0
    fi

    if ! head_after=$(git -C "$strategy_dir" rev-parse HEAD 2>/dev/null) || \
       ! origin_after=$(git -C "$strategy_dir" rev-parse origin/main 2>/dev/null) || \
       [ "$head_after" != "$head_before" ] || [ "$origin_after" != "$origin_before" ]; then
        log "SKIP: $repo_name changed before extractor commit"
        EXTRACTOR_COMMIT_RESULT="blocked"
        return 0
    fi

    # `git commit --only` does not discover a brand-new report directory. Stage only
    # extractor-owned paths; `--only` below still leaves every foreign staged path intact.
    if ! git -C "$strategy_dir" add -- inbox/captures.md inbox/captures/ inbox/extraction-reports/ >> "$LOG_FILE" 2>&1; then
        log "WARN: cannot stage extractor changes for $repo_name"
        EXTRACTOR_COMMIT_RESULT="failed"
        return 1
    fi

    if ! git -C "$strategy_dir" commit --only \
        -m "inbox-check: extraction report $DATE" -- \
        inbox/captures.md inbox/captures/ inbox/extraction-reports/ >> "$LOG_FILE" 2>&1; then
        log "WARN: git commit failed for $repo_name"
        EXTRACTOR_COMMIT_RESULT="failed"
        return 1
    fi

    if ! head_after=$(git -C "$strategy_dir" rev-parse HEAD 2>/dev/null) || \
       [ "$head_after" = "$head_before" ]; then
        log "WARN: commit did not advance HEAD for $repo_name"
        EXTRACTOR_COMMIT_RESULT="failed"
        return 1
    fi
    log "Committed $repo_name"

    if git -C "$strategy_dir" push origin "$head_after:refs/heads/main" >> "$LOG_FILE" 2>&1; then
        log "Pushed $repo_name"
        EXTRACTOR_COMMIT_RESULT="published"
        EXTRACTOR_PUBLISHED_SHA="$head_after"
    else
        log "WARN: git push failed; only the extractor commit was offered"
        EXTRACTOR_COMMIT_RESULT="failed"
        return 1
    fi
}

release_inbox_lock() {
    local lock_dir="$1"
    rm -f "$lock_dir/pid"
    rmdir "$lock_dir" 2>/dev/null || log "WARN: cannot release inbox-check lock: $lock_dir"
}

acquire_inbox_lock() {
    local lock_dir="$1"
    local owner_pid=""

    if mkdir "$lock_dir" 2>/dev/null; then
        printf '%s\n' "$$" > "$lock_dir/pid"
        return 0
    fi

    if [ -f "$lock_dir/pid" ]; then
        owner_pid=$(tr -d '[:space:]' < "$lock_dir/pid")
    fi
    if [[ "$owner_pid" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
        log "SKIP: inbox-check is already running (pid $owner_pid)"
        return 1
    fi

    # Only reclaim a lock whose recorded process has ended. A non-empty or malformed
    # directory stays blocked instead of risking deletion of another active run.
    if [ -n "$owner_pid" ]; then
        rm -f "$lock_dir/pid"
        if ! rmdir "$lock_dir" 2>/dev/null; then
            log "SKIP: stale inbox-check lock needs manual review: $lock_dir"
            return 1
        fi
        if mkdir "$lock_dir" 2>/dev/null; then
            printf '%s\n' "$$" > "$lock_dir/pid"
            log "WARN: reclaimed stale inbox-check lock from pid $owner_pid"
            return 0
        fi
    fi

    log "SKIP: inbox-check lock is unavailable: $lock_dir"
    return 1
}

cleanup_isolated_inbox_worktree() {
    local canonical_repo="$1"
    local worktree="$2"
    local branch_name="$3"
    local isolated_workspace="$4"
    local repo_name="$5"
    local run_root="$6"

    if ! git -C "$canonical_repo" worktree remove "$worktree" >> "$LOG_FILE" 2>&1; then
        log "WARN: published inbox-check worktree was preserved after cleanup failure: $worktree"
        return 1
    fi

    if ! git -C "$canonical_repo" branch -d "$branch_name" >> "$LOG_FILE" 2>&1; then
        log "WARN: published inbox-check branch was preserved for review: $branch_name"
    fi

    rm -f "$isolated_workspace/$repo_name" \
        "$isolated_workspace/FMT-exocortex-template/roles/extractor/config/routing.md" \
        "$isolated_workspace/FMT-exocortex-template/roles/extractor/prompts/session-close.md"
    rmdir "$isolated_workspace/FMT-exocortex-template/roles/extractor/config" 2>/dev/null || true
    rmdir "$isolated_workspace/FMT-exocortex-template/roles/extractor/prompts" 2>/dev/null || true
    rmdir "$isolated_workspace/FMT-exocortex-template/roles/extractor" 2>/dev/null || true
    rmdir "$isolated_workspace/FMT-exocortex-template/roles" 2>/dev/null || true
    rmdir "$isolated_workspace/FMT-exocortex-template" 2>/dev/null || true
    rmdir "$isolated_workspace" 2>/dev/null || log "WARN: cannot remove isolated workspace shell: $isolated_workspace"
    rmdir "$run_root" 2>/dev/null || log "WARN: cannot remove isolated run directory: $run_root"
}

pending_capture_count() {
    # Accepts one or more capture files; awk accumulates pending across all.
    awk '
      /^### / && !/\[(analyzed|processed|duplicate|defer)/ {
        found = 0
        for (i = 1; i <= 8; i++) {
          if ((getline line) > 0) {
            if (line ~ /^\*\*(Источник|Type|Тип|Source|Маркер|Trigger)/) { found = 1; break }
            if (line ~ /^### |^## /) break
          }
        }
        if (found) pending++
      }
      END { print pending+0 }
    ' "$@" 2>/dev/null
}

# WP-526 rotation: capture sources = legacy captures.md + monthly
# inbox/captures/YYYY-MM.md files (whitelist by name, other files in the
# directory are not inbox material).
capture_source_files() {
    local inbox_dir="$1"
    [ -f "$inbox_dir/captures.md" ] && printf '%s\n' "$inbox_dir/captures.md"
    if [ -d "$inbox_dir/captures" ]; then
        find "$inbox_dir/captures" -maxdepth 1 -type f \
            -name '[0-9][0-9][0-9][0-9]-[0-9][0-9].md' | sort
    fi
}

run_inbox_check_isolated() {
    local canonical_workspace="$WORKSPACE"
    local repo_name="${IWE_GOVERNANCE_REPO:-DS-strategy}"
    local canonical_repo="$canonical_workspace/$repo_name"
    local lock_dir="${IWE_EXTRACTOR_INBOX_LOCK_DIR:-${TMPDIR:-/tmp}/iwe-extractor-inbox-check.lock}"
    local run_root worktree isolated_workspace branch_name run_id isolated_template remote_sha actual_pending

    case "$repo_name" in
        ""|.*|*/*)
            log "ERROR: unsafe governance repository name for isolated inbox-check: '$repo_name'"
            return 1
            ;;
    esac
    if ! git -C "$canonical_repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        log "ERROR: governance repository is unavailable for isolated inbox-check: $canonical_repo"
        return 1
    fi
    if ! acquire_inbox_lock "$lock_dir"; then
        return 0
    fi

    if ! git -C "$canonical_repo" fetch origin main >> "$LOG_FILE" 2>&1; then
        log "WARN: cannot refresh origin/main; isolated inbox-check was not started"
        release_inbox_lock "$lock_dir"
        return 1
    fi

    run_root=$(mktemp -d "${TMPDIR:-/tmp}/iwe-extractor-inbox-check.XXXXXX") || {
        log "ERROR: cannot create isolated inbox-check directory"
        release_inbox_lock "$lock_dir"
        return 1
    }
    run_id="$(date +%Y%m%d%H%M%S)-$$"
    worktree="$run_root/$repo_name"
    isolated_workspace="$run_root/workspace"
    branch_name="extractor/inbox-check-$run_id"
    isolated_template="${IWE_TEMPLATE:-$canonical_workspace/FMT-exocortex-template}"

    if ! git -C "$canonical_repo" worktree add -b "$branch_name" "$worktree" origin/main >> "$LOG_FILE" 2>&1; then
        log "WARN: cannot create isolated inbox-check worktree; run directory preserved: $run_root"
        release_inbox_lock "$lock_dir"
        return 1
    fi
    git -C "$worktree" branch --set-upstream-to=origin/main "$branch_name" >> "$LOG_FILE" 2>&1 || true

    if ! mkdir "$isolated_workspace" || \
       ! ln -s "$worktree" "$isolated_workspace/$repo_name" || \
       ! [ -d "$isolated_template" ] || \
       ! mkdir -p "$isolated_workspace/FMT-exocortex-template/roles/extractor/config" \
           "$isolated_workspace/FMT-exocortex-template/roles/extractor/prompts" || \
       ! cp "$isolated_template/roles/extractor/config/routing.md" \
           "$isolated_workspace/FMT-exocortex-template/roles/extractor/config/routing.md" || \
       ! cp "$isolated_template/roles/extractor/prompts/session-close.md" \
           "$isolated_workspace/FMT-exocortex-template/roles/extractor/prompts/session-close.md"; then
        log "WARN: cannot prepare isolated inbox-check workspace; worktree preserved: $worktree"
        release_inbox_lock "$lock_dir"
        return 1
    fi

    local capture_sources=()
    while IFS= read -r src; do
        capture_sources+=("$src")
    done < <(capture_source_files "$worktree/inbox")
    actual_pending=0
    if [ "${#capture_sources[@]}" -gt 0 ]; then
        actual_pending=$(pending_capture_count "${capture_sources[@]}")
    fi
    actual_pending=${actual_pending:-0}
    if [ "$actual_pending" -le 0 ]; then
        log "SKIP: No pending captures in refreshed inbox"
        cleanup_isolated_inbox_worktree "$canonical_repo" "$worktree" "$branch_name" \
            "$isolated_workspace" "$repo_name" "$run_root" || true
        release_inbox_lock "$lock_dir"
        return 0
    fi
    log "Found $actual_pending pending captures in refreshed inbox"

    local WORKSPACE="$isolated_workspace"
    local IWE_WORKSPACE="$isolated_workspace"
    local AI_CLI_EXTRA_FLAGS="${IWE_EXTRACTOR_INBOX_AI_FLAGS:---dangerously-skip-permissions --allowedTools Read,Write,Edit,Glob,Grep}"
    export IWE_WORKSPACE
    if ! run_claude "inbox-check" "" "isolated-inbox"; then
        log "WARN: isolated inbox-check failed; worktree preserved for review: $worktree"
        release_inbox_lock "$lock_dir"
        return 1
    fi

    case "${EXTRACTOR_COMMIT_RESULT:-}" in
        published)
            remote_sha=$(git -C "$canonical_repo" ls-remote origin refs/heads/main 2>/dev/null | awk 'NR == 1 { print $1 }')
            if [ "$remote_sha" != "$EXTRACTOR_PUBLISHED_SHA" ]; then
                log "WARN: remote main did not confirm extractor commit; worktree preserved: $worktree"
                release_inbox_lock "$lock_dir"
                return 1
            fi
            cleanup_isolated_inbox_worktree "$canonical_repo" "$worktree" "$branch_name" \
                "$isolated_workspace" "$repo_name" "$run_root" || true
            ;;
        no_changes)
            cleanup_isolated_inbox_worktree "$canonical_repo" "$worktree" "$branch_name" \
                "$isolated_workspace" "$repo_name" "$run_root" || true
            ;;
        *)
            log "WARN: isolated inbox-check did not reach a safe publication state; worktree preserved: $worktree"
            release_inbox_lock "$lock_dir"
            return 1
            ;;
    esac

    release_inbox_lock "$lock_dir"
}

# Проверка рабочих часов
is_work_hours() {
    local hour
    hour=$(date +%H)
    [ "$hour" -ge 7 ] && [ "$hour" -le 23 ]
}

# Загружаем env
load_env

# launchd загружает минимальное окружение. Совместимость сохранена для старого
# GOVERNANCE_REPO, но все последующие пути используют единое имя репозитория.
if [ -z "${IWE_GOVERNANCE_REPO:-}" ]; then
    IWE_GOVERNANCE_REPO="${GOVERNANCE_REPO:-DS-strategy}"
    export IWE_GOVERNANCE_REPO
fi

# Определяем процесс
case "$1" in
    "inbox-check")
        if ! is_work_hours; then
            log "SKIP: inbox-check outside work hours ($HOUR:00)"
            exit 0
        fi

        run_inbox_check_isolated
        notify_telegram "inbox-check"
        ;;

    "audit")
        log "Running knowledge audit"
        run_claude "knowledge-audit" ""
        notify_telegram "audit"
        ;;

    "session-close")
        log "Running session-close extraction"
        run_claude "session-close" ""
        ;;

    "session-close-feed")
        # WP-247 Ф-MULTI-SOURCE.1: feeder-режим (non-interactive).
        # Извлекает кандидатов из транскрипта + git diff,
        # пишет ###-блоки в помесячный inbox/captures/YYYY-MM.md (ротация
        # WP-526; без ротации — в captures.md) с маркером [feed:session-close].
        # Не создаёт extraction-report — это работа inbox-check потом.
        log "Running session-close FEED (non-interactive, writes to captures inbox)"
        run_claude "session-close-feed" "${2:-}"
        notify_telegram "session-close-feed"
        ;;

    "git-diff-feed")
        # WP-247 Ф-MULTI-SOURCE.2: git-diff feeder (cron 06:00/21:00).
        # Извлекает кандидатов из git log за окно и пишет ###-блоки в captures-inbox.
        # Окно: $2 (по умолчанию "12 hours ago").
        SINCE="${2:-12 hours ago}"
        log "Running git-diff FEED (since: $SINCE)"
        run_claude "git-diff-feed" "$SINCE"
        notify_telegram "git-diff-feed"
        ;;

    "on-demand")
        log "Running on-demand extraction"
        run_claude "on-demand" ""
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
