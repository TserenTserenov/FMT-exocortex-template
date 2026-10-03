#!/bin/bash
# Strategist (Стратег) Agent Runner
# Запускает Claude Code с заданным сценарием

set -e

# issue #657: this script needs more than one independent EXIT cleanup (kill
# the sleep inhibitor below; release acquire_lock()'s owner links
# further down) — plain `trap ... EXIT` only keeps the LAST
# handler registered for a signal, so the second one silently replaced the
# first on every ordinary run, not just on kill -9/orphaning as first
# suspected. Register cleanups here instead of calling `trap` directly.
_EXIT_CLEANUPS=()
add_exit_cleanup() {
    _EXIT_CLEANUPS+=("$1")
}
run_exit_cleanups() {
    local cmd
    for cmd in "${_EXIT_CLEANUPS[@]}"; do
        eval "$cmd" 2>/dev/null || true
    done
}
# Bash may keep running after SIGINT while a foreground child returns; turn
# interruption into an exit so the composed EXIT cleanup releases this run's
# links and the scheduler can retry instead of inheriting an occupied lock.
trap 'exit 130' INT
trap 'exit 143' TERM
trap run_exit_cleanups EXIT

# Sleep inhibitor for the WHOLE script lifetime (issue #553: direct launchd
# units invoke this script bypassing scheduler.sh, so the inhibitor must live
# here too — parity with roles/synchronizer/scripts/scheduler.sh).
# macOS: caffeinate -diu (idle+display+user; works on battery; -s is NOT used —
# it is ignored on battery power). `-w $$` ties the inhibitor to this shell
# process, which stays alive for the entire scenario incl. the commit→push tail.
# Known OS limit: lid-close on battery cannot be held by caffeinate at all
# (-s works on AC only) — schedule night runs on AC or with the lid open.
# Linux: systemd-inhibit when available; direct systemd timers do not inhibit
# sleep by themselves. `timeout 4h` around `sleep infinity` is a second line
# of defense on top of the EXIT trap above (issue #657): a parent killed with
# SIGKILL or reaped by init before bash processes the trap leaves the trap
# unrun no matter how it is composed — bash cannot catch SIGKILL. Bounding
# the held process itself is the only thing that guarantees it cannot
# outlive a single scenario run indefinitely.
if [[ "$(uname)" == "Darwin" ]]; then
    caffeinate -diu -w $$ &
elif command -v systemd-inhibit &>/dev/null; then
    systemd-inhibit --what=idle:sleep --who=strategist --why="agent scenario" --mode=block \
        timeout 4h sleep infinity &
    _INHIBIT_PID=$!
    add_exit_cleanup 'kill $_INHIBIT_PID 2>/dev/null'
fi

# Конфигурация
# WP-273 R5 fix (Round 5 Евгения): substituted runner живёт в .iwe-runtime/,
# но prompts/ и notify.sh — read-only данные, должны браться из FMT (immutable upstream).
# Архитектурный принцип: substituted в runtime, read-only из FMT через $IWE_TEMPLATE.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# WP-273 0.29.4 R6.1 fix: было хардкоженое имя governance-репо.
# На Mac: build-runtime подставляет плейсхолдеры в .iwe-runtime/strategist.sh.
# На сервере (без build-runtime): резолвится через env vars с fallback.
# IWE_WORKSPACE / IWE_GOVERNANCE_REPO задаются в /etc/iwe/env или ~/.config/aist/env.
WORKSPACE="${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}"

# Guard: IWE_GOVERNANCE_REPO mismatch (Claude peer-review, 2026-05-26)
# WP-529 Ф94 (peer-session 2026-09-08-32, Evgenii's report): $HOME/.iwe-paths
# is a legacy path install-iwe-paths.sh stopped writing (canonical file is
# $WORKSPACE_DIR/.iwe-paths, see WORKSPACE above). Read the current path, and
# read it without a pipe: `grep|sed || echo` masked grep's exit code behind
# sed's (sed exits 0 on empty stdin), so the "|| echo DS-strategy" fallback
# never fired and EXPECTED_GOV silently ended up empty instead.
IWE_PATHS_FILE="${IWE_WORKSPACE:-$HOME/IWE}/.iwe-paths"
# `|| true` guards against awk's own exit code (e.g. file not found) tripping
# `set -e` on this assignment — not a pipe, so no exit-code-masking risk;
# the value fallback below is the actual default, this only keeps the script
# alive to reach it.
EXPECTED_GOV=$(awk -F'"' '/^export IWE_GOVERNANCE_REPO=/{print $2; exit}' "$IWE_PATHS_FILE" 2>/dev/null || true)
EXPECTED_GOV="${EXPECTED_GOV:-DS-strategy}"
if [ "${IWE_GOVERNANCE_REPO:-}" ] && [ "$IWE_GOVERNANCE_REPO" != "$EXPECTED_GOV" ]; then
    echo "WARN: IWE_GOVERNANCE_REPO=$IWE_GOVERNANCE_REPO, expected $EXPECTED_GOV (from $IWE_PATHS_FILE)" >&2
fi

# WP-529 F6 (Evgenii post-update defect #1, 18.08): update.sh reinstalls
# auto-roles while .update-incomplete is still present (the transaction closes
# at the very end), and launchctl load fires RunAtLoad right away — a mutating
# agent run started mid-update at 22:38. Defer every scenario with a temporary
# failure so the scheduler does not mark it done (#1029). The next scheduled
# run picks it up. Template root is resolved as
# $IWE_TEMPLATE first, then ${IWE_WORKSPACE:-$HOME/IWE}/FMT-exocortex-template
# (NOT identical to the PROMPTS_DIR fallback below, which hardcodes $HOME/IWE).
UPDATE_MARKER="${IWE_TEMPLATE:-${IWE_WORKSPACE:-$HOME/IWE}/FMT-exocortex-template}/.update-incomplete"
if [ -f "$UPDATE_MARKER" ]; then
    echo "[$(date '+%H:%M:%S')] BLOCKED: template update incomplete ($UPDATE_MARKER present) — no mutating run; finish or repair update.sh, then retry" >&2
    exit 75
fi

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
# На Mac: build-runtime подставляет {{CLAUDE_PATH}}. На сервере — резолв через env/PATH/known paths.
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
CLAUDE_TIMEOUT=1800  # 30 мин — защита от зависания Claude CLI

# AI CLI: переопределение через переменные окружения (см. extractor.sh)
AI_CLI="${AI_CLI:-$CLAUDE_PATH}"
AI_CLI_PROMPT_FLAG="${AI_CLI_PROMPT_FLAG:--p}"

# AR.293: гейт проверяет эффективную программу ($AI_CLI), не литерал CLAUDE_PATH —
# иначе override остаётся декоративным, когда claude физически отсутствует, но
# AI_CLI указывает на реально установленную другую программу.
if ! command -v "$AI_CLI" >/dev/null 2>&1 && [ ! -x "$AI_CLI" ]; then
    echo "[$(date '+%H:%M:%S')] ERROR: $AI_CLI CLI не найден (AI_CLI/CLAUDE_CLI_PATH/PATH/~/.local/bin/~/.npm-global/fallback='$AI_CLI')." >&2
    exit 127
fi

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
# issue #616: "первый Пн месяца" — календарная арифметика, не факт даты;
# LLM однажды вывела её из головы и ошиблась (последний Пн августа принят за
# первый Пн сентября). Считаем детерминированно здесь и передаём как готовый
# факт (тот же принцип, что DAY_OF_WEEK ниже) — модели больше не нужно её
# выводить самой.
IS_FIRST_MONDAY_OF_MONTH="нет"
if [ "$DAY_OF_WEEK" = "1" ] && [ "$(date +%d)" -le 7 ]; then
    IS_FIRST_MONDAY_OF_MONTH="да"
fi

# Лог файл
LOG_FILE="$LOG_DIR/$DATE.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Picks the publisher for publish_commit_or_explain: sets PUBLISHER (empty = none installed) and
# PUBLISHER_BRANCH_ARG (the value for --branch, empty = call without it). Candidates, in order:
# $WORKSPACE/scripts/ds-publish.sh, then <fallback repo>/scripts/ds-publish.sh. A target branch goes
# only to a publisher that knows --branch: update.sh never replaces an existing scripts/ds-publish.sh
# (an installation's own publisher, or a seed copy delivered before --branch existed), and such a
# publisher answers an unknown --branch with usage, exit 1. "Knows" is judged by the file's text (a
# heuristic): an argument-parsing branch for the option, a line that starts with a case pattern such
# as --branch), -b|--branch) or --branch=*). A comment, a usage text or `git status --branch` does not
# count. A miss (a wrapper that hands "$@" on) is safe, the publisher runs as before --branch existed;
# a false hit is not, hence the narrow match. The publication block of the strategy-session skill uses
# the same expression. When no candidate knows --branch, the first existing one runs without it.
PUBLISHER=""
PUBLISHER_BRANCH_ARG=""
pick_publisher() {  # <target branch, empty = the publisher's default> <fallback repo, empty = none>
    local target_branch="$1" fallback_repo="$2" candidate
    PUBLISHER=""
    PUBLISHER_BRANCH_ARG=""
    for candidate in "$WORKSPACE/scripts/ds-publish.sh" "${fallback_repo:+$fallback_repo/scripts/ds-publish.sh}"; do
        [ -f "$candidate" ] || continue
        [ -n "$PUBLISHER" ] || PUBLISHER="$candidate"
        [ -n "$target_branch" ] || return 0
        if grep -qE -e '^[[:space:]]*[(]?([^|)#[:space:]]+[[:space:]]*[|][[:space:]]*)*"?--branch(=[^|)[:space:]]*)?"?[[:space:]]*[|)]' "$candidate"; then
            PUBLISHER="$candidate"
            PUBLISHER_BRANCH_ARG="$target_branch"
            return 0
        fi
    done
    return 0
}

# Publish one commit via scripts/ds-publish.sh. The script is not shipped with
# the template (issue #884, regression of WP-7 Ф101): when it is absent, say so
# and keep the commit local instead of failing on a bare "No such file".
# Returns 0 only when the publisher reported success.
# The optional 5th argument names the branch on origin to publish to; empty = the
# publisher's default (the branch checked out in $WORKSPACE). An isolated copy sits on
# a local-only branch, so isolated_finish names the branch the copy was created from.
# The optional 6th argument is a repo whose scripts/ds-publish.sh runs when $WORKSPACE has
# none: update.sh puts the publisher into the canon's working tree without a commit
# (backfill_ds_publish), so a copy made from origin/main of an upgraded install lacks it.
# The publisher still publishes $WORKSPACE. Which publisher runs, and whether it gets
# --branch: pick_publisher. A publisher that had to run without the wanted --branch gets the
# replacement advice only in the refusal message: a successful run logs nothing extra.
PUBLISH_LAST_RC=""
publish_commit_or_explain() {
    local reason="$1" sha="$2" ok_msg="$3" fail_msg="$4" target_branch="${5:-}" fallback_repo="${6:-}"
    local prc=0 advice=""

    PUBLISH_LAST_RC=""
    pick_publisher "$target_branch" "$fallback_repo"
    if [ -z "$PUBLISHER" ]; then
        log "WARN: scripts/ds-publish.sh не установлен${fallback_repo:+ (нет ни в копии, ни в $fallback_repo)} — коммит ${sha:0:12} остался локальным и не опубликован. Запустите update.sh: он доставляет публикатор в репозиторий управления. Или опубликуйте вручную: git -C \"$WORKSPACE\" push origin HEAD${target_branch:+:$target_branch}"
        return 1
    fi
    set -- "$WORKSPACE" normal --reason "$reason" --from-commit "$sha"
    [ -z "$PUBLISHER_BRANCH_ARG" ] || set -- "$@" --branch "$PUBLISHER_BRANCH_ARG"
    bash "$PUBLISHER" "$@" >> "$LOG_FILE" 2>&1 || prc=$?
    if [ "$prc" -eq 0 ]; then
        log "$ok_msg"
        return 0
    fi
    PUBLISH_LAST_RC="$prc"  # WP-530 Ф72: the isolated path passes the publisher's own status on
    if [ -n "$target_branch" ] && [ -z "$PUBLISHER_BRANCH_ARG" ]; then
        advice=" (публикатор $PUBLISHER вызван без --branch $target_branch: по тексту файла он не знает --branch — старая копия шаблона или собственный публикатор установки; если отказ из-за этого, замените scripts/ds-publish.sh в репозитории управления версией шаблона seed/strategy/scripts/ds-publish.sh)"
    fi
    log "$fail_msg$advice"
    return 1
}

