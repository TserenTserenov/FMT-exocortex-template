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
    # `|| true`: a transient failure writing $LOG_FILE (seen live: macOS
    # "Operation not permitted" on a handful of runs, cause unconfirmed) must
    # not kill the whole run under `set -e` — every headless caller of this
    # script treats extractor failure as best-effort, not fatal, and this is
    # only the logger, not the work itself.
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE" 2>/dev/null || true
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
    # WP-5 Ф46: subscription token saved by scripts/connect.sh lives in its own
    # 600-mode file (add-secret.sh convention), not in ENV_FILE. An explicit
    # env var (launchd plist, shell) still wins over the file.
    local token_file="$HOME/.secrets/claude_code_oauth_token"
    if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -f "$token_file" ]; then
        CLAUDE_CODE_OAUTH_TOKEN="$(<"$token_file")"
        export CLAUDE_CODE_OAUTH_TOKEN
    fi
}

# AI_CLI may be overridden to a non-Claude CLI (see strategist.sh) — then
# Claude auth checks and hints are meaningless.
ai_cli_is_claude() {
    [ "$AI_CLI" = "$CLAUDE_PATH" ]
}

# WP-5 Ф46: preflight before any headless run. `claude auth status` is the
# vendor's own answer to "is any login configured?" (env token, API key,
# keychain on macOS, credentials file) — no API call, exit 1 when nothing is
# set up. Without it an unauthenticated run dies deep inside run_claude with a
# generic "AI CLI failed" that a regular user never reads.
check_auth() {
    ai_cli_is_claude || return 0
    local status_out
    if status_out=$("$AI_CLI" auth status --json 2>&1); then
        return 0
    fi
    log "ERROR: проверка входа Claude Code не прошла — headless-запуск невозможен. Ответ 'claude auth status': $(printf '%s' "$status_out" | tr -s '[:space:]' ' ')"
    log "Если это не сетевой/временный сбой, а подписка правда не подключена: bash \$IWE_TEMPLATE/roles/extractor/scripts/connect.sh"
    return 1
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
        # WP-5 Ф46: an expired/revoked subscription token is the most likely
        # cause (TTL is undocumented, seen live) and would otherwise drown in
        # the generic failure above. Live wording of the CLI error:
        # "Failed to authenticate. API Error: 401 OAuth access token is invalid."
        if ai_cli_is_claude && tail -n 20 "$LOG_FILE" | \
           grep -qiE "failed to authenticate|\b401\b|invalid.?api.?key|unauthorized|not logged in|token is (invalid|expired|revoked)"; then
            log "ERROR: похоже, токен подписки протух или отозван. Переподключите: bash \$IWE_TEMPLATE/roles/extractor/scripts/connect.sh"
        fi
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

# WP-5 Ф48 follow-up (found live 02.09 on the first real test run after the
# origin/main-alignment fix above): the shared pre-commit hook's Scope gate
# (session-guard.sh pre-commit-check) refuses any new/modified path that
# isn't registered under an active session semaphore. This was invisible
# before today because the origin/main equality check always fired first and
# the commit never reached this hook. extractor runs headless with no
# interactive session open, so it needs its own lightweight housekeeping
# semaphore -- the exact pattern session-guard.sh's own note-file error
# message documents, and the one already used by process-runner.py's
# terminal-card auto-commit (bug-2026-08-21-process-runner-auto-commit-
# scope-gate.md). Registration is repo-relative (scope_has_path compares
# plain strings from `git diff --cached --name-only`), so it stays valid
# through publish_commit's own cherry-pick in a separate disposable worktree
# -- close only after publish, not right after the local commit.
extractor_scope_open_and_note() {  # <strategy_dir> <agent> <reason> <changed-paths (newline-separated, repo-relative)>
    local strategy_dir="$1" agent="$2" reason="$3" changed_paths="$4"
    local guard="${IWE_SCRIPTS:-$HOME/IWE/scripts}/session-guard.sh"
    [ -x "$guard" ] || return 1
    bash "$guard" open --housekeeping "$reason" --agent "$agent" >> "$LOG_FILE" 2>&1 || return 1
    local rel
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        bash "$guard" note-file "$strategy_dir/$rel" --agent "$agent" >> "$LOG_FILE" 2>&1 \
            || log "WARN: note-file failed for $rel ($agent/$reason) — commit may still be blocked by the Scope gate"
    done <<< "$changed_paths"
    return 0
}

extractor_scope_close() {  # <strategy_dir> <agent> <reason>
    local strategy_dir="$1" agent="$2" reason="$3"
    local guard="${IWE_SCRIPTS:-$HOME/IWE/scripts}/session-guard.sh"
    [ -x "$guard" ] || return 0
    bash "$guard" close --housekeeping "$reason" --agent "$agent" >> "$LOG_FILE" 2>&1
}

# issue #633: 'main' used to be hardcoded as the governance repo's default
# branch in eight places across this file. A repo whose real default branch
# is something else (e.g. master) silently never got fetched/pushed/read --
# inbox-check exited immediately on every run, no capture ever processed.
# Resolve it once per repo, in order: explicit override -> the repo's real
# remote-tracking default -> whatever is currently checked out -> the
# historical 'main' default as a last resort (keeps old repos working
# unchanged).
resolve_governance_branch() {
    local repo="$1"
    if [ -n "${IWE_GOVERNANCE_BRANCH:-}" ]; then
        printf '%s\n' "$IWE_GOVERNANCE_BRANCH"
        return 0
    fi
    local ref
    if ref=$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null); then
        printf '%s\n' "${ref#origin/}"
        return 0
    fi
    if ref=$(git -C "$repo" branch --show-current 2>/dev/null) && [ -n "$ref" ]; then
        printf '%s\n' "$ref"
        return 0
    fi
    printf '%s\n' "main"
}

