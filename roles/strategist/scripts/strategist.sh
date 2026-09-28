#!/bin/bash
# Strategist (Стратег) Agent Runner
# Запускает Claude Code с заданным сценарием

set -e

# issue #657: this script needs more than one independent EXIT cleanup (kill
# the sleep inhibitor below; remove acquire_lock()'s concurrency lock
# directory further down) — plain `trap ... EXIT` only keeps the LAST
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
# agent run started mid-update at 22:38. Skip every scenario while an update
# is open; the next scheduled run picks it up. Template root is resolved as
# $IWE_TEMPLATE first, then ${IWE_WORKSPACE:-$HOME/IWE}/FMT-exocortex-template
# (NOT identical to the PROMPTS_DIR fallback below, which hardcodes $HOME/IWE).
UPDATE_MARKER="${IWE_TEMPLATE:-${IWE_WORKSPACE:-$HOME/IWE}/FMT-exocortex-template}/.update-incomplete"
if [ -f "$UPDATE_MARKER" ]; then
    echo "[$(date '+%H:%M:%S')] SKIP: template update in progress ($UPDATE_MARKER present) — no mutating run during update" >&2
    exit 0
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

# Publish one commit via scripts/ds-publish.sh. The script is not shipped with
# the template (issue #884, regression of WP-7 Ф101): when it is absent, say so
# and keep the commit local instead of failing on a bare "No such file".
# Returns 0 only when the publisher reported success.
publish_commit_or_explain() {
    local reason="$1" sha="$2" ok_msg="$3" fail_msg="$4"
    local publisher="$WORKSPACE/scripts/ds-publish.sh"

    if [ ! -f "$publisher" ]; then
        log "WARN: scripts/ds-publish.sh не установлен — коммит ${sha:0:12} остался локальным и не опубликован. Опубликуйте вручную: git -C \"$WORKSPACE\" push origin HEAD"
        return 1
    fi
    if bash "$publisher" "$WORKSPACE" normal --reason "$reason" --from-commit "$sha" >> "$LOG_FILE" 2>&1; then
        log "$ok_msg"
        return 0
    fi
    log "$fail_msg"
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
    mkdir -p "$WORKSPACE/$scope"
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
    prompt="[Системный контекст] Сегодня: ${ru_date_context}. ISO: ${DATE}. День недели №${DAY_OF_WEEK} (1=Пн..7=Вс). Первый Пн месяца: ${IS_FIRST_MONDAY_OF_MONTH} (посчитано командой date, не выводи это значение сам — issue #616). ЯЗЫК: отвечай ТОЛЬКО на русском. Украинский, английский и другие языки запрещены.

${prompt}"

    log "Starting scenario: $command_file"
    log "Command file: $command_path"
    log "Date context: $ru_date_context"

    cd "$WORKSPACE"

    # WP-561 Ф25: origin/main до запуска модели, точка отсчёта для постусловия доставки.
    local delivery_pre_origin
    delivery_pre_origin=$(delivery_baseline "$command_file")

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
    # AR.293: AI_CLI_EXTRA_FLAGS — точка подмены на случай, когда AI_CLI указывает
    # не на Claude Code (--model/--allowedTools — его флаги, не переносимы как есть).
    # Дефолт воспроизводит прежнее поведение один в один.
    local extra_flags
    if [ -n "${AI_CLI_EXTRA_FLAGS:-}" ]; then
        # намеренный word-splitting единой override-строки — тот же контракт,
        # что уже принят в extractor.sh
        read -ra extra_flags <<< "$AI_CLI_EXTRA_FLAGS"
    else
        extra_flags=("${model_args[@]}" --allowedTools "Read,Write,Edit,Glob,Grep,Bash,${calendar_mcp}")
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
    if git -C "$WORKSPACE" diff --quiet origin/main..HEAD 2>/dev/null; then
        log "No unpushed commits"
    else
        # WP-7 Ф101: raw pull --rebase + push on a checkout shared with
        # concurrent agent sessions routinely hit a dirty tree or a
        # non-fast-forward push and silently dropped the commit (found via a
        # W36 week-review that never reached origin/main). ds-publish.sh
        # isolates this exact commit into a disposable worktree instead of
        # waiting for a clean window.
        local push_sha
        push_sha=$(git -C "$WORKSPACE" rev-parse HEAD)
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
    if [ "$rc" -eq 0 ]; then
        printf '%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "SUCCESS" "$rc" > "$status_file"
    else
        printf '%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "FAILED" "$rc" > "$status_file"
        log "RECORDED: $command_file failed with rc=$rc (see $status_file)"
    fi

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
    add_exit_cleanup "rm -rf \"$lockdir\" 2>/dev/null"
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
            run_claude "session-prep" "claude-sonnet-4-6"
            notify_telegram "session-prep"
        else
            # Canonical Day Open pipeline: deterministic scaffold (reads priorities.yaml,
            # enforces ТВС section order, runs server-news.sh for «Мир»). The free-form
            # prompt is fallback ONLY — it ignores priorities.yaml and the scaffold, which
            # was the root cause of the 2026-06-21 structure/priority drift.
            log "Morning: running canonical Day Open pipeline"
            # $IWE_SCRIPTS first (matches the interactive day-open skill's own
            # resolution order), $WORKSPACE/scripts/ as legacy fallback for
            # installs that still deliver a workspace-root copy. #598: this
            # function used to read $WORKSPACE only, so $IWE_SCRIPTS-only
            # installs fell back to free-form silently, every morning, with
            # no escalation (found live: 37 consecutive days, 88 runs).
            DAY_OPEN_PIPELINE="${IWE_SCRIPTS:-}/day-open-pipeline.sh"
            if [ -z "${IWE_SCRIPTS:-}" ] || [ ! -f "$DAY_OPEN_PIPELINE" ]; then
                DAY_OPEN_PIPELINE="$WORKSPACE/scripts/day-open-pipeline.sh"
            fi
            if [ ! -f "$DAY_OPEN_PIPELINE" ]; then
                # WP-529 F6: on user installs workspace-root scripts/ is not
                # delivered at all (Evgenii defects #2/#3, 18.08) — say so
                # instead of a generic "unavailable/failed". The delivery
                # graph itself is WP-529 F7 scope, no silent bridge here.
                log "WARN: Day Open pipeline not found at \$IWE_SCRIPTS or $WORKSPACE/scripts — canonical pipeline is not delivered on this install (WP-529 F7); fallback to free-form day-plan prompt"
                run_claude "day-plan" "claude-sonnet-4-6"
                notify_telegram "day-plan"
            elif bash "$DAY_OPEN_PIPELINE" >> "$LOG_FILE" 2>&1; then
                log "Morning: Day Open pipeline OK (scaffold + llm-fill)"
            else
                pipeline_rc=$?
                # issue #893: exit 9 = no gateway configured (day-open-pipeline.sh
                # §2), a case the pipeline itself already ships an answer for
                # (--scaffold-only, issue #434) — retry with it instead of
                # falling all the way to the free-form prompt, which ignores
                # priorities.yaml and the scaffold (the #877 continuation:
                # after #885 the message changed from HTTP 401 to "not
                # configured", but strategist.sh still never used the escape
                # hatch the pipeline's own error text already pointed at).
                if [ "$pipeline_rc" -eq 9 ]; then
                    log "Morning: Day Open pipeline has no gateway configured — retrying with --scaffold-only"
                    if bash "$DAY_OPEN_PIPELINE" --scaffold-only >> "$LOG_FILE" 2>&1; then
                        log "Morning: Day Open pipeline OK (scaffold only, no gateway)"
                    else
                        log "WARN: Day Open pipeline --scaffold-only also failed (see lines above in this log) — fallback to free-form day-plan prompt"
                        run_claude "day-plan" "claude-sonnet-4-6"
                        notify_telegram "day-plan"
                    fi
                else
                    log "WARN: Day Open pipeline failed (see lines above in this log) — fallback to free-form day-plan prompt"
                    run_claude "day-plan" "claude-sonnet-4-6"
                    notify_telegram "day-plan"
                fi
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
            # the alarms and the FAILED status already tell the owner (exit 0 makes the scheduler
            # mark the week done, so a rerun after the fix is by hand). RECORDED is written once
            # per dispatch, unlike FAILED, which repeats on every auth retry inside one.
            if [ "$(grep -c 'RECORDED: week-review failed' "$LOG_FILE")" -ge "$WEEK_REVIEW_MAX_FAILED_RUNS" ]; then
                log "GAVE UP scenario: week-review after $WEEK_REVIEW_MAX_FAILED_RUNS failed runs today; exit 0 marks the week done for the scheduler, so rerun it by hand once the cause is fixed"
                exit 0
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
        log "Evening: running note review"
        # Canary: count bold notes before (exclude 🔄 — deferred ideas stay bold by design)
        # NB: `grep -c` при exit 1 (no matches) печатает "0" до `||`, так что `|| echo 0`
        # давал двухстрочный "0\n0" и ломал арифметику. Используем `|| true` + fallback.
        FLEETING="$WORKSPACE/inbox/fleeting-notes.md"
        BOLD_BEFORE=$(grep -c '^\*\*' "$FLEETING" 2>/dev/null || true); BOLD_BEFORE=${BOLD_BEFORE:-0}
        BOLD_NEW_BEFORE=$(grep -vc '🔄' <(grep '^\*\*' "$FLEETING" 2>/dev/null) 2>/dev/null || true); BOLD_NEW_BEFORE=${BOLD_NEW_BEFORE:-0}
        log "Canary: $BOLD_BEFORE bold total ($BOLD_NEW_BEFORE new, $(( BOLD_BEFORE - BOLD_NEW_BEFORE )) deferred 🔄)"

        acquire_captures_write_lock || true
        run_claude "note-review" "claude-haiku-4-5-20251001"

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
        if [ -n "$cleanup_python3" ]; then
            CLEANUP_OUTPUT=$("$cleanup_python3" "$cleanup_script" 2>&1) || true
        else
            CLEANUP_OUTPUT="no python3 interpreter found — skipped"
        fi
        log "Cleanup: $CLEANUP_OUTPUT"

        # If cleanup made changes, commit and push
        if ! git -C "$WORKSPACE" diff --quiet -- inbox/fleeting-notes.md archive/notes/Notes-Archive.md 2>/dev/null; then
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