notify() {
    local title="$1"
    local message="$2"
    printf 'display notification "%s" with title "%s"' "$message" "$title" | osascript 2>/dev/null \
        || notify-send "$title" "$message" 2>/dev/null \
        || true
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

# WP-561 Ф25: a scenario that must deliver a document proves it on origin/main, not by the
# CLI exit code. 28.09: week-review wrote WeekReport/WeekPlan, could not commit (the commit
# guard refused its session), was logged "SUCCESS", sent the "завершён" message and marked the
# day done -- the pilot learned of it from the model's own last lines.
# Proof: origin/main taken before the run is an ancestor of origin/main after it, and the
# range between them changes the scenario's exact expected path.
# Known limit: without a run id in the commit this cannot tell THIS run's commit from a
# foreign one that touches the same file -- the exact path keeps that window narrow.
DELIVERY_POSTCONDITION_RC=70
WEEK_REVIEW_MAX_FAILED_RUNS=2
WEEK_REVIEW_EXHAUSTED_RC=76  # scheduler suppresses further automatic runs today; never weekly done

expected_delivery_path() {  # <scenario> -> :(glob) pathspec in the governance repo, empty = none
    case "$1" in
        week-review) echo 'current/WeekReport W*' ;;
    esac
}

# Bounded and prompt-free: an unattended run must not hang on the network or on a credential
# prompt. Assumes a remote named `origin` and a default branch `main` (the publish step below
# assumes the same); a repo without them gets no baseline and the run is reported as unproven,
# which is loud rather than silently green.
# Retries absorb the short outages that hit a job with no rerun (weekly, 00:00): a baseline lost to
# a blip would turn a delivered report into a false "cannot prove". Worst case per call is about
# 105 s (3 x 30 s + 5 s + 10 s), and the call runs twice per scenario, before and after the model.
# It runs inside $(...) (see delivery_baseline), so it writes to the log file directly and never
# through log(), whose stdout would end up in the captured sha; the fetch's own stdout is discarded.
# DELIVERY_GIT_BIN is a test seam for this one fetch: the publisher and the guard keep the real git.
# DELIVERY_FETCH_{ATTEMPTS,TIMEOUT,PAUSE} override the defaults (3, 30 s, 5 s). Each is checked on its
# own: a bad value falls back to that default and leaves the others alone. Plain decimal digits only,
# at most four, and no leading zero (bash would read 010 as octal, and 09 as an arithmetic error that
# ends the script). Zero is valid for the pause only (no waiting; the test suite relies on it).
fetch_delivery_origin() {
    local attempts="${DELIVERY_FETCH_ATTEMPTS:-3}" per_try="${DELIVERY_FETCH_TIMEOUT:-30}" pause="${DELIVERY_FETCH_PAUSE:-5}"
    local n=1 rc
    case "$attempts" in ''|0*|*[!0-9]*|?????*) attempts=3 ;; esac
    case "$per_try" in ''|0*|*[!0-9]*|?????*) per_try=30 ;; esac
    case "$pause" in ''|0?*|*[!0-9]*|?????*) pause=5 ;; esac
    while :; do
        rc=0
        GIT_TERMINAL_PROMPT=0 timeout "$per_try" "${DELIVERY_GIT_BIN:-git}" -C "$WORKSPACE" fetch -q origin main >/dev/null 2>>"$LOG_FILE" || rc=$?
        [ "$rc" -eq 0 ] && return 0
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] GIT-FETCH: попытка $n из $attempts не удалась (код $rc)" >> "$LOG_FILE"
        [ "$n" -lt "$attempts" ] || return 1
        sleep $((pause * n))
        n=$((n + 1))
    done
}

delivery_baseline() {  # <scenario> -> origin/main sha before the run; empty = no contract or origin not freshly read
    [ -n "$(expected_delivery_path "$1")" ] || return 0
    # A failed fetch must NOT fall back to the old local origin/main: a stale baseline would let
    # an earlier report commit pass as this run's delivery.
    fetch_delivery_origin || return 0
    git -C "$WORKSPACE" rev-parse origin/main 2>/dev/null || true
}

verify_delivery_postcondition() {  # <scenario> <origin/main sha before the run>; 0 = delivered or none required
    local scenario="$1" pre_origin="$2" spec post_origin existing
    spec=$(expected_delivery_path "$scenario")
    [ -n "$spec" ] || return 0
    if [ -z "$pre_origin" ]; then
        log "POSTCONDITION scenario: $scenario -- origin/main перед запуском прочитать не удалось (нужны remote origin и ветка main, сеть), доставку проверить нельзя"
        return 1
    fi
    if ! fetch_delivery_origin; then
        log "POSTCONDITION scenario: $scenario -- git fetch не удался (нужны remote origin и ветка main, сеть), доставку проверить нельзя"
        return 1
    fi
    post_origin=$(git -C "$WORKSPACE" rev-parse origin/main 2>/dev/null) || post_origin=""
    if [ -z "$post_origin" ] || ! git -C "$WORKSPACE" merge-base --is-ancestor "$pre_origin" "$post_origin" 2>/dev/null; then
        log "POSTCONDITION scenario: $scenario -- origin/main не продолжает состояние до запуска (${pre_origin:0:12} не предок ${post_origin:0:12}): расхождение или force-push"
        return 1
    fi
    # ACMRT: a deletion of the report file is a change, not a delivery.
    if [ -z "$(git -C "$WORKSPACE" diff --name-only --diff-filter=ACMRT "$pre_origin" "$post_origin" -- ":(glob)$spec")" ]; then
        log "POSTCONDITION scenario: $scenario -- за запуск на origin/main не появилось созданного или изменённого файла '$spec': отчёт не доставлен"
        # The proof is per run, on purpose: a report that was already there is not this run's work
        # (an empty stub or last week's file would otherwise pass). A rerun after an earlier delivery
        # still fails here, so name what IS there -- the reader can tell a false alarm at a glance.
        # diff against the empty tree: the same pathspec semantics as the delivery check above
        # (ls-tree reads its paths differently and would miss the glob).
        existing=$(git -C "$WORKSPACE" diff --name-only "$(git -C "$WORKSPACE" hash-object -t tree /dev/null)" "$post_origin" -- ":(glob)$spec" 2>/dev/null | tr '\n' ';')
        [ -z "$existing" ] || log "POSTCONDITION scenario: $scenario -- на origin/main уже есть, без изменений за этот запуск: ${existing%;}"
        return 1
    fi
    return 0
}

# WP-561 Ф25: a scenario whose result is committed under the session guard gets a session owned by
# THIS script, opened as a scheduled runner (--canonical-owner: on a frozen checkout only that mode
# may open a housekeeping session). The guard's scope gate does not look at who commits: a live
# semaphore covering a path authorises it, so the model needs no session of its own and cannot
# invent one (28.09: `--wp week-review-w39`). A housekeeping semaphore has no wp and is skipped by
# the commit barrier: it grants rights, it never blocks anyone.
SESSION_OPEN_FAILED_RC=71
RUNNER_SESSION_OPEN=0
RUNNER_SESSION_CLEANUP_REGISTERED=0
RUNNER_GUARD=""
RUNNER_SESSION_AGENT=""
RUNNER_SESSION_REASON=""

runner_session_scope() {  # <scenario> -> repo-relative path the scenario may commit under; empty = no session
    case "$1" in
        week-review) echo 'current/' ;;
    esac
}

runner_guard_path() {  # -> path of session-guard.sh; empty when this install has none
    local guard="${IWE_SCRIPTS:-}/session-guard.sh"
    [ -f "$guard" ] || guard="${IWE_WORKSPACE:-$HOME/IWE}/scripts/session-guard.sh"
    if [ -f "$guard" ]; then echo "$guard"; fi
    return 0
}

runner_guard() {  # <guard args...>; root and governance repo are explicit: the guard aborts without them
    ( cd "$WORKSPACE" && IWE_ROOT="${IWE_WORKSPACE:-$HOME/IWE}" IWE_GOVERNANCE_REPO="${IWE_GOVERNANCE_REPO:-DS-strategy}" \
        bash "$RUNNER_GUARD" "$@" ) >> "$LOG_FILE" 2>&1
}

close_runner_session() {  # once per open; a failed close is logged and never replaces the run's own exit status
    [ "$RUNNER_SESSION_OPEN" = 1 ] || return 0
    RUNNER_SESSION_OPEN=0
    runner_guard close --housekeeping "$RUNNER_SESSION_REASON" --agent "$RUNNER_SESSION_AGENT" \
        || log "WARN: служебная сессия $RUNNER_SESSION_AGENT не закрыта (см. строки выше); следующий запуск закроет остаток"
    return 0
}

# Hygiene, never a precondition of the new run: close what earlier runs of this scenario left
# behind when they died. A semaphore whose recorded owner pid is still alive belongs to a live run
# (possibly one that started before midnight) and is left alone; a dead owner's is closed by its own
# reason (parsed from the file name). A failed close only means the lease will expire.
# Liveness is `kill -0` only: a pid reused by an unrelated process keeps a leftover alive until the
# guard's lease expires. Accepted -- since open_runner_session selects its own session by slug, such
# a leftover no longer gets in the way of the next run.
close_dead_runner_sessions() {  # <agent> <sessions dir>
    local agent="$1" dir="$2" sem reason pid
    for sem in "$dir/${agent}-housekeeping-"*.open; do
        [ -e "$sem" ] || continue
        pid=$(sed -n 's/^pid: //p' "$sem" 2>/dev/null | head -1)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            continue
        fi
        reason="${sem##*/}"
        reason="${reason#"${agent}-housekeeping-"}"
        reason="${reason%.open}"
        log "SESSION: остаточная сессия $agent/$reason (владелец не жив), закрываю"
        runner_guard close --housekeeping "$reason" --agent "$agent" \
            || log "WARN: остаточную сессию $reason закрыть не удалось, она истечёт по сроку аренды"
    done
}

# 0 = session open, or none required, or this install has no guard at all (old behaviour, WARN).
# 1 = a guard IS installed but did not give the session (refused, or too old to know the mode): the
# run must not start, it could only burn model time and end in a refused commit.
open_runner_session() {  # <scenario>
    local scenario="$1" scope agent reason
    scope=$(runner_session_scope "$scenario")
    [ -n "$scope" ] || return 0
    RUNNER_GUARD=$(runner_guard_path)
    if [ -z "$RUNNER_GUARD" ]; then
        log "WARN: session-guard.sh не найден, сценарий $scenario идёт без сессии охраны"
        return 0
    fi
    agent="strategist-$scenario"
    # The reason names the session file, so it is unique per run: a guard that keeps a closed-session
    # receipt for a name (older installs) would refuse to reopen the same name, and two runs that
    # overlap (one started after midnight while another is still in the model) must not collide.
    reason="$scenario-$DATE-$$"
    close_dead_runner_sessions "$agent" "${IWE_WORKSPACE:-$HOME/IWE}/.iwe-runtime/sessions"
    runner_guard open --housekeeping "$reason" --agent "$agent" --canonical-owner "$scenario" --owner-pid "$$" || return 1
    RUNNER_SESSION_AGENT="$agent"
    RUNNER_SESSION_REASON="$reason"
    RUNNER_SESSION_OPEN=1
    if [ "$RUNNER_SESSION_CLEANUP_REGISTERED" != 1 ]; then
        add_exit_cleanup 'close_runner_session'
        RUNNER_SESSION_CLEANUP_REGISTERED=1
    fi
    # Without the directory the guard records the scope as the literal path `current` (no trailing
    # slash), which covers no file below it.
    mkdir -p "$WORKSPACE/$scope" || { close_runner_session; return 1; }
    # --slug: the guard selects a session by agent, and a second live session of this agent (a run
    # that overlapped midnight, or a leftover whose recorded pid got reused) makes that ambiguous --
    # the guard then refuses and the run would die with exit 71 before the model (cold review, 28.09).
    # A housekeeping semaphore stores its reason as the slug, so the reason selects exactly this one.
    if ! runner_guard note-file "$scope" --agent "$agent" --slug "$reason"; then
        close_runner_session
        return 1
    fi
    log "SESSION: открыта служебная сессия $agent, область $scope"
    return 0
}