commit_extractor_changes() {
    local strategy_dir="$1"
    local repo_name="$2"
    local commit_mode="${3:-main}"
    local branch head_before head_after target_changes gov_branch

    EXTRACTOR_COMMIT_RESULT=""

    if ! branch=$(git -C "$strategy_dir" branch --show-current 2>/dev/null); then
        log "WARN: cannot determine branch for $repo_name; skipping commit"
        EXTRACTOR_COMMIT_RESULT="blocked"
        return 0
    fi
    gov_branch=$(resolve_governance_branch "$strategy_dir")
    if [ "$branch" != "$gov_branch" ] && \
       { [ "$commit_mode" != "isolated-inbox" ] || [[ "$branch" != extractor/inbox-check-* ]]; }; then
        log "SKIP: $repo_name is on branch '$branch', expected '$gov_branch'"
        EXTRACTOR_COMMIT_RESULT="blocked"
        return 0
    fi

    # WP-5 Ф48: no longer requires HEAD == origin/main before attempting a
    # commit. That equality check made every commit fail on a busy day --
    # origin/main routinely advances during the 2-8 minute Claude analysis
    # window (dozens of concurrent sessions publishing elsewhere), so by the
    # time this function runs the worktree is "stale" by definition, even
    # though the extractor's own paths (inbox/captures*, inbox/extraction-
    # reports/*) never touch the same lines as unrelated WP work. Staleness
    # is now handled downstream by publish_commit (fetch + cherry-pick onto
    # fresh origin/main + bounded retry, scripts/lib/publish-gate.sh) instead
    # of being refused upfront.
    if ! head_before=$(git -C "$strategy_dir" rev-parse HEAD 2>/dev/null); then
        log "WARN: cannot resolve HEAD for $repo_name; skipping commit"
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
       [ "$head_after" != "$head_before" ]; then
        log "SKIP: $repo_name changed before extractor commit"
        EXTRACTOR_COMMIT_RESULT="blocked"
        return 0
    fi

    # WP-5 Ф48 review fix: derive the paths to register from $target_changes
    # (porcelain output, so every entry is a real file that exists right now)
    # instead of a static guess list. The static list silently skipped a path
    # via `[ -e ... ] || continue` on a repo/run where e.g. inbox/captures/
    # didn't exist yet -- reintroducing the exact Scope-gate block this whole
    # function exists to avoid, with no warning.
    local changed_paths
    changed_paths=$(awk '{print substr($0, 4)}' <<< "$target_changes")

    local scope_agent="extractor" scope_reason="commit-$$" scope_opened=0
    if extractor_scope_open_and_note "$strategy_dir" "$scope_agent" "$scope_reason" "$changed_paths"; then
        scope_opened=1
    else
        log "WARN: cannot open housekeeping session-guard session for $repo_name; commit may be blocked by the pre-commit Scope gate"
    fi

    # `git commit --only` does not discover a brand-new report directory. Stage only
    # extractor-owned paths; `--only` below still leaves every foreign staged path intact.
    if ! git -C "$strategy_dir" add -- inbox/captures.md inbox/captures/ inbox/extraction-reports/ >> "$LOG_FILE" 2>&1; then
        log "WARN: cannot stage extractor changes for $repo_name"
        EXTRACTOR_COMMIT_RESULT="failed"
        [ "$scope_opened" -eq 1 ] && extractor_scope_close "$strategy_dir" "$scope_agent" "$scope_reason"
        return 1
    fi

    if ! git -C "$strategy_dir" commit --only \
        -m "inbox-check: extraction report $DATE" -- \
        inbox/captures.md inbox/captures/ inbox/extraction-reports/ >> "$LOG_FILE" 2>&1; then
        log "WARN: git commit failed for $repo_name"
        EXTRACTOR_COMMIT_RESULT="failed"
        [ "$scope_opened" -eq 1 ] && extractor_scope_close "$strategy_dir" "$scope_agent" "$scope_reason"
        return 1
    fi

    if ! head_after=$(git -C "$strategy_dir" rev-parse HEAD 2>/dev/null) || \
       [ "$head_after" = "$head_before" ]; then
        log "WARN: commit did not advance HEAD for $repo_name"
        EXTRACTOR_COMMIT_RESULT="failed"
        [ "$scope_opened" -eq 1 ] && extractor_scope_close "$strategy_dir" "$scope_agent" "$scope_reason"
        return 1
    fi
    log "Committed $repo_name ($head_after)"

    # WP-5 Ф48: publish through the shared coordination gate instead of a raw
    # fast-forward-only push. ds-publish.sh/isolate-push.sh fetches fresh
    # origin/main, cherry-picks this commit's patch onto it in a disposable
    # worktree, and pushes -- the same mechanism day-open/day-close/
    # peer-conversation already rely on for exactly this class of race. The
    # housekeeping registration above stays open through this step (its
    # repo-relative paths cover the cherry-picked commit too, not just this
    # worktree's own) and is closed once, right after, regardless of outcome.
    local publish_gate="$strategy_dir/scripts/lib/publish-gate.sh"
    if [ ! -f "$publish_gate" ]; then
        log "WARN: publish-gate.sh not found at $publish_gate; falling back to raw push for $repo_name"
        if git -C "$strategy_dir" push origin "$head_after:refs/heads/$gov_branch" >> "$LOG_FILE" 2>&1; then
            log "Pushed $repo_name ($head_after)"
            EXTRACTOR_COMMIT_RESULT="published"
        else
            log "WARN: git push failed; only the extractor commit was offered"
            EXTRACTOR_COMMIT_RESULT="failed"
        fi
        [ "$scope_opened" -eq 1 ] && extractor_scope_close "$strategy_dir" "$scope_agent" "$scope_reason"
        [ "$EXTRACTOR_COMMIT_RESULT" = "published" ] && return 0 || return 1
    fi
    # shellcheck source=/dev/null
    . "$publish_gate"

    # ds-publish.sh resolves its own IWE_WORKSPACE from the environment
    # (LOCK_FILE/QUEUE_DIR/canon-refresh paths), not from the $strategy_dir
    # argument. run_inbox_check_isolated() exports IWE_WORKSPACE pointing at
    # its own throwaway sandbox for run_claude's benefit -- ds-publish.sh must
    # not inherit that; it needs the real canonical workspace.
    if is_ds_repo_by_origin "$strategy_dir" \
        && IWE_WORKSPACE="${IWE_ROOT:-$HOME/IWE}" \
           publish_commit "$strategy_dir" "$head_after" normal "extractor $commit_mode $DATE" >> "$LOG_FILE" 2>&1; then
        log "Published $repo_name via ds-publish.sh (local commit $head_after)"
        EXTRACTOR_COMMIT_RESULT="published"
    elif ! is_ds_repo_by_origin "$strategy_dir" && push_branch "$strategy_dir" >> "$LOG_FILE" 2>&1; then
        log "Pushed $repo_name ($head_after)"
        EXTRACTOR_COMMIT_RESULT="published"
    else
        log "WARN: publish failed for $repo_name — commit stays local, см. $LOG_FILE"
        EXTRACTOR_COMMIT_RESULT="failed"
    fi
    [ "$scope_opened" -eq 1 ] && extractor_scope_close "$strategy_dir" "$scope_agent" "$scope_reason"
    [ "$EXTRACTOR_COMMIT_RESULT" = "published" ] && return 0 || return 1
}