# WP-530 Ф72: isolated scenario runs. A scheduled scenario used to write straight into the shared
# (frozen) governance checkout; the isolated mode runs it in a throwaway git worktree of origin/main,
# so the canonical checkout is only read. The model and the deterministic steps write into the copy;
# this script then checks that only the scenario's allowlisted paths changed, commits and publishes
# from the copy (publish_commit_or_explain), and removes the copy only after a publication. On any
# failure the copy is kept for review and the canonical checkout stays untouched.
# Off by default: STRATEGIST_ISOLATED_SCENARIOS is a comma/space list of scenarios (empty = none), so
# nothing changes until the pilot lists a scenario. Only scenarios with an allowlist can be listed
# (today: note-review); listing any other one is refused, never silently run un-isolated.
# Known limit: the model keeps Write/Bash tools and the caller's environment, so the copy isolates
# the runner's paths; it is not a sandbox against a model that writes to absolute canon paths.
ISOLATION_BLOCKED_RC=72
ISOLATED_RUN=0
ISOLATED_PROMPT_WORKSPACE=""
ISOLATED_RESULT=""
ISOLATED_CHANGED=()
ISO_SCENARIO=""
ISO_CANON_REPO=""
ISO_RUN_ROOT=""
ISO_WORKTREE=""
ISO_WORKSPACE=""
ISO_BRANCH=""
ISO_BASE_SHA=""
# The copy is created from origin/$ISO_BASE_BRANCH and its result is published back to it: the copy's
# own branch ($ISO_BRANCH) exists only locally. The value must match the branch fetch_delivery_origin
# refreshes (main, fixed there); change them together.
ISO_BASE_BRANCH="main"

isolation_enabled() {  # <scenario>; 0 = listed in STRATEGIST_ISOLATED_SCENARIOS
    local list=",${STRATEGIST_ISOLATED_SCENARIOS:-},"
    list="${list// /,}"
    case "$list" in *",$1,"*) return 0 ;; esac
    return 1
}

# An allowlist is exact repo-relative paths, so a scenario gets one only where its prompt fixes every
# path it writes (checked against roles/strategist/prompts/, WP-530 Ф72 steps V-D). Scenarios left
# out, and why -- each is refused with rc=72 when listed, never run un-isolated:
#   day-plan     the morning path is only scripts/day-open-pipeline.sh (its own commit/push and state
#                files, not run_claude); the run_claude prompt (manual `strategist.sh day-plan` only)
#                builds its paths from $IWE_WORKSPACE (the canon) and commits/pushes itself, so a copy
#                would not catch its writes.
#   evening      the prompt says only "update the day plan" (which file is not stated).
#   day-close    deprecated prompt: WeekPlan W*.md (dynamic name), MEMORY.md and exocortex/ backup
#                copies of a directory glob (outside the repo or a dynamic file list).
#   session-prep archives files under dynamic names (WeekPlan/WeekReport/DayPlan W{N}/dates, WP-*.md,
#                extraction reports, captures), edits docs/Strategy.md and MEMORY.md.
#   week-review  WeekReport/WeekPlan names carry W{N} and the date; it also writes the Knowledge Index
#                repo and MEMORY.md (outside the copy); and its delivery proof (codes 70/71, the
#                guard session opened on the checkout) runs inside run_claude, before an isolated
#                finish could publish -- it would report 70 on every isolated run.
isolated_allowlist() {  # <scenario> -> repo-relative paths the scenario may change, one per line; empty = none
    case "$1" in
        note-review) printf '%s\n' 'inbox/fleeting-notes.md' 'archive/notes/Notes-Archive.md' ;;
    esac
}

# Sets ISO_* and repoints WORKSPACE at the copy. The prompt workspace is a synthetic directory whose
# <governance repo> entry links to the copy (other repositories are linked for reading history).
isolated_begin() {  # <scenario>; 0 = ready, 1 = not started (canon untouched)
    local scenario="$1" canon="$WORKSPACE" repo_name="${IWE_GOVERNANCE_REPO:-DS-strategy}"
    local run_id repo_dir link_name gov_real repo_real
    if [ -z "$(isolated_allowlist "$scenario")" ]; then
        log "ISOLATION: для сценария $scenario не задан список разрешённых путей — изолированный запуск невозможен, сценарий не запущен"
        return 1
    fi
    case "$repo_name" in
        ""|.*|*/*) log "ISOLATION: небезопасное имя governance-репозитория '$repo_name', сценарий $scenario не запущен"; return 1 ;;
    esac
    if ! git -C "$canon" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        log "ISOLATION: governance-репозиторий недоступен: $canon, сценарий $scenario не запущен"
        return 1
    fi
    if ! fetch_delivery_origin; then
        log "ISOLATION: git fetch origin main не удался, свежую копию взять нельзя, сценарий $scenario не запущен"
        return 1
    fi
    if ! git -C "$canon" rev-parse --verify -q "origin/$ISO_BASE_BRANCH^{commit}" >/dev/null 2>&1; then
        log "ISOLATION: нет origin/$ISO_BASE_BRANCH в $canon, сценарий $scenario не запущен"
        return 1
    fi
    ISO_RUN_ROOT=$(mktemp -d "${STRATEGIST_ISOLATED_TMPDIR:-${TMPDIR:-/tmp}}/iwe-strategist-$scenario.XXXXXX") || {
        log "ISOLATION: не удалось создать каталог изолированного запуска"
        return 1
    }
    run_id="$(date +%Y%m%d%H%M%S)-$$"
    ISO_WORKTREE="$ISO_RUN_ROOT/$repo_name"
    ISO_WORKSPACE="$ISO_RUN_ROOT/workspace"
    ISO_BRANCH="strategist/$scenario-$run_id"
    if ! git -C "$canon" worktree add -b "$ISO_BRANCH" "$ISO_WORKTREE" "origin/$ISO_BASE_BRANCH" >> "$LOG_FILE" 2>&1; then
        log "ISOLATION: не удалось создать рабочую копию от origin/$ISO_BASE_BRANCH, пустой каталог запуска удалён"
        git -C "$canon" worktree prune >> "$LOG_FILE" 2>&1 || true
        rm -rf "$ISO_RUN_ROOT"
        return 1
    fi
    if ! ISO_BASE_SHA=$(git -C "$ISO_WORKTREE" rev-parse HEAD 2>/dev/null) || [ -z "$ISO_BASE_SHA" ]; then
        log "ISOLATION: не удалось определить базовый коммит копии; копия сохранена: $ISO_WORKTREE"
        return 1
    fi
    if ! mkdir "$ISO_WORKSPACE" || ! ln -s "$ISO_WORKTREE" "$ISO_WORKSPACE/$repo_name"; then
        log "ISOLATION: не удалось подготовить рабочее пространство копии; копия сохранена: $ISO_WORKTREE"
        return 1
    fi
    gov_real=$(cd -P "$canon" && pwd -P) || { log "ISOLATION: не удалось определить путь канона; копия сохранена: $ISO_WORKTREE"; return 1; }
    for repo_dir in "$(dirname "$canon")"/*/; do
        repo_dir="${repo_dir%/}"
        link_name="$(basename "$repo_dir")"
        repo_real=$(cd -P "$repo_dir" 2>/dev/null && pwd -P) || continue
        # governance is excluded by identity (an alias symlink would expose the frozen canon for writing)
        [ "$repo_real" = "$gov_real" ] && continue
        [ "$link_name" = "$repo_name" ] && continue
        [ -e "$repo_dir/.git" ] || continue
        ln -s "$repo_dir" "$ISO_WORKSPACE/$link_name" 2>/dev/null || true
    done
    ISO_SCENARIO="$scenario"
    ISO_CANON_REPO="$canon"
    ISOLATED_RESULT=""
    WORKSPACE="$ISO_WORKTREE"
    ISOLATED_PROMPT_WORKSPACE="$ISO_WORKSPACE"
    ISOLATED_RUN=1
    log "ISOLATION: сценарий $scenario идёт в копии $ISO_WORKTREE (ветка $ISO_BRANCH, база ${ISO_BASE_SHA:0:12}), канон $canon только читается"
    return 0
}

# Normalises whatever the model did (own commits, staged files) into plain working-tree changes
# against the base commit, then requires every changed path to be on the scenario's allowlist.
# 0 = allowed (ISOLATED_CHANGED holds the changed paths, possibly none); 1 = blocked.
isolated_verify() {
    local allow entry path p ok violation=0 status_file head_branch
    ISOLATED_CHANGED=()
    if [ "$ISOLATED_RUN" != 1 ] || [ -z "$ISO_BASE_SHA" ]; then
        log "ISOLATION: нет базового коммита копии, публикация заблокирована"
        return 1
    fi
    allow=$(isolated_allowlist "$ISO_SCENARIO")
    if [ -z "$allow" ]; then
        log "ISOLATION: для сценария $ISO_SCENARIO нет списка разрешённых путей, публикация заблокирована"
        return 1
    fi
    head_branch=$(git -C "$WORKSPACE" symbolic-ref --short -q HEAD 2>/dev/null) || head_branch=""
    if [ "$head_branch" != "$ISO_BRANCH" ]; then
        log "ISOLATION: копия сошла с ветки $ISO_BRANCH (сейчас '${head_branch:-detached}'), публикация заблокирована"
        return 1
    fi
    if ! git -C "$WORKSPACE" reset -q --mixed "$ISO_BASE_SHA" >> "$LOG_FILE" 2>&1; then
        log "ISOLATION: не удалось привести копию к базе $ISO_BASE_SHA, публикация заблокирована"
        return 1
    fi
    status_file=$(mktemp "${TMPDIR:-/tmp}/iwe-strategist-status.XXXXXX") || {
        log "ISOLATION: не удалось создать буфер статуса, публикация заблокирована"
        return 1
    }
    if ! git -C "$WORKSPACE" status --porcelain -z --untracked-files=all > "$status_file" 2>> "$LOG_FILE"; then
        rm -f "$status_file"
        log "ISOLATION: git status в копии не удался, публикация заблокирована"
        return 1
    fi
    # Known limit: git-ignored files are invisible to `git status`, so a change to one is neither
    # checked nor published, and it is deleted together with the copy.
    # After the reset the index equals the base, so status has no rename records; an unexpected
    # record would fail the exact-path comparison below and block (fail closed).
    while IFS= read -r -d '' entry; do
        path="${entry:3}"
        ok=0
        while IFS= read -r p; do
            if [ "$p" = "$path" ]; then ok=1; break; fi
        done <<< "$allow"
        if [ "$ok" -eq 0 ]; then
            log "ISOLATION: сценарий $ISO_SCENARIO тронул путь вне списка разрешённых: $path"
            violation=1
        elif [ -L "$WORKSPACE/$path" ]; then
            log "ISOLATION: разрешённый путь стал символической ссылкой (пишет за пределы копии): $path"
            violation=1
        else
            ISOLATED_CHANGED+=("$path")
        fi
    done < "$status_file"
    rm -f "$status_file"
    if [ "$violation" -ne 0 ]; then
        log "ISOLATION: результат нарушает контракт «только разрешённые пути», публикация заблокирована"
        return 1
    fi
    return 0
}

isolated_cleanup() {  # only after a publication (or nothing to publish); a failure keeps the copy
    if ! git -C "$ISO_CANON_REPO" worktree remove "$ISO_WORKTREE" >> "$LOG_FILE" 2>&1; then
        log "WARN: ISOLATION: копия сохранена после сбоя очистки: $ISO_WORKTREE"
        return 1
    fi
    git -C "$ISO_CANON_REPO" branch -D "$ISO_BRANCH" >> "$LOG_FILE" 2>&1 \
        || log "WARN: ISOLATION: ветка $ISO_BRANCH сохранена для проверки"
    find "$ISO_WORKSPACE" -maxdepth 1 -type l -exec rm -f {} + 2>/dev/null || true
    rmdir "$ISO_WORKSPACE" 2>/dev/null || log "WARN: ISOLATION: не удалось убрать $ISO_WORKSPACE"
    rmdir "$ISO_RUN_ROOT" 2>/dev/null || log "WARN: ISOLATION: не удалось убрать $ISO_RUN_ROOT"
    return 0
}