release_inbox_lock() {  # <lock_dir> [label]
    local lock_dir="$1" label="${2:-inbox-check}"
    rm -f "$lock_dir/pid"
    rmdir "$lock_dir" 2>/dev/null || log "WARN: cannot release $label lock: $lock_dir"
}

acquire_inbox_lock() {  # <lock_dir> [label]
    local lock_dir="$1" label="${2:-inbox-check}"
    local owner_pid=""

    if mkdir "$lock_dir" 2>/dev/null; then
        printf '%s\n' "$$" > "$lock_dir/pid"
        return 0
    fi

    if [ -f "$lock_dir/pid" ]; then
        owner_pid=$(tr -d '[:space:]' < "$lock_dir/pid")
    fi
    if [[ "$owner_pid" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
        log "SKIP: $label is already running (pid $owner_pid)"
        return 1
    fi

    # Only reclaim a lock whose recorded process has ended. A non-empty or malformed
    # directory stays blocked instead of risking deletion of another active run.
    if [ -n "$owner_pid" ]; then
        rm -f "$lock_dir/pid"
        if ! rmdir "$lock_dir" 2>/dev/null; then
            log "SKIP: stale $label lock needs manual review: $lock_dir"
            return 1
        fi
        if mkdir "$lock_dir" 2>/dev/null; then
            printf '%s\n' "$$" > "$lock_dir/pid"
            log "WARN: reclaimed stale $label lock from pid $owner_pid"
            return 0
        fi
    fi

    log "SKIP: $label lock is unavailable: $lock_dir"
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

    # Read-only Pack clones (see mount_readonly_packs()) are chmod a-w
    # recursively, including the directories themselves -- removing entries
    # from a directory needs write permission on that directory, so restore
    # it (owner-only, u+w) before rm -rf, or cleanup silently fails and the
    # final rmdir below leaves the whole run_root behind as a "cannot remove"
    # WARN forever.
    local pack_clone
    for pack_clone in "$isolated_workspace"/PACK-*; do
        [ -d "$pack_clone" ] || continue
        chmod -R u+w "$pack_clone" 2>/dev/null
        rm -rf "$pack_clone"
    done

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

# AR-gate 03.09 (архгейт, см. bug-2026-07-07-r15-decisions-bypassed-pilot.md):
# inbox-check.md never writes into a Pack -- headless steps only ever vote
# accept/reject/defer into the report, the actual write happens exclusively
# in the separate, pilot-triggered "Применение отчёта" session. Mounting
# Packs here only lets the headless vote be an informed one (duplicate/
# bounded-context checks Step 2d already requires) instead of blanket defer
# for "not mounted". Read-only is enforced by the filesystem (chmod), not
# prompt wording -- run_claude launches Claude with
# --dangerously-skip-permissions and Write/Edit in --allowedTools, so a
# prompt-only "don't write here" instruction is not a real control (the
# exact class of gap the cited bug found in a different skill). Each Pack
# gets its own disposable shallow clone, never the live checkout, so even a
# stray write attempt lands on a throwaway copy, not shared state other
# sessions might be editing concurrently.
mount_readonly_packs() {
    local canonical_workspace="$1"
    local isolated_workspace="$2"
    local pack_dir pack_name
    for pack_dir in "$canonical_workspace"/PACK-*; do
        [ -d "$pack_dir/.git" ] || continue
        pack_name=$(basename "$pack_dir")
        if git clone -q --depth 1 --no-tags "$pack_dir" "$isolated_workspace/$pack_name" >> "$LOG_FILE" 2>&1; then
            chmod -R a-w "$isolated_workspace/$pack_name"
            log "Mounted read-only Pack for duplicate-check: $pack_name"
        else
            log "WARN: could not clone $pack_name for read-only mount; inbox-check will see it as absent"
        fi
    done
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
    local run_root worktree isolated_workspace branch_name run_id isolated_template actual_pending gov_branch

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

    gov_branch=$(resolve_governance_branch "$canonical_repo")
    if ! git -C "$canonical_repo" fetch origin "$gov_branch" >> "$LOG_FILE" 2>&1; then
        log "WARN: cannot refresh origin/$gov_branch; isolated inbox-check was not started"
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

    if ! git -C "$canonical_repo" worktree add -b "$branch_name" "$worktree" "origin/$gov_branch" >> "$LOG_FILE" 2>&1; then
        log "WARN: cannot create isolated inbox-check worktree; run directory preserved: $run_root"
        release_inbox_lock "$lock_dir"
        return 1
    fi
    git -C "$worktree" branch --set-upstream-to="origin/$gov_branch" "$branch_name" >> "$LOG_FILE" 2>&1 || true

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

    mount_readonly_packs "$canonical_workspace" "$isolated_workspace"

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
            # WP-5 Ф48: no ls-remote SHA check here anymore. publish_commit
            # routes through ds-publish.sh/isolate-push.sh, which cherry-picks
            # this worktree's commit onto a fresh origin/main in its own
            # disposable worktree -- the SHA that lands on origin is a new one
            # (different parent), so comparing it against EXTRACTOR_PUBLISHED_SHA
            # would always mismatch. ds-publish.sh already confirms its own
            # push before returning 0; commit_extractor_changes() only sets
            # EXTRACTOR_COMMIT_RESULT=published after that 0.
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

# Показ usage (без аргумента/-h) не требует входа — только реальные команды ниже.
if [ -n "${1:-}" ] && [ "$1" != "-h" ] && [ "$1" != "--help" ]; then
    check_auth || exit 1
fi

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
        #
        # WP-5 follow-up (02.09): quick-close's own handler (session-close-
        # feeder.sh) now launches this call as a detached background job
        # instead of waiting synchronously -- multiple session closes can fire
        # in quick succession without one blocking on the other's completion.
        # Without a lock they'd race writing the same monthly captures.md.
        feed_lock_dir="${IWE_EXTRACTOR_FEED_LOCK_DIR:-${TMPDIR:-/tmp}/iwe-extractor-session-close-feed.lock}"
        if ! acquire_inbox_lock "$feed_lock_dir" "session-close-feed"; then
            exit 0
        fi
        # Cold-context review (02.09): under this file's `set -e`, run_claude
        # failing (exit 1 on a missing prompt file, or its own `return 1` on
        # an AI CLI failure -- a live, not hypothetical, case per its own
        # WP-5 Ф46 comment) aborted the script before release_inbox_lock ever
        # ran, leaving the lock held by a now-dead PID until the next call's
        # stale-reclaim path. Not a permanent deadlock, but a genuine
        # concurrent run in between was wrongly told "already running", with
        # nothing reported. The trap covers every exit path uniformly.
        trap 'release_inbox_lock "$feed_lock_dir" "session-close-feed"' EXIT
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