# Verify, commit the allowlisted changes, publish from the copy. Result in ISOLATED_RESULT:
# published | no_changes | blocked. 0 only for published/no_changes; the copy is removed only then.
isolated_finish() {  # <publish reason> <commit message>
    local reason="$1" msg="$2" path sha="" rc=0
    ISOLATED_RESULT="blocked"
    if ! isolated_verify; then
        rc=$ISOLATION_BLOCKED_RC
    elif [ "${#ISOLATED_CHANGED[@]}" -eq 0 ]; then
        ISOLATED_RESULT="no_changes"
    else
        for path in "${ISOLATED_CHANGED[@]}"; do
            git -C "$WORKSPACE" add -- "$path" >> "$LOG_FILE" 2>&1 || rc=$ISOLATION_BLOCKED_RC
        done
        if [ "$rc" -eq 0 ] && git -C "$WORKSPACE" commit -q -m "$msg" >> "$LOG_FILE" 2>&1 \
            && sha=$(git -C "$WORKSPACE" rev-parse HEAD 2>/dev/null) && [ -n "$sha" ]; then
            if publish_commit_or_explain "$reason" "$sha" "Isolated: pushed ${sha:0:12}" "WARN: isolated publish failed — публикация не удалась" "$ISO_BASE_BRANCH" "$ISO_CANON_REPO"; then
                ISOLATED_RESULT="published"
            else
                # The publisher's own status (70/71/...) goes out as is; 72 is only for the
                # isolation checks themselves (and a publisher that never ran).
                rc="${PUBLISH_LAST_RC:-$ISOLATION_BLOCKED_RC}"
            fi
        else
            [ "$rc" -ne 0 ] || log "WARN: ISOLATION: git commit в копии не удался"
            rc=$ISOLATION_BLOCKED_RC
        fi
    fi
    case "$ISOLATED_RESULT" in
        published|no_changes) isolated_cleanup || true ;;
        *) log "ISOLATION: публикации не было, копия сохранена для проверки: $ISO_WORKTREE" ;;
    esac
    WORKSPACE="$ISO_CANON_REPO"
    ISOLATED_PROMPT_WORKSPACE=""
    ISOLATED_RUN=0
    return "$rc"
}

log_size_bytes() {  # -> size of the daily log in bytes, 0 when there is none
    local size=0
    # BSD wc pads with spaces; strip so arithmetic/tail offsets stay sane.
    [ -f "$LOG_FILE" ] && size=$(wc -c < "$LOG_FILE" | tr -d '[:space:]')
    case "$size" in ''|*[!0-9]*) size=0 ;; esac
    echo "$size"
}

# Byte range of the log that holds exactly the output of the last AI_CLI call. run_claude_with_retry
# looks for auth failures only there: the rest of an attempt's log also carries the output of git
# fetch and of the publisher, whose own "401 Unauthorized" would restart a model run that failed
# for another reason. Empty = the last run_claude returned before calling the CLI (a refused guard
# session, exit 71); a missing prompt file ends the script with `exit 1` and never gets this far.
AI_CLI_OUT_START=""
AI_CLI_OUT_END=""

# Issue #1006: the shared helper ships with the template ($IWE_TEMPLATE/scripts/lib); the workspace
# has no scripts/lib on a typical install, so looking only there left calendar_source at "connector"
# for every scenario. Template first, then its default place, then the workspace.
find_common_sh() {
    local _ws="${IWE_WORKSPACE:-$HOME/IWE}" _base
    for _base in "${IWE_TEMPLATE:-}" "$_ws/FMT-exocortex-template" "$_ws"; do
        if [ -n "$_base" ] && [ -f "$_base/scripts/lib/common.sh" ]; then
            printf '%s\n' "$_base/scripts/lib/common.sh"
            return 0
        fi
    done
    return 1
}

run_claude() {
    local command_file="$1"
    # Опциональная модель: второй аргумент или IWE_STRATEGIST_MODEL из env.
    # Приоритет: аргумент > env > пустая строка (дефолт Claude CLI).
    local model_override="${2:-${IWE_STRATEGIST_MODEL:-}}"
    local command_path="$PROMPTS_DIR/$command_file.md"
    AI_CLI_OUT_START=""
    AI_CLI_OUT_END=""

    if [ ! -f "$command_path" ]; then
        log "ERROR: Command file not found: $command_path"
        exit 1
    fi

    # WP-530 Ф72: a scenario listed for isolation must arrive here through isolated_begin; a listed
    # one without an isolated setup is refused, never run against the shared checkout.
    if isolation_enabled "$command_file" && [ "$ISOLATED_RUN" != 1 ]; then
        log "ISOLATION: сценарий $command_file указан в STRATEGIST_ISOLATED_SCENARIOS, но изолированного запуска для него нет — не запускаю (rc=$ISOLATION_BLOCKED_RC)"
        return "$ISOLATION_BLOCKED_RC"
    fi

    # Читаем содержимое команды.
    # WP-273 0.29.6 R6.1**: build-runtime подменял плейсхолдеры в этих sed-выражениях
    # → runner становился сломан после build (искал значение в промпте вместо плейсхолдера).
    # Escape: собираем двойно-фигурные токены через bash-конкатенацию — build-runtime sed
    # не находит цельный паттерн и не трогает.
    local prompt
    local _gov_repo="${IWE_GOVERNANCE_REPO:-DS-strategy}"
    local _ws="${ISOLATED_PROMPT_WORKSPACE:-${IWE_WORKSPACE:-$HOME/IWE}}"  # WP-530 Ф72: the copy's workspace in an isolated run
    local _gh_user="${GITHUB_USER:-your-username}"
    local _o='{''{' _c='}''}'  # escape: build-runtime ищет цельный двойно-фигурный токен с UPPER_NAME внутри, поэтому конкатенация одиночных скобок его не матчит
    prompt=$(sed \
        -e "s|${_o}GOVERNANCE_REPO${_c}|$_gov_repo|g" \
        -e "s|${_o}WORKSPACE_DIR${_c}|$_ws|g" \
        -e "s|${_o}GITHUB_USER${_c}|$_gh_user|g" \
        "$command_path") || { log "ERROR: не удалось прочитать промпт $command_path (sed)"; return 1; }

    # issue #942: calendar_source (params.yaml) = connector | script | none.
    # Without the shared helper (old install) the calendar stays on, as before.
    local calendar_source="connector" _iwe_common
    _iwe_common=$(find_common_sh) || _iwe_common=""
    if [ -n "$_iwe_common" ]; then
        # shellcheck source=/dev/null
        . "$_iwe_common" || { log "ERROR: не удалось загрузить $_iwe_common"; return 1; }
        calendar_source=$(iwe_calendar_source "${IWE_WORKSPACE:-$HOME/IWE}/params.yaml") \
            || { log "ERROR: iwe_calendar_source не отработал"; return 1; }
    fi
    local calendar_note=""
    case "$calendar_source" in
        none) calendar_note=" Календарь отключён (params.yaml: calendar_source: none): шаг про календарь (3a) пропусти, секцию «Календарь» в плане не пиши, календарный коннектор не запрашивай." ;;
        script) calendar_note=" Календарь берётся только из scripts/server-calendar.sh (params.yaml: calendar_source: script): календарный коннектор не запрашивай." ;;
    esac

    # #961: note-review started from this script has no chat with the pilot. One line says so, the way the
    # calendar sentence above is added, so that skipping step 10 (the archive) does not rest on the model's guess.
    # A live session (the Day Open mini-review, a request in a chat) never passes here and gets no such line.
    local mode_line=""
    case "$command_file" in
        note-review) mode_line=$'\n'"РЕЖИМ: запуск из скрипта без чата; шаг 10 и архив не выполнять, только пометки и предложения" ;;
    esac

    # Inject current date + day of week (prevents LLM calendar arithmetic errors)
    local ru_date_context
    ru_date_context=$(python3 -c "
import datetime
days = ['Понедельник','Вторник','Среда','Четверг','Пятница','Суббота','Воскресенье']
months = ['января','февраля','марта','апреля','мая','июня','июля','августа','сентября','октября','ноября','декабря']
d = datetime.date.today()
print(f'{d.day} {months[d.month-1]} {d.year}, {days[d.weekday()]}')
") || { log "ERROR: не удалось получить дату для контекста (python3)"; return 1; }
    prompt="[Системный контекст] Сегодня: ${ru_date_context}. ISO: ${DATE}. День недели №${DAY_OF_WEEK} (1=Пн..7=Вс). Первый Пн месяца: ${IS_FIRST_MONDAY_OF_MONTH} (посчитано командой date, не выводи это значение сам — issue #616).${calendar_note} ЯЗЫК: отвечай ТОЛЬКО на русском. Украинский, английский и другие языки запрещены.${mode_line}

${prompt}"

    log "Starting scenario: $command_file"
    log "Command file: $command_path"
    log "Date context: $ru_date_context"

    cd "$WORKSPACE" || { log "ERROR: не удалось перейти в $WORKSPACE"; return 1; }

    # WP-561 Ф25: origin/main до запуска модели, точка отсчёта для постусловия доставки.
    local delivery_pre_origin
    delivery_pre_origin=$(delivery_baseline "$command_file") || { log "ERROR: не удалось прочитать базу доставки"; return 1; }

    if ! open_runner_session "$command_file"; then
        log "FAILED scenario: $command_file (rc=$SESSION_OPEN_FAILED_RC) -- сессия охраны не открыта (причина в строках выше), модель не запускалась"
        return "$SESSION_OPEN_FAILED_RC"
    fi

    # Запуск Claude Code с содержимым команды как промпт (с timeout-защитой)
    local rc=0
    local model_args=()
    if [ -n "$model_override" ]; then
        model_args=(--model "$model_override")
        log "Model override: $model_override"
    fi
    # NB: --dangerously-skip-permissions не используется — Claude Code блокирует флаг
    # под root/sudo (Linux cron). --allowedTools задаёт явный whitelist, чего достаточно.
    # Календарный коннектор в whitelist (issue #581): без него morning-прогон не видит
    # встречи дня ни при какой конфигурации. Имя сервера зависит от установки —
    # переопределяется через IWE_CALENDAR_MCP_SERVERS (список через запятую);
    # дефолт — проверенный mcp__claude_ai_Google_Calendar. Неизвестные имена в
    # whitelist безвредны — просто никогда не совпадут.
    local calendar_mcp="${IWE_CALENDAR_MCP_SERVERS:-mcp__claude_ai_Google_Calendar}"
    [ "$calendar_source" = "connector" ] || calendar_mcp=""
    # AR.293: AI_CLI_EXTRA_FLAGS — точка подмены на случай, когда AI_CLI указывает
    # не на Claude Code (--model/--allowedTools — его флаги, не переносимы как есть).
    # Дефолт воспроизводит прежнее поведение один в один.
    local extra_flags
    if [ -n "${AI_CLI_EXTRA_FLAGS:-}" ]; then
        # намеренный word-splitting единой override-строки — тот же контракт,
        # что уже принят в extractor.sh
        read -ra extra_flags <<< "$AI_CLI_EXTRA_FLAGS" || { log "ERROR: не удалось разобрать AI_CLI_EXTRA_FLAGS"; return 1; }
    else
        extra_flags=("${model_args[@]}" --allowedTools "Read,Write,Edit,Glob,Grep,Bash${calendar_mcp:+,$calendar_mcp}")
    fi
    AI_CLI_OUT_START=$(log_size_bytes)
    timeout "$CLAUDE_TIMEOUT" "$AI_CLI" \
        "${extra_flags[@]}" \
        $AI_CLI_PROMPT_FLAG "$prompt" \
        >> "$LOG_FILE" 2>&1 || rc=$?
    AI_CLI_OUT_END=$(log_size_bytes)

    if [ $rc -eq 124 ]; then
        log "WARN: Claude CLI timed out after ${CLAUDE_TIMEOUT}s for scenario: $command_file"
    elif [ $rc -ne 0 ]; then
        log "WARN: Claude CLI exited with code $rc for scenario: $command_file"
    fi

    # Push changes to GitHub (чтобы бот мог читать через API)
    if [ "$ISOLATED_RUN" = 1 ]; then
        # WP-530 Ф72: nothing the model committed is published unverified; the runner checks the
        # allowlist and publishes from the copy (isolated_finish).
        log "Isolated run: публикацию делает isolated_finish после проверки списка путей"
    elif git -C "$WORKSPACE" diff --quiet origin/main..HEAD 2>/dev/null; then
        log "No unpushed commits"
    else
        # WP-7 Ф101: raw pull --rebase + push on a checkout shared with
        # concurrent agent sessions routinely hit a dirty tree or a
        # non-fast-forward push and silently dropped the commit (found via a
        # W36 week-review that never reached origin/main). ds-publish.sh
        # isolates this exact commit into a disposable worktree instead of
        # waiting for a clean window.
        local push_sha
        push_sha=$(git -C "$WORKSPACE" rev-parse HEAD) || { log "ERROR: не удалось прочитать HEAD для публикации"; return 1; }
        # Outcome is logged inside; `|| true` only keeps `set -e` from ending
        # the run over a publish that already reported its own failure.
        publish_commit_or_explain "strategist: $command_file" "$push_sha" \
            "Pushed to GitHub" "WARN: ds-publish.sh failed — публикация не удалась" || true
    fi

    # Очистить staging area после Claude сессии (предотвращает staging leak в следующие скрипты)
    # НЕ трогаем working tree — только unstage orphaned changes
    git -C "$WORKSPACE" reset --quiet 2>/dev/null || true
    log "Cleared staging area after Claude session"

    close_runner_session

    # WP-561 Ф25: SUCCESS is written only after delivery is proven -- already_ran_today() keys
    # on it, so an undelivered run must not mark the day done (a manual rerun stays possible).
    if [ $rc -eq 0 ] && ! verify_delivery_postcondition "$command_file" "$delivery_pre_origin"; then
        rc=$DELIVERY_POSTCONDITION_RC
    fi
    if [ $rc -eq 0 ]; then
        log "SUCCESS scenario: $command_file"
    else
        log "FAILED scenario: $command_file (rc=$rc)"
    fi

    # macOS notification
    local summary
    summary=$(tail -5 "$LOG_FILE" | grep -v '^\[' | head -3)
    notify "Стратег: $command_file" "$summary"
    return $rc
}

# Publish only owner-generated status. The private temporary file is renamed
# into place, so a killed writer never exposes a partial counter (#1067).
publish_week_review_status() {
    local status_file="$1" outcome="$2" rc="$3" failed_runs="$4" status_tmp
    if [ -e "$status_file" ] || [ -L "$status_file" ]; then
        if [ ! -f "$status_file" ] || [ -L "$status_file" ]; then
            log "ERROR: week-review status changed type: $status_file"
            return 77
        fi
    fi
    status_tmp=$(umask 077; mktemp "$LOG_DIR/.week-review-last-status.XXXXXX") || {
        log "ERROR: cannot create week-review status record"
        return 77
    }
    if ! printf '%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$outcome" "$rc" "$failed_runs" > "$status_tmp" ||
        ! mv "$status_tmp" "$status_file" ||
        [ ! -f "$status_file" ] || [ -L "$status_file" ]; then
        rm -f "$status_tmp"
        log "ERROR: cannot publish week-review status record"
        return 77
    fi
}

# issue #866: retry transient auth failures and leave a recoverable record.
run_claude_with_retry() {
    local command_file="$1"
    local model_override="${2:-${IWE_STRATEGIST_MODEL:-}}"
    local max_attempts="${3:-3}"
    shift 3 || shift $#
    local delays=(60 300)
    if [ $# -gt 0 ]; then
        delays=("$@")
    fi
    local attempt=1
    local rc=0
    local status_file="$LOG_DIR/${command_file}-last-status"
    local week_review_failed_runs=0
    local stamped_at prior_outcome prior_rc prior_count extra

    # The model's stdout is written to LOG_FILE. Count only outcomes published
    # by this process, never RECORDED/GAVE UP text found in that shared log.
    if [ "$command_file" = week-review ] && { [ -e "$status_file" ] || [ -L "$status_file" ]; }; then
        if [ ! -f "$status_file" ] || [ -L "$status_file" ] ||
            ! IFS=$'\t' read -r stamped_at prior_outcome prior_rc prior_count extra < "$status_file"; then
            log "ERROR: week-review status is not a regular complete record: $status_file"
            return 77
        fi
        if [ -n "$extra" ] || ! [[ "$stamped_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] ||
            ! [[ "$prior_rc" =~ ^[0-9]+$ ]] ||
            { [ "$prior_outcome" != SUCCESS ] && [ "$prior_outcome" != FAILED ] &&
                [ "$prior_outcome" != UNKNOWN ]; }; then
            log "ERROR: malformed week-review status: $status_file"
            return 77
        fi
        case "$prior_outcome:$prior_count" in
            SUCCESS:|SUCCESS:0|FAILED:|FAILED:1|FAILED:2|UNKNOWN:1|UNKNOWN:2) ;;
            *) log "ERROR: invalid week-review outcome/count: $status_file"; return 77 ;;
        esac
        if [ "$prior_outcome" = UNKNOWN ] && [ "$prior_rc" != 77 ]; then
            log "ERROR: invalid uncertain week-review status: $status_file"
            return 77
        fi
        if [ "${stamped_at%% *}" = "$(date '+%Y-%m-%d')" ] &&
            { [ "$prior_outcome" = FAILED ] || [ "$prior_outcome" = UNKNOWN ]; }; then
            # The previous release did not record whether this was failure #1
            # or #2. Treat today's three-field FAILED as exhausted: automatic
            # replay might otherwise become a third model call after upgrade.
            prior_count=${prior_count:-2}
            week_review_failed_runs=$prior_count
        fi
    fi

    if [ "$command_file" = week-review ]; then
        # Reserve the attempt before invoking the model. UNKNOWN pauses every
        # automatic replay if this shell dies or final status publication fails:
        # the report may already have reached origin, even on attempt one.
        # A manual retry is allowed and success resets the count to zero.
        if [ "$week_review_failed_runs" -lt "$WEEK_REVIEW_MAX_FAILED_RUNS" ]; then
            week_review_failed_runs=$((week_review_failed_runs + 1))
        fi
        publish_week_review_status "$status_file" UNKNOWN 77 "$week_review_failed_runs" || return 77
        WEEK_REVIEW_FAILED_RUNS=$week_review_failed_runs
    fi

    while [ "$attempt" -le "$max_attempts" ]; do
        rc=0
        run_claude "$command_file" "$model_override" || rc=$?

        # Transient auth failure: 403/401 in this attempt's CLI output is
        # recoverable once the VPN/credentials become available. Only the CLI's own output counts
        # (AI_CLI_OUT_*), not the fetch/publish lines that share the log.
        if [ "$rc" -ne 0 ] && [ "$attempt" -lt "$max_attempts" ]; then
            local attempt_output=""
            # A model that wrote nothing leaves an empty range: `head -c 0` is an error on BSD/macOS.
            if [ -n "$AI_CLI_OUT_START" ] && [ -n "$AI_CLI_OUT_END" ] && [ "$AI_CLI_OUT_END" -gt "$AI_CLI_OUT_START" ] \
                && [ -f "$LOG_FILE" ]; then
                attempt_output=$(tail -c "+$((AI_CLI_OUT_START + 1))" "$LOG_FILE" 2>/dev/null \
                    | head -c "$((AI_CLI_OUT_END - AI_CLI_OUT_START))" || true)
            fi
            if printf '%s\n' "$attempt_output" | grep -qiE "(Failed to authenticate|API Error: 403|401 Unauthorized|Request not allowed)"; then
                local delay_idx=$((attempt - 1))
                local delay=300
                if [ "$delay_idx" -lt "${#delays[@]}" ]; then
                    delay="${delays[$delay_idx]}"
                elif [ "${#delays[@]}" -gt 0 ]; then
                    delay="${delays[$((${#delays[@]} - 1))]}"
                fi
                log "AUTH_FAILURE scenario: $command_file (attempt $attempt/$max_attempts); retry in ${delay}s"
                sleep "$delay"
                attempt=$((attempt + 1))
                continue
            fi
        fi

        break
    done

    # Record the final outcome so the morning traffic light can distinguish a
    # fresh failure from a stale one.
    if [ "$command_file" = week-review ]; then
        if [ "$rc" -eq 0 ]; then
            publish_week_review_status "$status_file" SUCCESS 0 0 || return 77
        else
            publish_week_review_status "$status_file" FAILED "$rc" "$week_review_failed_runs" || return 77
        fi
    elif [ "$rc" -eq 0 ]; then
        printf '%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "SUCCESS" "$rc" > "$status_file"
    else
        printf '%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "FAILED" "$rc" > "$status_file"
    fi
    if [ "$rc" -ne 0 ]; then
        log "RECORDED: $command_file failed with rc=$rc (see $status_file)"
    fi

    return $rc
}

# Проверка: уже запускался ли сценарий сегодня
# Done for today = it succeeded, or it gave up for the day with "GAVE UP scenario: <name> (<reason>)"
# (the morning Day Open below), so a launchd RunAtLoad/CalendarInterval rerun does not start it again.
# week-review's own "GAVE UP scenario: week-review after ..." line does not match on purpose: after
# that alarm the owner reruns week-review by hand the same day.
already_ran_today() {
    local scenario="$1"
    if [ "$scenario" = week-review ]; then
        local status_file="$LOG_DIR/week-review-last-status"
        local stamped_at outcome rc failed_runs extra
        [ -f "$status_file" ] && [ ! -L "$status_file" ] || return 1
        IFS=$'\t' read -r stamped_at outcome rc failed_runs extra < "$status_file" || return 1
        [ -z "$extra" ] && [ "${stamped_at%% *}" = "$(date '+%Y-%m-%d')" ] &&
            [ "$outcome" = SUCCESS ] && [ "$rc" = 0 ] &&
            { [ -z "$failed_runs" ] || [ "$failed_runs" = 0 ]; }
        return $?
    fi
    [ -f "$LOG_FILE" ] && grep -qF -e "SUCCESS scenario: $scenario" -e "GAVE UP scenario: $scenario (" "$LOG_FILE"
}

# D16 (#983, #981): the morning Day Open never falls back to the free-form day-plan prompt -- it
# ignores priorities.yaml and the scaffold and invents the plan (an "unavailable" calendar,
# mandatory items nobody configured, half the commits). A failed Day Open is logged with its reason
# and alarmed by one delivered day-open-failed message a day; the plan is then built in a live
# session. Structural failures end the day (GAVE UP + exit 0, the scheduler marks the day). A
# deferral (exit 7) is no failure: no alarm, not an attempt, exit 7. Any other pipeline code is
# passed out for the scheduler to retry. Attempts are counted when they START: the scheduler's
# timeout kills this script before it could record an end. The explicit `strategist.sh day-plan`
# below still runs the prompt by hand.
DAY_OPEN_MAX_ATTEMPTS=3
DAY_OPEN_ATTEMPT_MARK="RECORDED: day-open attempt"
DAY_OPEN_DEFERRED_MARK="RECORDED: day-open deferred"
DAY_OPEN_OK_MARK="Morning: Day Open pipeline OK"
DAY_OPEN_ALARM_MARK="ALARM: day-open-failed"
# What notify.sh prints into the same log once the Bot API accepted the message (send_telegram):
# only a delivered alarm counts, a failed send is retried by the next attempt.
DAY_OPEN_ALARM_SENT_MARK="Telegram notification sent: strategist/day-open-failed"
# ...and what it prints when Telegram is not configured: there is nothing to deliver then, the reason
# stays in this log. A send that fails on the transport (no network: curl exits non-zero under notify.sh's
# `set -e`) prints nothing at all, so "owed" cannot be read from a failure line; it is "not delivered, and
# not unconfigured".
DAY_OPEN_ALARM_UNCONFIGURED_MARK="SKIP: TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not set"
DAY_OPEN_ALARM_MAX_ATTEMPTS=3
# Left in today's log by a give-up whose alarm is still owed: "<mark><reason code>|<exit code>|<reason text>".
# The next run finishes that give-up from this record (day_open_resume_pending_give_up) and does not run the
# pipeline again.
DAY_OPEN_GIVEUP_PENDING_MARK="RECORDED: day-open give-up pending|"
# A run that gave up on the plan while the alarm is still owed exits with this code, so the scheduler
# comes back and the alarm goes out again; the day is not marked done meanwhile.
DAY_OPEN_ALARM_RETRY_RC=74
# The pipeline's own contract (day-open-pipeline.sh, steps 1 and 1.1/1.1b): 7 = deferred, not done
# (yesterday is not closed yet, the triage report is still being published, the week is closing).
DAY_OPEN_DEFERRED_RC=7
# A saved scaffold is useful local work, but never a completed Day Open.
DAY_OPEN_SCAFFOLD_RC=10
# The scheduler reads exit 2 as "lock held, another run is in progress" (scheduler.sh
# run_strategist_scenario); a pipeline that failed with 2 is passed out as this code instead.
DAY_OPEN_RC2_SUBSTITUTE=73
DAY_OPEN_ATTEMPT=0

count_in_log() {  # <literal text> -> number of today's log lines that contain it, 0 without a log
    local n
    n=$(grep -cF -- "$1" "$LOG_FILE" 2>/dev/null || true)
    echo "${n:-0}"
}

day_open_alarm() {  # <reason code> <reason text> [exit code]; at most one delivered message a day
    if grep -qF "$DAY_OPEN_ALARM_SENT_MARK" "$LOG_FILE" 2>/dev/null; then
        log "Day Open: тревога сегодня уже доставлена, повторно не шлю ($2)"
        return 0
    fi
    # The limit is checked BEFORE a send starts: a run killed inside the send leaves its ALARM line (and a
    # pending give-up) behind, and the next run must not start one more send past the limit (red team of the
    # 0.41.1 candidate: killed runs kept the count from ever stopping the sends).
    if [ "$(count_in_log "$DAY_OPEN_ALARM_MARK")" -ge "$DAY_OPEN_ALARM_MAX_ATTEMPTS" ]; then
        log "Day Open: тревога уже начата $DAY_OPEN_ALARM_MAX_ATTEMPTS раза за сегодня, больше не шлю ($2)"
        return 0
    fi
    log "$DAY_OPEN_ALARM_MARK ($2)"
    # The template turns the code into the message text (roles/synchronizer/scripts/templates/strategist.sh).
    DAY_OPEN_FAILED_REASON="$1" DAY_OPEN_FAILED_RC="${3:-}" notify_telegram "day-open-failed"
}

day_open_alarm_owed() {  # 0 = the alarm is not delivered, Telegram is configured and attempts are left
    grep -qF "$DAY_OPEN_ALARM_SENT_MARK" "$LOG_FILE" 2>/dev/null && return 1
    grep -qF "$DAY_OPEN_ALARM_UNCONFIGURED_MARK" "$LOG_FILE" 2>/dev/null && return 1
    [ "$(count_in_log "$DAY_OPEN_ALARM_MARK")" -lt "$DAY_OPEN_ALARM_MAX_ATTEMPTS" ]
}

# No more morning runs today and no false SUCCESS -- once the alarm is out: a give-up with an owed alarm
# leaves the day open (exit DAY_OPEN_ALARM_RETRY_RC, no GAVE UP line) and records what it gave up on, so
# the next scheduler run sends the alarm again and nothing else: day_open_resume_pending_give_up reads the
# record before the pipeline is looked at. That also bounds the sends: every one comes from a give-up or
# from a transient failure of attempts 1 and 2, and the owed test stops at DAY_OPEN_ALARM_MAX_ATTEMPTS.
day_open_give_up() {  # <reason code> <reason text> [exit code]
    day_open_alarm "$@"
    if day_open_alarm_owed; then
        log "$DAY_OPEN_GIVEUP_PENDING_MARK$1|${3:-}|$2"
        log "Day Open: тревога не доставлена, повтор доставки при следующем запуске планировщика без нового запуска конвейера, код $DAY_OPEN_ALARM_RETRY_RC ($2)"
        exit "$DAY_OPEN_ALARM_RETRY_RC"
    fi
    log "GAVE UP scenario: day-plan ($2)"
    exit 0
}

day_open_resume_pending_give_up() {  # finishes a give-up whose alarm is still owed; returns when there is none
    local rec code rc
    rec=$(grep -F "$DAY_OPEN_GIVEUP_PENDING_MARK" "$LOG_FILE" 2>/dev/null | tail -1) || true
    [ -n "$rec" ] || return 0
    rec=${rec#*"$DAY_OPEN_GIVEUP_PENDING_MARK"}
    code=${rec%%|*}
    rec=${rec#*|}
    rc=${rec%%|*}
    day_open_give_up "$code" "${rec#*|}" "$rc"
}

day_open_start_attempt() {  # gives up instead when DAY_OPEN_MAX_ATTEMPTS attempts already started today
    local started
    # A deferred run started an attempt too, but it is no failure and does not count.
    started=$(( $(count_in_log "$DAY_OPEN_ATTEMPT_MARK") - $(count_in_log "$DAY_OPEN_DEFERRED_MARK") ))
    # A plan built earlier today is no failure: a later run (RunAtLoad after a reboot) reaches the
    # pipeline, whose own dedup answers "already committed".
    if [ "$started" -ge "$DAY_OPEN_MAX_ATTEMPTS" ] && ! grep -qF "$DAY_OPEN_OK_MARK" "$LOG_FILE" 2>/dev/null; then
        day_open_give_up attempts-exhausted "за сегодня начато попыток: $started, ни одна не собрала план (ошибка или прерывание по тайм-ауту)"
    fi
    DAY_OPEN_ATTEMPT=$((started + 1))
    log "$DAY_OPEN_ATTEMPT_MARK $DAY_OPEN_ATTEMPT (предел $DAY_OPEN_MAX_ATTEMPTS за день, отсрочки не считаются)"
}

day_open_deferred() {  # the pipeline deferred the day (exit 7) and reported it itself; exits 7, the scheduler retries later
    log "$DAY_OPEN_DEFERRED_MARK: конвейер отложил Открытие дня (код 7: вчерашний день ещё не закрыт, отчёт triage ещё готовится или закрывается неделя). Это не сбой: тревоги нет, попытка не засчитана, повтор при следующем запуске планировщика"
    exit "$DAY_OPEN_DEFERRED_RC"
}

day_open_transient_failure() {  # <pipeline exit code>; exits with it (the scheduler retries) or gives up on the last attempt
    local rc="$1" out_rc="$1" note=""
    if [ "$DAY_OPEN_ATTEMPT" -ge "$DAY_OPEN_MAX_ATTEMPTS" ]; then
        day_open_give_up attempts-exhausted "попытка $DAY_OPEN_ATTEMPT из $DAY_OPEN_MAX_ATTEMPTS тоже не удалась: конвейер завершился с кодом $rc" "$rc"
    fi
    day_open_alarm pipeline-failed "конвейер Открытия дня завершился с кодом $rc, попытка $DAY_OPEN_ATTEMPT из $DAY_OPEN_MAX_ATTEMPTS" "$rc"
    if [ "$rc" -eq 2 ]; then
        out_rc=$DAY_OPEN_RC2_SUBSTITUTE
        note=" (код конвейера 2 передаю как $out_rc: планировщик читает 2 как «другой запуск ещё идёт»)"
    fi
    log "FAILED scenario: day-plan (rc=$rc) -- план дня не собран, выхожу с кодом $out_rc$note, повтор при следующем запуске планировщика"
    exit "$out_rc"
}

# Note-Review canary (#961): number of NEW notes in fleeting-notes.md, i.e. bold titles that carry
# neither 🔄 (deferred) nor ✅предложено (proposal already written). Since the template owner's
# decision of July 2026 a processed note stays bold and gets the ✅предложено mark instead of losing
# its bold, so a healthy run lowers THIS count, not the plain bold count. The mark is matched the way
# a model types it: spaces after ✅ (a no-break one too) and any mix of capitals. The letters are
# spelled out in (п|П) pairs instead of using grep -i, because folding Cyrillic case depends on the
# locale of the runner. The same mark means "waiting for the pilot" in cleanup-processed-notes.py
# (re.IGNORECASE) and in the Day Open scanner (day-open-scaffold.sh, the same pairs); the line is one
# line on purpose, the test harness cuts it out by name. Prints 0 for a missing file.
PROPOSED_MARK_ERE='✅([[:space:]]|'$'\302\240'')*(п|П)(р|Р)(е|Е)(д|Д)(л|Л)(о|О)(ж|Ж)(е|Е)(н|Н)(о|О)'
count_new_bold_notes() {  # <fleeting-notes.md>
    local count
    count=$(grep '^\*\*' "$1" 2>/dev/null | grep -vcE -e '🔄' -e "$PROPOSED_MARK_ERE" || true)
    echo "${count:-0}"
}

# File-based lock to prevent concurrent execution (RunAtLoad + CalendarInterval race).
# A complete owner record is published by one atomic hard link. A contender
# never removes a live or unpublished lock: the old mkdir/pid protocol exposed
# an empty pid file, then stale-lock reclaim deleted a live owner's directory
# (#1030). The short acquisition gate serializes recovery of dead new owners.
LOCK_DIR="$LOG_DIR/locks"
mkdir -p "$LOCK_DIR"

STRATEGIST_LOCK_OWNER=""
STRATEGIST_LOCK_MAIN=""
STRATEGIST_LOCK_LEGACY=""
STRATEGIST_LOCK_GATE=""

release_lock() {
    local path
    for path in "$STRATEGIST_LOCK_LEGACY" "$STRATEGIST_LOCK_MAIN"; do
        if [ -n "$path" ] && [ -n "$STRATEGIST_LOCK_OWNER" ] && [ ! -L "$path" ] && [ "$path" -ef "$STRATEGIST_LOCK_OWNER" ]; then
            rm -f -- "$path" || log "WARN: failed to release own lock: $path"
        fi
    done
    if [ -n "$STRATEGIST_LOCK_OWNER" ]; then
        rm -f -- "$STRATEGIST_LOCK_OWNER" || log "WARN: failed to remove lock owner record: $STRATEGIST_LOCK_OWNER"
    fi
    if [ -n "$STRATEGIST_LOCK_GATE" ]; then
        rmdir "$STRATEGIST_LOCK_GATE" || log "WARN: failed to release lock acquisition gate: $STRATEGIST_LOCK_GATE"
    fi
}

inspect_lock() {  # <scenario> <path>; under the acquisition gate
    local scenario="$1" path="$2" owner_ref="$2" pid=""
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
        return 0
    fi
    if [ -L "$path" ]; then
        log "ERROR: $scenario lock path is a symlink ($path); inspect it manually"
        exit 1
    elif [ -d "$path" ]; then
        # A running pre-#1030 strategist uses this dated directory. Its pid
        # may still be in the mkdir -> write window. Old contenders do not
        # honor our acquisition gate, so never reclaim their directory.
        owner_ref="$path/pid"
    elif [ ! -f "$path" ]; then
        log "ERROR: $scenario lock has an unexpected type ($path); inspect it manually"
        exit 1
    fi
    pid=$(head -n 1 "$owner_ref" 2>/dev/null || true)
    if [ -z "$pid" ] && [ -d "$path" ]; then
        log "ERROR: $scenario legacy lock has no published owner ($path); check for an old running strategist before manual removal"
        exit 1
    fi
    if ! [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
        log "ERROR: $scenario lock has an unreadable owner ($path); inspect it manually"
        exit 1
    fi
    if kill -0 "$pid" 2>/dev/null; then
        log "SKIP: $scenario already running (PID $pid)"
        exit 2
    fi
    if [ -d "$path" ]; then
        log "ERROR: $scenario has a stale legacy lock ($path, PID $pid); verify the old owner is stopped, then remove that directory manually"
        exit 1
    fi
    # Only new runners use this gate. The recorded owner is dead, so exactly
    # one contender may remove this stale hard link before publishing its own.
    rm -f -- "$path" || { log "ERROR: failed to remove stale lock for $scenario: $path"; exit 1; }
    log "WARN: recovered stale lock for $scenario (PID $pid): $path"
}

publish_lock_link() {  # <complete-owner-record> <fixed-lock-path>
    # Unlike `ln source target`, os.link never treats an existing directory
    # (or a symlink to one) as a destination in which to create a third file.
    # It fails with EEXIST instead. Python is already required by strategist.
    python3 - "$1" "$2" <<'PY'
import os
import sys

try:
    os.link(sys.argv[1], sys.argv[2])
except OSError:
    sys.exit(1)
PY
}

lock_conflict() {  # <scenario> <path>; publication failed while gate held
    local scenario="$1" path="$2"
    if [ -e "$path" ] || [ -L "$path" ]; then
        inspect_lock "$scenario" "$path"
        log "ERROR: lock path changed during publication for $scenario: $path"
    else
        log "ERROR: cannot publish lock for $scenario at $path (hard links unavailable or permission denied)"
    fi
    exit 1
}

acquire_lock() {
    local scenario="$1"
    local owner main="$LOCK_DIR/${scenario}.lock" legacy="$LOCK_DIR/${scenario}.${DATE}.lck"
    local gate="$LOCK_DIR/.${scenario}.acquire" attempt gate_signal=""
    if ! command -v python3 >/dev/null 2>&1; then
        log "ERROR: python3 is required to publish a lock for $scenario"
        exit 1
    fi
    add_exit_cleanup 'release_lock'
    # Bash can run a signal trap after mkdir returns but before the next
    # assignment. Defer INT/TERM until the gate has a recorded owner; never
    # let EXIT cleanup infer ownership from a path that another run may own.
    trap 'gate_signal=130' INT
    trap 'gate_signal=143' TERM
    for ((attempt = 0; attempt < 250; attempt++)); do
        if mkdir "$gate" 2>/dev/null; then
            STRATEGIST_LOCK_GATE="$gate"
            [ -z "$gate_signal" ] || exit "$gate_signal"
            break
        fi
        [ -z "$gate_signal" ] || exit "$gate_signal"
        sleep 0.02
    done
    [ -z "$gate_signal" ] || exit "$gate_signal"
    if [ -z "$STRATEGIST_LOCK_GATE" ]; then
        log "ERROR: acquisition gate unavailable for $scenario ($gate); inspect the gate before manual removal"
        exit 1
    fi
    inspect_lock "$scenario" "$main"
    inspect_lock "$scenario" "$legacy"
    owner=$(mktemp "$LOCK_DIR/.${scenario}.owner.XXXXXX") || { log "ERROR: failed to create lock owner record for $scenario"; exit 1; }
    STRATEGIST_LOCK_OWNER="$owner"
    if ! printf '%s\n' "$$" > "$owner"; then
        log "ERROR: failed to write lock owner record for $scenario"
        exit 1
    fi
    if ! publish_lock_link "$owner" "$main"; then
        lock_conflict "$scenario" "$main"
    fi
    STRATEGIST_LOCK_MAIN="$main"
    # A dated link fences pre-#1030 strategist processes during an update.
    # The undated link above keeps a run crossing midnight mutually exclusive.
    if ! publish_lock_link "$owner" "$legacy"; then
        lock_conflict "$scenario" "$legacy"
    fi
    STRATEGIST_LOCK_LEGACY="$legacy"
    # Clear ownership before unlinking the shared path: after rmdir succeeds,
    # another contender may create a new gate before our EXIT trap runs.
    STRATEGIST_LOCK_GATE=""
    if ! rmdir "$gate"; then
        log "ERROR: failed to release acquisition gate for $scenario: $gate"
        exit 1
    fi
    trap 'exit 130' INT
    trap 'exit 143' TERM
    [ -z "$gate_signal" ] || exit "$gate_signal"
}

# issue #840: git-diff-feed and session-close-feed (extractor.sh) and this
# note-review step all read-modify-write the same shared inbox/captures.md.
# acquire_lock() above only serializes note-review against a second
# note-review run (own $LOG_DIR/locks) -- it never intersects extractor.sh's
# separate TMPDIR-based lock, so the two scripts could still race on the
# same file. Shares that exact lock dir/var so both writers contend for the
# same resource instead of two disjoint namespaces.
acquire_captures_write_lock() {
    local lock_dir="${IWE_EXTRACTOR_FEED_LOCK_DIR:-${TMPDIR:-/tmp}/iwe-extractor-session-close-feed.lock}"
    local waited=0
    while true; do
        if mkdir "$lock_dir" 2>/dev/null; then
            printf '%s\n' "$$" > "$lock_dir/pid"
            add_exit_cleanup "rm -f '$lock_dir/pid' 2>/dev/null; rmdir '$lock_dir' 2>/dev/null"
            return 0
        fi
        local owner_pid=""
        [ -f "$lock_dir/pid" ] && owner_pid=$(tr -d '[:space:]' < "$lock_dir/pid")
        # Mirrors acquire_inbox_lock() (extractor.sh) exactly: only reclaim
        # when the pid file is present and non-empty. A missing/empty pid
        # file means another writer's mkdir has landed but its own pid write
        # has not (a real, if narrow, gap -- see extractor.sh's own mkdir/
        # printf pair) -- reclaiming there would steal a lock someone else
        # already holds (TOCTOU), reintroducing the exact race #840 fixes.
        # Cold-review (same session) caught this asymmetry before deploy.
        if [ -n "$owner_pid" ] && { ! [[ "$owner_pid" =~ ^[0-9]+$ ]] || ! kill -0 "$owner_pid" 2>/dev/null; }; then
            rm -f "$lock_dir/pid"
            rmdir "$lock_dir" 2>/dev/null
            continue
        fi
        if [ "$waited" -ge 30 ]; then
            log "WARN: captures.md lock unavailable after ${waited}s (pid: ${owner_pid:-mid-acquire}) — proceeding without it"
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
}

# Читаем strategy_day из конфига (L4 Personal)
# issue #729: раньше единственным источником был auto-memory Claude Code по
# литеральному пути "-Users-$(whoami)-IWE" — ломается молча, если workspace
# не буквально ~/IWE (симлинк или другой путь на Linux/WSL), а fallback на
# monday ничем не сигнализировал об ошибке. Governance-репо копия — тот же
# источник, что уже читают day-open-scaffold.sh и server-calendar.sh, и она
# не зависит от workspace-пути. Функция вынесена отдельно ради регрессионного
# теста (scripts/tests/test_issue_729_rhythm_config_resolve.sh).
resolve_rhythm_config() {
    local ws="$1" iwe_workspace="$2"
    local rhythm_config="$ws/exocortex/day-rhythm-config.yaml"
    if [ ! -f "$rhythm_config" ]; then
        # Fallback: auto-memory Claude Code, путь выводим из РЕАЛЬНОГО workspace
        # (pwd -P разворачивает симлинки), не из literal "~/IWE".
        local ws_real
        ws_real="$(cd "${iwe_workspace:-$HOME/IWE}" 2>/dev/null && pwd -P || true)"
        if [ -n "$ws_real" ]; then
            # tr '/_.' '-', не sed 's#/#-#g': Claude Code слугифицирует путь,
            # заменяя на "-" также "_" и "." (см. memory-exocortex-sync.sh) —
            # sed-only вариант молча ломался бы для workspace-путей с "." или "_".
            local ws_slug
            ws_slug="$(printf '%s' "$ws_real" | tr '/_.' '-')"
            rhythm_config="$HOME/.claude/projects/${ws_slug}/memory/day-rhythm-config.yaml"
        fi
    fi
    printf '%s\n' "$rhythm_config"
}

RHYTHM_CONFIG="$(resolve_rhythm_config "$WORKSPACE" "${IWE_WORKSPACE:-}")"
STRATEGY_DAY_NAME=$(grep 'strategy_day:' "$RHYTHM_CONFIG" 2>/dev/null | awk '{print $2}')
if [ -z "$STRATEGY_DAY_NAME" ]; then
    log "WARN: strategy_day not found in $RHYTHM_CONFIG — fallback: monday"
    STRATEGY_DAY_NAME="monday"
fi
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

# WP-530 Ф72: only scenarios with an isolated setup may be listed in STRATEGIST_ISOLATED_SCENARIOS.
if isolation_enabled "${1:-}" && [ -z "$(isolated_allowlist "$1")" ]; then
    log "ISOLATION: сценарий $1 указан в STRATEGIST_ISOLATED_SCENARIOS, но списка разрешённых путей для него нет — изолированный запуск не поддержан, сценарий не запущен (rc=$ISOLATION_BLOCKED_RC)"
    exit "$ISOLATION_BLOCKED_RC"
fi

# Определяем какой сценарий запускать
case "$1" in
    "morning")
        # Определяем нужный сценарий: strategy_day → session-prep, иначе → day-plan
        if [ "$DAY_OF_WEEK" -eq "$STRATEGY_DAY_NUM" ]; then
            SCENARIO="session-prep"
        else
            SCENARIO="day-plan"
        fi

        # WP-530 Ф72: `morning` itself is not a listed name, but the scenario it resolves to is. The
        # day-plan branch is served by day-open-pipeline.sh (no run_claude, no isolation), so a listed
        # day-plan must stop here, before the pipeline writes into the shared checkout.
        if isolation_enabled "$SCENARIO" && [ -z "$(isolated_allowlist "$SCENARIO")" ]; then
            log "ISOLATION: morning выбрал сценарий $SCENARIO, он указан в STRATEGIST_ISOLATED_SCENARIOS, но изолированного запуска для него нет — не запускаю (rc=$ISOLATION_BLOCKED_RC)"
            exit "$ISOLATION_BLOCKED_RC"
        fi

        # Защита от повторного запуска (RunAtLoad + CalendarInterval race condition)
        acquire_lock "$SCENARIO"
        if already_ran_today "$SCENARIO"; then
            log "SKIP: $SCENARIO already completed today"
            exit 0
        fi
        day_open_resume_pending_give_up

        if [ "$DAY_OF_WEEK" -eq "$STRATEGY_DAY_NUM" ]; then
            log "Strategy day ($STRATEGY_DAY_NAME): running session prep"
            run_claude "session-prep" "claude-sonnet-4-6"
            notify_telegram "session-prep"
        else
            # Canonical Day Open pipeline: deterministic scaffold (reads priorities.yaml,
            # enforces ТВС section order, runs server-news.sh for «Мир»). It is the only
            # morning path: a failure alarms instead of a free-form plan (D16, see
            # day_open_give_up() above).
            log "Morning: running canonical Day Open pipeline"
            # $IWE_SCRIPTS first (matches the interactive day-open skill's own
            # resolution order), $WORKSPACE/scripts/ as legacy fallback for
            # installs that still deliver a workspace-root copy. #598: this
            # function used to read $WORKSPACE only, so $IWE_SCRIPTS-only
            # installs fell back to the free-form prompt silently, every morning,
            # with no escalation (found live: 37 consecutive days, 88 runs).
            DAY_OPEN_PIPELINE="${IWE_SCRIPTS:-}/day-open-pipeline.sh"
            if [ -z "${IWE_SCRIPTS:-}" ] || [ ! -f "$DAY_OPEN_PIPELINE" ]; then
                DAY_OPEN_PIPELINE="$WORKSPACE/scripts/day-open-pipeline.sh"
            fi
            if [ ! -f "$DAY_OPEN_PIPELINE" ]; then
                # WP-529 F6: on user installs workspace-root scripts/ is not
                # delivered at all (Evgenii defects #2/#3, 18.08) — say so
                # instead of a generic "unavailable/failed". The delivery
                # graph itself is WP-529 F7 scope, no silent bridge here.
                log "WARN: Day Open pipeline not found at \$IWE_SCRIPTS or $WORKSPACE/scripts — canonical pipeline is not delivered on this install (WP-529 F7)"
                day_open_give_up not-delivered "конвейер Открытия дня не доставлен: day-open-pipeline.sh нет ни в \$IWE_SCRIPTS, ни в $WORKSPACE/scripts"
            fi
            day_open_start_attempt
            pipeline_rc=0
            DAY_OPEN_NOTIFICATION_OWNER=strategist bash "$DAY_OPEN_PIPELINE" >> "$LOG_FILE" 2>&1 || pipeline_rc=$?
            if [ "$pipeline_rc" -eq 0 ]; then
                log "$DAY_OPEN_OK_MARK (scaffold + llm-fill)"
            elif [ "$pipeline_rc" -eq "$DAY_OPEN_DEFERRED_RC" ]; then
                day_open_deferred
            elif [ "$pipeline_rc" -eq 9 ]; then
                # issue #893: exit 9 = no gateway configured (day-open-pipeline.sh
                # §2), a case the pipeline itself already ships an answer for
                # (--scaffold-only, issue #434). The retry's own code is kept
                # right away: it is what the alarm reports.
                log "Morning: Day Open pipeline has no gateway configured — retrying with --scaffold-only"
                scaffold_rc=0
                DAY_OPEN_NOTIFICATION_OWNER=strategist bash "$DAY_OPEN_PIPELINE" --scaffold-only >> "$LOG_FILE" 2>&1 || scaffold_rc=$?
                if [ "$scaffold_rc" -eq "$DAY_OPEN_SCAFFOLD_RC" ]; then
                    scaffold_path="${IWE_WORKSPACE:-$HOME/IWE}/.tmp/day-open-scaffold/DayPlan $(date +%Y-%m-%d).md"
                    day_open_give_up scaffold-incomplete "шлюз модели не настроен; неполный каркас сохранён: $scaffold_path. День не открыт; правки черновика не переносятся автоматически в полный план" "$scaffold_rc"
                elif [ "$scaffold_rc" -eq "$DAY_OPEN_DEFERRED_RC" ]; then
                    day_open_deferred
                else
                    day_open_give_up scaffold-only-failed "шлюз модели не настроен (код 9), повтор с --scaffold-only тоже не прошёл: код $scaffold_rc (причина в строках выше)" "$scaffold_rc"
                fi
            else
                day_open_transient_failure "$pipeline_rc"
            fi
        fi
        ;;
    "evening")
        # WP-529 F6: evening was the only scheduled scenario without the
        # RunAtLoad/CalendarInterval race lock and the ran-today check.
        acquire_lock "evening"
        if already_ran_today "evening"; then
            log "SKIP: evening already completed today"
            exit 0
        fi
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
        # issue #866: week-review runs at night when credentials/VPN may be
        # transiently unavailable. Retry auth failures with backoff and leave a
        # status file so the morning traffic light can distinguish fresh from
        # stale failures.
        # WP-561 Ф25: `set -e` would end the script silently on a failed run (no message at
        # all); keep the code, alarm the pilot, then exit with it.
        week_review_rc=0
        run_claude_with_retry "week-review" "claude-opus-4-7" 3 60 300 || week_review_rc=$?
        # Fallback push for Knowledge Index (week-review creates a post there)
        # KI_REPO may not exist for all users — guard with [ -d ]
        KI_REPO="$HOME/IWE/DS-Knowledge-Index"
        if [ -d "$KI_REPO/.git" ] && git -C "$KI_REPO" log --oneline -1 --since="1 hour ago" --grep="week-review" 2>/dev/null | grep -q .; then
            git -C "$KI_REPO" push >> "$LOG_FILE" 2>&1 && log "Pushed Knowledge Index (fallback)" || log "WARN: KI push failed"
        fi
        if [ "$week_review_rc" -ne 0 ]; then
            notify_telegram "week-review-failed" || true  # the alarm must never replace the run's own exit code
            # The scheduler reruns every non-zero exit at its next dispatch (about ten a day, 30
            # min of model time each). An undelivered report is usually structural (a refused
            # session, a frozen checkout), so after the second failed run today stop retrying:
            # the alarms and the FAILED status already tell the owner. Return a distinct failure
            # so the scheduler suppresses further automatic runs today without marking weekly done.
            # A manual run after the fix remains available. The persisted
            # failed-run count excludes model stdout and internal auth retries.
            if [ "${WEEK_REVIEW_FAILED_RUNS:-0}" -ge "$WEEK_REVIEW_MAX_FAILED_RUNS" ]; then
                log "GAVE UP scenario: week-review after $WEEK_REVIEW_MAX_FAILED_RUNS failed runs today; automatic retries paused for today, manual retry remains available"
                exit "$WEEK_REVIEW_EXHAUSTED_RC"
            fi
            exit "$week_review_rc"
        fi
        notify_telegram "week-review"
        ;;
    "session-prep")
        log "Manual: running session prep"
        run_claude "session-prep" "claude-sonnet-4-6"
        notify_telegram "session-prep"
        ;;
    "day-plan")
        log "Manual: running day plan"
        run_claude "day-plan" "claude-sonnet-4-6"
        notify_telegram "day-plan"
        ;;
    "note-review")
        acquire_lock "note-review"
        log "Manual: running note review"
        # WP-530 Ф72: opt-in isolation (STRATEGIST_ISOLATED_SCENARIOS); off = the legacy path below.
        if isolation_enabled "note-review"; then
            isolated_begin "note-review" || { log "FAILED scenario: note-review (rc=$ISOLATION_BLOCKED_RC) -- изолированная копия не создана, канон не тронут"; exit "$ISOLATION_BLOCKED_RC"; }
        fi
        # Canary: count bold notes before. "New" = bold without 🔄 (deferred ideas stay bold by design)
        # and without ✅предложено (already proposed; stays bold until the pilot closes it, #961).
        # NB: `grep -c` при exit 1 (no matches) печатает "0" до `||`, так что `|| echo 0`
        # давал двухстрочный "0\n0" и ломал арифметику. Используем `|| true` + fallback.
        FLEETING="$WORKSPACE/inbox/fleeting-notes.md"
        BOLD_BEFORE=$(grep -c '^\*\*' "$FLEETING" 2>/dev/null || true); BOLD_BEFORE=${BOLD_BEFORE:-0}
        BOLD_NEW_BEFORE=$(count_new_bold_notes "$FLEETING")
        log "Canary: $BOLD_BEFORE bold total ($BOLD_NEW_BEFORE new, $(( BOLD_BEFORE - BOLD_NEW_BEFORE )) deferred 🔄 or ✅предложено)"

        acquire_captures_write_lock || true
        if [ "$ISOLATED_RUN" = 1 ]; then
            note_review_rc=0
            run_claude "note-review" "claude-haiku-4-5-20251001" || note_review_rc=$?
            if [ "$note_review_rc" -ne 0 ]; then
                log "ISOLATION: сбой запуска модели (rc=$note_review_rc), публикации нет, копия сохранена: $ISO_WORKTREE"
                exit "$note_review_rc"
            fi
        else
            run_claude "note-review" "claude-haiku-4-5-20251001"
        fi

        # Canary: count bold notes after (needs to be visible for the alert further below)
        BOLD_AFTER=$(grep -c '^\*\*' "$FLEETING" 2>/dev/null || true); BOLD_AFTER=${BOLD_AFTER:-0}
        BOLD_NEW_AFTER=$(count_new_bold_notes "$FLEETING")
        # Non-blocking diagnostic (isolated from set -e to protect cleanup below)
        (
            log "Canary: $BOLD_AFTER bold total ($BOLD_NEW_AFTER new)"
            NON_BOLD=$(grep -c '^[^*#>-]' "$FLEETING" 2>/dev/null || true); NON_BOLD=${NON_BOLD:-0}
            log "Non-bold content lines: $NON_BOLD"
            if [ "$BOLD_NEW_AFTER" -ge "$BOLD_NEW_BEFORE" ] && [ "$BOLD_NEW_BEFORE" -gt 0 ]; then
                log "WARN: Note-Review did not mark new notes ✅предложено — new bold notes did not decrease ($BOLD_NEW_BEFORE → $BOLD_NEW_AFTER)"
            fi
        ) || true

        # Deterministic cleanup: archive non-bold, non-🔄 notes (safety net: only notes the pilot closed
        # by hand — bold removed or struck through; ✅предложено notes are never swept up, bold or not)
        # cleanup-processed-notes.py has no placeholders, so it is read-only
        # data from FMT (same rule as notify.sh above) and build-runtime does
        # not deliver it next to this runtime copy of strategist.sh — resolving
        # it via $SCRIPT_DIR silently no-op'd every run (#597).
        if [ -n "${IWE_TEMPLATE:-}" ] && [ -f "$IWE_TEMPLATE/roles/strategist/scripts/cleanup-processed-notes.py" ]; then
            cleanup_script="$IWE_TEMPLATE/roles/strategist/scripts/cleanup-processed-notes.py"
        elif [ -f "$HOME/IWE/FMT-exocortex-template/roles/strategist/scripts/cleanup-processed-notes.py" ]; then
            cleanup_script="$HOME/IWE/FMT-exocortex-template/roles/strategist/scripts/cleanup-processed-notes.py"
        else
            cleanup_script="$SCRIPT_DIR/cleanup-processed-notes.py"  # legacy fallback
        fi
        # cleanup-processed-notes.py only needs the stdlib (no PyYAML import) —
        # same STDLIB_PYTHON3 idiom as day-close.sh, not the yaml-requiring
        # scripts/lib/find-python3.sh resolver (would wrongly report "no
        # python3" on a system that has one without PyYAML installed).
        cleanup_python3=""
        for _cleanup_python_candidate in python3 python; do
            if command -v "$_cleanup_python_candidate" >/dev/null 2>&1; then
                cleanup_python3="$_cleanup_python_candidate"
                break
            fi
        done
        unset _cleanup_python_candidate
        log "Running deterministic cleanup..."
        # WP-530 Ф72: in an isolated run the script edits the copy's files, not the canon's.
        cleanup_env=()
        [ "$ISOLATED_RUN" != 1 ] || cleanup_env=(IWE_CLEANUP_ISOLATED=1 IWE_CLEANUP_REPO_DIR="$WORKSPACE")
        cleanup_rc=0
        if [ -n "$cleanup_python3" ]; then
            if [ "$ISOLATED_RUN" = 1 ]; then
                # isolated: a failing script must block, not read as "no changes"
                CLEANUP_OUTPUT=$(env ${cleanup_env[@]+"${cleanup_env[@]}"} "$cleanup_python3" "$cleanup_script" 2>&1) || cleanup_rc=$?
            else
                CLEANUP_OUTPUT=$(env ${cleanup_env[@]+"${cleanup_env[@]}"} "$cleanup_python3" "$cleanup_script" 2>&1) || true
            fi
        else
            CLEANUP_OUTPUT="no python3 interpreter found — skipped"
            [ "$ISOLATED_RUN" != 1 ] || cleanup_rc=127
        fi
        log "Cleanup: $CLEANUP_OUTPUT"

        # If cleanup made changes, commit and push
        iso_finish_rc=0
        if [ "$ISOLATED_RUN" = 1 ] && [ "$cleanup_rc" -ne 0 ]; then
            log "ISOLATION: cleanup-скрипт завершился с кодом $cleanup_rc, публикации нет, копия сохранена: $ISO_WORKTREE"
            iso_finish_rc=$ISOLATION_BLOCKED_RC
        elif [ "$ISOLATED_RUN" = 1 ]; then
            # Verify the allowlist (inbox/fleeting-notes.md, archive/notes/Notes-Archive.md), commit
            # and publish from the copy; the copy is removed only after a publication.
            isolated_finish "strategist: cleanup" "chore: auto-cleanup processed notes from fleeting-notes.md" || iso_finish_rc=$?
            log "Cleanup (isolated): $ISOLATED_RESULT"
        elif ! git -C "$WORKSPACE" diff --quiet -- inbox/fleeting-notes.md archive/notes/Notes-Archive.md 2>/dev/null; then
            git -C "$WORKSPACE" add inbox/fleeting-notes.md archive/notes/Notes-Archive.md
            # WP-7 Ф101: same ds-publish.sh move as the main push block above,
            # plus an explicit commit-result check — `|| true` here used to
            # swallow a failed commit while still reporting "Cleanup: pushed"
            # for a commit that never happened.
            if git -C "$WORKSPACE" commit -m "chore: auto-cleanup processed notes from fleeting-notes.md" >> "$LOG_FILE" 2>&1; then
                cleanup_sha=$(git -C "$WORKSPACE" rev-parse HEAD)
                publish_commit_or_explain "strategist: cleanup" "$cleanup_sha" \
                    "Cleanup: pushed" "WARN: cleanup ds-publish.sh failed" || true
            else
                log "WARN: cleanup git commit failed"
            fi
        else
            log "Cleanup: no changes to commit"
        fi

        # Alert if the LLM did not process the new notes (only NEW bold: not deferred 🔄, not already ✅предложено)
        if [ "$BOLD_NEW_AFTER" -ge "$BOLD_NEW_BEFORE" ] && [ "$BOLD_NEW_BEFORE" -gt 0 ]; then
            ENV_FILE="$HOME/.config/aist/env"
            if [ -f "$ENV_FILE" ]; then
                set -a; source "$ENV_FILE"; set +a
                ALERT_TEXT="⚠️ <b>Note-Review canary</b>: разбор не пометил новые заметки ✅предложено ($BOLD_NEW_BEFORE → $BOLD_NEW_AFTER новых жирных). Заметки остаются в inbox до решения пилота."
                ALERT_JSON=$(printf '%s' "$ALERT_TEXT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
                curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
                    -H "Content-Type: application/json" \
                    -d "{\"chat_id\":\"${TELEGRAM_CHAT_ID}\",\"text\":${ALERT_JSON},\"parse_mode\":\"HTML\"}" >> "$LOG_FILE" 2>&1 || true
            fi
        fi

        [ "$iso_finish_rc" -eq 0 ] || { log "FAILED scenario: note-review (rc=$iso_finish_rc) -- изолированный результат не опубликован"; exit "$iso_finish_rc"; }
        notify_telegram "note-review"
        ;;
    "day-close")
        log "Manual: running day close"
        run_claude "day-close" "claude-sonnet-4-6"
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
        echo "  note-review       - manual only: marks notes ✅предложено and writes proposals; the archive needs a live session with the pilot"
        echo "  week-review       - Sunday 19:00 EET review for club"
        echo "  session-prep      - Manual session prep (headless preparation)"
        echo "  strategy-session  - Manual strategy session (interactive with user)"
        echo "  day-plan          - Manual day plan"
        echo "  day-close         - Manual day close (update WeekPlan + MEMORY + backup)"
        exit 1
        ;;
esac

log "Done"
